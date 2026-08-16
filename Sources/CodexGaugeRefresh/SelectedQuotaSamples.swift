import CodexGaugeCore
import Foundation

public struct RefreshQuotaKey: Hashable, Sendable {
    public let product: UsageProduct
    public let rawDurationMinutes: Int?
    public let resetsAt: Date?

    public init(
        product: UsageProduct,
        rawDurationMinutes: Int?,
        resetsAt: Date?
    ) {
        let identifier = QuotaSelectionID(
            product: product,
            rawDurationMinutes: rawDurationMinutes
        )
        self.product = product
        self.rawDurationMinutes = identifier.rawDurationMinutes
        self.resetsAt = resetsAt
    }
}

public struct SelectedQuotaSamples: Equatable, Sendable {
    public let values: [RefreshQuotaKey: Int]

    public init(_ values: [RefreshQuotaKey: Int]) {
        self.values = values.mapValues(Self.clamp)
    }

    private static func clamp(_ usedPercent: Int) -> Int {
        min(max(usedPercent, 0), 100)
    }
}
