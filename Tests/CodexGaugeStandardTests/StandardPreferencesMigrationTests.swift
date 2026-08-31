import CodexGaugeCore
import CodexGaugeRefresh
import CodexGaugeSettings
import Foundation
import Testing

@Test("Preferred app language resolves supported system languages")
func preferredAppLanguageContract() {
    let resolver = PreferredAppLanguageResolver()

    #expect(
        resolver.resolve(preferredLanguages: ["ko-KR", "en-US"]) == .korean
    )
    #expect(
        resolver.resolve(preferredLanguages: ["en_KR", "ko-KR"]) == .english
    )
    #expect(
        resolver.resolve(preferredLanguages: ["ja-JP", "ko_KR"]) == .korean
    )
    #expect(
        resolver.resolve(preferredLanguages: ["ja-JP", "fr-FR"]) == .english
    )
}

@Test("Initial system language is persisted once")
func initialSystemLanguagePersistenceContract() async throws {
    let store = try StandardPreferencesStore(
        initialData: nil,
        defaultLanguage: .korean
    )
    defer { store.cleanUp() }

    let firstLoad = await store.repository.load()
    let secondRepository = AppPreferencesRepository(
        userDefaults: try #require(UserDefaults(suiteName: store.suiteName)),
        defaultLanguage: .english
    )
    let secondLoad = await secondRepository.load()

    #expect(firstLoad.language == .korean)
    #expect(secondLoad.language == .korean)
    let persistedData = try #require(store.storedData())
    let persisted = try #require(
        JSONSerialization.jsonObject(with: persistedData) as? [String: Any]
    )
    #expect(persisted["version"] as? Int == 3)
    #expect(persisted["language"] as? String == "ko")
    #expect(firstLoad.statusGaugeAppearance == .default)
    #expect(firstLoad.statusGaugeAppearance.borderColor.hexString == "#004C99")
    #expect(firstLoad.statusGaugeAppearance.fillColor.hexString == "#0A84FF")
}

@Test("Version zero preferences migrate through the isolated repository")
func versionZeroPreferencesMigrationContract() async throws {
    let payload: [String: Any] = [
        "version": 0,
        "displayProductMode": "both",
        "displayQuotaSelection": "manual",
        "manualQuotaSelections": [
            ["product": "codex", "rawDurationMinutes": 300],
            ["product": "spark", "rawDurationMinutes": 10_080]
        ],
        "refreshProfile": "eco",
        "launchAtLoginIntent": true,
        "hasCompletedFirstLaunch": true
    ]
    let store = try StandardPreferencesStore(
        initialData: JSONSerialization.data(withJSONObject: payload),
        defaultLanguage: .korean
    )
    defer { store.cleanUp() }

    let preferences = await store.repository.load()
    let expectedIdentifiers: Set<QuotaSelectionID> = [
        QuotaSelectionID(product: .codex, rawDurationMinutes: 300),
        QuotaSelectionID(product: .spark, rawDurationMinutes: 10_080)
    ]

    #expect(preferences.displayPreference.productMode == .both)
    #expect(
        preferences.displayPreference.quotaSelection
            == .manual(expectedIdentifiers)
    )
    #expect(preferences.refreshProfile == .eco)
    #expect(preferences.launchAtLoginIntent)
    #expect(preferences.hasCompletedFirstLaunch)
    #expect(preferences.language == .korean)

    let automaticallyMigratedData = try #require(store.storedData())
    let automaticallyMigrated = try #require(
        JSONSerialization.jsonObject(with: automaticallyMigratedData)
            as? [String: Any]
    )
    #expect(automaticallyMigrated["version"] as? Int == 3)
    #expect(automaticallyMigrated["language"] as? String == "ko")
    #expect(preferences.statusGaugeAppearance == .default)
    #expect(preferences.statusGaugeAppearance.fillColor.hexString == "#0A84FF")

    try await store.repository.save(preferences)
    let migratedData = try #require(store.storedData())
    let migratedObject = try #require(
        JSONSerialization.jsonObject(with: migratedData) as? [String: Any]
    )

    #expect(migratedObject["version"] as? Int == 3)
    #expect(migratedObject["language"] as? String == "ko")
}

@Test("Version one preferences migrate with the injected system language")
func versionOnePreferencesMigrationContract() async throws {
    let payload: [String: Any] = [
        "version": 1,
        "display": [
            "productMode": "spark",
            "selection": ["mode": "automatic"]
        ],
        "refreshProfile": "fast",
        "launchAtLoginIntent": true,
        "hasCompletedFirstLaunch": true
    ]
    let store = try StandardPreferencesStore(
        initialData: JSONSerialization.data(withJSONObject: payload),
        defaultLanguage: .korean
    )
    defer { store.cleanUp() }

    let preferences = await store.repository.load()

    #expect(preferences.language == .korean)
    #expect(preferences.displayPreference.productMode == .spark)
    #expect(preferences.refreshProfile == .fast)
    #expect(preferences.launchAtLoginIntent)
    #expect(preferences.hasCompletedFirstLaunch)

    let migratedData = try #require(store.storedData())
    let migrated = try #require(
        JSONSerialization.jsonObject(with: migratedData) as? [String: Any]
    )
    #expect(migrated["version"] as? Int == 3)
    #expect(migrated["language"] as? String == "ko")
    #expect(preferences.statusGaugeAppearance == .default)
    #expect(preferences.statusGaugeAppearance.fillColor.hexString == "#0A84FF")
}

@Test("Version two preferences migrate with a default gauge appearance")
func versionTwoPreferencesMigrationContract() async throws {
    let payload: [String: Any] = [
        "version": 2,
        "display": [
            "productMode": "codex",
            "selection": ["mode": "automatic"]
        ],
        "refreshProfile": "balanced",
        "language": "ko"
    ]
    let store = try StandardPreferencesStore(
        initialData: JSONSerialization.data(withJSONObject: payload)
    )
    defer { store.cleanUp() }

    let preferences = await store.repository.load()
    let migratedData = try #require(store.storedData())
    let migrated = try #require(
        JSONSerialization.jsonObject(with: migratedData) as? [String: Any]
    )

    #expect(preferences.statusGaugeAppearance == .default)
    #expect(preferences.statusGaugeAppearance.fillColor.hexString == "#0A84FF")
    #expect(migrated["version"] as? Int == 3)
}

@Test("Malformed and future preference payloads use safe defaults")
func unsafePreferencePayloadFallbackContract() async throws {
    let payloads = [
        Data([0xFF, 0x00]),
        try JSONSerialization.data(
            withJSONObject: ["refreshProfile": "fast"]
        ),
        try JSONSerialization.data(
            withJSONObject: ["version": 999, "refreshProfile": "fast"]
        )
    ]

    for payload in payloads {
        let store = try StandardPreferencesStore(
            initialData: payload,
            defaultLanguage: .korean
        )
        let originalData = try #require(store.storedData())
        #expect(
            await store.repository.load() == AppPreferences(language: .korean)
        )
        #expect(store.storedData() == originalData)
        store.cleanUp()
    }
}

private struct StandardPreferencesStore {
    let repository: AppPreferencesRepository
    let suiteName: String

    init(
        initialData: Data?,
        defaultLanguage: AppLanguage = .english
    ) throws {
        let suiteName = "io.github.symflee.codex-gauge.standard-tests.\(UUID().uuidString)"
        let userDefaults = try #require(UserDefaults(suiteName: suiteName))
        userDefaults.removePersistentDomain(forName: suiteName)
        if let initialData {
            userDefaults.set(
                initialData,
                forKey: AppPreferencesRepository.storageKey
            )
        }
        self.suiteName = suiteName
        self.repository = AppPreferencesRepository(
            userDefaults: userDefaults,
            defaultLanguage: defaultLanguage
        )
    }

    func storedData() -> Data? {
        UserDefaults(suiteName: suiteName)?.data(
            forKey: AppPreferencesRepository.storageKey
        )
    }

    func cleanUp() {
        UserDefaults.standard.removePersistentDomain(forName: suiteName)
    }
}
