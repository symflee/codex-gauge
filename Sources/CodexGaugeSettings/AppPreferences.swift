import CodexGaugeCore
import CodexGaugeRefresh
import Foundation

public struct AppPreferences: Equatable, Sendable {
    public static let `default` = AppPreferences()

    public let displayPreference: DisplayPreference
    public let refreshProfile: RefreshProfile
    public let launchAtLoginIntent: Bool
    public let selectedExecutableURL: URL?
    public let hasCompletedFirstLaunch: Bool
    public let language: AppLanguage
    public let statusGaugeAppearance: StatusGaugeAppearance

    public init(
        displayPreference: DisplayPreference = .default,
        refreshProfile: RefreshProfile = .default,
        launchAtLoginIntent: Bool = false,
        selectedExecutableURL: URL? = nil,
        hasCompletedFirstLaunch: Bool = false,
        language: AppLanguage = .english,
        statusGaugeAppearance: StatusGaugeAppearance = .default
    ) {
        self.displayPreference = Self.normalize(displayPreference)
        self.refreshProfile = refreshProfile
        self.launchAtLoginIntent = launchAtLoginIntent
        self.selectedExecutableURL = Self.fileURL(selectedExecutableURL)
        self.hasCompletedFirstLaunch = hasCompletedFirstLaunch
        self.language = language
        self.statusGaugeAppearance = statusGaugeAppearance
    }

    private static func normalize(
        _ preference: DisplayPreference
    ) -> DisplayPreference {
        guard case .manual(let identifiers) = preference.quotaSelection else {
            return preference
        }
        let displayedProducts = Set(preference.productMode.products)
        let relevantIdentifiers = Set(identifiers.filter { identifier in
            displayedProducts.contains(identifier.product)
        })
        guard !relevantIdentifiers.isEmpty else {
            return DisplayPreference(
                productMode: preference.productMode,
                quotaSelection: .automatic
            )
        }
        return DisplayPreference(
            productMode: preference.productMode,
            quotaSelection: .manual(relevantIdentifiers)
        )
    }

    private static func fileURL(_ url: URL?) -> URL? {
        guard let url, url.isFileURL else {
            return nil
        }
        return url
    }
}
