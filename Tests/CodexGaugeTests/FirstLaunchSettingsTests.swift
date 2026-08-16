import CodexGaugeAppKit
import CodexGaugeCore
import CodexGaugeProtocol
import CodexGaugeRefresh
import CodexGaugeSettings
import Foundation

func firstLaunchSettingsTests() -> [TestCase] {
    [
        firstLaunchShowsOnceAndRecordsVisibleWindowTest(),
        firstLaunchFailedShowRemainsIncompleteTest(),
        firstLaunchCancelledBeforeShowRemainsIncompleteTest(),
        firstLaunchVisibleWindowCompletionSurvivesCancellationTest(),
        firstLaunchResetArgumentPreservesPreferencesTest(),
        firstLaunchConcurrentUpdatesArePreservedTest(),
        firstLaunchResetMergesConcurrentUpdatesTest()
    ]
}

private func firstLaunchCancelledBeforeShowRemainsIncompleteTest() -> TestCase {
    TestCase(name: "cancelled first launch before show does not complete") {
        try await firstLaunchCancelledBeforeShowRemainsIncompleteScenario()
    }
}

@MainActor
private func firstLaunchCancelledBeforeShowRemainsIncompleteScenario() async throws {
    let store = try FirstLaunchPreferencesStore()
    defer { store.cleanUp() }
    let repository = try store.repository()
    let settings = FirstLaunchSettingsRuntimeSpy(showResult: true)
    let coordinator = FirstLaunchSettingsCoordinator(
        repository: repository,
        settingsRuntime: settings,
        testingOptions: .production
    )
    let runTask = Task { @MainActor in
        await coordinator.runAfterInitialRefreshStarted()
    }
    runTask.cancel()
    await runTask.value

    let preferences = await repository.load()
    try expect(!preferences.hasCompletedFirstLaunch, "Expected cancellation not completed")
    try expect(settings.showCount == 0, "Expected no show after prior cancellation")
}

private func firstLaunchVisibleWindowCompletionSurvivesCancellationTest() -> TestCase {
    TestCase(name: "visible first launch completion drains after caller cancellation") {
        try await firstLaunchVisibleWindowCompletionSurvivesCancellationScenario()
    }
}

@MainActor
private func firstLaunchVisibleWindowCompletionSurvivesCancellationScenario() async throws {
    let store = try FirstLaunchPreferencesStore()
    defer { store.cleanUp() }
    let repository = try store.repository()
    let settings = FirstLaunchSettingsRuntimeSpy(showResult: true)
    settings.onShow = {
        withUnsafeCurrentTask { task in
            task?.cancel()
        }
    }
    let coordinator = FirstLaunchSettingsCoordinator(
        repository: repository,
        settingsRuntime: settings,
        testingOptions: .production
    )
    let runTask = Task { @MainActor in
        await coordinator.runAfterInitialRefreshStarted()
    }

    await runTask.value

    let preferences = await repository.load()
    try expect(preferences.hasCompletedFirstLaunch, "Expected visible window completed")
    try expect(settings.showCount == 1, "Expected one visible presentation")
}

private func firstLaunchShowsOnceAndRecordsVisibleWindowTest() -> TestCase {
    TestCase(name: "first launch shows settings once and records a visible window") {
        try await firstLaunchShowsOnceAndRecordsVisibleWindowScenario()
    }
}

@MainActor
private func firstLaunchShowsOnceAndRecordsVisibleWindowScenario() async throws {
    let store = try FirstLaunchPreferencesStore()
    defer { store.cleanUp() }
    let repository = try store.repository()
    let settings = FirstLaunchSettingsRuntimeSpy(showResult: true)
    let coordinator = FirstLaunchSettingsCoordinator(
        repository: repository,
        settingsRuntime: settings,
        testingOptions: .production
    )

    await coordinator.runAfterInitialRefreshStarted()
    await coordinator.runAfterInitialRefreshStarted()

    try expect(settings.showCount == 1, "Expected one automatic settings window")
    let completedPreferences = await repository.load()
    try expect(completedPreferences.hasCompletedFirstLaunch, "Expected completion saved")

    let subsequentSettings = FirstLaunchSettingsRuntimeSpy(showResult: true)
    let subsequentLaunch = FirstLaunchSettingsCoordinator(
        repository: repository,
        settingsRuntime: subsequentSettings,
        testingOptions: .production
    )
    await subsequentLaunch.runAfterInitialRefreshStarted()

    try expect(subsequentSettings.showCount == 0, "Expected no later automatic window")
}

private func firstLaunchFailedShowRemainsIncompleteTest() -> TestCase {
    TestCase(name: "first launch does not complete when settings is not visible") {
        try await firstLaunchFailedShowRemainsIncompleteScenario()
    }
}

@MainActor
private func firstLaunchFailedShowRemainsIncompleteScenario() async throws {
    let store = try FirstLaunchPreferencesStore()
    defer { store.cleanUp() }
    let repository = try store.repository()
    let settings = FirstLaunchSettingsRuntimeSpy(showResult: false)
    let coordinator = FirstLaunchSettingsCoordinator(
        repository: repository,
        settingsRuntime: settings,
        testingOptions: .production
    )

    await coordinator.runAfterInitialRefreshStarted()
    await coordinator.runAfterInitialRefreshStarted()

    try expect(settings.showCount == 1, "Expected one failed attempt per launch")
    let failedPreferences = await repository.load()
    try expect(
        !failedPreferences.hasCompletedFirstLaunch,
        "Expected failed visibility not marked complete"
    )
}

private func firstLaunchResetArgumentPreservesPreferencesTest() -> TestCase {
    TestCase(name: "first launch UI test reset preserves every other preference") {
        try await firstLaunchResetArgumentPreservesPreferencesScenario()
    }
}

@MainActor
private func firstLaunchResetArgumentPreservesPreferencesScenario() async throws {
    let store = try FirstLaunchPreferencesStore()
    defer { store.cleanUp() }
    let repository = try store.repository()
    let initial = firstLaunchSyntheticPreferences(hasCompletedFirstLaunch: true)
    try await repository.save(initial)
    var preferencesWhileShowing: AppPreferences?
    let settings = FirstLaunchSettingsRuntimeSpy(showResult: true)
    settings.onShow = {
        preferencesWhileShowing = await repository.load()
    }
    let options = FirstLaunchTestingOptions(arguments: [
        "/Synthetic/CodexGauge",
        FirstLaunchTestingOptions.resetCompletionArgument
    ])
    let coordinator = FirstLaunchSettingsCoordinator(
        repository: repository,
        settingsRuntime: settings,
        testingOptions: options
    )

    await coordinator.runAfterInitialRefreshStarted()

    let expectedDuringShow = firstLaunchSyntheticPreferences(
        hasCompletedFirstLaunch: false
    )
    let finalPreferences = await repository.load()
    try expect(preferencesWhileShowing == expectedDuringShow, "Expected only flag reset")
    try expect(finalPreferences == initial, "Expected other preferences preserved")
    try expect(settings.showCount == 1, "Expected reset to show settings")
    try expect(
        !FirstLaunchTestingOptions(arguments: ["--reset-first-launch"])
            .shouldResetCompletion,
        "Expected only the explicit UI test argument"
    )
}

private func firstLaunchConcurrentUpdatesArePreservedTest() -> TestCase {
    TestCase(name: "first launch completion preserves concurrent form and selection saves") {
        try await firstLaunchConcurrentUpdatesArePreservedScenario()
    }
}

@MainActor
private func firstLaunchConcurrentUpdatesArePreservedScenario() async throws {
    let store = try FirstLaunchPreferencesStore()
    defer { store.cleanUp() }
    let repository = try store.repository()
    let showGate = FirstLaunchShowGate()
    let settings = FirstLaunchSettingsRuntimeSpy(showResult: true)
    settings.onShow = {
        await showGate.wait()
    }
    let coordinator = FirstLaunchSettingsCoordinator(
        repository: repository,
        settingsRuntime: settings,
        testingOptions: .production
    )
    let runTask = Task { @MainActor in
        await coordinator.runAfterInitialRefreshStarted()
    }
    try await waitForFirstLaunchCondition { await showGate.hasStarted }
    let values = firstLaunchFormValues()
    let selectedURL = URL(fileURLWithPath: "/Synthetic/Concurrent/codex")

    async let formSave: Void = repository.saveSettingsForm(values)
    async let selectionSave: Void = repository.saveSelectedExecutableURL(selectedURL)
    _ = try await (formSave, selectionSave)
    await showGate.finish()
    await runTask.value

    let saved = await repository.load()
    try expect(saved.displayPreference == values.displayPreference, "Expected display saved")
    try expect(saved.refreshProfile == values.refreshProfile, "Expected profile saved")
    try expect(saved.launchAtLoginIntent, "Expected login intent saved")
    try expect(saved.selectedExecutableURL == selectedURL, "Expected executable saved")
    try expect(saved.hasCompletedFirstLaunch, "Expected completion merged last")
}

private func firstLaunchResetMergesConcurrentUpdatesTest() -> TestCase {
    TestCase(name: "first launch UI test reset merges concurrent preference updates") {
        let store = try FirstLaunchPreferencesStore()
        defer { store.cleanUp() }
        let repository = try store.repository()
        try await repository.save(
            firstLaunchSyntheticPreferences(hasCompletedFirstLaunch: true)
        )
        let values = firstLaunchFormValues()
        let selectedURL = URL(fileURLWithPath: "/Synthetic/Reset/codex")

        async let reset: Void = repository.resetFirstLaunchCompletionForUITesting()
        async let formSave: Void = repository.saveSettingsForm(values)
        async let selectionSave: Void = repository.saveSelectedExecutableURL(selectedURL)
        _ = try await (reset, formSave, selectionSave)

        let saved = await repository.load()
        try expect(saved.displayPreference == values.displayPreference, "Expected display preserved")
        try expect(saved.refreshProfile == values.refreshProfile, "Expected profile preserved")
        try expect(saved.launchAtLoginIntent, "Expected login preserved")
        try expect(saved.selectedExecutableURL == selectedURL, "Expected selection preserved")
        try expect(!saved.hasCompletedFirstLaunch, "Expected test reset retained")
    }
}

@MainActor
private final class FirstLaunchSettingsRuntimeSpy: ApplicationSettingsRuntime {
    private let showResult: Bool
    var onShow: (@MainActor () async -> Void)?
    private(set) var showCount = 0

    init(showResult: Bool) {
        self.showResult = showResult
    }

    func showSettings() async -> Bool {
        showCount += 1
        await onShow?()
        return showResult
    }

    func requestExecutableSelection() {}

    func updateDiscoveredQuotaIDs(_ identifiers: Set<QuotaSelectionID>) {
        _ = identifiers
    }

    func updateConnectionStatus(_ status: CodexConnectionStatus) {
        _ = status
    }

    func shutdown() async {}
}

private actor FirstLaunchShowGate {
    private(set) var hasStarted = false
    private var continuation: CheckedContinuation<Void, Never>?

    func wait() async {
        hasStarted = true
        await withCheckedContinuation { continuation in
            self.continuation = continuation
        }
    }

    func finish() {
        continuation?.resume()
        continuation = nil
    }
}

private struct FirstLaunchPreferencesStore {
    let suiteName: String
    let userDefaults: UserDefaults

    init() throws {
        let suiteName = "io.github.symflee.codex-gauge.tests.first-launch.\(UUID().uuidString)"
        guard let userDefaults = UserDefaults(suiteName: suiteName) else {
            throw TestFailure(description: "Unable to create first-launch defaults")
        }
        self.suiteName = suiteName
        self.userDefaults = userDefaults
    }

    func repository() throws -> AppPreferencesRepository {
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            throw TestFailure(description: "Unable to inject first-launch defaults")
        }
        return AppPreferencesRepository(userDefaults: defaults)
    }

    func cleanUp() {
        userDefaults.removePersistentDomain(forName: suiteName)
    }
}

@MainActor
private func waitForFirstLaunchCondition(
    _ condition: @escaping @MainActor () async -> Bool
) async throws {
    for _ in 0..<200 {
        if await condition() {
            return
        }
        await Task.yield()
    }
    throw TestFailure(description: "Timed out waiting for first-launch condition")
}

private func firstLaunchSyntheticPreferences(
    hasCompletedFirstLaunch: Bool
) -> AppPreferences {
    AppPreferences(
        displayPreference: firstLaunchFormValues().displayPreference,
        refreshProfile: .fast,
        launchAtLoginIntent: true,
        selectedExecutableURL: URL(fileURLWithPath: "/Synthetic/Existing/codex"),
        hasCompletedFirstLaunch: hasCompletedFirstLaunch
    )
}

private func firstLaunchFormValues() -> SettingsFormValues {
    SettingsFormValues(
        displayPreference: DisplayPreference(
            productMode: .both,
            quotaSelection: .manual([
                QuotaSelectionID(product: .codex, rawDurationMinutes: 300),
                QuotaSelectionID(product: .spark, rawDurationMinutes: 10_080)
            ])
        ),
        refreshProfile: .eco,
        launchAtLoginIntent: true
    )
}
