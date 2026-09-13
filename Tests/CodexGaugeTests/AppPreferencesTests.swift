import CodexGaugeCore
import CodexGaugeRefresh
import CodexGaugeSettings
import Foundation

func appPreferencesTests() -> [TestCase] {
    [
        singleQuotaLegacyMigrationTest(),
        preferredAppLanguageResolverTest(),
        statusGaugeAppearanceDomainTest(),
        slimCapsulePreferencesMigrationTest(),
        appPreferencesDefaultsTest(),
        appPreferencesRoundTripTest(),
        appPreferencesVividPresetRoundTripTest(),
        appPreferencesMutedCustomPreservationTest(),
        appPreferencesDeterministicEncodingTest(),
        appPreferencesMalformedSchemaTest(),
        appPreferencesFieldRecoveryTest(),
        appPreferencesVersionTwoMigrationTest(),
        appPreferencesVersionOneMigrationTest(),
        appPreferencesVersionZeroMigrationTest(),
        appPreferencesEmptyManualSelectionTest(),
        appPreferencesManualProductNormalizationTest(),
        appPreferencesInconsistentPayloadNormalizationTest(),
        appPreferencesNonFileURLTest(),
        appPreferencesExecutableSelectionMergeTest(),
        appPreferencesFirstLaunchAtomicMergeTest(),
        appPreferencesSuiteIsolationTest(),
        appPreferencesSafePayloadTest()
    ]
}

private func singleQuotaLegacyMigrationTest() -> TestCase {
    TestCase(name: "single quota legacy Spark settings migrate to automatic Codex without losing preferences") {
        let store = try PreferencesTestStore()
        defer { store.cleanUp() }
        let repository = try store.repository()
        let payload: [String: Any] = [
            "version": 4,
            "display": ["productMode": "spark", "selection": ["mode": "manual", "items": [
                ["product": "spark", "rawDurationMinutes": 300]
            ]]],
            "language": "ko", "refreshProfile": "manual", "launchAtLoginIntent": true,
            "hasCompletedFirstLaunch": true,
            "statusGaugeAppearance": ["mode": "preset", "preset": "blue"]
        ]
        store.userDefaults.set(try preferencesJSON(payload), forKey: AppPreferencesRepository.storageKey)
        let loaded = await repository.load()
        try expect(loaded.displayPreference == .default, "Expected retired Spark selection to become automatic Codex")
        try expect(loaded.language == .korean && loaded.refreshProfile == .manual, "Expected language and refresh preserved")
        try expect(loaded.launchAtLoginIntent && loaded.hasCompletedFirstLaunch, "Expected launch preferences preserved")
        try expect(loaded.statusGaugeAppearance == .preset(.blue), "Expected explicit v4 color preserved")
        let encoded = try preferencesJSONObject(from: storedPreferencesData(in: store.userDefaults))
        try expect(encoded["version"] as? Int == 5, "Expected v5 migration persisted")
    }
}

private func slimCapsulePreferencesMigrationTest() -> TestCase {
    TestCase(name: "slim capsule gauge migration adopts neutral once and preserves custom colors") {
        let store = try PreferencesTestStore()
        defer { store.cleanUp() }
        let repository = try store.repository()
        let cases: [([String: String], String)] = [
            (["mode": "preset", "preset": "blue"], "neutral"),
            (["mode": "preset", "preset": "green"], "green"),
            (["mode": "custom", "borderColor": "#004C99", "fillColor": "#0A84FF"], "custom")
        ]
        for (savedAppearance, expected) in cases {
            let payload: [String: Any] = [
                "version": 3, "language": "ko", "hasCompletedFirstLaunch": true,
                "refreshProfile": "manual", "statusGaugeAppearance": savedAppearance
            ]
            store.userDefaults.set(try preferencesJSON(payload), forKey: AppPreferencesRepository.storageKey)
            let loaded = await repository.load()
            let encoded = try preferencesJSONObject(from: storedPreferencesData(in: store.userDefaults))
            let appearance = encoded["statusGaugeAppearance"] as? [String: String]
            try expect(encoded["version"] as? Int == 5, "Expected one-time v5 migration")
            try expect(loaded.language == .korean && loaded.hasCompletedFirstLaunch, "Expected other settings preserved")
            if expected == "custom" {
                try expect(appearance == savedAppearance, "Expected exact custom colors preserved")
                continue
            }
            try expect(appearance?["preset"] == expected, "Expected the correct migrated preset")
        }
        let blue = AppPreferences(statusGaugeAppearance: .preset(.blue))
        try await repository.save(blue)
        let reloaded = await repository.load()
        try expect(reloaded == blue, "Expected a newly selected blue preset to survive reload")
    }
}

private func statusGaugeAppearanceDomainTest() -> TestCase {
    TestCase(name: "status gauge presets expose stable colors and custom identity") {
        let expected: [(StatusGaugePreset, String, String)] = [
            (.neutral, "#A5ACB6", "#D8DEE6"),
            (.blue, "#004C99", "#0A84FF"),
            (.graphite, "#343A40", "#7B8490"),
            (.green, "#147A3D", "#30D158"),
            (.orange, "#B84F00", "#FF9F0A"),
            (.purple, "#7531A8", "#BF5AF2")
        ]
        try expect(StatusGaugePreset.allCases == expected.map(\.0), "Expected stable order")
        try expect(
            StatusGaugePreset.allCases.map(\.rawValue)
                == ["neutral", "blue", "graphite", "green", "orange", "purple"],
            "Expected stable preset identifiers"
        )
        for (preset, border, fill) in expected {
            try expect(preset.borderColor.hexString == border, "Expected preset border")
            try expect(preset.fillColor.hexString == fill, "Expected preset fill")
        }
        let custom = StatusGaugeAppearance.custom(
            borderColor: .init(red: 0x00, green: 0x4C, blue: 0x99),
            fillColor: .init(red: 0x0A, green: 0x84, blue: 0xFF)
        )
        try expect(custom != .preset(.blue), "Expected custom identity to be preserved")
        try expect(custom.borderColor == StatusGaugePreset.blue.borderColor, "Expected border")
        try expect(custom.fillColor == StatusGaugePreset.blue.fillColor, "Expected fill")
    }
}

private func preferredAppLanguageResolverTest() -> TestCase {
    TestCase(name: "preferred language resolver selects Korean or English deterministically") {
        let resolver = PreferredAppLanguageResolver()

        try expect(
            resolver.resolve(preferredLanguages: ["ko-KR", "en-US"]) == .korean,
            "Expected Korean system preference"
        )
        try expect(
            resolver.resolve(preferredLanguages: ["en_KR", "ko-KR"]) == .english,
            "Expected first supported preference"
        )
        try expect(
            resolver.resolve(preferredLanguages: ["ja-JP", "ko_KR"]) == .korean,
            "Expected unsupported preferences to be skipped"
        )
        try expect(
            resolver.resolve(preferredLanguages: ["ja-JP", "fr-FR"]) == .english,
            "Expected English fallback"
        )
        try expect(
            resolver.resolve(preferredLanguages: []) == .english,
            "Expected empty preference fallback"
        )
    }
}

private func appPreferencesDefaultsTest() -> TestCase {
    TestCase(name: "preferences load safe defaults from an empty suite") {
        let store = try PreferencesTestStore()
        defer { store.cleanUp() }
        let repository = try store.repository(defaultLanguage: .korean)

        let preferences = await repository.load()

        try expect(
            preferences == AppPreferences(language: .korean),
            "Expected injected default preferences"
        )
        try expect(preferences.language == .korean, "Expected Korean default language")
        try expect(AppPreferences.default == AppPreferences(), "Expected stable defaults")
        try expect(AppPreferences.default.language == .english, "Expected English fallback")
        try expect(preferences.displayPreference == .default, "Expected default display")
        try expect(preferences.statusGaugeAppearance == .default, "Expected neutral gauge")
        try expect(
            preferences.statusGaugeAppearance.borderColor.hexString == "#A5ACB6",
            "Expected neutral default border"
        )
        try expect(
            preferences.statusGaugeAppearance.fillColor.hexString == "#D8DEE6",
            "Expected neutral default fill"
        )
        try expect(preferences.refreshProfile == .balanced, "Expected balanced refresh")
        try expect(!preferences.launchAtLoginIntent, "Expected login launch disabled")
        try expect(preferences.selectedExecutableURL == nil, "Expected no selected executable")
        try expect(!preferences.hasCompletedFirstLaunch, "Expected incomplete first launch")

        let persisted = try preferencesJSONObject(
            from: storedPreferencesData(in: store.userDefaults)
        )
        try expect(persisted["version"] as? Int == 5, "Expected initial v5 persistence")
        try expect(persisted["language"] as? String == "ko", "Expected concrete language")
        try expect(
            persisted["statusGaugeAppearance"] as? [String: String]
                == ["mode": "preset", "preset": "neutral"],
            "Expected persisted default appearance"
        )

        let secondRepository = try store.repository(defaultLanguage: .english)
        let secondLoad = await secondRepository.load()
        try expect(
            secondLoad.language == .korean,
            "Expected persisted language to ignore later system changes"
        )
    }
}

private func appPreferencesVividPresetRoundTripTest() -> TestCase {
    TestCase(name: "vivid preset preferences round trip deterministically") {
        let store = try PreferencesTestStore()
        defer { store.cleanUp() }
        let repository = try store.repository()
        let preferences = AppPreferences(statusGaugeAppearance: .preset(.orange))

        try await repository.save(preferences)
        let firstData = try storedPreferencesData(in: store.userDefaults)
        let loaded = await repository.load()
        try await repository.save(loaded)
        let secondData = try storedPreferencesData(in: store.userDefaults)

        try expect(loaded == preferences, "Expected preset identity round trip")
        try expect(loaded.statusGaugeAppearance.borderColor.hexString == "#B84F00", "Expected border")
        try expect(loaded.statusGaugeAppearance.fillColor.hexString == "#FF9F0A", "Expected fill")
        try expect(firstData == secondData, "Expected deterministic preset bytes")
        let object = try preferencesJSONObject(from: firstData)
        try expect(
            object["statusGaugeAppearance"] as? [String: String]
                == ["mode": "preset", "preset": "orange"],
            "Expected stable preset schema"
        )
    }
}

private func appPreferencesMutedCustomPreservationTest() -> TestCase {
    TestCase(name: "legacy muted colors remain an explicit custom appearance") {
        let store = try PreferencesTestStore()
        defer { store.cleanUp() }
        let repository = try store.repository()
        let oldMuted = StatusGaugeAppearance.custom(
            borderColor: .init(red: 0x2D, green: 0x52, blue: 0x6A),
            fillColor: .init(red: 0x47, green: 0x75, blue: 0x93)
        )
        let preferences = AppPreferences(statusGaugeAppearance: oldMuted)

        try await repository.save(preferences)
        let firstData = try storedPreferencesData(in: store.userDefaults)
        let loaded = await repository.load()
        try await repository.save(loaded)
        let secondData = try storedPreferencesData(in: store.userDefaults)

        try expect(loaded.statusGaugeAppearance == oldMuted, "Expected muted custom identity")
        try expect(firstData == secondData, "Expected muted custom bytes preserved")
        let object = try preferencesJSONObject(from: firstData)
        try expect(
            object["statusGaugeAppearance"] as? [String: String] == [
                "mode": "custom",
                "borderColor": "#2D526A",
                "fillColor": "#477593"
            ],
            "Expected old muted colors to remain custom"
        )
    }
}

private func appPreferencesRoundTripTest() -> TestCase {
    TestCase(name: "preferences round trip automatic and every single quota selection") {
        let store = try PreferencesTestStore()
        defer { store.cleanUp() }
        let repository = try store.repository()
        let selections: [DisplayQuotaSelection] = [.automatic] + [nil, 300, 10_080].map {
            .manual(QuotaSelectionID(product: .codex, rawDurationMinutes: $0))
        }
        for selection in selections {
            for refreshProfile in RefreshProfile.allCases {
                for language in AppLanguage.allCases {
                    let preferences = AppPreferences(
                        displayPreference: DisplayPreference(quotaSelection: selection),
                        refreshProfile: refreshProfile,
                        launchAtLoginIntent: true,
                        selectedExecutableURL: syntheticExecutableURL,
                        hasCompletedFirstLaunch: true,
                        language: language,
                        statusGaugeAppearance: .preset(.green)
                    )
                    try await repository.save(preferences)
                    let loaded = await repository.load()
                    try expect(loaded == preferences, "Expected exact settings round trip")
                }
            }
        }
    }
}

private func appPreferencesVersionTwoMigrationTest() -> TestCase {
    TestCase(name: "preferences migrate version two with the default neutral gauge") {
        let store = try PreferencesTestStore()
        defer { store.cleanUp() }
        let repository = try store.repository(defaultLanguage: .korean)
        let payload: [String: Any] = [
            "version": 2,
            "display": [
                "productMode": "spark",
                "selection": ["mode": "automatic"]
            ],
            "refreshProfile": "fast",
            "language": "en"
        ]
        store.userDefaults.set(
            try preferencesJSON(payload),
            forKey: AppPreferencesRepository.storageKey
        )

        let preferences = await repository.load()

        try expect(preferences.language == .english, "Expected stored v2 language")
        try expect(preferences.statusGaugeAppearance == .default, "Expected blue migration")
        try expect(
            preferences.statusGaugeAppearance.borderColor.hexString == "#A5ACB6",
            "Expected vivid migrated border"
        )
        try expect(
            preferences.statusGaugeAppearance.fillColor.hexString == "#D8DEE6",
            "Expected vivid migrated fill"
        )
        let migrated = try preferencesJSONObject(
            from: storedPreferencesData(in: store.userDefaults)
        )
        try expect(migrated["version"] as? Int == 5, "Expected automatic v5 migration")
    }
}

private func appPreferencesDeterministicEncodingTest() -> TestCase {
    TestCase(name: "manual preference encoding is deterministic and singular") {
        let store = try PreferencesTestStore()
        defer { store.cleanUp() }
        let repository = try store.repository()
        let identifier = QuotaSelectionID(product: .codex, rawDurationMinutes: nil)
        let preferences = manualPreferences(identifier)
        try await repository.save(preferences)
        let firstData = try storedPreferencesData(in: store.userDefaults)
        let loaded = await repository.load()
        try await repository.save(loaded)
        let secondData = try storedPreferencesData(in: store.userDefaults)
        try expect(firstData == secondData, "Expected stable bytes across round trip")
        let object = try preferencesJSONObject(from: firstData)
        guard let display = object["display"] as? [String: Any],
              let selection = display["selection"] as? [String: Any],
              let item = selection["item"] as? [String: Any] else {
            throw TestFailure(description: "Expected singular persisted selection")
        }
        try expect(display["productMode"] == nil && selection["items"] == nil, "Expected retired multi-product fields omitted")
        try expect(item["product"] as? String == "codex" && item["rawDurationMinutes"] is NSNull, "Expected explicit unknown-duration selection")
        try expect(object["statusGaugeAppearance"] as? [String: String] == [
            "mode": "custom", "borderColor": "#010203", "fillColor": "#AABBCC"
        ], "Expected canonical custom colors")
    }
}

private func appPreferencesMalformedSchemaTest() -> TestCase {
    TestCase(name: "preferences recover from malformed and future schemas") {
        let store = try PreferencesTestStore()
        defer { store.cleanUp() }
        let repository = try store.repository(defaultLanguage: .korean)

        store.userDefaults.set("not-data", forKey: AppPreferencesRepository.storageKey)
        let wrongStorageType = await repository.load()
        try expect(wrongStorageType.language == .korean, "Expected non-Data language fallback")
        try expect(
            store.userDefaults.string(forKey: AppPreferencesRepository.storageKey) == "not-data",
            "Expected non-Data payload preserved"
        )

        let malformedData = Data([0xFF, 0x00])
        store.userDefaults.set(malformedData, forKey: AppPreferencesRepository.storageKey)
        let malformed = await repository.load()
        try expect(malformed.language == .korean, "Expected malformed language fallback")
        try expect(
            store.userDefaults.data(forKey: AppPreferencesRepository.storageKey) == malformedData,
            "Expected malformed payload preserved"
        )

        let wrongShapeData = try preferencesJSON(["not", "an", "object"])
        store.userDefaults.set(wrongShapeData, forKey: AppPreferencesRepository.storageKey)
        let wrongShape = await repository.load()
        try expect(wrongShape.language == .korean, "Expected non-object language fallback")
        try expect(
            store.userDefaults.data(forKey: AppPreferencesRepository.storageKey) == wrongShapeData,
            "Expected non-object payload preserved"
        )

        let futureData = try preferencesJSON(["version": 999, "refreshProfile": "fast"])
        store.userDefaults.set(futureData, forKey: AppPreferencesRepository.storageKey)
        let future = await repository.load()
        try expect(future.language == .korean, "Expected future schema language fallback")
        try expect(
            store.userDefaults.data(forKey: AppPreferencesRepository.storageKey) == futureData,
            "Expected future payload preserved"
        )

        let missingVersionData = try preferencesJSON(["refreshProfile": "fast"])
        store.userDefaults.set(missingVersionData, forKey: AppPreferencesRepository.storageKey)
        let missingVersion = await repository.load()
        try expect(missingVersion.language == .korean, "Expected missing version language fallback")
        try expect(
            store.userDefaults.data(forKey: AppPreferencesRepository.storageKey)
                == missingVersionData,
            "Expected missing-version payload preserved"
        )

        store.userDefaults.set(
            try preferencesJSON(["version": UInt64(Int64.max) + 1]),
            forKey: AppPreferencesRepository.storageKey
        )
        let overflowingVersion = await repository.load()
        try expect(
            overflowingVersion.language == .korean,
            "Expected overflowing version language fallback"
        )
    }
}

private func appPreferencesFieldRecoveryTest() -> TestCase {
    TestCase(name: "preferences recover malformed fields independently") {
        let store = try PreferencesTestStore()
        defer { store.cleanUp() }
        let repository = try store.repository(defaultLanguage: .korean)
        let payload: [String: Any] = [
            "version": 3,
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
            "language": "future-language",
            "statusGaugeAppearance": [
                "mode": "custom",
                "borderColor": "invalid",
                "fillColor": "#123456"
            ],
            "futureField": ["ignored": true]
        ]
        store.userDefaults.set(
            try preferencesJSON(payload),
            forKey: AppPreferencesRepository.storageKey
        )

        let preferences = await repository.load()
        let expectedIdentifier = QuotaSelectionID(product: .codex, rawDurationMinutes: 300)

        try expect(
            preferences.displayPreference.quotaSelection == .manual(expectedIdentifier),
            "Expected valid manual item preservation"
        )
        try expect(preferences.refreshProfile == .balanced, "Expected refresh fallback")
        try expect(preferences.launchAtLoginIntent, "Expected valid login intent")
        try expect(preferences.selectedExecutableURL == nil, "Expected invalid URL rejection")
        try expect(!preferences.hasCompletedFirstLaunch, "Expected boolean fallback")
        try expect(preferences.language == .korean, "Expected invalid language fallback")
        try expect(
            preferences.statusGaugeAppearance == .custom(
                borderColor: .init(red: 0x00, green: 0x4C, blue: 0x99),
                fillColor: .init(red: 0x12, green: 0x34, blue: 0x56)
            ),
            "Expected malformed border alone to recover"
        )

        let unknownSelectionPayload: [String: Any] = [
            "version": 3,
            "display": [
                "productMode": "spark",
                "selection": [
                    "mode": "future-selection",
                    "items": [["product": "spark", "rawDurationMinutes": 300]]
                ]
            ],
            "refreshProfile": "manual",
            "language": "en",
            "statusGaugeAppearance": [
                "mode": "custom",
                "borderColor": "#ABCDEF",
                "fillColor": "#FFFFF"
            ]
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
            unknownSelection.refreshProfile == .manual,
            "Expected valid manual refresh profile"
        )
        try expect(unknownSelection.language == .english, "Expected valid language sibling")
        try expect(
            unknownSelection.statusGaugeAppearance == .custom(
                borderColor: .init(red: 0xAB, green: 0xCD, blue: 0xEF),
                fillColor: StatusGaugePreset.blue.fillColor
            ),
            "Expected malformed fill alone to recover"
        )

        let invalidPresetPayload: [String: Any] = [
            "version": 3,
            "statusGaugeAppearance": [
                "mode": "preset",
                "preset": "muted-blue"
            ]
        ]
        store.userDefaults.set(
            try preferencesJSON(invalidPresetPayload),
            forKey: AppPreferencesRepository.storageKey
        )
        let invalidPreset = await repository.load()
        try expect(invalidPreset.statusGaugeAppearance == .default, "Expected preset fallback")
        try expect(
            invalidPreset.statusGaugeAppearance.fillColor.hexString == "#D8DEE6",
            "Expected fallback to vivid blue"
        )
    }
}

private func appPreferencesVersionOneMigrationTest() -> TestCase {
    TestCase(name: "preferences migrate version one with the injected system language") {
        let store = try PreferencesTestStore()
        defer { store.cleanUp() }
        let repository = try store.repository(defaultLanguage: .korean)
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
        store.userDefaults.set(
            try preferencesJSON(payload),
            forKey: AppPreferencesRepository.storageKey
        )

        let preferences = await repository.load()

        try expect(preferences.language == .korean, "Expected injected migration language")
        try expect(preferences.refreshProfile == .fast, "Expected refresh sibling")
        try expect(preferences.launchAtLoginIntent, "Expected login sibling")
        try expect(preferences.hasCompletedFirstLaunch, "Expected first-launch sibling")

        let automaticallyMigrated = try preferencesJSONObject(
            from: storedPreferencesData(in: store.userDefaults)
        )
        try expect(
            automaticallyMigrated["version"] as? Int == 5,
            "Expected version one migrated during load"
        )
        try expect(
            automaticallyMigrated["language"] as? String == "ko",
            "Expected migrated language fixed during load"
        )

        try await repository.save(preferences)
        let migrated = try preferencesJSONObject(
            from: storedPreferencesData(in: store.userDefaults)
        )
        try expect(migrated["version"] as? Int == 5, "Expected version five save")
        try expect(migrated["language"] as? String == "ko", "Expected language persisted")
        try expect(preferences.statusGaugeAppearance == .default, "Expected blue migration")
        try expect(
            preferences.statusGaugeAppearance.fillColor.hexString == "#D8DEE6",
            "Expected vivid v1 migration"
        )
    }
}

private func appPreferencesVersionZeroMigrationTest() -> TestCase {
    TestCase(name: "preferences migrate the flattened version zero schema") {
        let store = try PreferencesTestStore()
        defer { store.cleanUp() }
        let repository = try store.repository(defaultLanguage: .korean)
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
        let expectedIdentifier = QuotaSelectionID(product: .codex, rawDurationMinutes: nil)

        try expect(
            preferences.displayPreference.quotaSelection == .manual(expectedIdentifier),
            "Expected migrated manual selection"
        )
        try expect(preferences.refreshProfile == .eco, "Expected migrated refresh profile")
        try expect(preferences.launchAtLoginIntent, "Expected migrated login intent")
        try expect(preferences.selectedExecutableURL == syntheticExecutableURL, "Expected migrated URL")
        try expect(preferences.hasCompletedFirstLaunch, "Expected migrated first launch")
        try expect(preferences.language == .korean, "Expected migrated system language")

        let automaticallyMigrated = try preferencesJSONObject(
            from: storedPreferencesData(in: store.userDefaults)
        )
        try expect(
            automaticallyMigrated["version"] as? Int == 5,
            "Expected version zero migrated during load"
        )
        try expect(
            automaticallyMigrated["language"] as? String == "ko",
            "Expected v0 language fixed during load"
        )

        try await repository.save(preferences)
        let migratedData = try storedPreferencesData(in: store.userDefaults)
        let migratedObject = try preferencesJSONObject(from: migratedData)
        try expect(migratedObject["version"] as? Int == 5, "Expected current schema on save")
        try expect(migratedObject["language"] as? String == "ko", "Expected language on save")
        try expect(preferences.statusGaugeAppearance == .default, "Expected blue migration")
        try expect(
            preferences.statusGaugeAppearance.fillColor.hexString == "#D8DEE6",
            "Expected vivid v0 migration"
        )

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
        try expect(
            recovered.displayPreference.quotaSelection == .automatic,
            "Expected off-product v0 sibling to recover automatically"
        )
        try expect(recovered.refreshProfile == .balanced, "Expected v0 refresh fallback")
        try expect(!recovered.launchAtLoginIntent, "Expected v0 boolean fallback")
        try expect(recovered.selectedExecutableURL == nil, "Expected v0 URL fallback")
        try expect(recovered.hasCompletedFirstLaunch, "Expected valid v0 sibling preserved")
        try expect(recovered.language == .korean, "Expected v0 language fallback")
    }
}

private func appPreferencesEmptyManualSelectionTest() -> TestCase {
    TestCase(name: "empty manual selections normalize to automatic") {
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

private func appPreferencesManualProductNormalizationTest() -> TestCase {
    TestCase(name: "single quota migrations preserve one Codex choice and recover ambiguous choices") {
        let store = try PreferencesTestStore()
        defer { store.cleanUp() }
        let repository = try store.repository()
        let codex: [String: Any] = ["product": "codex", "rawDurationMinutes": 300]
        let weekly: [String: Any] = ["product": "codex", "rawDurationMinutes": 10_080]
        let spark: [String: Any] = ["product": "spark", "rawDurationMinutes": 300]
        let identifier = QuotaSelectionID(product: .codex, rawDurationMinutes: 300)
        let cases: [([[String: Any]], DisplayQuotaSelection)] = [
            ([], .automatic), ([spark], .automatic), ([codex], .manual(identifier)),
            ([spark, codex], .manual(identifier)), ([codex, weekly], .automatic),
            ([spark, codex, weekly], .automatic), ([codex, codex], .manual(identifier))
        ]
        for version in 0...4 {
            for (items, expected) in cases {
                var payload: [String: Any] = ["version": version]
                if version == 0 {
                    payload["displayProductMode"] = "both"
                    payload["displayQuotaSelection"] = "manual"
                    payload["manualQuotaSelections"] = items
                } else {
                    payload["display"] = ["productMode": "both", "selection": ["mode": "manual", "items": items]]
                }
                store.userDefaults.set(try preferencesJSON(payload), forKey: AppPreferencesRepository.storageKey)
                let loaded = await repository.load()
                try expect(loaded.displayPreference.quotaSelection == expected, "Expected legacy selection normalization")
                let data = try storedPreferencesData(in: store.userDefaults)
                let object = try preferencesJSONObject(from: data)
                try expect(object["version"] as? Int == 5, "Expected current schema persisted")
                let reloaded = await repository.load()
                try expect(reloaded == loaded, "Expected migration to be stable on next load")
            }
        }
    }
}

private func appPreferencesInconsistentPayloadNormalizationTest() -> TestCase {
    TestCase(name: "single quota v5 rejects malformed manual items without losing siblings") {
        let store = try PreferencesTestStore()
        defer { store.cleanUp() }
        let repository = try store.repository()
        let items: [[String: Any]] = [
            ["product": "spark", "rawDurationMinutes": 300],
            ["product": "codex"], ["product": "codex", "rawDurationMinutes": "300"],
            ["product": "codex", "rawDurationMinutes": 0]
        ]
        for item in items {
            let payload: [String: Any] = [
                "version": 5, "display": ["selection": ["mode": "manual", "item": item,
                    "items": [["product": "codex", "rawDurationMinutes": 300]]]],
                "language": "ko", "refreshProfile": "fast"
            ]
            store.userDefaults.set(try preferencesJSON(payload), forKey: AppPreferencesRepository.storageKey)
            let loaded = await repository.load()
            try expect(loaded.displayPreference == .default, "Expected invalid manual item fallback")
            try expect(loaded.language == .korean && loaded.refreshProfile == .fast, "Expected valid siblings preserved")
        }
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
        let initial = manualPreferences(
            QuotaSelectionID(product: .codex, rawDurationMinutes: 300)
        )
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
        try expect(saved.language == initial.language, "Expected language preserved")
        try expect(
            saved.statusGaugeAppearance == initial.statusGaugeAppearance,
            "Expected gauge appearance preserved"
        )
    }
}

private func appPreferencesFirstLaunchAtomicMergeTest() -> TestCase {
    TestCase(name: "first launch completion atomically preserves concurrent settings updates") {
        let store = try PreferencesTestStore()
        defer { store.cleanUp() }
        let repository = try store.repository()
        try await repository.save(.default)
        let identifier = QuotaSelectionID(product: .codex, rawDurationMinutes: 300)
        let formValues = SettingsFormValues(
            displayPreference: DisplayPreference(
                quotaSelection: .manual(identifier)
            ),
            refreshProfile: .eco,
            launchAtLoginIntent: true,
            language: .korean,
            statusGaugeAppearance: .preset(.purple)
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
        try expect(saved.language == .korean, "Expected form language")
        try expect(saved.statusGaugeAppearance == .preset(.purple), "Expected form appearance")

        let firstData = try storedPreferencesData(in: store.userDefaults)
        try await repository.markFirstLaunchCompleted()
        let secondData = try storedPreferencesData(in: store.userDefaults)
        try expect(firstData == secondData, "Expected idempotent completion bytes")

        try await repository.resetFirstLaunchCompletionForUITesting()
        let reset = await repository.load()
        try expect(!reset.hasCompletedFirstLaunch, "Expected first launch reset")
        try expect(reset.language == .korean, "Expected reset to preserve language")
        try expect(reset.statusGaugeAppearance == .preset(.purple), "Expected reset appearance")
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
            QuotaSelectionID(product: .codex, rawDurationMinutes: 300)
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
            "hasCompletedFirstLaunch",
            "language",
            "statusGaugeAppearance"
        ])
        try expect(Set(object.keys) == expectedRootKeys, "Expected settings-only root schema")
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

    func repository(
        defaultLanguage: AppLanguage = .english
    ) throws -> AppPreferencesRepository {
        guard let repositoryDefaults = UserDefaults(suiteName: suiteName) else {
            throw TestFailure(description: "Unable to inject defaults suite")
        }
        return AppPreferencesRepository(
            userDefaults: repositoryDefaults,
            defaultLanguage: defaultLanguage
        )
    }

    func cleanUp() {
        userDefaults.removePersistentDomain(forName: suiteName)
    }
}

private let syntheticExecutableURL = URL(
    fileURLWithPath: "/Synthetic/Codex Gauge/codex"
)

private func manualPreferences(
    _ identifier: QuotaSelectionID
) -> AppPreferences {
    AppPreferences(
        displayPreference: DisplayPreference(
            quotaSelection: .manual(identifier)
        ),
        refreshProfile: .fast,
        launchAtLoginIntent: true,
        selectedExecutableURL: syntheticExecutableURL,
        hasCompletedFirstLaunch: true,
        language: .english,
        statusGaugeAppearance: .custom(
            borderColor: .init(red: 1, green: 2, blue: 3),
            fillColor: .init(red: 0xAA, green: 0xBB, blue: 0xCC)
        )
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
