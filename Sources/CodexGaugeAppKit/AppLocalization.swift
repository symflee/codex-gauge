import CodexGaugeSettings
import Foundation

public struct AppLocalization {
    public let language: AppLanguage
    public let locale: Locale

    private let localizedBundle: Bundle?

    public init(language: AppLanguage) {
        self.init(language: language, resourceBundle: .module)
    }

    public init(
        language: AppLanguage,
        resourceBundle: Bundle
    ) {
        self.language = language
        locale = Locale(identifier: language.rawValue)
        localizedBundle = Self.localizedBundle(
            language: language,
            resourceBundle: resourceBundle
        )
    }

    public func string(_ key: String) -> String {
        localizedBundle?.localizedString(
            forKey: key,
            value: key,
            table: nil
        ) ?? key
    }

    private static func localizedBundle(
        language: AppLanguage,
        resourceBundle: Bundle
    ) -> Bundle? {
        guard let path = resourceBundle.path(
            forResource: language.rawValue,
            ofType: "lproj"
        ) else {
            return nil
        }
        return Bundle(path: path)
    }
}
