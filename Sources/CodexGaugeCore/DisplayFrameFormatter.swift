public struct DisplayFrameFormatter: Sendable {
    public init() {}

    public func format(_ frame: DisplayFrame) -> FormattedDisplayFrame {
        switch frame {
        case .single(let quota):
            FormattedDisplayFrame(title: singleTitle(quota))
        }
    }

    private func singleTitle(_ quota: DisplayQuota) -> String {
        let badge = quota.durationBadge.label
        let value = titleValue(quota.value)
        return "[\(badge)] \(value)"
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
