import CodexGaugeCore
import Foundation

public struct StatusAccessibilityVocabulary: Equatable, Sendable {
    public let quotaFormat: String
    public let freshValueFormat: String
    public let staleValueFormat: String
    public let loadingValue: String
    public let unavailableValue: String
    public let comparisonSeparator: String

    public init(
        quotaFormat: String,
        freshValueFormat: String,
        staleValueFormat: String,
        loadingValue: String,
        unavailableValue: String,
        comparisonSeparator: String
    ) {
        self.quotaFormat = quotaFormat
        self.freshValueFormat = freshValueFormat
        self.staleValueFormat = staleValueFormat
        self.loadingValue = loadingValue
        self.unavailableValue = unavailableValue
        self.comparisonSeparator = comparisonSeparator
    }
}

public struct StatusAccessibilityFormatter: Sendable {
    private let vocabulary: StatusAccessibilityVocabulary
    private let durationFormatter: SettingsDurationAccessibilityFormatter

    public init() {
        self.init(
            vocabulary: Self.localizedVocabulary(),
            durationVocabulary: Self.localizedDurationVocabulary()
        )
    }

    public init(
        vocabulary: StatusAccessibilityVocabulary,
        durationVocabulary: SettingsDurationAccessibilityVocabulary
    ) {
        self.vocabulary = vocabulary
        durationFormatter = SettingsDurationAccessibilityFormatter(
            vocabulary: durationVocabulary
        )
    }

    public func format(_ frame: DisplayFrame) -> String {
        switch frame {
        case .single(let quota):
            quotaLabel(quota)
        case .comparison(let codex, let spark):
            quotaLabel(codex)
                + vocabulary.comparisonSeparator
                + quotaLabel(spark)
        }
    }

    private func quotaLabel(_ quota: DisplayQuota) -> String {
        replace(
            vocabulary.quotaFormat,
            values: [
                "product": productName(quota.identifier.product),
                "duration": durationFormatter.format(quota.identifier.rawDurationMinutes),
                "value": valueLabel(quota.value)
            ]
        )
    }

    private func productName(_ product: UsageProduct) -> String {
        switch product {
        case .codex:
            "Codex"
        case .spark:
            "Spark"
        }
    }

    private func valueLabel(_ value: DisplayValueState) -> String {
        switch value {
        case .fresh(let percent):
            percentLabel(vocabulary.freshValueFormat, percent: percent)
        case .stale(let percent):
            percentLabel(vocabulary.staleValueFormat, percent: percent)
        case .loading:
            vocabulary.loadingValue
        case .unavailable:
            vocabulary.unavailableValue
        }
    }

    private func percentLabel(_ format: String, percent: Int) -> String {
        replace(format, values: ["percent": String(percent)])
    }

    private func replace(_ format: String, values: [String: String]) -> String {
        values.reduce(format) { result, value in
            result.replacingOccurrences(of: "{\(value.key)}", with: value.value)
        }
    }

    private static func localizedVocabulary() -> StatusAccessibilityVocabulary {
        StatusAccessibilityVocabulary(
            quotaFormat: localized("status.accessibility.quota.format"),
            freshValueFormat: localized("status.accessibility.value.fresh"),
            staleValueFormat: localized("status.accessibility.value.stale"),
            loadingValue: localized("status.accessibility.value.loading"),
            unavailableValue: localized("status.accessibility.value.unavailable"),
            comparisonSeparator: localized("status.accessibility.comparison.separator")
        )
    }

    private static func localizedDurationVocabulary(
    ) -> SettingsDurationAccessibilityVocabulary {
        SettingsDurationAccessibilityVocabulary(
            unknown: localized("status.accessibility.duration.unknown"),
            oneHour: localized("status.accessibility.duration.one-hour"),
            hours: localized("status.accessibility.duration.hours"),
            oneDay: localized("status.accessibility.duration.one-day"),
            days: localized("status.accessibility.duration.days"),
            oneWeek: localized("status.accessibility.duration.one-week"),
            weeks: localized("status.accessibility.duration.weeks")
        )
    }

    private static func localized(_ key: String) -> String {
        NSLocalizedString(key, bundle: .module, comment: "")
    }
}
