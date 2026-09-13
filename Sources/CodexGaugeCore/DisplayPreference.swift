public struct QuotaSelectionID: Hashable, Sendable {
    public let product: UsageProduct
    public let rawDurationMinutes: Int?

    public init(product: UsageProduct, rawDurationMinutes: Int?) {
        self.product = product
        self.rawDurationMinutes = Self.normalize(rawDurationMinutes)
    }

    private static func normalize(_ minutes: Int?) -> Int? {
        guard let minutes, minutes > 0 else {
            return nil
        }
        return minutes
    }
}

public enum DisplayQuotaSelection: Equatable, Sendable {
    case automatic
    case manual(QuotaSelectionID)
}

public struct DisplayPreference: Equatable, Sendable {
    public static let `default` = DisplayPreference()
    public let quotaSelection: DisplayQuotaSelection

    public init(quotaSelection: DisplayQuotaSelection = .automatic) {
        self.quotaSelection = quotaSelection
    }
}
