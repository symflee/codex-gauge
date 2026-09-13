import Foundation

public struct DisplayFrameBuilder: Sendable {
    private let selector = QuotaSelector()
    private let validityPolicy = QuotaValueValidityPolicy()

    public init() {}

    public func makeFrames(
        preference: DisplayPreference,
        productStates: [UsageProduct: ProductUsageState],
        now: Date
    ) -> [DisplayFrame] {
        switch preference.quotaSelection {
        case .automatic:
            [.single(automaticQuota(for: .codex, states: productStates, now: now))]
        case .manual(let identifier):
            [.single(selectedQuota(identifier: identifier, state: productStates[.codex] ?? .unavailable, now: now))]
        }
    }

    private func automaticQuota(
        for product: UsageProduct,
        states: [UsageProduct: ProductUsageState],
        now: Date
    ) -> DisplayQuota {
        let state = states[product] ?? .unavailable
        guard case .value(let value, let freshness) = state else {
            return placeholder(for: product, state: state)
        }
        guard let quota = selector.automaticQuota(from: value.quotaWindows) else {
            return unavailableQuota(for: product, durationMinutes: nil)
        }
        return displayQuota(
            for: product,
            quota: quota,
            productValue: value,
            freshness: freshness,
            now: now
        )
    }

    private func selectedQuota(
        identifier: QuotaSelectionID,
        state: ProductUsageState,
        now: Date
    ) -> DisplayQuota {
        guard case .value(let value, let freshness) = state else {
            return placeholder(identifier: identifier, state: state)
        }
        guard let quota = selector.quota(matching: identifier, from: value.quotaWindows) else {
            return DisplayQuota(identifier: identifier, value: .unavailable)
        }
        return displayQuota(
            identifier: identifier,
            quota: quota,
            productValue: value,
            freshness: freshness,
            now: now
        )
    }

    private func displayQuota(
        for product: UsageProduct,
        quota: QuotaWindow,
        productValue: ProductQuotaValue,
        freshness: ProductValueFreshness,
        now: Date
    ) -> DisplayQuota {
        let identifier = QuotaSelectionID(
            product: product,
            rawDurationMinutes: quota.windowDurationMinutes
        )
        return displayQuota(
            identifier: identifier,
            quota: quota,
            productValue: productValue,
            freshness: freshness,
            now: now
        )
    }

    private func displayQuota(
        identifier: QuotaSelectionID,
        quota: QuotaWindow,
        productValue: ProductQuotaValue,
        freshness: ProductValueFreshness,
        now: Date
    ) -> DisplayQuota {
        let value = displayValue(
            for: quota,
            capturedAt: productValue.capturedAt,
            freshness: freshness,
            now: now
        )
        return DisplayQuota(identifier: identifier, value: value)
    }

    private func displayValue(
        for quota: QuotaWindow,
        capturedAt: Date,
        freshness: ProductValueFreshness,
        now: Date
    ) -> DisplayValueState {
        guard validityPolicy.isValid(quota, capturedAt: capturedAt, now: now) else {
            return .unavailable
        }
        switch freshness {
        case .fresh:
            return .fresh(quota.remainingPercent)
        case .stale:
            return .stale(quota.remainingPercent)
        }
    }

    private func placeholder(
        for product: UsageProduct,
        state: ProductUsageState
    ) -> DisplayQuota {
        let identifier = QuotaSelectionID(product: product, rawDurationMinutes: nil)
        return placeholder(identifier: identifier, state: state)
    }

    private func placeholder(
        identifier: QuotaSelectionID,
        state: ProductUsageState
    ) -> DisplayQuota {
        guard case .loading = state else {
            return DisplayQuota(identifier: identifier, value: .unavailable)
        }
        return DisplayQuota(identifier: identifier, value: .loading)
    }

    private func unavailableQuota(
        for product: UsageProduct,
        durationMinutes: Int?
    ) -> DisplayQuota {
        let identifier = QuotaSelectionID(
            product: product,
            rawDurationMinutes: durationMinutes
        )
        return DisplayQuota(identifier: identifier, value: .unavailable)
    }

}
