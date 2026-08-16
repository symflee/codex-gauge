public struct RefreshIntervals: Equatable, Sendable {
    public let normal: Duration?
    public let burst: Duration?

    public init(normal: Duration?, burst: Duration?) {
        self.normal = normal
        self.burst = burst
    }
}

public enum RefreshProfile: String, CaseIterable, Sendable {
    public static let `default`: RefreshProfile = .balanced

    case manual
    case eco
    case balanced
    case fast

    public var intervals: RefreshIntervals {
        switch self {
        case .manual:
            RefreshIntervals(normal: nil, burst: nil)
        case .eco:
            RefreshIntervals(normal: .seconds(600), burst: .seconds(60))
        case .balanced:
            RefreshIntervals(normal: .seconds(180), burst: .seconds(20))
        case .fast:
            RefreshIntervals(normal: .seconds(60), burst: .seconds(10))
        }
    }

    public func effectiveIntervals(
        lowPowerModeEnabled: Bool
    ) -> RefreshIntervals {
        guard lowPowerModeEnabled, self != .manual else {
            return intervals
        }
        return RefreshIntervals(
            normal: max(intervals.normal ?? .seconds(600), .seconds(600)),
            burst: max(intervals.burst ?? .seconds(60), .seconds(60))
        )
    }
}
