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
}
