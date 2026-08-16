import CodexGaugeCore
import CodexGaugeProtocol

public protocol SelectedQuotaSampleSelecting: Sendable {
    func samples(
        from result: RateLimitReadResult,
        preference: DisplayPreference
    ) -> SelectedQuotaSamples
}

public struct DisplayPreferenceQuotaSampleSelector: SelectedQuotaSampleSelecting, Sendable {
    private let quotaSelector = QuotaSelector()

    public init() {}

    public func samples(
        from result: RateLimitReadResult,
        preference: DisplayPreference
    ) -> SelectedQuotaSamples {
        let pairs = selectedWindows(from: result, preference: preference)
        let values = Dictionary(uniqueKeysWithValues: pairs.map(samplePair))
        return SelectedQuotaSamples(values)
    }

    private func selectedWindows(
        from result: RateLimitReadResult,
        preference: DisplayPreference
    ) -> [(UsageProduct, QuotaWindow)] {
        switch preference.quotaSelection {
        case .automatic:
            return automaticWindows(from: result, preference: preference)
        case let .manual(identifiers):
            return manualWindows(identifiers, from: result, preference: preference)
        }
    }

    private func automaticWindows(
        from result: RateLimitReadResult,
        preference: DisplayPreference
    ) -> [(UsageProduct, QuotaWindow)] {
        preference.productMode.products.compactMap { product in
            let windows = result.rateLimits(for: product).windows
            guard let window = quotaSelector.automaticQuota(from: windows) else {
                return nil
            }
            return (product, window)
        }
    }

    private func manualWindows(
        _ identifiers: Set<QuotaSelectionID>,
        from result: RateLimitReadResult,
        preference: DisplayPreference
    ) -> [(UsageProduct, QuotaWindow)] {
        identifiers.compactMap { identifier in
            guard preference.productMode.products.contains(identifier.product) else {
                return nil
            }
            let windows = result.rateLimits(for: identifier.product).windows
            guard let window = quotaSelector.quota(matching: identifier, from: windows) else {
                return nil
            }
            return (identifier.product, window)
        }
    }

    private func samplePair(
        _ pair: (UsageProduct, QuotaWindow)
    ) -> (RefreshQuotaKey, Int) {
        let key = RefreshQuotaKey(
            product: pair.0,
            rawDurationMinutes: pair.1.windowDurationMinutes,
            resetsAt: pair.1.resetsAt
        )
        return (key, pair.1.comparisonUsedPercent)
    }
}
