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
        self.displayPreference = displayPreference
        self.refreshProfile = refreshProfile
        self.launchAtLoginIntent = launchAtLoginIntent
        self.selectedExecutableURL = Self.fileURL(selectedExecutableURL)
        self.hasCompletedFirstLaunch = hasCompletedFirstLaunch
        self.language = language
        self.statusGaugeAppearance = statusGaugeAppearance
    }

    private static func fileURL(_ url: URL?) -> URL? {
        guard let url, url.isFileURL else {
            return nil
        }
        return url
    }
}
