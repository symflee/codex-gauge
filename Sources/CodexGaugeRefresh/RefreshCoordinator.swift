import CodexGaugeCore
import CodexGaugeProtocol
import Foundation

public actor RefreshCoordinator {
    public private(set) var state: RefreshState
    public private(set) var publication = RefreshPublication.initial

    private let provider: any RefreshSessionProviding
    private let clock: any RefreshClock
    private let sampleSelector: any SelectedQuotaSampleSelecting
    private let publicationDelivery: RefreshPublicationDelivery
    private var publicationRevision: UInt64 = 0
    private var latestPublicationTicket: RefreshPublicationTicket?
    private let reducer = RefreshReducer()

    private var displayPreference: DisplayPreference
    private var timerTask: Task<Void, Never>?
    private var timerPurpose: RefreshTimerPurpose?
    private var nextSystemResumeGeneration: UInt64 = 0
    private var isSuspendedForSystem = false
    private var pendingSystemResumeReset = false
    private var requestTask: Task<Void, Never>?
    private var requestGeneration: UInt64?
    private var activeSession: RefreshSessionLease?
    private var acquisitionGeneration: UInt64?
    private var stoppingSessionGeneration: UInt64?
    private var stopAttemptTask: Task<UsageSessionStopResult, Never>?
    private var terminationTask: Task<Void, Never>?
    private var terminationBarrier: Task<Void, Never>?
    private var terminationContinuation: CheckedContinuation<Void, Never>?
    private var nextSessionGeneration: UInt64 = 0
    private var lifecycleGeneration: UInt64 = 0
    private var profileChangeGeneration: UInt64 = 0
    private var powerChangeGeneration: UInt64 = 0

    public init(
        provider: any RefreshSessionProviding,
        clock: any RefreshClock = SystemRefreshClock(),
        sampleSelector: any SelectedQuotaSampleSelecting = DisplayPreferenceQuotaSampleSelector(),
        profile: RefreshProfile = .default,
        lowPowerModeEnabled: Bool = false,
        displayPreference: DisplayPreference = .default,
        publicationHandler: RefreshPublicationHandler? = nil
    ) {
        self.provider = provider
        self.clock = clock
        self.sampleSelector = sampleSelector
        self.state = RefreshState(
            profile: profile,
            lowPowerModeEnabled: lowPowerModeEnabled
        )
        self.displayPreference = displayPreference
        self.publicationDelivery = RefreshPublicationDelivery(handler: publicationHandler)
    }

    public func start() async {
        lifecycleGeneration += 1
        let generation = lifecycleGeneration
        isSuspendedForSystem = false
        pendingSystemResumeReset = false
        invalidateSystemResume()
        let instant = await clock.now()
        guard lifecycleGeneration == generation, !Task.isCancelled else { return }
        await process(.start(at: instant))
    }

    public func refreshManually() async {
        let generation = lifecycleGeneration
        let instant = await clock.now()
        guard lifecycleGeneration == generation, !Task.isCancelled else { return }
        await process(.manualRefresh(at: instant))
    }

    public func establishWakeBaseline() async {
        let generation = lifecycleGeneration
        let instant = await clock.now()
        guard lifecycleGeneration == generation, !Task.isCancelled else { return }
        await process(.wakeBaseline(at: instant))
    }

    public func refreshAfterQuotaReset() async {
        guard !isSuspendedForSystem else {
            pendingSystemResumeReset = true
            return
        }
        let generation = lifecycleGeneration
        let instant = await clock.now()
        guard lifecycleGeneration == generation, !Task.isCancelled else { return }
        await process(.quotaReset(at: instant))
    }

    public func updateProfile(_ profile: RefreshProfile) async {
        profileChangeGeneration += 1
        let generation = profileChangeGeneration
        let instant = await clock.now()
        guard profileChangeGeneration == generation, !Task.isCancelled else { return }
        await process(.profileChanged(profile: profile, at: instant))
    }

    public func setLowPowerMode(_ isEnabled: Bool) async {
        powerChangeGeneration += 1
        let generation = powerChangeGeneration
        let instant = await clock.now()
        guard powerChangeGeneration == generation, !Task.isCancelled else { return }
        await process(.lowPowerModeChanged(isEnabled: isEnabled, at: instant))
    }

    public func updateLowPowerMode(isEnabled: Bool) async {
        await setLowPowerMode(isEnabled)
    }

    public func updateDisplayPreference(_ preference: DisplayPreference) {
        displayPreference = preference
    }

    public func suspend() async {
        guard !isSuspendedForSystem else {
            return
        }
        lifecycleGeneration += 1
        let generation = lifecycleGeneration
        isSuspendedForSystem = true
        pendingSystemResumeReset = false
        invalidateSystemResume()
        cancelAnyTimer()
        let instant = await clock.now()
        guard lifecycleGeneration == generation else { return }
        await process(.suspend(at: instant))
    }

    public func resumeAfterSystemWake() async {
        guard isSuspendedForSystem, state.isRunning == false else {
            return
        }
        if case .systemResume = timerPurpose {
            return
        }
        nextSystemResumeGeneration += 1
        let generation = nextSystemResumeGeneration
        let instant = await clock.now()
        guard state.isRunning == false, generation == nextSystemResumeGeneration else {
            return
        }
        installSystemResume(
            generation: generation,
            deadline: instant.advanced(by: .seconds(5))
        )
    }

    public func isAwaitingSystemResume() -> Bool {
        if case .systemResume = timerPurpose {
            return true
        }
        return false
    }

    public func stop() async {
        lifecycleGeneration += 1
        isSuspendedForSystem = false
        pendingSystemResumeReset = false
        invalidateSystemResume()
        cancelAnyTimer()
        await process(.stop)
    }

    /// Call after stop(), before replacing this coordinator. A factory result
    /// that arrives after cancellation is also owned until its cleanup finishes.
    public func waitForTermination() async {
        guard !hasRetiredAllSessions else { return }
        if let terminationBarrier {
            await terminationBarrier.value
            return
        }
        let barrier = Task {
            await withCheckedContinuation { continuation in
                terminationContinuation = continuation
                finishTerminationBarrierIfIdle()
            }
        }
        terminationBarrier = barrier
        await barrier.value
    }

    private var hasRetiredAllSessions: Bool {
        acquisitionGeneration == nil && activeSession == nil && state.inFlightRequest == nil
    }

    private func finishTerminationBarrierIfIdle() {
        guard hasRetiredAllSessions else { return }
        let continuation = terminationContinuation
        terminationContinuation = nil
        terminationBarrier = nil
        continuation?.resume()
    }

    private func process(_ event: RefreshEvent) async {
        let transition = reducer.reduce(state: state, event: event)
        state = transition.state
        let ticket = commitPublication(publication.settingRefreshing(state.inFlightRequest != nil))
        execute(transition.commands)
        closeIdleSession()
        finishTerminationBarrierIfIdle()
        let cleanup = stopAttemptTask
        await deliver(ticket)
        // Await only this transition's bounded stop attempt. An unconfirmed
        // process retains its lease and exit waiter without blocking new events.
        if let cleanup { _ = await cleanup.value }
    }

    private func execute(_ commands: [RefreshCommand]) {
        for command in commands {
            switch command {
            case let .startRequest(request): startRequest(request)
            case let .scheduleRefresh(schedule): installSchedule(schedule)
            case let .cancelRequest(generation): cancelRequest(generation)
            case let .cancelScheduledRefresh(generation): cancelSchedule(generation)
            }
        }
    }

    private func startRequest(_ request: RefreshRequest) {
        // state.inFlightRequest is also the single coalesced pending request
        // while a factory or the previous process is still being retired.
        guard state.inFlightRequest?.generation == request.generation,
              requestTask == nil,
              acquisitionGeneration == nil,
              stoppingSessionGeneration == nil else { return }
        requestGeneration = request.generation
        let retainedSession = activeSession
        let ticket = latestPublicationTicket
        let delivery = publicationDelivery
        requestTask = Task { [weak self] in
            if let ticket { await delivery.deliver(ticket) }
            guard let self else { return }
            await self.perform(request, retainedSession: retainedSession)
        }
    }

    private func perform(
        _ request: RefreshRequest,
        retainedSession: RefreshSessionLease?
    ) async {
        var session = retainedSession
        do {
            guard await admitRequest(request) else { return }
            let acquired = try await acquireSession(for: request, retained: session)
            session = acquired
            guard await admitRequest(request) else { return }
            try Task.checkCancellation()
            guard isCurrentRequest(request.generation) else { throw CancellationError() }
            if retainedSession == nil {
                try await acquired.session.start()
            }
            try Task.checkCancellation()
            let capturedAt = await clock.currentDate()
            guard await admitRequest(request) else { return }
            try Task.checkCancellation()
            guard isCurrentRequest(request.generation) else { throw CancellationError() }
            let result = try await acquired.session.readRateLimits(capturedAt: capturedAt)
            guard result.responseStatus == .accepted else {
                throw RefreshResponseValidationError.incompatible
            }
            try Task.checkCancellation()
            let instant = await clock.now()
            await requestSucceeded(request, result: result, at: instant)
        } catch {
            let wasCancelled = Task.isCancelled || error is CancellationError
            let instant = await clock.now()
            await requestFailed(
                request,
                session: session,
                error: error,
                wasCancelled: wasCancelled,
                at: instant
            )
        }
    }

    private func admitRequest(_ request: RefreshRequest) async -> Bool {
        let instant = await clock.now()
        guard isCurrentRequest(request.generation), !Task.isCancelled else { return false }
        let transition = reducer.reduce(
            state: state,
            event: .requestAdmission(generation: request.generation, at: instant)
        )
        state = transition.state
        guard state.inFlightRequest?.generation != request.generation else { return true }
        requestTask = nil
        requestGeneration = nil
        let ticket = commitPublication(publication.settingRefreshing(false))
        execute(transition.commands)
        closeIdleSession()
        finishTerminationBarrierIfIdle()
        let cleanup = stopAttemptTask
        await deliver(ticket)
        if let cleanup { _ = await cleanup.value }
        return false
    }

    private func acquireSession(
        for request: RefreshRequest,
        retained: RefreshSessionLease?
    ) async throws -> RefreshSessionLease {
        guard isCurrentRequest(request.generation), !Task.isCancelled else { throw CancellationError() }
        if let retained { return retained }
        acquisitionGeneration = request.generation
        let created: any RefreshUsageSession
        do {
            created = try await provider.makeSession()
        } catch {
            if acquisitionGeneration == request.generation {
                acquisitionGeneration = nil
                if !isCurrentRequest(request.generation) { startPendingRequest() }
                finishTerminationBarrierIfIdle()
            }
            throw error
        }
        guard acquisitionGeneration == request.generation else {
            // Every acquisition is serialized until its result is retired.
            preconditionFailure("Unexpected overlapping session acquisition")
        }
        acquisitionGeneration = nil
        nextSessionGeneration += 1
        let lease = RefreshSessionLease(generation: nextSessionGeneration, session: created)
        activeSession = lease
        guard isCurrentRequest(request.generation), !Task.isCancelled else {
            closeSession(lease)
            throw CancellationError()
        }
        return lease
    }

    private func requestSucceeded(
        _ request: RefreshRequest,
        result: RateLimitReadResult,
        at instant: ContinuousClock.Instant
    ) async {
        guard isCurrentRequest(request.generation) else {
            return
        }
        if let deadline = state.burstDeadline, instant >= deadline,
           let schedule = state.scheduledRefresh {
            await scheduledRefreshFired(schedule.generation, at: instant)
            return
        }
        requestTask = nil
        requestGeneration = nil
        let samples = sampleSelector.samples(from: result, preference: displayPreference)
        let transition = reducer.reduce(
            state: state,
            event: .requestSucceeded(
                generation: request.generation,
                samples: samples,
                at: instant
            )
        )
        state = transition.state
        let ticket = commitPublication(
            publication.applying(result).settingRefreshing(state.inFlightRequest != nil)
        )
        execute(transition.commands)
        closeIdleSession()
        finishTerminationBarrierIfIdle()
        let cleanup = stopAttemptTask
        await deliver(ticket)
        if let cleanup { _ = await cleanup.value }
    }

    private func requestFailed(
        _ request: RefreshRequest,
        session: RefreshSessionLease?,
        error: any Error,
        wasCancelled: Bool,
        at instant: ContinuousClock.Instant
    ) async {
        guard isCurrentRequest(request.generation), wasCancelled == false else {
            return
        }
        requestTask = nil
        requestGeneration = nil
        let classification = RefreshFailureClassification(error)
        let event = classification.event(generation: request.generation, at: instant)
        let transition = reducer.reduce(state: state, event: event)
        state = transition.state
        let ticket = commitPublication(
            publication.applying(classification.failure).settingRefreshing(state.inFlightRequest != nil)
        )
        if let session { closeSession(session) }
        execute(transition.commands)
        closeIdleSession()
        finishTerminationBarrierIfIdle()
        let cleanup = stopAttemptTask
        await deliver(ticket)
        if let cleanup { _ = await cleanup.value }
    }

    private func isCurrentRequest(_ generation: UInt64) -> Bool {
        requestGeneration == generation
            && state.inFlightRequest?.generation == generation
    }

    private func cancelRequest(_ generation: UInt64) {
        guard requestGeneration == generation else { return }
        requestTask?.cancel()
        requestTask = nil
        requestGeneration = nil
        if let session = activeSession { closeSession(session) }
    }

    private func installSchedule(_ schedule: RefreshSchedule) {
        guard timerPurpose != .refresh(schedule.generation) else { return }
        timerTask?.cancel()
        timerPurpose = .refresh(schedule.generation)
        let clock = self.clock
        timerTask = Task { [weak self] in
            do {
                try await clock.sleep(until: schedule.deadline)
                let instant = await clock.now()
                await self?.scheduledRefreshFired(schedule.generation, at: instant)
            } catch {
                return
            }
        }
    }

    private func cancelSchedule(_ generation: UInt64) {
        guard timerPurpose == .refresh(generation) else {
            return
        }
        cancelAnyTimer()
    }

    private func scheduledRefreshFired(
        _ generation: UInt64,
        at instant: ContinuousClock.Instant
    ) async {
        guard timerPurpose == .refresh(generation) else {
            return
        }
        timerTask = nil
        timerPurpose = nil
        await process(.scheduledRefreshFired(generation: generation, at: instant))
    }

    private func installSystemResume(
        generation: UInt64,
        deadline: ContinuousClock.Instant
    ) {
        timerTask?.cancel()
        timerPurpose = .systemResume(generation)
        let clock = self.clock
        timerTask = Task { [weak self] in
            do {
                try await clock.sleep(until: deadline)
                let instant = await clock.now()
                await self?.systemResumeTimerFired(generation, at: instant)
            } catch {
                return
            }
        }
    }

    private func systemResumeTimerFired(
        _ generation: UInt64,
        at instant: ContinuousClock.Instant
    ) async {
        guard timerPurpose == .systemResume(generation) else {
            return
        }
        timerTask = nil
        timerPurpose = nil
        isSuspendedForSystem = false
        let shouldApplyReset = pendingSystemResumeReset
        pendingSystemResumeReset = false
        let lifecycle = lifecycleGeneration
        await process(.resumeAfterSystemWake(at: instant))
        guard lifecycleGeneration == lifecycle, shouldApplyReset else {
            return
        }
        await process(.quotaReset(at: instant))
    }

    private func invalidateSystemResume() {
        nextSystemResumeGeneration += 1
        if case .systemResume = timerPurpose {
            cancelAnyTimer()
        }
    }

    private func cancelAnyTimer() {
        timerTask?.cancel()
        timerTask = nil
        timerPurpose = nil
    }

    private func closeIdleSession() {
        guard state.inFlightRequest == nil, state.burstDeadline == nil,
              let session = activeSession else { return }
        closeSession(session)
    }

    private func closeSession(_ lease: RefreshSessionLease) {
        guard activeSession?.generation == lease.generation,
              stoppingSessionGeneration == nil else { return }
        stoppingSessionGeneration = lease.generation
        let ticket = latestPublicationTicket
        let delivery = publicationDelivery
        stopAttemptTask = Task { [weak self] in
            if let ticket { await delivery.deliver(ticket) }
            let result = await lease.session.stop()
            await self?.stopAttemptCompleted(lease, result: result)
            return result
        }
    }

    private func stopAttemptCompleted(_ lease: RefreshSessionLease, result: UsageSessionStopResult) {
        guard stoppingSessionGeneration == lease.generation else { return }
        stopAttemptTask = nil
        switch result {
        case .exited:
            sessionTerminationConfirmed(lease.generation)
        case .unconfirmed:
            terminationTask = Task { [weak self] in
                await lease.session.waitForTermination()
                await self?.sessionTerminationConfirmed(lease.generation)
            }
        }
    }

    private func sessionTerminationConfirmed(_ generation: UInt64) {
        guard stoppingSessionGeneration == generation,
              activeSession?.generation == generation else { return }
        activeSession = nil
        stoppingSessionGeneration = nil
        terminationTask = nil
        startPendingRequest()
        finishTerminationBarrierIfIdle()
    }

    private func startPendingRequest() {
        guard let pending = state.inFlightRequest else { return }
        startRequest(pending)
    }

    private func commitPublication(_ value: RefreshPublication) -> RefreshPublicationTicket? {
        guard publication != value else { return nil }
        publication = value
        publicationRevision += 1
        let ticket = RefreshPublicationTicket(revision: publicationRevision, value: value)
        latestPublicationTicket = ticket
        return ticket
    }

    private func deliver(_ ticket: RefreshPublicationTicket?) async {
        guard let ticket else { return }
        await publicationDelivery.deliver(ticket)
    }
}

private struct RefreshPublicationTicket: Sendable {
    let revision: UInt64
    let value: RefreshPublication
}

@MainActor
private final class RefreshPublicationDelivery {
    private let handler: RefreshPublicationHandler?
    private var deliveredRevision: UInt64 = 0

    nonisolated init(handler: RefreshPublicationHandler?) {
        self.handler = handler
    }

    func deliver(_ ticket: RefreshPublicationTicket) {
        // Actor hops may arrive out of order. A state transition is delivered
        // once, and an older transition can never overwrite a newer one.
        guard ticket.revision > deliveredRevision else { return }
        deliveredRevision = ticket.revision
        handler?(ticket.value)
    }
}

private struct RefreshSessionLease: Sendable {
    let generation: UInt64
    let session: any RefreshUsageSession
}

private enum RefreshTimerPurpose: Equatable, Sendable {
    case refresh(UInt64)
    case systemResume(UInt64)
}

private struct RefreshFailureClassification {
    let failure: RefreshFailure
    let isTransient: Bool

    init(_ error: any Error) {
        if error is RefreshResponseValidationError {
            self.init(failure: .protocolIncompatible, isTransient: false)
            return
        }
        if let locationError = error as? CodexLocationError {
            self = Self.location(locationError)
            return
        }
        if let sessionError = error as? UsageSessionError {
            self = Self.session(sessionError)
            return
        }
        self.init(failure: .connectionInterrupted, isTransient: true)
    }

    init(failure: RefreshFailure, isTransient: Bool) {
        self.failure = failure
        self.isTransient = isTransient
    }

    func event(
        generation: UInt64,
        at instant: ContinuousClock.Instant
    ) -> RefreshEvent {
        guard isTransient else {
            return .terminalFailure(generation: generation, at: instant)
        }
        return .transientFailure(generation: generation, at: instant)
    }

    private static func location(
        _ error: CodexLocationError
    ) -> RefreshFailureClassification {
        switch error {
        case .notFound:
            RefreshFailureClassification(failure: .codexNotFound, isTransient: false)
        case .invalidSelection:
            RefreshFailureClassification(failure: .invalidCodexSelection, isTransient: false)
        }
    }

    private static func session(
        _ error: UsageSessionError
    ) -> RefreshFailureClassification {
        switch error {
        case .timeout:
            RefreshFailureClassification(failure: .timeout, isTransient: true)
        case .launchFailed:
            RefreshFailureClassification(failure: .processUnavailable, isTransient: true)
        case .processFailed, .endOfFile, .stopped, .cancelled:
            RefreshFailureClassification(failure: .connectionInterrupted, isTransient: true)
        case .signedOut:
            RefreshFailureClassification(failure: .signedOut, isTransient: false)
        case .unsupportedAuth:
            RefreshFailureClassification(failure: .unsupportedAuthentication, isTransient: false)
        case .unsupportedVersion, .protocolIncompatible, .malformedResponse, .responseTooLarge:
            RefreshFailureClassification(failure: .protocolIncompatible, isTransient: false)
        case .notStarted, .requestInProgress, .requestIdentifierExhausted:
            RefreshFailureClassification(failure: .protocolIncompatible, isTransient: false)
        case let .rpcFailure(code):
            rpcFailure(code)
        }
    }

    private static func rpcFailure(_ code: Int) -> RefreshFailureClassification {
        switch code {
        case -32_700, -32_600, -32_601, -32_602:
            RefreshFailureClassification(failure: .protocolIncompatible, isTransient: false)
        default:
            RefreshFailureClassification(failure: .server(code: code), isTransient: true)
        }
    }
}

private enum RefreshResponseValidationError: Error {
    case incompatible
}
