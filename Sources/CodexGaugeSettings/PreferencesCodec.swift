import CodexGaugeCore
import CodexGaugeRefresh
import CoreFoundation
import Foundation

enum PreferencesCodec {
    private static let currentVersion = 5

    static func encode(_ preferences: AppPreferences) throws -> Data {
        let object: [String: Any] = [
            "version": currentVersion,
            "display": encodeDisplay(preferences.displayPreference),
            "refreshProfile": preferences.refreshProfile.rawValue,
            "launchAtLoginIntent": preferences.launchAtLoginIntent,
            "selectedExecutableURL": encodeURL(preferences.selectedExecutableURL),
            "hasCompletedFirstLaunch": preferences.hasCompletedFirstLaunch,
            "language": preferences.language.rawValue,
            "statusGaugeAppearance": encodeAppearance(
                preferences.statusGaugeAppearance
            )
        ]
        return try JSONSerialization.data(
            withJSONObject: object,
            options: [.sortedKeys]
        )
    }

    static func decode(
        _ data: Data,
        defaultLanguage: AppLanguage = .english
    ) -> AppPreferences {
        let fallback = AppPreferences(language: defaultLanguage)
        guard let object = try? JSONSerialization.jsonObject(with: data) else {
            return fallback
        }
        guard let dictionary = object as? [String: Any] else {
            return fallback
        }
        guard let version = integer(dictionary["version"]) else {
            return fallback
        }
        switch version {
        case 0:
            return decodeVersionZero(
                dictionary,
                defaultLanguage: defaultLanguage
            )
        case 1:
            return decodeVersionOne(
                dictionary,
                defaultLanguage: defaultLanguage
            )
        case 2:
            return decodeVersionTwo(
                dictionary,
                defaultLanguage: defaultLanguage
            )
        case 3:
            return decodeVersionThree(dictionary, defaultLanguage: defaultLanguage)
        case 4, currentVersion:
            return decodeCurrent(
                dictionary,
                defaultLanguage: defaultLanguage
            )
        default:
            return fallback
        }
    }

    static func isKnownLegacySchema(_ data: Data) -> Bool {
        guard let object = try? JSONSerialization.jsonObject(with: data) else {
            return false
        }
        guard let dictionary = object as? [String: Any] else {
            return false
        }
        guard let version = integer(dictionary["version"]) else {
            return false
        }
        return (0...4).contains(version)
    }

    private static func encodeDisplay(
        _ preference: DisplayPreference
    ) -> [String: Any] {
        [
            "selection": encodeSelection(preference.quotaSelection)
        ]
    }

    private static func encodeSelection(
        _ selection: DisplayQuotaSelection
    ) -> [String: Any] {
        guard case .manual(let identifier) = selection else {
            return ["mode": "automatic"]
        }
        return [
            "mode": "manual",
            "item": encodeIdentifier(identifier)
        ]
    }

    private static func encodeIdentifier(
        _ identifier: QuotaSelectionID
    ) -> [String: Any] {
        [
            "product": identifier.product.rawValue,
            "rawDurationMinutes": identifier.rawDurationMinutes ?? NSNull()
        ]
    }

    private static func encodeURL(_ url: URL?) -> Any {
        url?.absoluteString ?? NSNull()
    }

    private static func encodeAppearance(
        _ appearance: StatusGaugeAppearance
    ) -> [String: String] {
        switch appearance {
        case .preset(let preset):
            return ["mode": "preset", "preset": preset.rawValue]
        case .custom(let borderColor, let fillColor):
            return [
                "mode": "custom",
                "borderColor": borderColor.hexString,
                "fillColor": fillColor.hexString
            ]
        }
    }

    private static func decodeCurrent(
        _ dictionary: [String: Any],
        defaultLanguage: AppLanguage
    ) -> AppPreferences {
        decodeShared(
            dictionary,
            language: decodeLanguage(
                dictionary["language"],
                defaultLanguage: defaultLanguage
            ),
            appearance: decodeAppearance(dictionary["statusGaugeAppearance"])
        )
    }

    private static func decodeVersionThree(
        _ dictionary: [String: Any],
        defaultLanguage: AppLanguage
    ) -> AppPreferences {
        let appearance = decodeAppearance(dictionary["statusGaugeAppearance"])
        return decodeShared(
            dictionary,
            language: decodeLanguage(dictionary["language"], defaultLanguage: defaultLanguage),
            appearance: appearance == .preset(.blue) ? .default : appearance
        )
    }

    private static func decodeVersionTwo(
        _ dictionary: [String: Any],
        defaultLanguage: AppLanguage
    ) -> AppPreferences {
        decodeShared(
            dictionary,
            language: decodeLanguage(
                dictionary["language"],
                defaultLanguage: defaultLanguage
            ),
            appearance: .default
        )
    }

    private static func decodeVersionOne(
        _ dictionary: [String: Any],
        defaultLanguage: AppLanguage
    ) -> AppPreferences {
        decodeShared(
            dictionary,
            language: defaultLanguage,
            appearance: .default
        )
    }

    private static func decodeShared(
        _ dictionary: [String: Any],
        language: AppLanguage,
        appearance: StatusGaugeAppearance
    ) -> AppPreferences {
        AppPreferences(
            displayPreference: decodeDisplay(dictionary["display"], legacy: integer(dictionary["version"]) != currentVersion),
            refreshProfile: decodeRefreshProfile(
                dictionary["refreshProfile"]
            ),
            launchAtLoginIntent: boolean(
                dictionary["launchAtLoginIntent"]
            ) ?? false,
            selectedExecutableURL: fileURL(
                dictionary["selectedExecutableURL"]
            ),
            hasCompletedFirstLaunch: boolean(
                dictionary["hasCompletedFirstLaunch"]
            ) ?? false,
            language: language,
            statusGaugeAppearance: appearance
        )
    }

    private static func decodeAppearance(_ value: Any?) -> StatusGaugeAppearance {
        guard let dictionary = value as? [String: Any] else {
            return .default
        }
        switch string(dictionary["mode"]) {
        case "preset":
            return decodePresetAppearance(dictionary["preset"])
        case "custom":
            return decodeCustomAppearance(dictionary)
        default:
            return .default
        }
    }

    private static func decodePresetAppearance(_ value: Any?) -> StatusGaugeAppearance {
        guard let rawValue = string(value) else {
            return .default
        }
        guard let preset = StatusGaugePreset(rawValue: rawValue) else {
            return .default
        }
        return .preset(preset)
    }

    private static func decodeCustomAppearance(
        _ dictionary: [String: Any]
    ) -> StatusGaugeAppearance {
        let borderColor = decodeColor(dictionary["borderColor"])
            ?? StatusGaugePreset.blue.borderColor
        let fillColor = decodeColor(dictionary["fillColor"])
            ?? StatusGaugePreset.blue.fillColor
        return .custom(borderColor: borderColor, fillColor: fillColor)
    }

    private static func decodeColor(_ value: Any?) -> StatusGaugeColor? {
        guard let hexString = string(value) else {
            return nil
        }
        return StatusGaugeColor(hexString: hexString)
    }

    private static func decodeDisplay(_ value: Any?, legacy: Bool) -> DisplayPreference {
        guard let dictionary = value as? [String: Any] else {
            return .default
        }
        let selection = decodeSelection(dictionary["selection"], legacy: legacy)
        return DisplayPreference(
            quotaSelection: selection
        )
    }

    private static func decodeVersionZero(
        _ dictionary: [String: Any],
        defaultLanguage: AppLanguage
    ) -> AppPreferences {
        let display = DisplayPreference(
            quotaSelection: decodeVersionZeroSelection(dictionary)
        )
        return AppPreferences(
            displayPreference: display,
            refreshProfile: decodeRefreshProfile(
                dictionary["refreshProfile"]
            ),
            launchAtLoginIntent: boolean(
                dictionary["launchAtLoginIntent"]
            ) ?? false,
            selectedExecutableURL: fileURL(
                dictionary["selectedExecutableURL"]
            ),
            hasCompletedFirstLaunch: boolean(
                dictionary["hasCompletedFirstLaunch"]
            ) ?? false,
            language: defaultLanguage
        )
    }

    private static func decodeLanguage(
        _ value: Any?,
        defaultLanguage: AppLanguage
    ) -> AppLanguage {
        guard let rawValue = string(value) else {
            return defaultLanguage
        }
        return AppLanguage(rawValue: rawValue) ?? defaultLanguage
    }

    private static func decodeVersionZeroSelection(
        _ dictionary: [String: Any]
    ) -> DisplayQuotaSelection {
        guard string(dictionary["displayQuotaSelection"]) == "manual" else {
            return .automatic
        }
        return decodeManualSelection(dictionary["manualQuotaSelections"])
    }

    private static func decodeSelection(
        _ value: Any?,
        legacy: Bool
    ) -> DisplayQuotaSelection {
        guard let dictionary = value as? [String: Any] else {
            return .automatic
        }
        guard string(dictionary["mode"]) == "manual" else {
            return .automatic
        }
        if legacy {
            return decodeManualSelection(dictionary["items"])
        }
        guard let item = dictionary["item"], let identifier = decodeIdentifier(item) else {
            return .automatic
        }
        return .manual(identifier)
    }

    private static func decodeManualSelection(
        _ value: Any?
    ) -> DisplayQuotaSelection {
        guard let values = value as? [Any] else {
            return .automatic
        }
        let identifiers = Set(values.compactMap(decodeIdentifier))
        guard identifiers.count == 1, let identifier = identifiers.first else {
            return .automatic
        }
        return .manual(identifier)
    }

    private static func decodeIdentifier(_ value: Any) -> QuotaSelectionID? {
        guard let dictionary = value as? [String: Any] else {
            return nil
        }
        guard let productValue = string(dictionary["product"]) else {
            return nil
        }
        guard let product = UsageProduct(rawValue: productValue) else {
            return nil
        }
        guard dictionary.keys.contains("rawDurationMinutes") else {
            return nil
        }
        guard let duration = decodeDuration(dictionary["rawDurationMinutes"]) else {
            return nil
        }
        return QuotaSelectionID(
            product: product,
            rawDurationMinutes: duration.value
        )
    }

    private static func decodeDuration(_ value: Any?) -> OptionalDuration? {
        guard let value else {
            return nil
        }
        guard !(value is NSNull) else {
            return OptionalDuration(value: nil)
        }
        guard let minutes = integer(value), minutes > 0 else {
            return nil
        }
        return OptionalDuration(value: minutes)
    }

    private static func decodeRefreshProfile(_ value: Any?) -> RefreshProfile {
        guard let rawValue = string(value) else {
            return .default
        }
        return RefreshProfile(rawValue: rawValue) ?? .default
    }

    private static func fileURL(_ value: Any?) -> URL? {
        guard let rawValue = string(value) else {
            return nil
        }
        guard let url = URL(string: rawValue), url.isFileURL else {
            return nil
        }
        return url
    }

    private static func string(_ value: Any?) -> String? {
        value as? String
    }

    private static func boolean(_ value: Any?) -> Bool? {
        guard let number = value as? NSNumber else {
            return nil
        }
        guard CFGetTypeID(number) == CFBooleanGetTypeID() else {
            return nil
        }
        return number.boolValue
    }

    private static func integer(_ value: Any?) -> Int? {
        guard let number = value as? NSNumber else {
            return nil
        }
        guard CFGetTypeID(number) != CFBooleanGetTypeID() else {
            return nil
        }
        return Int(number.stringValue)
    }
}

private struct OptionalDuration {
    let value: Int?
}
