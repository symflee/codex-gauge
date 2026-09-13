import CodexGaugeCore
import CodexGaugeSettings
import Foundation

public struct StatusAccessibilityVocabulary: Equatable, Sendable {
    public let quotaFormat: String
    public let freshValueFormat: String
    public let staleValueFormat: String
    public let loadingValue: String
    public let unavailableValue: String

    public init(
        quotaFormat: String,
        freshValueFormat: String,
        staleValueFormat: String,
        loadingValue: String,
        unavailableValue: String
    ) {
        self.quotaFormat = quotaFormat
        self.freshValueFormat = freshValueFormat
        self.staleValueFormat = staleValueFormat
        self.loadingValue = loadingValue
        self.unavailableValue = unavailableValue
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

    public init(language: AppLanguage) {
        let localization = AppLocalization(language: language)
        self.init(
            vocabulary: Self.localizedVocabulary(localization),
            durationVocabulary: Self.localizedDurationVocabulary(localization)
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
            unavailableValue: localized("status.accessibility.value.unavailable")
        )
    }

    private static func localizedVocabulary(
        _ localization: AppLocalization
    ) -> StatusAccessibilityVocabulary {
        StatusAccessibilityVocabulary(
            quotaFormat: localization.string(
                "status.accessibility.quota.format"
            ),
            freshValueFormat: localization.string(
                "status.accessibility.value.fresh"
            ),
            staleValueFormat: localization.string(
                "status.accessibility.value.stale"
            ),
            loadingValue: localization.string(
                "status.accessibility.value.loading"
            ),
            unavailableValue: localization.string(
                "status.accessibility.value.unavailable"
            )
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

    private static func localizedDurationVocabulary(
        _ localization: AppLocalization
    ) -> SettingsDurationAccessibilityVocabulary {
        SettingsDurationAccessibilityVocabulary(
            unknown: localization.string(
                "status.accessibility.duration.unknown"
            ),
            oneHour: localization.string(
                "status.accessibility.duration.one-hour"
            ),
            hours: localization.string(
                "status.accessibility.duration.hours"
            ),
            oneDay: localization.string(
                "status.accessibility.duration.one-day"
            ),
            days: localization.string(
                "status.accessibility.duration.days"
            ),
            oneWeek: localization.string(
                "status.accessibility.duration.one-week"
            ),
            weeks: localization.string(
                "status.accessibility.duration.weeks"
            )
        )
    }

    private static func localized(_ key: String) -> String {
        NSLocalizedString(key, bundle: .module, comment: "")
    }
}
