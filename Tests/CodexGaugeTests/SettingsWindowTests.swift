import AppKit
import CodexGaugeAppKit
import CodexGaugeCore
import CodexGaugeRefresh
import CodexGaugeSettings
import Foundation

func settingsWindowTests() -> [TestCase] {
    [
        settingsWindowStructureTest(),
        settingsWindowPersistsEditsTest(),
        settingsWindowRecreationReloadsPreferencesTest(),
        settingsWindowReleasesUIObjectsTest(),
        settingsDurationAccessibilityLocalizationTest()
    ]
}

private func settingsWindowStructureTest() -> TestCase {
    TestCase(name: "settings opens a lazy independent AppKit window") {
        try await settingsWindowStructureScenario()
    }
}

@MainActor
private func settingsWindowStructureScenario() async throws {
    _ = NSApplication.shared
    let store = try SettingsUITestStore()
    defer { store.cleanUp() }
    let repository = try store.repository()
    let coordinator = SettingsWindowCoordinator(
        repository: repository,
        discoveredQuotaProvider: { [] }
    )

    try expect(coordinator.activeWindowController == nil, "Expected lazy window creation")
    let controller = await coordinator.showSettings()
    guard let window = controller.window else {
        throw TestFailure(description: "Expected settings window")
    }

    try expect(coordinator.activeWindowController === controller, "Expected owner retention")
    try expect(window.styleMask.contains(.titled), "Expected titled window")
    try expect(window.styleMask.contains(.closable), "Expected closable window")
    try expect(window.styleMask != .borderless, "Expected standard window chrome")
    try expect(abs(window.contentLayoutRect.width - 440) < 1, "Expected 440pt content width")
    try expect(controller.settingsViewController.isViewLoaded, "Expected programmatic view")
    try expect(!window.title.hasPrefix("settings."), "Expected localized window title")
    let repeatedController = await coordinator.showSettings()
    try expect(repeatedController === controller, "Expected one settings window")

    controller.close()
}

private func settingsWindowPersistsEditsTest() -> TestCase {
    TestCase(name: "settings persists form edits and preserves hidden fields") {
        try await settingsWindowPersistenceScenario()
    }
}

@MainActor
private func settingsWindowPersistenceScenario() async throws {
    _ = NSApplication.shared
    let store = try SettingsUITestStore()
    defer { store.cleanUp() }
    let repository = try store.repository()
    let initialExecutableURL = URL(fileURLWithPath: "/Synthetic/Initial/codex")
    let currentExecutableURL = URL(fileURLWithPath: "/Synthetic/Current/codex")
    let missing = QuotaSelectionID(product: .codex, rawDurationMinutes: 10_080)
    let discovered = QuotaSelectionID(product: .codex, rawDurationMinutes: 300)
    let initial = AppPreferences(
        displayPreference: DisplayPreference(
            productMode: .codex,
            quotaSelection: .manual([missing])
        ),
        selectedExecutableURL: initialExecutableURL,
        hasCompletedFirstLaunch: false
    )
    try await repository.save(initial)
    let coordinator = SettingsWindowCoordinator(
        repository: repository,
        discoveredQuotaProvider: { [discovered] }
    )
    let controller = await coordinator.showSettings()
    let viewController = controller.settingsViewController

    guard let missingOption = viewController.formState.quotaOptions.first(
        where: { $0.identifier == missing }
    ) else {
        throw TestFailure(description: "Expected missing saved option")
    }
    try expect(
        missingOption.availability == .currentlyUnavailable,
        "Expected unavailable saved option"
    )
    try expect(
        viewController.renderedQuotaOptionTitles.allSatisfy {
            !$0.hasPrefix("settings.")
        },
        "Expected localized quota option titles"
    )
    let externallyUpdated = AppPreferences(
        displayPreference: initial.displayPreference,
        refreshProfile: initial.refreshProfile,
        launchAtLoginIntent: initial.launchAtLoginIntent,
        selectedExecutableURL: currentExecutableURL,
        hasCompletedFirstLaunch: true
    )
    try await repository.save(externallyUpdated)

    viewController.apply(.productModeChanged(.both))
    viewController.apply(.quotaSelectionChanged(discovered, isSelected: true))
    viewController.apply(.refreshProfileChanged(.fast))
    viewController.apply(.launchAtLoginIntentChanged(true))
    await coordinator.flushPendingSave()
    let saved = await repository.load()

    try expect(saved.displayPreference.productMode == .both, "Expected products saved")
    try expect(
        saved.displayPreference.quotaSelection == .manual([missing, discovered]),
        "Expected manual selections saved"
    )
    try expect(saved.refreshProfile == .fast, "Expected refresh profile saved")
    try expect(saved.launchAtLoginIntent, "Expected login intent saved")
    try expect(saved.selectedExecutableURL == currentExecutableURL, "Expected latest executable")
    try expect(saved.hasCompletedFirstLaunch, "Expected first launch preserved")

    controller.close()
}

private func settingsWindowRecreationReloadsPreferencesTest() -> TestCase {
    TestCase(name: "settings recreation reloads current UserDefaults") {
        try await settingsWindowRecreationScenario()
    }
}

@MainActor
private func settingsWindowRecreationScenario() async throws {
    _ = NSApplication.shared
    let store = try SettingsUITestStore()
    defer { store.cleanUp() }
    let repository = try store.repository()
    let identifier = QuotaSelectionID(product: .spark, rawDurationMinutes: 300)
    let coordinator = SettingsWindowCoordinator(
        repository: repository,
        discoveredQuotaProvider: { [identifier] }
    )

    var controller: SettingsWindowController? = await coordinator.showSettings()
    controller?.close()
    controller = nil
    let updated = AppPreferences(
        displayPreference: DisplayPreference(
            productMode: .spark,
            quotaSelection: .manual([identifier])
        ),
        refreshProfile: .eco,
        launchAtLoginIntent: true
    )
    try await repository.save(updated)

    controller = await coordinator.showSettings()
    guard let state = controller?.settingsViewController.formState else {
        throw TestFailure(description: "Expected recreated settings state")
    }
    try expect(state.productMode == .spark, "Expected reloaded product mode")
    try expect(state.selectedQuotaIDs == [identifier], "Expected reloaded selection")
    try expect(state.refreshProfile == .eco, "Expected reloaded refresh profile")
    try expect(state.launchAtLoginIntent, "Expected reloaded login intent")

    controller?.close()
}

private func settingsWindowReleasesUIObjectsTest() -> TestCase {
    TestCase(name: "closing settings releases controller view controller and views") {
        try await settingsWindowDeallocationScenario()
    }
}

@MainActor
private func settingsWindowDeallocationScenario() async throws {
    _ = NSApplication.shared
    let store = try SettingsUITestStore()
    defer { store.cleanUp() }
    let repository = try store.repository()
    let coordinator = SettingsWindowCoordinator(
        repository: repository,
        discoveredQuotaProvider: { [] }
    )
    var controller: SettingsWindowController? = await coordinator.showSettings()
    weak let weakController = controller
    weak let weakViewController = controller?.settingsViewController
    weak let weakView = controller?.settingsViewController.view

    controller?.close()
    controller = nil
    await Task.yield()

    try expect(coordinator.activeWindowController == nil, "Expected owner release")
    try expect(weakController == nil, "Expected window controller deallocation")
    try expect(weakViewController == nil, "Expected view controller deallocation")
    try expect(weakView == nil, "Expected view graph deallocation")
}

private struct SettingsUITestStore {
    let suiteName: String
    let inspectionDefaults: UserDefaults

    init() throws {
        let suiteName = "io.github.symflee.codex-gauge.tests.settings-ui.\(UUID().uuidString)"
        guard let inspectionDefaults = UserDefaults(suiteName: suiteName) else {
            throw TestFailure(description: "Unable to create settings UI defaults")
        }
        self.suiteName = suiteName
        self.inspectionDefaults = inspectionDefaults
    }

    func repository() throws -> AppPreferencesRepository {
        guard let repositoryDefaults = UserDefaults(suiteName: suiteName) else {
            throw TestFailure(description: "Unable to inject settings UI defaults")
        }
        return AppPreferencesRepository(userDefaults: repositoryDefaults)
    }

    func cleanUp() {
        inspectionDefaults.removePersistentDomain(forName: suiteName)
    }
}

private func settingsDurationAccessibilityLocalizationTest() -> TestCase {
    TestCase(name: "settings duration accessibility uses localized full units") {
        let formatter = SettingsDurationAccessibilityFormatter(
            vocabulary: SettingsDurationAccessibilityVocabulary(
                unknown: "Unknown duration",
                oneHour: "1 hour",
                hours: "{count} hours",
                oneDay: "1 day",
                days: "{count} days",
                oneWeek: "1 week",
                weeks: "{count} weeks"
            )
        )

        try expect(formatter.format(300) == "5 hours", "Expected localized hours")
        try expect(formatter.format(1_440) == "1 day", "Expected localized day")
        try expect(formatter.format(10_080) == "1 week", "Expected localized week")
        try expect(formatter.format(20_160) == "2 weeks", "Expected localized weeks")
        try expect(formatter.format(43_200) == "30 days", "Expected no month inference")
        try expect(formatter.format(nil) == "Unknown duration", "Expected localized unknown")
    }
}
