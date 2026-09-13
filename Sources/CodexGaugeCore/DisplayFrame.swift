public enum DisplayValueState: Equatable, Sendable {
    case fresh(Int)
    case stale(Int)
    case loading
    case unavailable
}

public struct DisplayQuota: Equatable, Sendable {
    public let identifier: QuotaSelectionID
    public let value: DisplayValueState

    public init(identifier: QuotaSelectionID, value: DisplayValueState) {
        self.identifier = identifier
        self.value = value
    }

    public var durationBadge: DurationBadge {
        DurationBadge(windowDurationMinutes: identifier.rawDurationMinutes)
    }
}

public enum DisplayFrame: Equatable, Sendable {
    case single(DisplayQuota)
}

public struct FormattedDisplayFrame: Equatable, Sendable {
    public let title: String

    public init(title: String) {
        self.title = title
    }
}
