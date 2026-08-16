import AppKit
import CodexGaugeAppKit
import CodexGaugeCore
import CodexGaugeProtocol
import CodexGaugeRefresh
import CodexGaugeSettings
import Foundation

func settingsWindowTests() -> [TestCase] {
    [
        settingsWindowStructureTest(),
        settingsWindowPersistsEditsTest(),
        settingsWindowRecreationReloadsPreferencesTest(),
        settingsWindowReleasesUIObjectsTest(),
        settingsWindowConnectionSectionTest(),
        settingsWindowConnectionActionsTest(),
        settingsWindowExecutableSelectionSeamTest(),
        settingsWindowCommittedSelectionCallbackTest(),
        settingsWindowSelectionIdentityTest(),
        settingsWindowDiscoveryUpdateTest(),
        settingsWindowSerializesDiagnosticsTest(),
        settingsWindowPendingDiagnosticsReleaseTest(),
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
    var runtimeValues = [SettingsFormValues]()
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
        discoveredQuotaProvider: { [discovered] },
        onSettingsFormValuesChanged: { runtimeValues.append($0) }
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
    try expect(runtimeValues.count == 4, "Expected every form change forwarded")
    try expect(
        runtimeValues.last == viewController.formState.formValues,
        "Expected latest form values forwarded for runtime application"
    )
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

private func settingsWindowConnectionSectionTest() -> TestCase {
    TestCase(name: "settings renders sanitized connection diagnostics") {
        try await settingsWindowConnectionSectionScenario()
    }
}

@MainActor
private func settingsWindowConnectionSectionScenario() async throws {
    _ = NSApplication.shared
    let store = try SettingsUITestStore()
    defer { store.cleanUp() }
    let provider = try SettingsDiagnosticsProviderStub()
    let coordinator = SettingsWindowCoordinator(
        repository: try store.repository(),
        discoveredQuotaProvider: { [] },
        connectionDiagnosticsProvider: { selectedURL, status in
            await provider.snapshot(selectedURL: selectedURL, status: status)
        },
        connectionStatusProvider: { .connected }
    )
    let controller = await coordinator.showSettings()
    let viewController = controller.settingsViewController
    try await waitForSettingsCondition {
        viewController.connectionDiagnostics.cliVersion?.value == "1.2.3"
    }

    try expect(
        viewController.connectionDiagnostics.connectionStatus == .connected,
        "Expected typed connected state"
    )
    try expect(
        viewController.renderedConnectionDetailTexts.allSatisfy {
            !$0.hasPrefix("settings.") && !$0.contains("/Synthetic/")
        },
        "Expected localized path-safe connection details"
    )
    try expect(
        viewController.renderedConnectionActionTitles.allSatisfy {
            !$0.hasPrefix("settings.")
        },
        "Expected localized connection actions"
    )
    controller.close()
}

private func settingsWindowConnectionActionsTest() -> TestCase {
    TestCase(name: "settings injects Codex selection and diagnostic copy actions") {
        try await settingsWindowConnectionActionsScenario()
    }
}

@MainActor
private func settingsWindowConnectionActionsScenario() async throws {
    _ = NSApplication.shared
    let store = try SettingsUITestStore()
    defer { store.cleanUp() }
    let repository = try store.repository()
    let provider = try SettingsDiagnosticsProviderStub()
    let selectedURL = URL(fileURLWithPath: "/Synthetic/Chosen/codex")
    let selector = SettingsExecutableSelectorStub(selectedURL: selectedURL)
    let clipboard = SettingsDiagnosticClipboardStub()
    var callbackURL: URL?
    let coordinator = SettingsWindowCoordinator(
        repository: repository,
        discoveredQuotaProvider: { [] },
        connectionDiagnosticsProvider: { selectedURL, status in
            await provider.snapshot(selectedURL: selectedURL, status: status)
        },
        connectionStatusProvider: { .signedOut },
        executableSelector: selector,
        clipboardWriter: clipboard,
        diagnosticEnvironment: DiagnosticEnvironment(
            appVersion: "0.1.0",
            macOSVersion: "15.4.1",
            architecture: .arm64
        ),
        onExecutableSelectionChanged: { callbackURL = $0 }
    )
    let controller = await coordinator.showSettings()
    let viewController = controller.settingsViewController
    try await waitForSettingsCondition {
        viewController.connectionDiagnostics.cliVersion != nil
    }

    viewController.performConnectionAction(.copyDiagnostics)
    guard let firstReport = clipboard.lastText else {
        throw TestFailure(description: "Expected copied diagnostics")
    }
    try expect(firstReport.contains("connection-status: signed-out"), "Expected typed status")
    try expect(!firstReport.contains("/Synthetic/"), "Expected no path in clipboard")

    viewController.performConnectionAction(.selectCodex)
    try await waitForSettingsCondition {
        await repository.load().selectedExecutableURL == selectedURL
    }
    try await waitForSettingsCondition {
        viewController.connectionDiagnostics.path?.source == .userSelected
    }
    try expect(callbackURL == selectedURL, "Expected injected selection callback")
    try expect(
        viewController.renderedConnectionDetailTexts.allSatisfy {
            !$0.contains("/Synthetic/")
        },
        "Expected selected path to remain redacted"
    )
    controller.close()
}

private func settingsWindowPendingDiagnosticsReleaseTest() -> TestCase {
    TestCase(name: "pending connection diagnostics do not retain the settings graph") {
        try await settingsWindowPendingDiagnosticsReleaseScenario()
    }
}

private func settingsWindowDiscoveryUpdateTest() -> TestCase {
    TestCase(name: "settings discovery refresh rerenders without save callbacks") {
        try await settingsWindowDiscoveryUpdateScenario()
    }
}

@MainActor
private func settingsWindowDiscoveryUpdateScenario() async throws {
    _ = NSApplication.shared
    let store = try SettingsUITestStore()
    defer { store.cleanUp() }
    let repository = try store.repository()
    var runtimeChangeCount = 0
    let coordinator = SettingsWindowCoordinator(
        repository: repository,
        discoveredQuotaProvider: { [] },
        onSettingsFormValuesChanged: { _ in runtimeChangeCount += 1 }
    )
    let controller = await coordinator.showSettings()
    let identifier = QuotaSelectionID(product: .codex, rawDurationMinutes: 300)

    coordinator.updateDiscoveredQuotaIDs([identifier])

    try expect(
        controller.settingsViewController.formState.quotaOptions.map(\.identifier)
            == [identifier],
        "Expected newly discovered quota row"
    )
    try expect(
        controller.settingsViewController.renderedQuotaOptionTitles.count == 1,
        "Expected quota rows rerendered"
    )
    try expect(runtimeChangeCount == 0, "Expected no runtime preference callback")
    let saved = await repository.load()
    try expect(saved == .default, "Expected no discovery persistence")
    controller.close()
}

private func settingsWindowExecutableSelectionSeamTest() -> TestCase {
    TestCase(name: "menu selection seam opens settings and reuses executable selection") {
        try await settingsWindowExecutableSelectionSeamScenario()
    }
}

private func settingsWindowCommittedSelectionCallbackTest() -> TestCase {
    TestCase(name: "committed executable selection updates runtime after window close") {
        try await settingsWindowCommittedSelectionCallbackScenario()
    }
}

@MainActor
private func settingsWindowCommittedSelectionCallbackScenario() async throws {
    _ = NSApplication.shared
    let store = try SettingsUITestStore()
    defer { store.cleanUp() }
    let repository = try store.repository()
    let selectedURL = URL(fileURLWithPath: "/Synthetic/Closed/codex")
    let saveGate = SettingsSelectionSaveGate()
    var callbackURL: URL?
    let coordinator = SettingsWindowCoordinator(
        repository: repository,
        discoveredQuotaProvider: { [] },
        executableSelector: SettingsExecutableSelectorStub(selectedURL: selectedURL),
        executableSelectionSaver: { url in try await saveGate.save(url) },
        onExecutableSelectionChanged: { callbackURL = $0 }
    )

    coordinator.requestExecutableSelection()
    try await waitForSettingsCondition { await saveGate.hasStarted }
    coordinator.activeWindowController?.close()
    await saveGate.finish()
    try await waitForSettingsCondition { callbackURL == selectedURL }

    try expect(coordinator.activeWindowController == nil, "Expected closed settings window")
    let savedURL = await saveGate.savedURL
    try expect(savedURL == selectedURL, "Expected selected URL committed")
    try expect(callbackURL == selectedURL, "Expected committed selection applied at runtime")
}

private func settingsWindowSelectionIdentityTest() -> TestCase {
    TestCase(name: "stale executable selection cannot clear a newer selection task") {
        try await settingsWindowSelectionIdentityScenario()
    }
}

@MainActor
private func settingsWindowSelectionIdentityScenario() async throws {
    _ = NSApplication.shared
    let store = try SettingsUITestStore()
    defer { store.cleanUp() }
    let selector = OverlappingSettingsExecutableSelectorStub()
    let recorder = SettingsSelectionRecorder()
    var callbackURLs = [URL]()
    let coordinator = SettingsWindowCoordinator(
        repository: try store.repository(),
        discoveredQuotaProvider: { [] },
        executableSelector: selector,
        executableSelectionSaver: { url in await recorder.save(url) },
        onExecutableSelectionChanged: { callbackURLs.append($0) }
    )

    coordinator.requestExecutableSelection()
    try await waitForSettingsCondition { selector.callCount == 1 }
    var firstController = coordinator.activeWindowController
    weak let weakFirstController = firstController
    firstController?.close()
    firstController = nil
    await Task.yield()
    try expect(weakFirstController == nil, "Expected pending selection not to retain settings")

    coordinator.requestExecutableSelection()
    try await waitForSettingsCondition { selector.callCount == 2 }
    selector.finish(call: 1, url: URL(fileURLWithPath: "/Synthetic/Stale/codex"))
    for _ in 0..<20 {
        await Task.yield()
    }
    coordinator.requestExecutableSelection()
    for _ in 0..<20 {
        await Task.yield()
    }
    try expect(selector.callCount == 2, "Expected newer selection task retained")

    let currentURL = URL(fileURLWithPath: "/Synthetic/Current/codex")
    selector.finish(call: 2, url: currentURL)
    try await waitForSettingsCondition { await recorder.savedURLs == [currentURL] }
    try expect(callbackURLs == [currentURL], "Expected only current selection applied")
    coordinator.activeWindowController?.close()
}

private func settingsWindowSerializesDiagnosticsTest() -> TestCase {
    TestCase(name: "connection diagnostics wait for cancelled process cleanup") {
        try await settingsWindowSerializesDiagnosticsScenario()
    }
}

@MainActor
private func settingsWindowSerializesDiagnosticsScenario() async throws {
    _ = NSApplication.shared
    let store = try SettingsUITestStore()
    defer { store.cleanUp() }
    let probe = SerializedSettingsDiagnosticsProbe()
    let coordinator = SettingsWindowCoordinator(
        repository: try store.repository(),
        discoveredQuotaProvider: { [] },
        connectionDiagnosticsProvider: { _, _ in
            await probe.snapshot()
        }
    )
    let controller = await coordinator.showSettings()
    try await waitForSettingsCondition { await probe.callCount == 1 }

    await coordinator.refreshConnectionDiagnostics()
    for _ in 0..<20 {
        await Task.yield()
    }
    let callCountBeforeCleanup = await probe.callCount
    try expect(callCountBeforeCleanup == 1, "Expected cleanup before the next probe")

    await probe.finishFirstCall()
    try await waitForSettingsCondition { await probe.callCount == 2 }
    controller.close()
}

@MainActor
private func settingsWindowExecutableSelectionSeamScenario() async throws {
    _ = NSApplication.shared
    let store = try SettingsUITestStore()
    defer { store.cleanUp() }
    let repository = try store.repository()
    let selectedURL = URL(fileURLWithPath: "/Synthetic/Menu/codex")
    let coordinator = SettingsWindowCoordinator(
        repository: repository,
        discoveredQuotaProvider: { [] },
        executableSelector: SettingsExecutableSelectorStub(selectedURL: selectedURL)
    )

    coordinator.requestExecutableSelection()
    try await waitForSettingsCondition {
        await repository.load().selectedExecutableURL == selectedURL
    }
    try expect(coordinator.activeWindowController != nil, "Expected settings window opened")
    coordinator.requestExecutableSelection()
    let saved = await repository.load()
    try expect(
        saved.selectedExecutableURL == selectedURL,
        "Expected idempotent selection request"
    )
    coordinator.activeWindowController?.close()
}

@MainActor
private func settingsWindowPendingDiagnosticsReleaseScenario() async throws {
    _ = NSApplication.shared
    let store = try SettingsUITestStore()
    defer { store.cleanUp() }
    let gate = SettingsDiagnosticsGate()
    let coordinator = SettingsWindowCoordinator(
        repository: try store.repository(),
        discoveredQuotaProvider: { [] },
        connectionDiagnosticsProvider: { _, _ in
            await gate.wait()
        }
    )
    var controller: SettingsWindowController? = await coordinator.showSettings()
    weak let weakController = controller
    weak let weakViewController = controller?.settingsViewController
    weak let weakView = controller?.settingsViewController.view

    controller?.close()
    controller = nil
    await Task.yield()

    try expect(weakController == nil, "Expected pending task not to retain controller")
    try expect(weakViewController == nil, "Expected pending task not to retain view controller")
    try expect(weakView == nil, "Expected pending task not to retain views")
    await gate.resume()
}

@MainActor
private func waitForSettingsCondition(
    _ condition: @escaping @MainActor () async -> Bool
) async throws {
    for _ in 0..<200 {
        if await condition() {
            return
        }
        await Task.yield()
    }
    throw TestFailure(description: "Timed out waiting for settings condition")
}

private actor SettingsDiagnosticsProviderStub {
    private let version: CodexCLIVersion

    init() throws {
        version = try CodexCLIVersionParser().parse(Data("codex-cli 1.2.3\n".utf8))
    }

    func snapshot(
        selectedURL: URL?,
        status: CodexConnectionStatus
    ) -> ConnectionDiagnosticsSnapshot {
        let source: CodexExecutableSource = selectedURL == nil ? .automatic : .userSelected
        return ConnectionDiagnosticsSnapshot(
            path: CodexPathSummary(
                source: source,
                category: selectedURL == nil ? .applicationBundle : .other,
                basename: "codex"
            ),
            cliVersion: version,
            cliVersionIssue: nil,
            connectionStatus: status
        )
    }
}

@MainActor
private final class SettingsExecutableSelectorStub: CodexExecutableSelecting {
    private let selectedURL: URL?

    init(selectedURL: URL?) {
        self.selectedURL = selectedURL
    }

    func selectExecutable(attachedTo window: NSWindow?) async -> URL? {
        _ = window
        return selectedURL
    }
}

@MainActor
private final class SettingsDiagnosticClipboardStub: DiagnosticClipboardWriting {
    private(set) var lastText: String?

    func writeDiagnosticText(_ text: String) {
        lastText = text
    }
}

private actor SettingsDiagnosticsGate {
    private var continuation: CheckedContinuation<ConnectionDiagnosticsSnapshot, Never>?

    func wait() async -> ConnectionDiagnosticsSnapshot {
        await withCheckedContinuation { continuation in
            self.continuation = continuation
        }
    }

    func resume() {
        continuation?.resume(returning: .checking)
        continuation = nil
    }
}

private actor SerializedSettingsDiagnosticsProbe {
    private(set) var callCount = 0
    private var firstCallContinuation: CheckedContinuation<Void, Never>?

    func snapshot() async -> ConnectionDiagnosticsSnapshot {
        callCount += 1
        guard callCount == 1 else {
            return .checking
        }
        await withCheckedContinuation { continuation in
            firstCallContinuation = continuation
        }
        return .checking
    }

    func finishFirstCall() {
        firstCallContinuation?.resume()
        firstCallContinuation = nil
    }
}

private actor SettingsSelectionSaveGate {
    private(set) var hasStarted = false
    private(set) var savedURL: URL?
    private var continuation: CheckedContinuation<Void, Never>?

    func save(_ url: URL) async throws {
        savedURL = url
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

private actor SettingsSelectionRecorder {
    private(set) var savedURLs = [URL]()

    func save(_ url: URL) {
        savedURLs.append(url)
    }
}

@MainActor
private final class OverlappingSettingsExecutableSelectorStub: CodexExecutableSelecting {
    private(set) var callCount = 0
    private var continuations = [Int: CheckedContinuation<URL?, Never>]()

    func selectExecutable(attachedTo window: NSWindow?) async -> URL? {
        _ = window
        callCount += 1
        let call = callCount
        return await withCheckedContinuation { continuation in
            continuations[call] = continuation
        }
    }

    func finish(call: Int, url: URL?) {
        continuations.removeValue(forKey: call)?.resume(returning: url)
    }
}
