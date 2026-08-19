import Foundation

public actor AppPreferencesRepository {
    public static let storageKey = "io.github.symflee.codex-gauge.preferences"

    private let userDefaults: UserDefaults
    private let defaultPreferences: AppPreferences

    public init(
        userDefaults: UserDefaults,
        defaultLanguage: AppLanguage = PreferredAppLanguageResolver().resolve(
            preferredLanguages: Locale.preferredLanguages
        )
    ) {
        self.userDefaults = userDefaults
        defaultPreferences = AppPreferences(language: defaultLanguage)
    }

    public func load() -> AppPreferences {
        guard let storedValue = userDefaults.object(forKey: Self.storageKey) else {
            persistDefaultPreferences()
            return defaultPreferences
        }
        guard let data = storedValue as? Data else {
            return defaultPreferences
        }
        let requiresMigration = PreferencesCodec.isKnownLegacySchema(data)
        let preferences = PreferencesCodec.decode(
            data,
            defaultLanguage: defaultPreferences.language
        )
        if requiresMigration {
            try? save(preferences)
        }
        return preferences
    }

    private func persistDefaultPreferences() {
        try? save(defaultPreferences)
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
            hasCompletedFirstLaunch: current.hasCompletedFirstLaunch,
            language: values.language
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
            hasCompletedFirstLaunch: current.hasCompletedFirstLaunch,
            language: current.language
        )
        try save(merged)
    }

    public func markFirstLaunchCompleted() throws {
        let current = load()
        guard current.hasCompletedFirstLaunch == false else {
            return
        }
        try save(current.replacingFirstLaunchCompletion(true))
    }

    public func resetFirstLaunchCompletionForUITesting() throws {
        let current = load()
        guard current.hasCompletedFirstLaunch else {
            return
        }
        try save(current.replacingFirstLaunchCompletion(false))
    }
}

private extension AppPreferences {
    func replacingFirstLaunchCompletion(_ isCompleted: Bool) -> AppPreferences {
        let merged = AppPreferences(
            displayPreference: displayPreference,
            refreshProfile: refreshProfile,
            launchAtLoginIntent: launchAtLoginIntent,
            selectedExecutableURL: selectedExecutableURL,
            hasCompletedFirstLaunch: isCompleted,
            language: language
        )
        return merged
    }
}
