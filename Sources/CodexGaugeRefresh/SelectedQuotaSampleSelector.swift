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
        let windows = result.rateLimits(for: .codex).windows
        let selected: QuotaWindow?
        switch preference.quotaSelection {
        case .automatic:
            selected = quotaSelector.automaticQuota(from: windows)
        case let .manual(identifier):
            selected = quotaSelector.quota(matching: identifier, from: windows)
        }
        guard let selected else {
            return SelectedQuotaSamples([:])
        }
        let key = RefreshQuotaKey(
            product: .codex,
            rawDurationMinutes: selected.windowDurationMinutes,
            resetsAt: selected.resetsAt
        )
        return SelectedQuotaSamples([key: selected.comparisonUsedPercent])
    }
}
