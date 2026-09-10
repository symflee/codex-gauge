public enum RefreshRequestReason: Equatable, Sendable {
    case startup
    case manual
    case wakeBaseline
    case quotaReset
    case normal
    case burst
    case retry

    var establishesBaseline: Bool {
        self == .startup || self == .wakeBaseline || self == .quotaReset
    }
}

public struct RefreshRequest: Equatable, Sendable {
    public let generation: UInt64
    public let reason: RefreshRequestReason
    public let isUserInitiated: Bool

    public init(
        generation: UInt64,
        reason: RefreshRequestReason,
        isUserInitiated: Bool = false
    ) {
        self.generation = generation
        self.reason = reason
        self.isUserInitiated = isUserInitiated || reason == .manual
    }
}

public enum RefreshScheduleReason: Equatable, Sendable {
    case normal
    case burst
    case retry
    case wakeBaseline
    case quotaReset
    case burstExpiry
}

public struct RefreshSchedule: Equatable, Sendable {
    public let generation: UInt64
    public let deadline: ContinuousClock.Instant
    public let reason: RefreshScheduleReason

    public init(
        generation: UInt64,
        deadline: ContinuousClock.Instant,
        reason: RefreshScheduleReason
    ) {
        self.generation = generation
        self.deadline = deadline
        self.reason = reason
    }
}

public struct RefreshState: Equatable, Sendable {
    public internal(set) var profile: RefreshProfile
    public internal(set) var lowPowerModeEnabled: Bool
    public internal(set) var isRunning: Bool
    public internal(set) var baseline: SelectedQuotaSamples?
    public internal(set) var burstDeadline: ContinuousClock.Instant?
    public internal(set) var burstCooldownDeadline: ContinuousClock.Instant?
    public internal(set) var lastRequestCompletedAt: ContinuousClock.Instant?
    internal var requiresNormalBurstRearm = false
    internal var retryNotBefore: ContinuousClock.Instant?
    public internal(set) var consecutiveTransientFailures: Int
    public internal(set) var inFlightRequest: RefreshRequest?
    public internal(set) var scheduledRefresh: RefreshSchedule?
    internal var nextRequestGeneration: UInt64
    internal var nextScheduleGeneration: UInt64

    public init(
        profile: RefreshProfile = .default,
        lowPowerModeEnabled: Bool = false
    ) {
        self.profile = profile
        self.lowPowerModeEnabled = lowPowerModeEnabled
        self.isRunning = false
        self.baseline = nil
        self.burstDeadline = nil
        self.consecutiveTransientFailures = 0
        self.inFlightRequest = nil
        self.scheduledRefresh = nil
        self.nextRequestGeneration = 0
        self.nextScheduleGeneration = 0
    }
}

public enum RefreshEvent: Equatable, Sendable {
    case start(at: ContinuousClock.Instant)
    case manualRefresh(at: ContinuousClock.Instant)
    case wakeBaseline(at: ContinuousClock.Instant)
    case quotaReset(at: ContinuousClock.Instant)
    case resumeAfterSystemWake(at: ContinuousClock.Instant)
    case scheduledRefreshFired(
        generation: UInt64,
        at: ContinuousClock.Instant
    )
    case lowPowerModeChanged(
        isEnabled: Bool,
        at: ContinuousClock.Instant
    )
    case profileChanged(
        profile: RefreshProfile,
        at: ContinuousClock.Instant
    )
    case requestAdmission(
        generation: UInt64,
        at: ContinuousClock.Instant
    )
    case requestSucceeded(
        generation: UInt64,
        samples: SelectedQuotaSamples,
        at: ContinuousClock.Instant
    )
    case transientFailure(
        generation: UInt64,
        at: ContinuousClock.Instant
    )
    case terminalFailure(generation: UInt64, at: ContinuousClock.Instant? = nil)
    case suspend(at: ContinuousClock.Instant)
    case stop
}

public enum RefreshCommand: Equatable, Sendable {
    case startRequest(RefreshRequest)
    case scheduleRefresh(RefreshSchedule)
    case cancelRequest(generation: UInt64)
    case cancelScheduledRefresh(generation: UInt64)
}

public struct RefreshTransition: Equatable, Sendable {
    public let state: RefreshState
    public let commands: [RefreshCommand]

    public init(state: RefreshState, commands: [RefreshCommand]) {
        self.state = state
        self.commands = commands
    }
}
