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
            automaticFrames(
                productMode: preference.productMode,
                productStates: productStates,
                now: now
            )
        case .manual(let identifiers):
            manualFrames(
                identifiers: identifiers,
                productMode: preference.productMode,
                productStates: productStates,
                now: now
            )
        }
    }

    private func automaticFrames(
        productMode: DisplayProductMode,
        productStates: [UsageProduct: ProductUsageState],
        now: Date
    ) -> [DisplayFrame] {
        switch productMode {
        case .codex:
            [.single(automaticQuota(for: .codex, states: productStates, now: now))]
        case .spark:
            [.single(automaticQuota(for: .spark, states: productStates, now: now))]
        case .both:
            [automaticComparison(states: productStates, now: now)]
        }
    }

    private func automaticComparison(
        states: [UsageProduct: ProductUsageState],
        now: Date
    ) -> DisplayFrame {
        let codex = automaticQuota(for: .codex, states: states, now: now)
        let spark = automaticQuota(for: .spark, states: states, now: now)
        return .comparison(codex: codex, spark: spark)
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

    private func manualFrames(
        identifiers: Set<QuotaSelectionID>,
        productMode: DisplayProductMode,
        productStates: [UsageProduct: ProductUsageState],
        now: Date
    ) -> [DisplayFrame] {
        let relevant = identifiers.filter {
            productMode.products.contains($0.product)
        }
        guard !relevant.isEmpty else {
            return automaticFrames(
                productMode: productMode,
                productStates: productStates,
                now: now
            )
        }
        let durations = orderedDurations(from: relevant)
        return durations.compactMap {
            manualFrame(
                durationMinutes: $0,
                identifiers: relevant,
                productStates: productStates,
                now: now
            )
        }
    }

    private func manualFrame(
        durationMinutes: Int?,
        identifiers: Set<QuotaSelectionID>,
        productStates: [UsageProduct: ProductUsageState],
        now: Date
    ) -> DisplayFrame? {
        let codex = manualQuota(
            product: .codex,
            durationMinutes: durationMinutes,
            identifiers: identifiers,
            states: productStates,
            now: now
        )
        let spark = manualQuota(
            product: .spark,
            durationMinutes: durationMinutes,
            identifiers: identifiers,
            states: productStates,
            now: now
        )
        return frame(codex: codex, spark: spark)
    }

    private func manualQuota(
        product: UsageProduct,
        durationMinutes: Int?,
        identifiers: Set<QuotaSelectionID>,
        states: [UsageProduct: ProductUsageState],
        now: Date
    ) -> DisplayQuota? {
        let identifier = QuotaSelectionID(
            product: product,
            rawDurationMinutes: durationMinutes
        )
        guard identifiers.contains(identifier) else {
            return nil
        }
        return selectedQuota(
            identifier: identifier,
            state: states[product] ?? .unavailable,
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

    private func orderedDurations(
        from identifiers: Set<QuotaSelectionID>
    ) -> [Int?] {
        let durations = Set(identifiers.map(\.rawDurationMinutes))
        return durations.sorted(by: durationComesBefore)
    }

    private func durationComesBefore(_ left: Int?, _ right: Int?) -> Bool {
        guard let left else {
            return false
        }
        guard let right else {
            return true
        }
        return left < right
    }

    private func frame(
        codex: DisplayQuota?,
        spark: DisplayQuota?
    ) -> DisplayFrame? {
        if let codex, let spark {
            return .comparison(codex: codex, spark: spark)
        }
        if let codex {
            return .single(codex)
        }
        if let spark {
            return .single(spark)
        }
        return nil
    }
}
