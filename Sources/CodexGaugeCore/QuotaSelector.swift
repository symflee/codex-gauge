import Foundation

public struct QuotaSelector: Sendable {
    public init() {}

    public func automaticQuota(from quotas: [QuotaWindow]) -> QuotaWindow? {
        if let fiveHour = preferredQuota(for: 300, from: quotas) {
            return fiveHour
        }
        if let weekly = preferredQuota(for: 10_080, from: quotas) {
            return weekly
        }
        if let shortest = shortestPositiveQuota(from: quotas) {
            return shortest
        }
        return preferredUnknownQuota(from: quotas)
    }

    public func quota(
        matching identifier: QuotaSelectionID,
        from quotas: [QuotaWindow]
    ) -> QuotaWindow? {
        preferredQuota(for: identifier.rawDurationMinutes, from: quotas)
    }

    private func shortestPositiveQuota(from quotas: [QuotaWindow]) -> QuotaWindow? {
        let durations = quotas.compactMap(\.windowDurationMinutes)
        guard let shortestDuration = durations.min() else {
            return nil
        }
        return preferredQuota(for: shortestDuration, from: quotas)
    }

    private func preferredUnknownQuota(from quotas: [QuotaWindow]) -> QuotaWindow? {
        let unknown = quotas.filter { $0.windowDurationMinutes == nil }
        let primary = unknown.filter { $0.slot == .primary }
        if let quota = preferredQuota(from: primary) {
            return quota
        }
        let secondary = unknown.filter { $0.slot == .secondary }
        return preferredQuota(from: secondary)
    }

    private func preferredQuota(
        for durationMinutes: Int?,
        from quotas: [QuotaWindow]
    ) -> QuotaWindow? {
        let matching = quotas.filter {
            $0.windowDurationMinutes == durationMinutes
        }
        return preferredQuota(from: matching)
    }

    private func preferredQuota(from quotas: [QuotaWindow]) -> QuotaWindow? {
        var preferred: QuotaWindow?
        for quota in quotas {
            guard let current = preferred else {
                preferred = quota
                continue
            }
            if isPreferred(quota, over: current) {
                preferred = quota
            }
        }
        return preferred
    }

    private func isPreferred(_ candidate: QuotaWindow, over current: QuotaWindow) -> Bool {
        if candidate.usedPercent != current.usedPercent {
            return candidate.usedPercent > current.usedPercent
        }
        if candidate.resetsAt != current.resetsAt {
            return hasLaterReset(candidate, than: current)
        }
        return candidate.slot == .primary && current.slot == .secondary
    }

    private func hasLaterReset(_ candidate: QuotaWindow, than current: QuotaWindow) -> Bool {
        guard let candidateReset = candidate.resetsAt else {
            return false
        }
        guard let currentReset = current.resetsAt else {
            return true
        }
        return candidateReset > currentReset
    }
}
