import CodexGaugeCore
import CodexGaugeRefresh
import CoreFoundation
import Foundation

enum PreferencesCodec {
    private static let currentVersion = 1

    static func encode(_ preferences: AppPreferences) throws -> Data {
        let object: [String: Any] = [
            "version": currentVersion,
            "display": encodeDisplay(preferences.displayPreference),
            "refreshProfile": preferences.refreshProfile.rawValue,
            "launchAtLoginIntent": preferences.launchAtLoginIntent,
            "selectedExecutableURL": encodeURL(preferences.selectedExecutableURL),
            "hasCompletedFirstLaunch": preferences.hasCompletedFirstLaunch
        ]
        return try JSONSerialization.data(
            withJSONObject: object,
            options: [.sortedKeys]
        )
    }

    static func decode(_ data: Data) -> AppPreferences {
        guard let object = try? JSONSerialization.jsonObject(with: data) else {
            return .default
        }
        guard let dictionary = object as? [String: Any] else {
            return .default
        }
        guard let version = integer(dictionary["version"]) else {
            return .default
        }
        switch version {
        case 0:
            return decodeVersionZero(dictionary)
        case currentVersion:
            return decodeCurrent(dictionary)
        default:
            return .default
        }
    }

    private static func encodeDisplay(
        _ preference: DisplayPreference
    ) -> [String: Any] {
        [
            "productMode": preference.productMode.rawValue,
            "selection": encodeSelection(preference.quotaSelection)
        ]
    }

    private static func encodeSelection(
        _ selection: DisplayQuotaSelection
    ) -> [String: Any] {
        guard case .manual(let identifiers) = selection else {
            return ["mode": "automatic"]
        }
        return [
            "mode": "manual",
            "items": sorted(identifiers).map(encodeIdentifier)
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

    private static func sorted(
        _ identifiers: Set<QuotaSelectionID>
    ) -> [QuotaSelectionID] {
        identifiers.sorted { left, right in
            if left.product != right.product {
                return left.product.rawValue < right.product.rawValue
            }
            return durationPrecedes(
                left.rawDurationMinutes,
                right.rawDurationMinutes
            )
        }
    }

    private static func durationPrecedes(_ left: Int?, _ right: Int?) -> Bool {
        switch (left, right) {
        case let (left?, right?):
            return left < right
        case (_?, nil):
            return true
        case (nil, _?):
            return false
        case (nil, nil):
            return false
        }
    }

    private static func decodeCurrent(
        _ dictionary: [String: Any]
    ) -> AppPreferences {
        AppPreferences(
            displayPreference: decodeDisplay(dictionary["display"]),
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
            ) ?? false
        )
    }

    private static func decodeDisplay(_ value: Any?) -> DisplayPreference {
        guard let dictionary = value as? [String: Any] else {
            return .default
        }
        let productMode = decodeProductMode(dictionary["productMode"])
        let selection = decodeSelection(dictionary["selection"])
        return DisplayPreference(
            productMode: productMode,
            quotaSelection: selection
        )
    }

    private static func decodeVersionZero(
        _ dictionary: [String: Any]
    ) -> AppPreferences {
        let display = DisplayPreference(
            productMode: decodeProductMode(
                dictionary["displayProductMode"]
            ),
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
            ) ?? false
        )
    }

    private static func decodeVersionZeroSelection(
        _ dictionary: [String: Any]
    ) -> DisplayQuotaSelection {
        guard string(dictionary["displayQuotaSelection"]) == "manual" else {
            return .automatic
        }
        return decodeManualSelection(dictionary["manualQuotaSelections"])
    }

    private static func decodeProductMode(_ value: Any?) -> DisplayProductMode {
        guard let rawValue = string(value) else {
            return .codex
        }
        return DisplayProductMode(rawValue: rawValue) ?? .codex
    }

    private static func decodeSelection(
        _ value: Any?
    ) -> DisplayQuotaSelection {
        guard let dictionary = value as? [String: Any] else {
            return .automatic
        }
        guard string(dictionary["mode"]) == "manual" else {
            return .automatic
        }
        return decodeManualSelection(dictionary["items"])
    }

    private static func decodeManualSelection(
        _ value: Any?
    ) -> DisplayQuotaSelection {
        guard let values = value as? [Any] else {
            return .automatic
        }
        let identifiers = Set(values.compactMap(decodeIdentifier))
        guard !identifiers.isEmpty else {
            return .automatic
        }
        return .manual(identifiers)
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
