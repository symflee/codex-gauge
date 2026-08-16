public enum DisplayProductMode: String, CaseIterable, Sendable {
    case codex
    case spark
    case both

    public var products: [UsageProduct] {
        switch self {
        case .codex:
            [.codex]
        case .spark:
            [.spark]
        case .both:
            [.codex, .spark]
        }
    }
}

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
    case manual(Set<QuotaSelectionID>)
}

public struct DisplayPreference: Equatable, Sendable {
    public static let `default` = DisplayPreference(
        productMode: .codex,
        quotaSelection: .automatic
    )

    public let productMode: DisplayProductMode
    public let quotaSelection: DisplayQuotaSelection

    public init(
        productMode: DisplayProductMode,
        quotaSelection: DisplayQuotaSelection
    ) {
        self.productMode = productMode
        self.quotaSelection = quotaSelection
    }
}
