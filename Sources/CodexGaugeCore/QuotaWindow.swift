import Foundation

public struct QuotaWindow: Equatable, Sendable {
    public let slot: QuotaSlot
    public let usedPercent: Double
    public let windowDurationMinutes: Int?
    public let resetsAt: Date?

    public init?(
        slot: QuotaSlot,
        usedPercent: Double,
        windowDurationMinutes: Int? = nil,
        resetUnixSeconds: TimeInterval? = nil
    ) {
        guard usedPercent.isFinite else {
            return nil
        }
        self.slot = slot
        self.usedPercent = Self.clamp(usedPercent)
        self.windowDurationMinutes = Self.normalize(windowDurationMinutes)
        self.resetsAt = Self.resetDate(from: resetUnixSeconds)
    }

    public var remainingPercent: Int {
        Int((100 - usedPercent).rounded(.down))
    }

    public var comparisonUsedPercent: Int {
        Int(usedPercent.rounded(.down))
    }

    public var durationBadge: DurationBadge {
        DurationBadge(windowDurationMinutes: windowDurationMinutes)
    }

    private static func clamp(_ usedPercent: Double) -> Double {
        min(max(usedPercent, 0), 100)
    }

    private static func normalize(_ minutes: Int?) -> Int? {
        guard let minutes, minutes > 0 else {
            return nil
        }
        return minutes
    }

    private static func resetDate(from unixSeconds: TimeInterval?) -> Date? {
        guard let unixSeconds, unixSeconds.isFinite else {
            return nil
        }
        return Date(timeIntervalSince1970: unixSeconds)
    }
}
