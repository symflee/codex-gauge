public struct DisplayFrameFormatter: Sendable {
    public init() {}

    public func format(_ frame: DisplayFrame) -> FormattedDisplayFrame {
        switch frame {
        case .single(let quota):
            FormattedDisplayFrame(title: singleTitle(quota))
        case .comparison(let codex, let spark):
            FormattedDisplayFrame(title: comparisonTitle(codex: codex, spark: spark))
        }
    }

    private func singleTitle(_ quota: DisplayQuota) -> String {
        let badge = quota.durationBadge.label
        let value = titleValue(quota.value)
        guard quota.identifier.product == .spark else {
            return "[\(badge)] \(value)"
        }
        return "S[\(badge)] \(value)"
    }

    private func comparisonTitle(
        codex: DisplayQuota,
        spark: DisplayQuota
    ) -> String {
        guard codex.identifier.rawDurationMinutes == spark.identifier.rawDurationMinutes else {
            return mixedDurationTitle(codex: codex, spark: spark)
        }
        let badge = codex.durationBadge.label
        return "[\(badge)] C\(titleValue(codex.value)) · S\(titleValue(spark.value))"
    }

    private func mixedDurationTitle(
        codex: DisplayQuota,
        spark: DisplayQuota
    ) -> String {
        let codexBadge = codex.durationBadge.label
        let sparkBadge = spark.durationBadge.label
        return "C[\(codexBadge)]\(titleValue(codex.value)) · "
            + "S[\(sparkBadge)]\(titleValue(spark.value))"
    }

    private func titleValue(_ value: DisplayValueState) -> String {
        switch value {
        case .fresh(let percent):
            "\(percent)%"
        case .stale(let percent):
            "~\(percent)%"
        case .loading:
            "…"
        case .unavailable:
            "—"
        }
    }

}
