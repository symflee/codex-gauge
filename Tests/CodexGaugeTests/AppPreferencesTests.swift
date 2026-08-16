import CodexGaugeCore
import CodexGaugeRefresh
import CodexGaugeSettings
import Foundation

func appPreferencesTests() -> [TestCase] {
    [
        appPreferencesDefaultsTest(),
        appPreferencesRoundTripTest(),
        appPreferencesDeterministicEncodingTest(),
        appPreferencesMalformedSchemaTest(),
        appPreferencesFieldRecoveryTest(),
        appPreferencesVersionZeroMigrationTest(),
        appPreferencesEmptyManualSelectionTest(),
        appPreferencesNonFileURLTest(),
        appPreferencesExecutableSelectionMergeTest(),
        appPreferencesFirstLaunchAtomicMergeTest(),
        appPreferencesSuiteIsolationTest(),
        appPreferencesSafePayloadTest(),
        appPreferencesSendabilityTest()
    ]
}

private func appPreferencesDefaultsTest() -> TestCase {
    TestCase(name: "preferences load safe defaults from an empty suite") {
        let store = try PreferencesTestStore()
        defer { store.cleanUp() }
        let repository = try store.repository()

        let preferences = await repository.load()

        try expect(preferences == .default, "Expected default preferences")
        try expect(preferences.displayPreference == .default, "Expected default display")
        try expect(preferences.refreshProfile == .balanced, "Expected balanced refresh")
        try expect(!preferences.launchAtLoginIntent, "Expected login launch disabled")
        try expect(preferences.selectedExecutableURL == nil, "Expected no selected executable")
        try expect(!preferences.hasCompletedFirstLaunch, "Expected incomplete first launch")
    }
}

private func appPreferencesRoundTripTest() -> TestCase {
    TestCase(name: "preferences round trip every product and selection mode") {
        let store = try PreferencesTestStore()
        defer { store.cleanUp() }
        let repository = try store.repository()
        let identifiers = Set([
            QuotaSelectionID(product: .codex, rawDurationMinutes: nil),
            QuotaSelectionID(product: .codex, rawDurationMinutes: 300),
            QuotaSelectionID(product: .spark, rawDurationMinutes: 10_080)
        ])

        for productMode in DisplayProductMode.allCases {
            for refreshProfile in RefreshProfile.allCases {
                let automatic = AppPreferences(
                    displayPreference: DisplayPreference(
                        productMode: productMode,
                        quotaSelection: .automatic
                    ),
                    refreshProfile: refreshProfile,
                    launchAtLoginIntent: false,
                    selectedExecutableURL: nil,
                    hasCompletedFirstLaunch: true
                )
                try await repository.save(automatic)
                let loadedAutomatic = await repository.load()
                try expect(loadedAutomatic == automatic, "Expected automatic round trip")

                let manual = AppPreferences(
                    displayPreference: DisplayPreference(
                        productMode: productMode,
                        quotaSelection: .manual(identifiers)
                    ),
                    refreshProfile: refreshProfile,
                    launchAtLoginIntent: true,
                    selectedExecutableURL: syntheticExecutableURL,
                    hasCompletedFirstLaunch: true
                )
                try await repository.save(manual)
                let loadedManual = await repository.load()
                try expect(loadedManual == manual, "Expected manual round trip")
            }
        }
    }
}

private func appPreferencesDeterministicEncodingTest() -> TestCase {
    TestCase(name: "manual preference encoding is deterministic") {
        let store = try PreferencesTestStore()
        defer { store.cleanUp() }
        let repository = try store.repository()
        let firstIdentifier = QuotaSelectionID(
            product: .spark,
            rawDurationMinutes: nil
        )
        let secondIdentifier = QuotaSelectionID(
            product: .codex,
            rawDurationMinutes: 10_080
        )
        let thirdIdentifier = QuotaSelectionID(
            product: .codex,
            rawDurationMinutes: 300
        )
        let first = manualPreferences(
            Set([firstIdentifier, secondIdentifier, thirdIdentifier])
        )
        let second = manualPreferences(
            Set([thirdIdentifier, firstIdentifier, secondIdentifier])
        )

        try await repository.save(first)
        let firstData = try storedPreferencesData(in: store.userDefaults)
        try await repository.save(second)
        let secondData = try storedPreferencesData(in: store.userDefaults)

        try expect(firstData == secondData, "Expected stable bytes for an unordered set")
        let object = try preferencesJSONObject(from: firstData)
        guard let display = object["display"] as? [String: Any],
              let selection = display["selection"] as? [String: Any],
              let items = selection["items"] as? [[String: Any]],
              items.count == 3 else {
            throw TestFailure(description: "Expected canonical manual items")
        }
        try expect(items[0]["product"] as? String == "codex", "Expected Codex first")
        try expect(items[0]["rawDurationMinutes"] as? Int == 300, "Expected shortest first")
        try expect(items[1]["product"] as? String == "codex", "Expected grouped product")
        try expect(items[1]["rawDurationMinutes"] as? Int == 10_080, "Expected duration order")
        try expect(items[2]["product"] as? String == "spark", "Expected Spark last")
        try expect(items[2]["rawDurationMinutes"] is NSNull, "Expected unknown duration last")
    }
}

private func appPreferencesMalformedSchemaTest() -> TestCase {
    TestCase(name: "preferences recover from malformed and future schemas") {
        let store = try PreferencesTestStore()
        defer { store.cleanUp() }
        let repository = try store.repository()

        store.userDefaults.set("not-data", forKey: AppPreferencesRepository.storageKey)
        let wrongStorageType = await repository.load()
        try expect(wrongStorageType == .default, "Expected non-Data fallback")

        store.userDefaults.set(Data([0xFF, 0x00]), forKey: AppPreferencesRepository.storageKey)
        let malformed = await repository.load()
        try expect(malformed == .default, "Expected malformed data fallback")

        store.userDefaults.set(try preferencesJSON(["not", "an", "object"]), forKey: AppPreferencesRepository.storageKey)
        let wrongShape = await repository.load()
        try expect(wrongShape == .default, "Expected non-object fallback")

        store.userDefaults.set(
            try preferencesJSON(["version": 999, "refreshProfile": "fast"]),
            forKey: AppPreferencesRepository.storageKey
        )
        let future = await repository.load()
        try expect(future == .default, "Expected future schema fallback")

        store.userDefaults.set(
            try preferencesJSON(["refreshProfile": "fast"]),
            forKey: AppPreferencesRepository.storageKey
        )
        let missingVersion = await repository.load()
        try expect(missingVersion == .default, "Expected missing version fallback")

        store.userDefaults.set(
            try preferencesJSON(["version": UInt64(Int64.max) + 1]),
            forKey: AppPreferencesRepository.storageKey
        )
        let overflowingVersion = await repository.load()
        try expect(overflowingVersion == .default, "Expected overflowing version fallback")
    }
}

private func appPreferencesFieldRecoveryTest() -> TestCase {
    TestCase(name: "preferences recover malformed fields independently") {
        let store = try PreferencesTestStore()
        defer { store.cleanUp() }
        let repository = try store.repository()
        let payload: [String: Any] = [
            "version": 1,
            "display": [
                "productMode": "future-product",
                "selection": [
                    "mode": "manual",
                    "items": [
                        ["product": "codex", "rawDurationMinutes": 300],
                        ["product": "future-product", "rawDurationMinutes": 300],
                        ["product": "spark", "rawDurationMinutes": "invalid"]
                    ]
                ]
            ],
            "refreshProfile": "future-profile",
            "launchAtLoginIntent": true,
            "selectedExecutableURL": "https://example.invalid/codex",
            "hasCompletedFirstLaunch": "invalid",
            "futureField": ["ignored": true]
        ]
        store.userDefaults.set(
            try preferencesJSON(payload),
            forKey: AppPreferencesRepository.storageKey
        )

        let preferences = await repository.load()
        let expectedIdentifiers = Set([
            QuotaSelectionID(product: .codex, rawDurationMinutes: 300)
        ])

        try expect(preferences.displayPreference.productMode == .codex, "Expected product fallback")
        try expect(
            preferences.displayPreference.quotaSelection == .manual(expectedIdentifiers),
            "Expected valid manual item preservation"
        )
        try expect(preferences.refreshProfile == .balanced, "Expected refresh fallback")
        try expect(preferences.launchAtLoginIntent, "Expected valid login intent")
        try expect(preferences.selectedExecutableURL == nil, "Expected invalid URL rejection")
        try expect(!preferences.hasCompletedFirstLaunch, "Expected boolean fallback")

        let unknownSelectionPayload: [String: Any] = [
            "version": 1,
            "display": [
                "productMode": "spark",
                "selection": [
                    "mode": "future-selection",
                    "items": [["product": "spark", "rawDurationMinutes": 300]]
                ]
            ],
            "refreshProfile": "manual"
        ]
        store.userDefaults.set(
            try preferencesJSON(unknownSelectionPayload),
            forKey: AppPreferencesRepository.storageKey
        )
        let unknownSelection = await repository.load()
        try expect(
            unknownSelection.displayPreference.quotaSelection == .automatic,
            "Expected unknown selection fallback"
        )
        try expect(
            unknownSelection.displayPreference.productMode == .spark,
            "Expected valid sibling field preservation"
        )
        try expect(
            unknownSelection.refreshProfile == .manual,
            "Expected valid manual refresh profile"
        )
    }
}

private func appPreferencesVersionZeroMigrationTest() -> TestCase {
    TestCase(name: "preferences migrate the flattened version zero schema") {
        let store = try PreferencesTestStore()
        defer { store.cleanUp() }
        let repository = try store.repository()
        let payload: [String: Any] = [
            "version": 0,
            "displayProductMode": "both",
            "displayQuotaSelection": "manual",
            "manualQuotaSelections": [
                ["product": "spark", "rawDurationMinutes": 10_080],
                ["product": "codex", "rawDurationMinutes": NSNull()]
            ],
            "refreshProfile": "eco",
            "launchAtLoginIntent": true,
            "selectedExecutableURL": syntheticExecutableURL.absoluteString,
            "hasCompletedFirstLaunch": true
        ]
        store.userDefaults.set(
            try preferencesJSON(payload),
            forKey: AppPreferencesRepository.storageKey
        )

        let preferences = await repository.load()
        let expectedIdentifiers = Set([
            QuotaSelectionID(product: .spark, rawDurationMinutes: 10_080),
            QuotaSelectionID(product: .codex, rawDurationMinutes: nil)
        ])

        try expect(preferences.displayPreference.productMode == .both, "Expected migrated products")
        try expect(
            preferences.displayPreference.quotaSelection == .manual(expectedIdentifiers),
            "Expected migrated manual selection"
        )
        try expect(preferences.refreshProfile == .eco, "Expected migrated refresh profile")
        try expect(preferences.launchAtLoginIntent, "Expected migrated login intent")
        try expect(preferences.selectedExecutableURL == syntheticExecutableURL, "Expected migrated URL")
        try expect(preferences.hasCompletedFirstLaunch, "Expected migrated first launch")

        try await repository.save(preferences)
        let migratedData = try storedPreferencesData(in: store.userDefaults)
        let migratedObject = try preferencesJSONObject(from: migratedData)
        try expect(migratedObject["version"] as? Int == 1, "Expected current schema on save")

        let malformedPayload: [String: Any] = [
            "version": 0,
            "displayProductMode": "future-product",
            "displayQuotaSelection": "manual",
            "manualQuotaSelections": [
                ["product": "spark", "rawDurationMinutes": 300],
                ["product": "codex"],
                ["product": "future-product", "rawDurationMinutes": 10_080]
            ],
            "refreshProfile": "future-profile",
            "launchAtLoginIntent": "invalid",
            "selectedExecutableURL": "https://example.invalid/codex",
            "hasCompletedFirstLaunch": true
        ]
        store.userDefaults.set(
            try preferencesJSON(malformedPayload),
            forKey: AppPreferencesRepository.storageKey
        )
        let recovered = await repository.load()
        let survivingIdentifier = QuotaSelectionID(
            product: .spark,
            rawDurationMinutes: 300
        )

        try expect(recovered.displayPreference.productMode == .codex, "Expected v0 mode fallback")
        try expect(
            recovered.displayPreference.quotaSelection == .manual([survivingIdentifier]),
            "Expected valid v0 manual sibling"
        )
        try expect(recovered.refreshProfile == .balanced, "Expected v0 refresh fallback")
        try expect(!recovered.launchAtLoginIntent, "Expected v0 boolean fallback")
        try expect(recovered.selectedExecutableURL == nil, "Expected v0 URL fallback")
        try expect(recovered.hasCompletedFirstLaunch, "Expected valid v0 sibling preserved")
    }
}

private func appPreferencesEmptyManualSelectionTest() -> TestCase {
    TestCase(name: "empty manual selections normalize to automatic") {
        let direct = AppPreferences(
            displayPreference: DisplayPreference(
                productMode: .spark,
                quotaSelection: .manual([])
            )
        )
        try expect(
            direct.displayPreference.quotaSelection == .automatic,
            "Expected direct normalization"
        )

        let store = try PreferencesTestStore()
        defer { store.cleanUp() }
        let repository = try store.repository()
        let payload: [String: Any] = [
            "version": 1,
            "display": [
                "productMode": "spark",
                "selection": ["mode": "manual", "items": []]
            ]
        ]
        store.userDefaults.set(
            try preferencesJSON(payload),
            forKey: AppPreferencesRepository.storageKey
        )

        let loaded = await repository.load()
        try expect(
            loaded.displayPreference.quotaSelection == .automatic,
            "Expected persisted empty selection normalization"
        )

        let missingDurationPayload: [String: Any] = [
            "version": 1,
            "display": [
                "productMode": "codex",
                "selection": [
                    "mode": "manual",
                    "items": [["product": "codex"]]
                ]
            ]
        ]
        store.userDefaults.set(
            try preferencesJSON(missingDurationPayload),
            forKey: AppPreferencesRepository.storageKey
        )
        let missingDuration = await repository.load()
        try expect(
            missingDuration.displayPreference.quotaSelection == .automatic,
            "Expected omitted duration item rejection"
        )
    }
}

private func appPreferencesNonFileURLTest() -> TestCase {
    TestCase(name: "preferences accept selected executable file URLs only") {
        let webURL = try requiredURL("https://example.invalid/codex")
        let preferences = AppPreferences(selectedExecutableURL: webURL)
        try expect(preferences.selectedExecutableURL == nil, "Expected non-file URL rejection")
        try expect(
            AppPreferences(selectedExecutableURL: syntheticExecutableURL).selectedExecutableURL
                == syntheticExecutableURL,
            "Expected file URL acceptance"
        )
    }
}

private func appPreferencesExecutableSelectionMergeTest() -> TestCase {
    TestCase(name: "executable selection preserves every unrelated preference") {
        let store = try PreferencesTestStore()
        defer { store.cleanUp() }
        let repository = try store.repository()
        let initial = manualPreferences([
            QuotaSelectionID(product: .codex, rawDurationMinutes: 300)
        ])
        let selected = URL(fileURLWithPath: "/Synthetic/New/codex")
        try await repository.save(initial)

        try await repository.saveSelectedExecutableURL(selected)
        let saved = await repository.load()

        try expect(saved.displayPreference == initial.displayPreference, "Expected display preserved")
        try expect(saved.refreshProfile == initial.refreshProfile, "Expected refresh preserved")
        try expect(
            saved.launchAtLoginIntent == initial.launchAtLoginIntent,
            "Expected login intent preserved"
        )
        try expect(saved.hasCompletedFirstLaunch, "Expected first launch preserved")
        try expect(saved.selectedExecutableURL == selected, "Expected selected executable saved")
    }
}

private func appPreferencesFirstLaunchAtomicMergeTest() -> TestCase {
    TestCase(name: "first launch completion atomically preserves concurrent settings updates") {
        let store = try PreferencesTestStore()
        defer { store.cleanUp() }
        let repository = try store.repository()
        try await repository.save(.default)
        let identifier = QuotaSelectionID(product: .spark, rawDurationMinutes: 300)
        let formValues = SettingsFormValues(
            displayPreference: DisplayPreference(
                productMode: .both,
                quotaSelection: .manual([identifier])
            ),
            refreshProfile: .eco,
            launchAtLoginIntent: true
        )
        let executableURL = URL(fileURLWithPath: "/Synthetic/Selected/codex")

        async let formSave: Void = repository.saveSettingsForm(formValues)
        async let executableSave: Void = repository.saveSelectedExecutableURL(executableURL)
        async let firstLaunchSave: Void = repository.markFirstLaunchCompleted()
        _ = try await (formSave, executableSave, firstLaunchSave)
        let saved = await repository.load()

        try expect(saved.displayPreference == formValues.displayPreference, "Expected display")
        try expect(saved.refreshProfile == .eco, "Expected refresh profile")
        try expect(saved.launchAtLoginIntent, "Expected login intent")
        try expect(saved.selectedExecutableURL == executableURL, "Expected executable")
        try expect(saved.hasCompletedFirstLaunch, "Expected first launch completion")

        let firstData = try storedPreferencesData(in: store.userDefaults)
        try await repository.markFirstLaunchCompleted()
        let secondData = try storedPreferencesData(in: store.userDefaults)
        try expect(firstData == secondData, "Expected idempotent completion bytes")
    }
}

private func appPreferencesSuiteIsolationTest() -> TestCase {
    TestCase(name: "preferences save one namespaced key in the injected suite") {
        let firstStore = try PreferencesTestStore()
        let secondStore = try PreferencesTestStore()
        defer {
            firstStore.cleanUp()
            secondStore.cleanUp()
        }
        firstStore.userDefaults.set("preserve", forKey: "synthetic.unrelated")
        let repository = try firstStore.repository()

        try await repository.save(.default)

        try expect(
            firstStore.userDefaults.string(forKey: "synthetic.unrelated") == "preserve",
            "Expected unrelated default preserved"
        )
        try expect(
            secondStore.userDefaults.object(forKey: AppPreferencesRepository.storageKey) == nil,
            "Expected other suite untouched"
        )
        guard let domain = firstStore.userDefaults.persistentDomain(
            forName: firstStore.suiteName
        ) else {
            throw TestFailure(description: "Expected test defaults domain")
        }
        let expectedKeys = Set([
            "synthetic.unrelated",
            AppPreferencesRepository.storageKey
        ])
        try expect(Set(domain.keys) == expectedKeys, "Expected only one preferences key")
        try expect(
            domain[AppPreferencesRepository.storageKey] is Data,
            "Expected versioned Data storage"
        )
    }
}

private func appPreferencesSafePayloadTest() -> TestCase {
    TestCase(name: "preferences payload contains settings fields only") {
        let store = try PreferencesTestStore()
        defer { store.cleanUp() }
        let repository = try store.repository()
        let preferences = manualPreferences(
            Set([
                QuotaSelectionID(product: .codex, rawDurationMinutes: 300),
                QuotaSelectionID(product: .spark, rawDurationMinutes: nil)
            ])
        )

        try await repository.save(preferences)
        let data = try storedPreferencesData(in: store.userDefaults)
        guard let text = String(data: data, encoding: .utf8) else {
            throw TestFailure(description: "Expected UTF-8 preferences payload")
        }
        let forbiddenTerms = [
            "quota",
            "usedpercent",
            "remainingpercent",
            "snapshot",
            "reset",
            "account",
            "error",
            "response",
            "email",
            "token"
        ]
        let lowercasePayload = text.lowercased()
        try expect(
            forbiddenTerms.allSatisfy { !lowercasePayload.contains($0) },
            "Expected no runtime usage or account fields"
        )
        let object = try preferencesJSONObject(from: data)
        let expectedRootKeys = Set([
            "version",
            "display",
            "refreshProfile",
            "launchAtLoginIntent",
            "selectedExecutableURL",
            "hasCompletedFirstLaunch"
        ])
        try expect(Set(object.keys) == expectedRootKeys, "Expected settings-only root schema")
    }
}

private func appPreferencesSendabilityTest() -> TestCase {
    TestCase(name: "application preferences are immutable sendable values") {
        requirePreferencesSendable(AppPreferences.default)
        try expect(AppPreferences.default == AppPreferences(), "Expected stable defaults")
    }
}

private struct PreferencesTestStore {
    let suiteName: String
    let userDefaults: UserDefaults

    init() throws {
        let suiteName = "io.github.symflee.codex-gauge.tests.preferences.\(UUID().uuidString)"
        guard let userDefaults = UserDefaults(suiteName: suiteName) else {
            throw TestFailure(description: "Unable to create isolated defaults suite")
        }
        self.suiteName = suiteName
        self.userDefaults = userDefaults
    }

    func repository() throws -> AppPreferencesRepository {
        guard let repositoryDefaults = UserDefaults(suiteName: suiteName) else {
            throw TestFailure(description: "Unable to inject defaults suite")
        }
        return AppPreferencesRepository(userDefaults: repositoryDefaults)
    }

    func cleanUp() {
        userDefaults.removePersistentDomain(forName: suiteName)
    }
}

private let syntheticExecutableURL = URL(
    fileURLWithPath: "/Synthetic/Codex Gauge/codex"
)

private func manualPreferences(
    _ identifiers: Set<QuotaSelectionID>
) -> AppPreferences {
    AppPreferences(
        displayPreference: DisplayPreference(
            productMode: .both,
            quotaSelection: .manual(identifiers)
        ),
        refreshProfile: .fast,
        launchAtLoginIntent: true,
        selectedExecutableURL: syntheticExecutableURL,
        hasCompletedFirstLaunch: true
    )
}

private func storedPreferencesData(
    in userDefaults: UserDefaults
) throws -> Data {
    guard let data = userDefaults.data(
        forKey: AppPreferencesRepository.storageKey
    ) else {
        throw TestFailure(description: "Expected stored preferences Data")
    }
    return data
}

private func preferencesJSON(_ object: Any) throws -> Data {
    try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
}

private func preferencesJSONObject(from data: Data) throws -> [String: Any] {
    let object = try JSONSerialization.jsonObject(with: data)
    guard let dictionary = object as? [String: Any] else {
        throw TestFailure(description: "Expected preferences JSON object")
    }
    return dictionary
}

private func requiredURL(_ string: String) throws -> URL {
    guard let url = URL(string: string) else {
        throw TestFailure(description: "Expected synthetic URL")
    }
    return url
}

private func requirePreferencesSendable<Value: Sendable>(_ value: Value) {
    _ = value
}
