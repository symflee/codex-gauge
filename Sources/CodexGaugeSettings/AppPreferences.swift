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

    public init(
        displayPreference: DisplayPreference = .default,
        refreshProfile: RefreshProfile = .default,
        launchAtLoginIntent: Bool = false,
        selectedExecutableURL: URL? = nil,
        hasCompletedFirstLaunch: Bool = false
    ) {
        self.displayPreference = Self.normalize(displayPreference)
        self.refreshProfile = refreshProfile
        self.launchAtLoginIntent = launchAtLoginIntent
        self.selectedExecutableURL = Self.fileURL(selectedExecutableURL)
        self.hasCompletedFirstLaunch = hasCompletedFirstLaunch
    }

    private static func normalize(
        _ preference: DisplayPreference
    ) -> DisplayPreference {
        guard case .manual(let identifiers) = preference.quotaSelection else {
            return preference
        }
        guard !identifiers.isEmpty else {
            return DisplayPreference(
                productMode: preference.productMode,
                quotaSelection: .automatic
            )
        }
        return preference
    }

    private static func fileURL(_ url: URL?) -> URL? {
        guard let url, url.isFileURL else {
            return nil
        }
        return url
    }
}
