import Foundation

public enum AppLanguage: String, CaseIterable, Equatable, Sendable {
    case korean = "ko"
    case english = "en"
}

public struct PreferredAppLanguageResolver: Sendable {
    public init() {}

    public func resolve(
        preferredLanguages: [String]
    ) -> AppLanguage {
        preferredLanguages.lazy.compactMap(resolve).first ?? .english
    }

    private func resolve(_ identifier: String) -> AppLanguage? {
        let normalized = identifier.replacingOccurrences(of: "_", with: "-")
        guard let languageCode = normalized.split(separator: "-").first else {
            return nil
        }
        switch languageCode.lowercased() {
        case AppLanguage.korean.rawValue:
            return .korean
        case AppLanguage.english.rawValue:
            return .english
        default:
            return nil
        }
    }
}
