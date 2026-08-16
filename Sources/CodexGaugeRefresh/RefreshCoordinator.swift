import CodexGaugeCore
import CodexGaugeProtocol
import Foundation

public actor RefreshCoordinator {
    public private(set) var state: RefreshState
    public private(set) var publication = RefreshPublication.initial

    private let provider: any RefreshSessionProviding
    private let clock: any RefreshClock
    private let sampleSelector: any SelectedQuotaSampleSelecting
    private let publicationHandler: RefreshPublicationHandler?
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
    private var nextSessionGeneration: UInt64 = 0

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
        self.publicationHandler = publicationHandler
    }

    public func start() async {
        isSuspendedForSystem = false
        pendingSystemResumeReset = false
        invalidateSystemResume()
        let instant = await clock.now()
        await process(.start(at: instant))
    }

    public func refreshManually() async {
        let instant = await clock.now()
        await process(.manualRefresh(at: instant))
    }

    public func establishWakeBaseline() async {
        let instant = await clock.now()
        await process(.wakeBaseline(at: instant))
    }

    public func refreshAfterQuotaReset() async {
        guard !isSuspendedForSystem else {
            pendingSystemResumeReset = true
            return
        }
        let instant = await clock.now()
        await process(.quotaReset(at: instant))
    }

    public func updateProfile(_ profile: RefreshProfile) async {
        let instant = await clock.now()
        await process(.profileChanged(profile: profile, at: instant))
    }

    public func setLowPowerMode(_ isEnabled: Bool) async {
        let instant = await clock.now()
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
        isSuspendedForSystem = true
        pendingSystemResumeReset = false
        invalidateSystemResume()
        cancelAnyTimer()
        await process(.stop)
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
        isSuspendedForSystem = false
        pendingSystemResumeReset = false
        invalidateSystemResume()
        cancelAnyTimer()
        await process(.stop)
    }

    private func process(_ event: RefreshEvent) async {
        let originalPublication = publication
        let transition = reducer.reduce(state: state, event: event)
        state = transition.state
        var sessionsToStop = execute(transition.commands)
        appendIdleSession(to: &sessionsToStop)
        publication = publication.settingRefreshing(state.inFlightRequest != nil)
        await stop(sessionsToStop)
        await publishIfChanged(from: originalPublication)
    }

    private func execute(
        _ commands: [RefreshCommand]
    ) -> [any RefreshUsageSession] {
        var sessionsToStop = [any RefreshUsageSession]()
        for command in commands {
            if let session = execute(command) {
                sessionsToStop.append(session)
            }
        }
        return sessionsToStop
    }

    private func execute(
        _ command: RefreshCommand
    ) -> (any RefreshUsageSession)? {
        switch command {
        case let .startRequest(request):
            startRequest(request)
            return nil
        case let .scheduleRefresh(schedule):
            installSchedule(schedule)
            return nil
        case let .cancelRequest(generation):
            return cancelRequest(generation)
        case let .cancelScheduledRefresh(generation):
            cancelSchedule(generation)
            return nil
        }
    }

    private func startRequest(_ request: RefreshRequest) {
        guard requestTask == nil else {
            return
        }
        requestGeneration = request.generation
        let retainedSession = activeSession
        requestTask = Task { [weak self] in
            guard let self else {
                await retainedSession?.session.stop()
                return
            }
            await self.perform(request, retainedSession: retainedSession)
        }
    }

    private func perform(
        _ request: RefreshRequest,
        retainedSession: RefreshSessionLease?
    ) async {
        var session = retainedSession
        do {
            let acquired = try await acquireSession(for: request, retained: session)
            session = acquired
            try Task.checkCancellation()
            if retainedSession == nil {
                try await acquired.session.start()
            }
            try Task.checkCancellation()
            let capturedAt = await clock.currentDate()
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

    private func acquireSession(
        for request: RefreshRequest,
        retained: RefreshSessionLease?
    ) async throws -> RefreshSessionLease {
        if let retained {
            return retained
        }
        let created = try await provider.makeSession()
        guard let registered = register(created, for: request) else {
            await created.stop()
            throw CancellationError()
        }
        return registered
    }

    private func register(
        _ session: any RefreshUsageSession,
        for request: RefreshRequest
    ) -> RefreshSessionLease? {
        guard isCurrentRequest(request.generation), activeSession == nil else {
            return nil
        }
        nextSessionGeneration += 1
        let lease = RefreshSessionLease(
            generation: nextSessionGeneration,
            session: session
        )
        activeSession = lease
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
        publication = publication.applying(result)
        var sessionsToStop = execute(transition.commands)
        appendIdleSession(to: &sessionsToStop)
        await stop(sessionsToStop)
        await publishCurrent()
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
        let failedSession = detachSession(session)
        let classification = RefreshFailureClassification(error)
        let event = classification.event(generation: request.generation, at: instant)
        let transition = reducer.reduce(state: state, event: event)
        state = transition.state
        publication = publication.applying(classification.failure)
        var sessionsToStop = execute(transition.commands)
        if let failedSession {
            sessionsToStop.append(failedSession)
        }
        appendIdleSession(to: &sessionsToStop)
        await stop(sessionsToStop)
        await publishCurrent()
    }

    private func isCurrentRequest(_ generation: UInt64) -> Bool {
        requestGeneration == generation
            && state.inFlightRequest?.generation == generation
    }

    private func cancelRequest(
        _ generation: UInt64
    ) -> (any RefreshUsageSession)? {
        guard requestGeneration == generation else {
            return nil
        }
        requestTask?.cancel()
        requestTask = nil
        requestGeneration = nil
        let session = activeSession
        activeSession = nil
        return session?.session
    }

    private func installSchedule(_ schedule: RefreshSchedule) {
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
        await process(.resumeAfterSystemWake(at: instant))
        guard shouldApplyReset else {
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

    private func appendIdleSession(
        to sessions: inout [any RefreshUsageSession]
    ) {
        guard state.inFlightRequest == nil, state.burstDeadline == nil else {
            return
        }
        let session = activeSession
        activeSession = nil
        if let session {
            sessions.append(session.session)
        }
    }

    private func stop(
        _ sessions: [any RefreshUsageSession]
    ) async {
        for session in sessions {
            await session.stop()
        }
    }

    private func detachSession(
        _ session: RefreshSessionLease?
    ) -> (any RefreshUsageSession)? {
        guard let session else {
            return nil
        }
        if activeSession?.generation == session.generation {
            activeSession = nil
        }
        return session.session
    }

    private func publishIfChanged(
        from original: RefreshPublication
    ) async {
        guard original != publication else {
            return
        }
        await publishCurrent()
    }

    private func publishCurrent() async {
        await publicationHandler?(publication)
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
            return .terminalFailure(generation: generation)
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
