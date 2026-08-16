import Foundation

public struct QuotaValueValidityPolicy: Sendable {
    public static let maximumValueAge: TimeInterval = 86_400

    public init() {}

    public func isValid(
        _ quota: QuotaWindow,
        capturedAt: Date,
        now: Date
    ) -> Bool {
        if let resetsAt = quota.resetsAt, now >= resetsAt {
            return false
        }
        return now.timeIntervalSince(capturedAt) < Self.maximumValueAge
    }
}
