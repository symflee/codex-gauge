import Foundation

public struct SettingsDurationAccessibilityVocabulary: Equatable, Sendable {
    public let unknown: String
    public let oneHour: String
    public let hours: String
    public let oneDay: String
    public let days: String
    public let oneWeek: String
    public let weeks: String

    public init(
        unknown: String,
        oneHour: String,
        hours: String,
        oneDay: String,
        days: String,
        oneWeek: String,
        weeks: String
    ) {
        self.unknown = unknown
        self.oneHour = oneHour
        self.hours = hours
        self.oneDay = oneDay
        self.days = days
        self.oneWeek = oneWeek
        self.weeks = weeks
    }
}

public struct SettingsDurationAccessibilityFormatter: Sendable {
    private let vocabulary: SettingsDurationAccessibilityVocabulary

    public init(vocabulary: SettingsDurationAccessibilityVocabulary) {
        self.vocabulary = vocabulary
    }

    public func format(_ minutes: Int?) -> String {
        guard let minutes, minutes > 0 else {
            return vocabulary.unknown
        }
        return switch minutes {
        case 300:
            unit(5, one: vocabulary.oneHour, many: vocabulary.hours)
        case 1_440:
            unit(1, one: vocabulary.oneDay, many: vocabulary.days)
        case 10_080:
            unit(1, one: vocabulary.oneWeek, many: vocabulary.weeks)
        case 20_160:
            unit(2, one: vocabulary.oneWeek, many: vocabulary.weeks)
        case 43_200:
            unit(30, one: vocabulary.oneDay, many: vocabulary.days)
        default:
            exactUnit(minutes)
        }
    }

    private func exactUnit(_ minutes: Int) -> String {
        if minutes.isMultiple(of: 1_440) {
            return unit(
                minutes / 1_440,
                one: vocabulary.oneDay,
                many: vocabulary.days
            )
        }
        guard minutes.isMultiple(of: 60) else {
            return vocabulary.unknown
        }
        return unit(
            minutes / 60,
            one: vocabulary.oneHour,
            many: vocabulary.hours
        )
    }

    private func unit(_ count: Int, one: String, many: String) -> String {
        guard count != 1 else {
            return one
        }
        return many.replacingOccurrences(of: "{count}", with: String(count))
    }
}
