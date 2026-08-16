import Foundation

public struct UsageSnapshot: Equatable, Sendable {
    public let capturedAt: Date
    public let quotasByProduct: [UsageProduct: [QuotaWindow]]

    public init(
        capturedAt: Date,
        quotasByProduct: [UsageProduct: [QuotaWindow]]
    ) {
        self.capturedAt = capturedAt
        self.quotasByProduct = quotasByProduct
    }

    public func quotaWindows(for product: UsageProduct) -> [QuotaWindow] {
        quotasByProduct[product] ?? []
    }
}
