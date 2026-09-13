import CodexGaugeCore
import CodexGaugeProtocol
import CodexGaugeRefresh
import Foundation

struct SessionCounters: Encodable, Sendable {
    var created = 0
    var startAttempts = 0
    var successfulStarts = 0
    var reads = 0
    var successfulReads = 0
    var failedReads = 0
    var confirmedStops = 0
    var unconfirmedStops = 0
    var activeLeases = 0
    var maximumActiveLeases = 0
    var activeReads = 0
    var maximumActiveReads = 0
    var minimumReadStartIntervalSeconds: Double?
    var maximumReadStartIntervalSeconds: Double?
}

/// Counts logical session lifetimes. These are explicitly not OS child counts.
/// Only live leases are retained, so a long measurement does not accumulate sessions.
actor MeasuredSessionProvider: RefreshSessionProviding {
    private let realProvider: CodexUsageProvider?
    private let syntheticSource: SyntheticQuotaSource
    private var sessions: [Int: MeasuredSession] = [:]
    private var counters = SessionCounters()
    private var previousReadStartedAt: ContinuousClock.Instant?
    private var shuttingDown = false

    init(mode: MeasurementMode) {
        if mode == .real {
            realProvider = CodexUsageProvider(locator: CodexExecutableLocator(
                homeDirectoryURL: FileManager.default.homeDirectoryForCurrentUser
            ))
        } else {
            realProvider = nil
        }
        syntheticSource = SyntheticQuotaSource(growing: mode == .burst)
    }

    func makeSession() async throws -> any RefreshUsageSession {
        guard !shuttingDown else { throw CancellationError() }
        let underlying: any RefreshUsageSession
        if let realProvider {
            // The production provider performs the repository's verified discovery.
            // No selected executable, preference domain, credentials, or response log is read here.
            underlying = try realProvider.makeSession()
        } else {
            underlying = SyntheticUsageSession(source: syntheticSource)
        }
        counters.created += 1
        let identifier = counters.created
        let session = MeasuredSession(underlying: underlying, owner: self, identifier: identifier)
        sessions[identifier] = session
        counters.activeLeases = sessions.count
        counters.maximumActiveLeases = max(counters.maximumActiveLeases, sessions.count)
        return session
    }

    func snapshot() -> SessionCounters { counters }

    func didAttemptStart() { counters.startAttempts += 1 }
    func didStart() { counters.successfulStarts += 1 }

    func willRead() {
        counters.reads += 1
        counters.activeReads += 1
        counters.maximumActiveReads = max(counters.maximumActiveReads, counters.activeReads)
        let now = ContinuousClock().now
        if let previousReadStartedAt {
            let duration = previousReadStartedAt.duration(to: now).components
            let interval = Double(duration.seconds) + Double(duration.attoseconds) / 1e18
            counters.minimumReadStartIntervalSeconds = min(
                counters.minimumReadStartIntervalSeconds ?? interval, interval
            )
            counters.maximumReadStartIntervalSeconds = max(
                counters.maximumReadStartIntervalSeconds ?? interval, interval
            )
        }
        previousReadStartedAt = now
    }

    func didRead(succeeded: Bool) {
        counters.activeReads -= 1
        if succeeded { counters.successfulReads += 1 } else { counters.failedReads += 1 }
    }

    func didConfirmExit(identifier: Int) {
        guard sessions.removeValue(forKey: identifier) != nil else { return }
        counters.confirmedStops += 1
        counters.activeLeases = sessions.count
    }

    func didFailToConfirmExit() { counters.unconfirmedStops += 1 }

    func shutdown() async {
        shuttingDown = true
        // Snapshot only the currently owned leases; stop callbacks may remove them.
        for session in Array(sessions.values) {
            let result = await session.stop()
            if result == .unconfirmed {
                // Never claim cleanup, emit complete child CPU, or exit while an owned
                // child remains unconfirmed. This waits on an exit event, not polling.
                await session.waitForTermination()
            }
        }
    }
}

private actor MeasuredSession: RefreshUsageSession {
    private let underlying: any RefreshUsageSession
    private weak var owner: MeasuredSessionProvider?
    private let identifier: Int
    private var stopTask: Task<UsageSessionStopResult, Never>?
    private var exitConfirmed = false

    init(underlying: any RefreshUsageSession, owner: MeasuredSessionProvider, identifier: Int) {
        self.underlying = underlying
        self.owner = owner
        self.identifier = identifier
    }

    func start() async throws {
        guard stopTask == nil else { throw CancellationError() }
        await owner?.didAttemptStart()
        try Task.checkCancellation()
        try await underlying.start()
        await owner?.didStart()
    }

    func readRateLimits(capturedAt: Date) async throws -> RateLimitReadResult {
        await owner?.willRead()
        do {
            let result = try await underlying.readRateLimits(capturedAt: capturedAt)
            await owner?.didRead(succeeded: result.responseStatus == .accepted)
            return result
        } catch {
            await owner?.didRead(succeeded: false)
            throw error
        }
    }

    func stop() async -> UsageSessionStopResult {
        if exitConfirmed { return .exited }
        if let stopTask { return await stopTask.value }
        let task = Task { await performStop() }
        stopTask = task
        return await task.value
    }

    private func performStop() async -> UsageSessionStopResult {
        let result = await underlying.stop()
        if result == .exited {
            await confirmExit()
        } else {
            await owner?.didFailToConfirmExit()
        }
        return result
    }

    func waitForTermination() async {
        await underlying.waitForTermination()
        await confirmExit()
    }

    private func confirmExit() async {
        guard !exitConfirmed else { return }
        exitConfirmed = true
        await owner?.didConfirmExit(identifier: identifier)
    }
}

private actor SyntheticQuotaSource {
    private let growing: Bool
    private var reads = 0

    init(growing: Bool) { self.growing = growing }

    func read(capturedAt: Date) -> RateLimitReadResult {
        reads += 1
        // Fixed duration/reset identity lets the real reducer see sustained growth.
        // These values exist only in memory and are never included in output.
        let used = growing ? min(95, 15 + reads) : 17
        let primary = QuotaWindow(slot: .primary, usedPercent: Double(used), windowDurationMinutes: 300)!
        let secondary = QuotaWindow(slot: .secondary, usedPercent: 29, windowDurationMinutes: 10_080)!
        return RateLimitReadResult(capturedAt: capturedAt, rateLimitsByProduct: [
            .codex: ProductRateLimits(state: .available, windows: [primary, secondary])
        ])
    }
}

private actor SyntheticUsageSession: RefreshUsageSession {
    private let source: SyntheticQuotaSource
    private var stopped = false

    init(source: SyntheticQuotaSource) { self.source = source }

    func start() throws {
        guard !stopped else { throw CancellationError() }
    }

    func readRateLimits(capturedAt: Date) async throws -> RateLimitReadResult {
        try Task.checkCancellation()
        guard !stopped else { throw CancellationError() }
        return await source.read(capturedAt: capturedAt)
    }

    func stop() -> UsageSessionStopResult {
        stopped = true
        return .exited
    }

    func waitForTermination() {}
}
