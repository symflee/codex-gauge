public struct DurationBadge: Equatable, Sendable {
    public static let unknown = DurationBadge(
        label: "?",
        accessibilityLabel: "기간 미상"
    )

    public let label: String
    public let accessibilityLabel: String

    public init(windowDurationMinutes: Int?) {
        self = Self.makeBadge(for: windowDurationMinutes)
    }

    private init(label: String, accessibilityLabel: String) {
        self.label = label
        self.accessibilityLabel = accessibilityLabel
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
            DurationBadge(label: "5h", accessibilityLabel: "5시간")
        case 1_440:
            DurationBadge(label: "d", accessibilityLabel: "1일")
        case 10_080:
            DurationBadge(label: "w", accessibilityLabel: "1주")
        case 20_160:
            DurationBadge(label: "2w", accessibilityLabel: "2주")
        case 43_200:
            DurationBadge(label: "30d", accessibilityLabel: "30일")
        default:
            nil
        }
    }

    private static func exactUnitBadge(for minutes: Int) -> DurationBadge? {
        if let badge = exactBadge(for: minutes, unitMinutes: 1_440, label: "d", word: "일") {
            return badge
        }
        return exactBadge(for: minutes, unitMinutes: 60, label: "h", word: "시간")
    }

    private static func exactBadge(
        for minutes: Int,
        unitMinutes: Int,
        label: String,
        word: String
    ) -> DurationBadge? {
        guard minutes.isMultiple(of: unitMinutes) else {
            return nil
        }
        let count = minutes / unitMinutes
        return DurationBadge(
            label: "\(count)\(label)",
            accessibilityLabel: "\(count)\(word)"
        )
    }
}
