import Foundation

public actor AppPreferencesRepository {
    public static let storageKey = "io.github.symflee.codex-gauge.preferences"

    private let userDefaults: UserDefaults

    public init(userDefaults: UserDefaults) {
        self.userDefaults = userDefaults
    }

    public func load() -> AppPreferences {
        guard let data = userDefaults.data(forKey: Self.storageKey) else {
            return .default
        }
        return PreferencesCodec.decode(data)
    }

    public func save(_ preferences: AppPreferences) throws {
        let data = try PreferencesCodec.encode(preferences)
        userDefaults.set(data, forKey: Self.storageKey)
    }

    public func saveSettingsForm(_ values: SettingsFormValues) throws {
        let current = load()
        let merged = AppPreferences(
            displayPreference: values.displayPreference,
            refreshProfile: values.refreshProfile,
            launchAtLoginIntent: values.launchAtLoginIntent,
            selectedExecutableURL: current.selectedExecutableURL,
            hasCompletedFirstLaunch: current.hasCompletedFirstLaunch
        )
        try save(merged)
    }

    public func saveSelectedExecutableURL(_ url: URL?) throws {
        let current = load()
        let merged = AppPreferences(
            displayPreference: current.displayPreference,
            refreshProfile: current.refreshProfile,
            launchAtLoginIntent: current.launchAtLoginIntent,
            selectedExecutableURL: url,
            hasCompletedFirstLaunch: current.hasCompletedFirstLaunch
        )
        try save(merged)
    }

    public func markFirstLaunchCompleted() throws {
        let current = load()
        guard current.hasCompletedFirstLaunch == false else {
            return
        }
        let merged = AppPreferences(
            displayPreference: current.displayPreference,
            refreshProfile: current.refreshProfile,
            launchAtLoginIntent: current.launchAtLoginIntent,
            selectedExecutableURL: current.selectedExecutableURL,
            hasCompletedFirstLaunch: true
        )
        try save(merged)
    }
}
