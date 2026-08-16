import CodexGaugeCore
import CodexGaugeRefresh
import CodexGaugeSettings
import Foundation
import Testing

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
        initialData: JSONSerialization.data(withJSONObject: payload)
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

    try await store.repository.save(preferences)
    let migratedData = try #require(store.storedData())
    let migratedObject = try #require(
        JSONSerialization.jsonObject(with: migratedData) as? [String: Any]
    )

    #expect(migratedObject["version"] as? Int == 1)
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
        let store = try StandardPreferencesStore(initialData: payload)
        #expect(await store.repository.load() == .default)
        store.cleanUp()
    }
}

private struct StandardPreferencesStore {
    let repository: AppPreferencesRepository

    private let suiteName: String
    init(initialData: Data) throws {
        let suiteName = "io.github.symflee.codex-gauge.standard-tests.\(UUID().uuidString)"
        let userDefaults = try #require(UserDefaults(suiteName: suiteName))
        userDefaults.removePersistentDomain(forName: suiteName)
        userDefaults.set(
            initialData,
            forKey: AppPreferencesRepository.storageKey
        )
        self.suiteName = suiteName
        self.repository = AppPreferencesRepository(userDefaults: userDefaults)
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
