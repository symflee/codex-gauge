import Foundation

public enum ProductValueFreshness: Equatable, Sendable {
    case fresh
    case stale
}

public struct ProductQuotaValue: Equatable, Sendable {
    public let capturedAt: Date
    public let quotaWindows: [QuotaWindow]

    public init(capturedAt: Date, quotaWindows: [QuotaWindow]) {
        self.capturedAt = capturedAt
        self.quotaWindows = quotaWindows
    }

    public init(snapshot: UsageSnapshot, product: UsageProduct) {
        self.init(
            capturedAt: snapshot.capturedAt,
            quotaWindows: snapshot.quotaWindows(for: product)
        )
    }
}

public enum ProductUsageState: Equatable, Sendable {
    case loading
    case value(ProductQuotaValue, freshness: ProductValueFreshness)
    case unavailable
}
