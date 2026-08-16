public struct DurationBadge: Equatable, Sendable {
    public static let unknown = DurationBadge(label: "?")

    public let label: String

    public init(windowDurationMinutes: Int?) {
        self = Self.makeBadge(for: windowDurationMinutes)
    }

    private init(label: String) {
        self.label = label
    }

    private static func makeBadge(for minutes: Int?) -> DurationBadge {
        guard let minutes, minutes > 0 else {
            return .unknown
        }
        guard let knownBadge = knownBadge(for: minutes) else {
            return exactUnitBadge(for: minutes) ?? .unknown
        }
        return knownBadge
    }

    private static func knownBadge(for minutes: Int) -> DurationBadge? {
        switch minutes {
        case 300:
            DurationBadge(label: "5h")
        case 1_440:
            DurationBadge(label: "d")
        case 10_080:
            DurationBadge(label: "w")
        case 20_160:
            DurationBadge(label: "2w")
        case 43_200:
            DurationBadge(label: "30d")
        default:
            nil
        }
    }

    private static func exactUnitBadge(for minutes: Int) -> DurationBadge? {
        if let badge = exactBadge(for: minutes, unitMinutes: 1_440, label: "d") {
            return badge
        }
        return exactBadge(for: minutes, unitMinutes: 60, label: "h")
    }

    private static func exactBadge(
        for minutes: Int,
        unitMinutes: Int,
        label: String
    ) -> DurationBadge? {
        guard minutes.isMultiple(of: unitMinutes) else {
            return nil
        }
        let count = minutes / unitMinutes
        return DurationBadge(label: "\(count)\(label)")
    }
}
