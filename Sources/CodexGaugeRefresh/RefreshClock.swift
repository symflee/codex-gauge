import Foundation

public protocol RefreshClock: Sendable {
    func now() async -> ContinuousClock.Instant
    func currentDate() async -> Date
    func sleep(until deadline: ContinuousClock.Instant) async throws
}

public struct SystemRefreshClock: RefreshClock, Sendable {
    private let clock = ContinuousClock()

    public init() {}

    public func now() async -> ContinuousClock.Instant {
        clock.now
    }

    public func currentDate() async -> Date {
        Date()
    }

    public func sleep(until deadline: ContinuousClock.Instant) async throws {
        try await clock.sleep(until: deadline)
    }
}
