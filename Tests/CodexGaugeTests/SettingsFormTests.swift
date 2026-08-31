import CodexGaugeCore
import CodexGaugeRefresh
import CodexGaugeSettings
import Foundation

func settingsFormTests() -> [TestCase] {
    [
        settingsFormBuildsQuotaOptionsTest(),
        settingsFormReducerEditsPreferencesTest(),
        settingsFormReducerFiltersProductsTest(),
        settingsFormEditsGaugeAppearanceTest(),
        settingsFormPresenterTest(),
        settingsFormReplacesDiscoveredQuotasTest(),
        settingsFormNormalizesEmptyManualPersistenceTest()
    ]
}

private func settingsFormBuildsQuotaOptionsTest() -> TestCase {
    TestCase(name: "settings form keeps discovered and missing saved quotas") {
        let codexFiveHour = settingsQuotaID(product: .codex, duration: 300)
        let codexWeekly = settingsQuotaID(product: .codex, duration: 10_080)
        let codexUnknown = settingsQuotaID(product: .codex, duration: nil)
        let sparkFiveHour = settingsQuotaID(product: .spark, duration: 300)
        let missingSparkWeekly = settingsQuotaID(product: .spark, duration: 10_080)
        let preferences = settingsPreferences(
            productMode: .both,
            selection: .manual([codexFiveHour, missingSparkWeekly])
        )
        let state = SettingsFormState(
            preferences: preferences,
            discoveredQuotaIDs: [
                codexUnknown,
                sparkFiveHour,
                codexWeekly,
                codexFiveHour
            ]
        )

        try expect(
            state.quotaOptions.map(\.identifier) == [
                codexFiveHour,
                codexWeekly,
                codexUnknown,
                sparkFiveHour,
                missingSparkWeekly
            ],
            "Expected product, duration and unknown ordering"
        )
        try expect(state.quotaOptions[0].isSelected, "Expected saved Codex selection")
        try expect(state.quotaOptions[0].availability == .discovered, "Expected discovered row")
        try expect(state.quotaOptions[4].isSelected, "Expected missing selection retained")
        try expect(
            state.quotaOptions[4].availability == .currentlyUnavailable,
            "Expected missing selection status"
        )
    }
}

private func settingsFormReducerEditsPreferencesTest() -> TestCase {
    TestCase(name: "settings reducer edits only visible preferences") {
        let executableURL = URL(fileURLWithPath: "/Synthetic/Codex/codex")
        let identifier = settingsQuotaID(product: .spark, duration: 300)
        let initial = AppPreferences(
            selectedExecutableURL: executableURL,
            hasCompletedFirstLaunch: true,
            language: .english
        )
        let reducer = SettingsFormReducer()
        var state = SettingsFormState(
            preferences: initial,
            discoveredQuotaIDs: [identifier]
        )

        state = reducer.reduce(
            state: state,
            event: .quotaSelectionChanged(identifier, isSelected: true)
        )
        try expect(state.selectedQuotaIDs.isEmpty, "Expected automatic mode to ignore checks")

        let events: [SettingsFormEvent] = [
            .productModeChanged(.both),
            .quotaSelectionModeChanged(.manual),
            .quotaSelectionChanged(identifier, isSelected: true),
            .refreshProfileChanged(.fast),
            .launchAtLoginIntentChanged(true),
            .languageChanged(.korean)
        ]
        for event in events {
            state = reducer.reduce(state: state, event: event)
        }
        let formValues = state.formValues

        try expect(formValues.displayPreference.productMode == .both, "Expected both products")
        try expect(
            formValues.displayPreference.quotaSelection == .manual([identifier]),
            "Expected manual quota selection"
        )
        try expect(formValues.refreshProfile == .fast, "Expected fast refresh")
        try expect(formValues.launchAtLoginIntent, "Expected login launch intent")
        try expect(formValues.language == .korean, "Expected Korean language")
        try expect(formValues.statusGaugeAppearance == .default, "Expected gauge preserved")
    }
}

private func settingsFormEditsGaugeAppearanceTest() -> TestCase {
    TestCase(name: "settings form preserves explicit preset and custom gauge modes") {
        let reducer = SettingsFormReducer()
        var state = SettingsFormState(preferences: .default, discoveredQuotaIDs: [])

        state = reducer.reduce(state: state, event: .statusGaugePresetChanged(.green))
        try expect(state.statusGaugeAppearance == .preset(.green), "Expected green preset")

        state = reducer.reduce(state: state, event: .statusGaugeCustomSelected)
        try expect(
            state.statusGaugeAppearance == .custom(
                borderColor: StatusGaugePreset.green.borderColor,
                fillColor: StatusGaugePreset.green.fillColor
            ),
            "Expected custom mode with current colors"
        )

        let border = StatusGaugeColor(red: 0x01, green: 0x23, blue: 0x45)
        state = reducer.reduce(state: state, event: .statusGaugeBorderColorChanged(border))
        try expect(state.statusGaugeAppearance.borderColor == border, "Expected custom border")
        try expect(
            state.statusGaugeAppearance.fillColor == StatusGaugePreset.green.fillColor,
            "Expected fill preserved"
        )

        state = reducer.reduce(
            state: state,
            event: .statusGaugePresetChanged(.blue)
        )
        state = reducer.reduce(
            state: state,
            event: .statusGaugeFillColorChanged(StatusGaugePreset.blue.fillColor)
        )
        try expect(
            state.statusGaugeAppearance == .custom(
                borderColor: StatusGaugePreset.blue.borderColor,
                fillColor: StatusGaugePreset.blue.fillColor
            ),
            "Expected matching colors to retain custom mode"
        )
        try expect(state.formValues.statusGaugeAppearance == state.statusGaugeAppearance, "Expected form value")
    }
}

private func settingsFormReducerFiltersProductsTest() -> TestCase {
    TestCase(name: "settings form filters discovery while retaining saved selections") {
        let codex = settingsQuotaID(product: .codex, duration: 300)
        let spark = settingsQuotaID(product: .spark, duration: 300)
        let reducer = SettingsFormReducer()
        let preferences = settingsPreferences(
            productMode: .codex,
            selection: .manual([codex])
        )
        var state = SettingsFormState(
            preferences: preferences,
            discoveredQuotaIDs: [codex, spark]
        )

        try expect(state.quotaOptions.map(\.identifier) == [codex], "Expected Codex discovery")

        state = reducer.reduce(state: state, event: .productModeChanged(.spark))

        try expect(state.quotaOptions.map(\.identifier) == [spark], "Expected Spark discovery")
        try expect(state.selectedQuotaIDs.isEmpty, "Expected off-product choice excluded")
        try expect(
            state.formValues.displayPreference.quotaSelection == .automatic,
            "Expected empty effective manual selection to recover"
        )

        state = reducer.reduce(state: state, event: .productModeChanged(.codex))

        try expect(state.selectedQuotaIDs == [codex], "Expected transient choice restoration")
    }
}

private func settingsFormPresenterTest() -> TestCase {
    TestCase(name: "settings presenter derives checkbox and empty states") {
        let identifier = settingsQuotaID(product: .codex, duration: 300)
        let presenter = SettingsFormPresenter()
        let automatic = SettingsFormState(
            preferences: .default,
            discoveredQuotaIDs: [identifier]
        )
        let automaticPresentation = presenter.present(automatic)

        try expect(!automaticPresentation.quotaChoicesEnabled, "Expected automatic disabling")
        try expect(!automaticPresentation.showsEmptyQuotaMessage, "Expected discovered row")
        try expect(
            automaticPresentation.quotaRows.map(\.identifier) == [identifier],
            "Expected presented identifier"
        )

        let reducer = SettingsFormReducer()
        let manual = reducer.reduce(
            state: SettingsFormState(preferences: .default, discoveredQuotaIDs: []),
            event: .quotaSelectionModeChanged(.manual)
        )
        let manualPresentation = presenter.present(manual)

        try expect(manualPresentation.quotaChoicesEnabled, "Expected manual enabling")
        try expect(manualPresentation.showsEmptyQuotaMessage, "Expected empty quota message")
    }
}

private func settingsFormNormalizesEmptyManualPersistenceTest() -> TestCase {
    TestCase(name: "settings form persists empty manual state as automatic") {
        let reducer = SettingsFormReducer()
        var state = SettingsFormState(preferences: .default, discoveredQuotaIDs: [])

        try expect(
            state.formValues == SettingsFormValues(preferences: .default),
            "Expected stable form defaults"
        )
        try expect(state.language == .english, "Expected default form language")
        try expect(state.statusGaugeAppearance == .default, "Expected default gauge")
        state = reducer.reduce(
            state: state,
            event: .quotaSelectionModeChanged(.manual)
        )

        try expect(state.quotaSelectionMode == .manual, "Expected editable manual state")
        try expect(
            state.formValues.displayPreference.quotaSelection == .automatic,
            "Expected safe persisted normalization"
        )
    }
}

private func settingsFormReplacesDiscoveredQuotasTest() -> TestCase {
    TestCase(name: "settings discovery update preserves every user preference") {
        let selected = settingsQuotaID(product: .codex, duration: 300)
        let discovered = settingsQuotaID(product: .codex, duration: 10_080)
        let preferences = settingsPreferences(
            productMode: .codex,
            selection: .manual([selected])
        )
        let reducer = SettingsFormReducer()
        let initial = SettingsFormState(
            preferences: preferences,
            discoveredQuotaIDs: []
        )
        let updated = reducer.reduce(
            state: initial,
            event: .discoveredQuotaIDsChanged([selected, discovered])
        )

        try expect(updated.formValues == initial.formValues, "Expected preferences unchanged")
        try expect(updated.language == preferences.language, "Expected language unchanged")
        try expect(
            updated.statusGaugeAppearance == preferences.statusGaugeAppearance,
            "Expected gauge appearance unchanged"
        )
        try expect(updated.quotaOptions.count == 2, "Expected discovery rows replaced")
        try expect(
            updated.quotaOptions.first?.availability == .discovered,
            "Expected selected row to become available"
        )
    }
}

private func settingsPreferences(
    productMode: DisplayProductMode,
    selection: DisplayQuotaSelection
) -> AppPreferences {
    AppPreferences(
        displayPreference: DisplayPreference(
            productMode: productMode,
            quotaSelection: selection
        )
    )
}

private func settingsQuotaID(
    product: UsageProduct,
    duration: Int?
) -> QuotaSelectionID {
    QuotaSelectionID(product: product, rawDurationMinutes: duration)
}
