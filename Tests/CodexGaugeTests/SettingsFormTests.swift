import CodexGaugeCore
import CodexGaugeRefresh
import CodexGaugeSettings
import Foundation

func settingsFormTests() -> [TestCase] {
    [
        settingsFormBuildsQuotaOptionsTest(),
        settingsFormReducerEditsPreferencesTest(),
        settingsFormReducerFiltersProductsTest(),
        settingsFormPresenterTest(),
        settingsFormNormalizesEmptyManualPersistenceTest(),
        settingsFormValuesAreSendableTest()
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
            hasCompletedFirstLaunch: true
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
            .launchAtLoginIntentChanged(true)
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

private func settingsFormValuesAreSendableTest() -> TestCase {
    TestCase(name: "settings form values are immutable and Sendable") {
        let state = SettingsFormState(preferences: .default, discoveredQuotaIDs: [])
        requireSettingsFormSendable(state)
        requireSettingsFormSendable(SettingsFormReducer())
        requireSettingsFormSendable(SettingsFormPresenter().present(state))
        requireSettingsFormSendable(state.formValues)
        try expect(
            state.formValues == SettingsFormValues(preferences: .default),
            "Expected stable form defaults"
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

private func requireSettingsFormSendable<Value: Sendable>(_ value: Value) {
    _ = value
}
