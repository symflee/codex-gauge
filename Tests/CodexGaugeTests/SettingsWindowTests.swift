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
        settingsWindowCreationFailureSkipsActivationTest(),
        settingsWindowLateCancellationSkipsActivationTest(),
        settingsWindowPersistsEditsTest(),
        settingsWindowGaugeAppearanceControlsTest(),
        settingsWindowRelocalizesInPlaceTest(),
        settingsWindowExternalLanguageUpdateDoesNotSaveTest(),
        settingsExecutableSelectorForwardsPromptTest(),
        settingsWindowUsesCurrentLanguageForExecutablePromptTest(),
        settingsWindowRecreationReloadsPreferencesTest(),
        settingsWindowReleasesUIObjectsTest(),
        settingsWindowConnectionSectionTest(),
        settingsWindowKeepsLatestConnectionStatusTest(),
        settingsWindowProjectNoticeTest(),
        settingsWindowConnectionActionsTest(),
        settingsWindowExecutableSelectionSeamTest(),
        settingsWindowPanelCancellationTest(),
        settingsWindowCommittedSelectionCallbackTest(),
        settingsWindowCommittedSelectionUpdatesReopenedWindowTest(),
        settingsWindowSelectionIdentityTest(),
        settingsWindowDiscoveryUpdateTest(),
        settingsWindowSerializesDiagnosticsTest(),
        settingsWindowPendingDiagnosticsReleaseTest(),
        settingsWindowShutdownDrainsPendingWorkTest(),
        settingsWindowRejectsTerminalShowTest(),
        settingsWindowShutdownClosesLateWindowTest(),
        settingsWindowShutdownFinishesCommittedSelectionTest(),
        settingsDurationAccessibilityLocalizationTest(),
        settingsGaugeLocalizationParityTest()
    ]
}

private func settingsWindowRelocalizesInPlaceTest() -> TestCase {
    TestCase(name: "settings changes every owned string in place and persists language") {
        try await settingsWindowRelocalizesInPlaceScenario()
    }
}

@MainActor
private func settingsWindowRelocalizesInPlaceScenario() async throws {
    _ = NSApplication.shared
    let store = try SettingsUITestStore()
    defer { store.cleanUp() }
    let repository = try store.repository(defaultLanguage: .korean)
    let quota = QuotaSelectionID(product: .codex, rawDurationMinutes: 300)
    let preferences = AppPreferences(
        displayPreference: DisplayPreference(
            productMode: .both,
            quotaSelection: .manual([quota])
        ),
        language: .korean,
        statusGaugeAppearance: .preset(.green)
    )
    try await repository.save(preferences)
    var runtimeValues = [SettingsFormValues]()
    let coordinator = SettingsWindowCoordinator(
        repository: repository,
        discoveredQuotaProvider: { [quota] },
        connectionDiagnosticsProvider: { _, _ in
            ConnectionDiagnosticsSnapshot(
                executableSource: .automatic,
                path: nil,
                cliVersion: nil,
                cliVersionIssue: nil,
                connectionStatus: .connected
            )
        },
        connectionStatusProvider: { .checking },
        onSettingsFormValuesChanged: { runtimeValues.append($0) }
    )
    let controller = try await showSettingsController(coordinator)
    let viewController = controller.settingsViewController
    try await waitForSettingsCondition {
        viewController.connectionDiagnostics.connectionStatus == .connected
    }
    let diagnosticsBeforeChange = viewController.connectionDiagnostics

    try expect(controller.window?.title == "Codex Gauge 설정", "Expected Korean title")
    try expect(
        viewController.renderedSectionTitles == [
            "언어", "표시 대상", "게이지 색상", "표시할 한도", "갱신 주기", "Codex 연결"
        ],
        "Expected every Korean section title"
    )
    try expect(
        viewController.renderedLanguageOptionTitles == ["한국어", "English"],
        "Expected recognizable language autonyms"
    )
    try expect(
        viewController.renderedProductOptionTitles.last == "Codex와 Spark",
        "Expected Korean product option"
    )
    try expect(
        viewController.renderedSelectionOptionTitles == ["자동 선택", "직접 선택"],
        "Expected Korean selection options"
    )
    try expect(
        viewController.renderedGaugePresetOptionTitles == [
            "선명한 파랑 — 기본", "그라파이트", "선명한 초록",
            "선명한 주황", "선명한 보라", "사용자 지정"
        ],
        "Expected Korean gauge preset names"
    )
    try expect(
        viewController.renderedGaugeColorLabels == ["테두리 색상", "채우기 색상"],
        "Expected Korean gauge color labels"
    )
    try expect(
        viewController.renderedRefreshOptionTitles == ["수동", "절전", "균형", "빠름"],
        "Expected Korean refresh options"
    )
    try expect(
        viewController.renderedLaunchAtLoginTitle == "로그인 시 실행",
        "Expected Korean launch title"
    )

    viewController.apply(.languageChanged(.english))
    await coordinator.flushPendingSave()

    try expect(coordinator.activeWindowController === controller, "Expected same window controller")
    try expect(controller.settingsViewController === viewController, "Expected same view controller")
    try expect(controller.window?.title == "Codex Gauge Settings", "Expected English title")
    try expect(viewController.formState.language == .english, "Expected English form state")
    try expect(
        viewController.renderedSectionTitles == [
            "Language", "Display", "Gauge colors", "Quotas to display",
            "Refresh profile", "Codex connection"
        ],
        "Expected every English section title"
    )
    try expect(
        viewController.renderedLanguageOptionTitles == ["한국어", "English"],
        "Expected stable language autonyms"
    )
    try expect(
        viewController.renderedProductOptionTitles.last == "Codex and Spark",
        "Expected English product option"
    )
    try expect(
        viewController.renderedSelectionOptionTitles == ["Automatic", "Manual"],
        "Expected English selection options"
    )
    try expect(
        viewController.renderedGaugePresetOptionTitles == [
            "Vivid Blue — Default", "Graphite", "Vivid Green",
            "Vivid Orange", "Vivid Purple", "Custom"
        ],
        "Expected English gauge preset names"
    )
    try expect(
        viewController.renderedGaugeColorLabels == ["Border color", "Fill color"],
        "Expected English gauge color labels"
    )
    try expect(
        viewController.formState.statusGaugeAppearance == .preset(.green),
        "Expected language change to preserve gauge appearance"
    )
    try expect(
        viewController.renderedRefreshOptionTitles == ["Manual", "Eco", "Balanced", "Fast"],
        "Expected English refresh options"
    )
    try expect(
        viewController.renderedLaunchAtLoginTitle == "Launch at login",
        "Expected English launch title"
    )
    try expect(
        viewController.renderedConnectionActionTitles == ["Select Codex…", "Copy Diagnostics"],
        "Expected English connection actions"
    )
    try expect(
        viewController.renderedConnectionDetailTexts.contains { $0.hasPrefix("Connection:") },
        "Expected English connection details"
    )
    try expect(
        viewController.renderedProjectNoticeText.contains("unofficial community project"),
        "Expected English project notice"
    )
    try expect(
        viewController.renderedQuotaAccessibilityLabels == ["Codex 5 hours quota"],
        "Expected English quota accessibility"
    )
    try expect(
        viewController.connectionDiagnostics == diagnosticsBeforeChange,
        "Expected diagnostics state preserved"
    )
    try expect(runtimeValues.last?.language == .english, "Expected runtime language callback")
    let savedPreferences = await repository.load()
    try expect(savedPreferences.language == .english, "Expected saved language")
    controller.close()
}

private func settingsWindowExternalLanguageUpdateDoesNotSaveTest() -> TestCase {
    TestCase(name: "external settings language update relocalizes without save callbacks") {
        try await settingsWindowExternalLanguageUpdateDoesNotSaveScenario()
    }
}

@MainActor
private func settingsWindowExternalLanguageUpdateDoesNotSaveScenario() async throws {
    _ = NSApplication.shared
    let store = try SettingsUITestStore()
    defer { store.cleanUp() }
    let repository = try store.repository(defaultLanguage: .korean)
    try await repository.save(AppPreferences(language: .korean))
    var runtimeChangeCount = 0
    let coordinator = SettingsWindowCoordinator(
        repository: repository,
        discoveredQuotaProvider: { [] },
        onSettingsFormValuesChanged: { _ in runtimeChangeCount += 1 }
    )
    let controller = try await showSettingsController(coordinator)
    let viewController = controller.settingsViewController

    coordinator.updateLanguage(.english)

    try expect(coordinator.activeWindowController === controller, "Expected same controller")
    try expect(controller.settingsViewController === viewController, "Expected same view")
    try expect(controller.window?.title == "Codex Gauge Settings", "Expected live title")
    try expect(viewController.formState.language == .english, "Expected live form language")
    try expect(runtimeChangeCount == 0, "Expected no user-change callback")
    let savedPreferences = await repository.load()
    try expect(savedPreferences.language == .korean, "Expected no implicit save")
    controller.close()
}

private func settingsExecutableSelectorForwardsPromptTest() -> TestCase {
    TestCase(name: "executable selector gives each panel the requested localized prompt") {
        try await settingsExecutableSelectorForwardsPromptScenario()
    }
}

@MainActor
private func settingsExecutableSelectorForwardsPromptScenario() async throws {
    _ = NSApplication.shared
    let panel = SettingsExecutablePanelStub(selectedURL: nil)
    var prompts = [String]()
    let selector = NSOpenPanelCodexExecutableSelector(
        panelFactory: { prompt in
            prompts.append(prompt)
            return panel
        }
    )
    let selection = Task { @MainActor in
        await selector.selectExecutable(attachedTo: nil, prompt: "Codex 선택…")
    }
    try await waitForSettingsCondition { panel.presentCount == 1 }

    try expect(prompts == ["Codex 선택…"], "Expected localized panel prompt")
    panel.respond(.cancel)
    _ = await selection.value
}

private func settingsWindowUsesCurrentLanguageForExecutablePromptTest() -> TestCase {
    TestCase(name: "settings gives executable selection the current language prompt") {
        try await settingsWindowUsesCurrentLanguageForExecutablePromptScenario()
    }
}

@MainActor
private func settingsWindowUsesCurrentLanguageForExecutablePromptScenario() async throws {
    _ = NSApplication.shared
    let store = try SettingsUITestStore()
    defer { store.cleanUp() }
    let repository = try store.repository(defaultLanguage: .korean)
    try await repository.save(AppPreferences(language: .korean))
    let selector = SettingsPromptRecordingExecutableSelectorStub()
    let coordinator = SettingsWindowCoordinator(
        repository: repository,
        discoveredQuotaProvider: { [] },
        executableSelector: selector
    )
    _ = try await showSettingsController(coordinator)

    coordinator.updateLanguage(.english)
    coordinator.requestExecutableSelection()
    try await waitForSettingsCondition { selector.prompts.count == 1 }

    try expect(selector.prompts == ["Select Codex…"], "Expected current English prompt")
    await coordinator.shutdown()
}

private func settingsWindowLateCancellationSkipsActivationTest() -> TestCase {
    TestCase(name: "cancelled settings creation does not activate the application") {
        try await settingsWindowLateCancellationSkipsActivationScenario()
    }
}

@MainActor
private func settingsWindowLateCancellationSkipsActivationScenario() async throws {
    _ = NSApplication.shared
    let store = try SettingsUITestStore()
    defer { store.cleanUp() }
    let activation = SettingsWindowCoordinatorActivationSpy()
    let showTaskCancellation = SettingsShowTaskCancellation()
    let coordinator = SettingsWindowCoordinator(
        repository: try store.repository(),
        discoveredQuotaProvider: { [] },
        foregroundPresenter: SettingsWindowForegroundPresenter(
            applicationActivator: activation
        ),
        onSettingsWindowCreated: { _ in
            showTaskCancellation.cancel()
        }
    )
    let showResult = SettingsWindowResult()
    let showTask = Task { @MainActor in
        showResult.controller = await coordinator.showSettings()
    }
    showTaskCancellation.install(showTask)

    await showTask.value
    await Task.yield()

    try expect(showResult.controller == nil, "Expected cancelled late show rejection")
    try expect(coordinator.activeWindowController == nil, "Expected cancelled graph released")
    try expect(
        activation.ignoringOtherAppsValues.isEmpty,
        "Expected no activation after cancellation during creation"
    )
}

private func settingsWindowCreationFailureSkipsActivationTest() -> TestCase {
    TestCase(name: "settings creation failure does not activate the application") {
        try await settingsWindowCreationFailureSkipsActivationScenario()
    }
}

@MainActor
private func settingsWindowCreationFailureSkipsActivationScenario() async throws {
    _ = NSApplication.shared
    let store = try SettingsUITestStore()
    defer { store.cleanUp() }
    let activation = SettingsWindowCoordinatorActivationSpy()
    weak var weakController: SettingsWindowController?
    let coordinator = SettingsWindowCoordinator(
        repository: try store.repository(),
        discoveredQuotaProvider: { [] },
        foregroundPresenter: SettingsWindowForegroundPresenter(
            applicationActivator: activation
        ),
        onSettingsWindowCreated: { controller in
            weakController = controller
            controller.window = nil
        }
    )

    let result = await coordinator.showSettings()
    await Task.yield()

    try expect(result == nil, "Expected a missing settings window to fail")
    try expect(coordinator.activeWindowController == nil, "Expected failed graph released")
    try expect(weakController == nil, "Expected failed controller deallocation")
    try expect(
        activation.ignoringOtherAppsValues.isEmpty,
        "Expected no activation when window creation did not produce a window"
    )
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
    let controller = try await showSettingsController(coordinator)
    guard let window = controller.window else {
        throw TestFailure(description: "Expected settings window")
    }

    try expect(coordinator.activeWindowController === controller, "Expected owner retention")
    try expect(window.styleMask.contains(.titled), "Expected titled window")
    try expect(window.styleMask.contains(.closable), "Expected closable window")
    try expect(window.styleMask != .borderless, "Expected standard window chrome")
    try expect(abs(window.contentLayoutRect.width - 440) < 1, "Expected 440pt content width")
    try expect(controller.settingsViewController.isViewLoaded, "Expected programmatic view")
    let outerScrollViews = controller.settingsViewController.view.subviews.compactMap {
        $0 as? NSScrollView
    }
    try expect(outerScrollViews.count == 1, "Expected one outer form scroll view")
    try expect(
        outerScrollViews.first?.borderType == .noBorder,
        "Expected borderless outer form scrolling"
    )
    try expect(
        outerScrollViews.first?.hasVerticalScroller == true,
        "Expected vertical form scrolling"
    )
    window.contentView?.layoutSubtreeIfNeeded()
    let formHeight = outerScrollViews.first?.documentView?.frame.height ?? 0
    let viewportHeight = outerScrollViews.first?.contentView.bounds.height ?? 0
    try expect(formHeight > viewportHeight, "Expected form content to require scrolling")
    try expect(!window.title.hasPrefix("settings."), "Expected localized window title")
    let repeatedController = try await showSettingsController(coordinator)
    try expect(repeatedController === controller, "Expected one settings window")

    controller.close()
}

private func settingsWindowPersistsEditsTest() -> TestCase {
    TestCase(name: "settings persists form edits and preserves hidden fields") {
        try await settingsWindowPersistenceScenario()
    }
}

private func settingsWindowGaugeAppearanceControlsTest() -> TestCase {
    TestCase(name: "settings renders and persists preset and custom gauge colors") {
        try await settingsWindowGaugeAppearanceControlsScenario()
    }
}

@MainActor
private func settingsWindowGaugeAppearanceControlsScenario() async throws {
    _ = NSApplication.shared
    let store = try SettingsUITestStore()
    defer { store.cleanUp() }
    let repository = try store.repository(defaultLanguage: .korean)
    try await repository.save(
        AppPreferences(
            language: .korean,
            statusGaugeAppearance: .preset(.blue)
        )
    )
    var runtimeValues = [SettingsFormValues]()
    let coordinator = SettingsWindowCoordinator(
        repository: repository,
        discoveredQuotaProvider: { [] },
        onSettingsFormValuesChanged: { runtimeValues.append($0) }
    )
    let controller = try await showSettingsController(coordinator)
    let viewController = controller.settingsViewController

    try verifyInitialGaugeControls(viewController)
    viewController.apply(.statusGaugePresetChanged(.purple))
    try expect(runtimeValues.count == 1, "Expected one atomic preset callback")
    try expect(
        runtimeValues.last?.statusGaugeAppearance == .preset(.purple),
        "Expected complete preset colors in one form value"
    )
    viewController.apply(.statusGaugeCustomSelected)
    try expect(
        viewController.formState.statusGaugeAppearance == .custom(
            borderColor: StatusGaugePreset.purple.borderColor,
            fillColor: StatusGaugePreset.purple.fillColor
        ),
        "Expected custom mode to copy the effective preset colors"
    )

    viewController.performGaugeBorderColorSelection(
        testGaugeColor(red: 0x12, green: 0x34, blue: 0x56, alpha: 0.25)
    )
    try expect(
        viewController.renderedGaugeColorHexValues == ["#123456", "#BF5AF2"],
        "Expected opaque 8-bit sRGB border and preserved fill"
    )
    viewController.performGaugeFillColorSelection(
        testGaugeColor(red: 0xAB, green: 0xCD, blue: 0xEF, alpha: 0)
    )
    try expect(
        viewController.renderedGaugeColorHexValues == ["#123456", "#ABCDEF"],
        "Expected opaque 8-bit sRGB fill and preserved border"
    )
    try expect(
        viewController.renderedGaugeColorAccessibilityValues == ["#123456", "#ABCDEF"],
        "Expected accessibility values to follow the current custom colors"
    )
    let callbackCount = runtimeValues.count
    viewController.performGaugeBorderColorSelection(
        NSColor(patternImage: NSImage(size: NSSize(width: 1, height: 1)))
    )
    try expect(
        viewController.renderedGaugeColorHexValues == ["#123456", "#ABCDEF"],
        "Expected an unconvertible color selection to be ignored"
    )
    try expect(
        runtimeValues.count == callbackCount,
        "Expected no form callback for an unconvertible color"
    )
    await coordinator.flushPendingSave()

    let saved = await repository.load()
    try expect(
        saved.statusGaugeAppearance == .custom(
            borderColor: StatusGaugeColor(red: 0x12, green: 0x34, blue: 0x56),
            fillColor: StatusGaugeColor(red: 0xAB, green: 0xCD, blue: 0xEF)
        ),
        "Expected normalized custom colors persisted"
    )
    controller.close()
}

@MainActor
private func verifyInitialGaugeControls(
    _ viewController: SettingsFormViewController
) throws {
    try expect(
        viewController.renderedGaugePresetOptionTitles == [
            "선명한 파랑 — 기본", "그라파이트", "선명한 초록",
            "선명한 주황", "선명한 보라", "사용자 지정"
        ],
        "Expected five ordered presets and custom"
    )
    try expect(
        viewController.renderedGaugePresetSeparatorCount == 1,
        "Expected one separator before custom"
    )
    try expect(
        viewController.renderedGaugePresetSwatchCount == 6,
        "Expected programmatic two-color swatches"
    )
    try expect(
        viewController.renderedGaugeColorHexValues == ["#004C99", "#0A84FF"],
        "Expected default blue colors"
    )
    try expect(
        viewController.renderedGaugeColorAccessibilityValues == ["#004C99", "#0A84FF"],
        "Expected current hex values for assistive technologies"
    )
    try expect(
        viewController.usesExpandedNonContinuousGaugeColorWells,
        "Expected expanded color wells with end-only updates"
    )
}

private func testGaugeColor(
    red: UInt8,
    green: UInt8,
    blue: UInt8,
    alpha: CGFloat
) -> NSColor {
    NSColor(
        srgbRed: CGFloat(red) / 255,
        green: CGFloat(green) / 255,
        blue: CGFloat(blue) / 255,
        alpha: alpha
    )
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
    let controller = try await showSettingsController(coordinator)
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
        launchAtLoginIntent: true,
        statusGaugeAppearance: .preset(.orange)
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
    try expect(
        state.statusGaugeAppearance == .preset(.orange),
        "Expected reloaded gauge appearance"
    )

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

    func repository(
        defaultLanguage: AppLanguage = .english
    ) throws -> AppPreferencesRepository {
        guard let repositoryDefaults = UserDefaults(suiteName: suiteName) else {
            throw TestFailure(description: "Unable to inject settings UI defaults")
        }
        return AppPreferencesRepository(
            userDefaults: repositoryDefaults,
            defaultLanguage: defaultLanguage
        )
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

private func settingsGaugeLocalizationParityTest() -> TestCase {
    TestCase(name: "gauge settings keep Korean and English localization keys in parity") {
        let korean = try gaugeSettingsLocalizationKeys(language: "ko")
        let english = try gaugeSettingsLocalizationKeys(language: "en")
        let required = Set([
            "settings.section.gauge-colors",
            "settings.gauge.preset.accessibility",
            "settings.gauge.preset.blue",
            "settings.gauge.preset.graphite",
            "settings.gauge.preset.green",
            "settings.gauge.preset.orange",
            "settings.gauge.preset.purple",
            "settings.gauge.preset.custom",
            "settings.gauge.border",
            "settings.gauge.fill"
        ])

        try expect(korean == english, "Expected complete localization key parity")
        try expect(required.isSubset(of: korean), "Expected gauge localization keys")
    }
}

private func gaugeSettingsLocalizationKeys(language: String) throws -> Set<String> {
    let root = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
    let file = root
        .appendingPathComponent("Sources/CodexGaugeAppKit/Resources")
        .appendingPathComponent("\(language).lproj/Localizable.strings")
    let contents = try String(contentsOf: file, encoding: .utf8)
    return Set(contents.split(separator: "\n").compactMap(gaugeLocalizationKey))
}

private func gaugeLocalizationKey(_ line: Substring) -> String? {
    guard line.first == "\"" else {
        return nil
    }
    let parts = line.split(
        separator: "\"",
        maxSplits: 2,
        omittingEmptySubsequences: false
    )
    guard parts.count > 1 else {
        return nil
    }
    return String(parts[1])
}

private func settingsWindowConnectionSectionTest() -> TestCase {
    TestCase(name: "settings renders sanitized connection diagnostics") {
        try await settingsWindowConnectionSectionScenario()
    }
}

private func settingsWindowKeepsLatestConnectionStatusTest() -> TestCase {
    TestCase(name: "settings keeps live status during an in-flight CLI probe") {
        try await settingsWindowKeepsLatestConnectionStatusScenario()
    }
}

@MainActor
private func settingsWindowKeepsLatestConnectionStatusScenario() async throws {
    _ = NSApplication.shared
    let store = try SettingsUITestStore()
    defer { store.cleanUp() }
    let gate = try StaleStatusSettingsDiagnosticsGate()
    let clipboard = SettingsDiagnosticClipboardStub()
    let coordinator = SettingsWindowCoordinator(
        repository: try store.repository(),
        discoveredQuotaProvider: { [] },
        connectionDiagnosticsProvider: { selectedURL, status in
            await gate.snapshot(selectedURL: selectedURL, capturedStatus: status)
        },
        connectionStatusProvider: { .signedOut },
        clipboardWriter: clipboard,
        diagnosticEnvironment: DiagnosticEnvironment(
            appVersion: "0.1.0",
            macOSVersion: "15.4.1",
            architecture: .arm64
        )
    )
    let controller = try await showSettingsController(coordinator)
    let viewController = controller.settingsViewController
    viewController.performConnectionAction(.copyDiagnostics)

    try expect(
        clipboard.lastText?.contains("connection-status: signed-out") == true,
        "Expected initial screen and copied snapshot to share the status"
    )
    try await waitForSettingsCondition { await gate.hasStarted }

    coordinator.updateConnectionStatus(.connected)
    viewController.performConnectionAction(.copyDiagnostics)

    try expect(
        viewController.connectionDiagnostics.connectionStatus == .connected,
        "Expected an immediate live status update"
    )
    try expect(
        clipboard.lastText?.contains("connection-status: connected") == true,
        "Expected copied diagnostics to use the live status"
    )

    await gate.finish()
    try await waitForSettingsCondition {
        viewController.connectionDiagnostics.cliVersion?.value == "2.3.4"
    }
    try expect(
        viewController.connectionDiagnostics.connectionStatus == .connected,
        "Expected stale probe status not to replace the live status"
    )
    controller.close()
}

private func settingsWindowProjectNoticeTest() -> TestCase {
    TestCase(name: "settings shows a localized unofficial project notice") {
        try await settingsWindowProjectNoticeScenario()
    }
}

@MainActor
private func settingsWindowProjectNoticeScenario() async throws {
    _ = NSApplication.shared
    let store = try SettingsUITestStore()
    defer { store.cleanUp() }
    let coordinator = SettingsWindowCoordinator(
        repository: try store.repository(),
        discoveredQuotaProvider: { [] }
    )

    let controller = try await showSettingsController(coordinator)
    let notice = controller.settingsViewController.renderedProjectNoticeText

    try expect(!notice.hasPrefix("settings."), "Expected localized notice text")
    try expect(notice.contains("OpenAI"), "Expected OpenAI non-affiliation notice")
    try expect(notice.contains("Codex App Server"), "Expected experimental dependency notice")
    controller.close()
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
    let controller = try await showSettingsController(coordinator)
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
    let controller = try await showSettingsController(coordinator)
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

private func settingsWindowShutdownDrainsPendingWorkTest() -> TestCase {
    TestCase(name: "settings shutdown saves forms and drains diagnostics and panels") {
        try await settingsWindowShutdownDrainsPendingWorkScenario()
    }
}

@MainActor
private func settingsWindowShutdownDrainsPendingWorkScenario() async throws {
    _ = NSApplication.shared
    let store = try SettingsUITestStore()
    defer { store.cleanUp() }
    let diagnostics = CancellationAwareSettingsDiagnosticsGate()
    let panel = SettingsExecutablePanelStub(
        selectedURL: URL(fileURLWithPath: "/Synthetic/Cancelled/codex")
    )
    let selector = NSOpenPanelCodexExecutableSelector(panelFactory: { panel })
    let completion = SettingsShutdownCompletion()
    let repository = try store.repository()
    let coordinator = SettingsWindowCoordinator(
        repository: repository,
        discoveredQuotaProvider: { [] },
        connectionDiagnosticsProvider: { _, _ in await diagnostics.snapshot() },
        executableSelector: selector
    )
    let controller = try await showSettingsController(coordinator)
    try await waitForSettingsCondition { await diagnostics.hasStarted }
    controller.settingsViewController.apply(.refreshProfileChanged(.fast))
    coordinator.requestExecutableSelection()
    try await waitForSettingsCondition { panel.presentCount == 1 }

    let shutdownTask = Task { @MainActor in
        await coordinator.shutdown()
        completion.didFinish = true
    }
    try await waitForSettingsCondition {
        await diagnostics.hasObservedCancellation && panel.dismissCount == 1
    }

    try expect(!completion.didFinish, "Expected shutdown to await diagnostics cleanup")
    await diagnostics.finishCleanup()
    await shutdownTask.value

    try expect(completion.didFinish, "Expected shutdown completion")
    try expect(coordinator.activeWindowController == nil, "Expected shutdown window release")
    try expect(panel.dismissCount == 1, "Expected pending panel cancelled once")
    let saved = await repository.load()
    try expect(saved.refreshProfile == .fast, "Expected pending form save preserved")
}

private func settingsWindowShutdownFinishesCommittedSelectionTest() -> TestCase {
    TestCase(name: "settings shutdown finishes a committed executable selection") {
        try await settingsWindowShutdownFinishesCommittedSelectionScenario()
    }
}

private func settingsWindowRejectsTerminalShowTest() -> TestCase {
    TestCase(name: "settings rejects pending and later shows after shutdown begins") {
        try await settingsWindowRejectsTerminalShowScenario()
    }
}

@MainActor
private func settingsWindowRejectsTerminalShowScenario() async throws {
    _ = NSApplication.shared
    let store = try SettingsUITestStore()
    defer { store.cleanUp() }
    let formSaveGate = SettingsFormSaveGate()
    let completion = SettingsShutdownCompletion()
    let pendingShowResult = SettingsWindowResult()
    let activation = SettingsWindowCoordinatorActivationSpy()
    var windowCreationCount = 0
    let coordinator = SettingsWindowCoordinator(
        repository: try store.repository(),
        discoveredQuotaProvider: { [] },
        foregroundPresenter: SettingsWindowForegroundPresenter(
            applicationActivator: activation
        ),
        settingsFormValuesSaver: { values in await formSaveGate.save(values) },
        onSettingsWindowCreated: { _ in windowCreationCount += 1 }
    )
    var controller: SettingsWindowController? = await coordinator.showSettings()
    controller?.settingsViewController.apply(.refreshProfileChanged(.fast))
    try await waitForSettingsCondition { await formSaveGate.hasStarted }
    controller?.close()
    controller = nil

    let pendingShow = Task { @MainActor in
        pendingShowResult.controller = await coordinator.showSettings()
    }
    for _ in 0..<20 {
        await Task.yield()
    }
    let shutdownTask = Task { @MainActor in
        await coordinator.shutdown()
        completion.didFinish = true
    }
    for _ in 0..<20 {
        await Task.yield()
    }
    try expect(!completion.didFinish, "Expected shutdown to wait for the form save")

    await formSaveGate.finish()
    await pendingShow.value
    await shutdownTask.value
    let terminalResult: SettingsWindowController? = await coordinator.showSettings()

    try expect(pendingShowResult.controller == nil, "Expected pending show rejected after shutdown")
    try expect(terminalResult == nil, "Expected terminal show rejected")
    try expect(coordinator.activeWindowController == nil, "Expected no terminal window")
    try expect(windowCreationCount == 1, "Expected no window created after shutdown began")
    try expect(
        activation.ignoringOtherAppsValues.isEmpty,
        "Expected headless pending and terminal shows not to activate"
    )
}

private func settingsWindowShutdownClosesLateWindowTest() -> TestCase {
    TestCase(name: "settings shutdown closes a window created after a gated save") {
        try await settingsWindowShutdownClosesLateWindowScenario()
    }
}

@MainActor
private func settingsWindowShutdownClosesLateWindowScenario() async throws {
    _ = NSApplication.shared
    let store = try SettingsUITestStore()
    defer { store.cleanUp() }
    let formSaveGate = SettingsFormSaveGate()
    let selector = SettingsExecutableSelectorStub(selectedURL: nil)
    weak var weakLatestController: SettingsWindowController?
    let coordinator = SettingsWindowCoordinator(
        repository: try store.repository(),
        discoveredQuotaProvider: { [] },
        settingsFormValuesSaver: { values in await formSaveGate.save(values) },
        executableSelector: selector,
        onSettingsWindowCreated: { weakLatestController = $0 }
    )
    var controller: SettingsWindowController? = await coordinator.showSettings()
    controller?.settingsViewController.apply(.refreshProfileChanged(.fast))
    try await waitForSettingsCondition { await formSaveGate.hasStarted }
    controller?.close()
    controller = nil
    await Task.yield()

    coordinator.requestExecutableSelection()
    for _ in 0..<20 {
        await Task.yield()
    }
    let shutdownTask = Task { @MainActor in
        await coordinator.shutdown()
    }
    for _ in 0..<20 {
        await Task.yield()
    }
    await formSaveGate.finish()
    await shutdownTask.value
    await Task.yield()

    try expect(coordinator.activeWindowController == nil, "Expected no late active window")
    try expect(weakLatestController == nil, "Expected the late window graph released")
    try expect(selector.callCount == 0, "Expected no panel after shutdown")
}

@MainActor
private func settingsWindowShutdownFinishesCommittedSelectionScenario() async throws {
    _ = NSApplication.shared
    let store = try SettingsUITestStore()
    defer { store.cleanUp() }
    let selectedURL = URL(fileURLWithPath: "/Synthetic/Shutdown/codex")
    let saveGate = SettingsSelectionSaveGate()
    let completion = SettingsShutdownCompletion()
    var callbackURL: URL?
    let coordinator = SettingsWindowCoordinator(
        repository: try store.repository(),
        discoveredQuotaProvider: { [] },
        executableSelector: SettingsExecutableSelectorStub(selectedURL: selectedURL),
        executableSelectionSaver: { url in try await saveGate.save(url) },
        onExecutableSelectionChanged: { callbackURL = $0 }
    )
    coordinator.requestExecutableSelection()
    try await waitForSettingsCondition { await saveGate.hasStarted }

    let shutdownTask = Task { @MainActor in
        await coordinator.shutdown()
        completion.didFinish = true
    }
    for _ in 0..<20 {
        await Task.yield()
    }
    try expect(!completion.didFinish, "Expected committed save to drain before shutdown")
    try expect(callbackURL == nil, "Expected runtime callback after the save")

    await saveGate.finish()
    await shutdownTask.value

    try expect(callbackURL == selectedURL, "Expected committed runtime callback")
    try expect(completion.didFinish, "Expected shutdown after committed selection")
    try expect(coordinator.activeWindowController == nil, "Expected shutdown window release")
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
    let controller = try await showSettingsController(coordinator)
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

private func settingsWindowPanelCancellationTest() -> TestCase {
    TestCase(name: "closing and reopening settings cancels each panel exactly once") {
        try await settingsWindowPanelCancellationScenario()
    }
}

@MainActor
private func settingsWindowPanelCancellationScenario() async throws {
    _ = NSApplication.shared
    let store = try SettingsUITestStore()
    defer { store.cleanUp() }
    let staleURL = URL(fileURLWithPath: "/Synthetic/Stale/codex")
    let currentURL = URL(fileURLWithPath: "/Synthetic/Current/codex")
    let firstPanel = SettingsExecutablePanelStub(selectedURL: staleURL)
    let secondPanel = SettingsExecutablePanelStub(selectedURL: currentURL)
    let panelFactory = SettingsExecutablePanelFactoryStub(
        panels: [firstPanel, secondPanel]
    )
    let selector = NSOpenPanelCodexExecutableSelector(
        panelFactory: { panelFactory.makePanel() }
    )
    var callbackURLs = [URL]()
    let coordinator = SettingsWindowCoordinator(
        repository: try store.repository(),
        discoveredQuotaProvider: { [] },
        executableSelector: selector,
        onExecutableSelectionChanged: { callbackURLs.append($0) }
    )

    coordinator.requestExecutableSelection()
    try await waitForSettingsCondition { firstPanel.presentCount == 1 }
    coordinator.activeWindowController?.close()
    try await waitForSettingsCondition { firstPanel.dismissCount == 1 }
    firstPanel.respond(.OK)

    coordinator.requestExecutableSelection()
    try await waitForSettingsCondition { secondPanel.presentCount == 1 }
    secondPanel.respond(.OK)
    try await waitForSettingsCondition { callbackURLs == [currentURL] }

    try expect(firstPanel.dismissCount == 1, "Expected one cancellation dismissal")
    try expect(panelFactory.makeCount == 2, "Expected a fresh panel after reopening")
    try expect(callbackURLs == [currentURL], "Expected no stale panel selection")
    coordinator.activeWindowController?.close()
}

private func settingsWindowCommittedSelectionCallbackTest() -> TestCase {
    TestCase(name: "committed executable selection updates runtime after window close") {
        try await settingsWindowCommittedSelectionCallbackScenario()
    }
}

private func settingsWindowCommittedSelectionUpdatesReopenedWindowTest() -> TestCase {
    TestCase(name: "committed executable selection updates a reopened settings window") {
        try await settingsWindowCommittedSelectionUpdatesReopenedWindowScenario()
    }
}

@MainActor
private func settingsWindowCommittedSelectionUpdatesReopenedWindowScenario() async throws {
    _ = NSApplication.shared
    let store = try SettingsUITestStore()
    defer { store.cleanUp() }
    let repository = try store.repository()
    let previousURL = URL(fileURLWithPath: "/Synthetic/Previous/codex")
    let selectedURL = URL(fileURLWithPath: "/Synthetic/Reopened/codex")
    try await repository.save(
        AppPreferences(selectedExecutableURL: previousURL)
    )
    let diagnostics = ReopenedSelectionDiagnosticsProbe(selectedURL: selectedURL)
    let saveGate = SettingsSelectionSaveGate()
    var callbackURL: URL?
    let coordinator = SettingsWindowCoordinator(
        repository: repository,
        discoveredQuotaProvider: { [] },
        connectionDiagnosticsProvider: { url, status in
            await diagnostics.snapshot(selectedURL: url, status: status)
        },
        connectionStatusProvider: { .connected },
        executableSelector: SettingsExecutableSelectorStub(selectedURL: selectedURL),
        executableSelectionSaver: { url in try await saveGate.save(url) },
        onExecutableSelectionChanged: { callbackURL = $0 }
    )

    var controller: SettingsWindowController? = await coordinator.showSettings()
    coordinator.requestExecutableSelection()
    try await waitForSettingsCondition { await saveGate.hasStarted }
    controller?.close()
    controller = nil

    let reopenedCandidate: SettingsWindowController? = await coordinator.showSettings()
    guard let reopenedController = reopenedCandidate else {
        throw TestFailure(description: "Expected reopened settings window")
    }
    try await waitForSettingsCondition {
        reopenedController.settingsViewController.connectionDiagnostics.path?.basename
            == "previous-codex"
    }

    await saveGate.finish()
    try await waitForSettingsCondition {
        guard callbackURL == selectedURL else {
            return false
        }
        return await diagnostics.hasStartedSelectedProbe
    }
    let checking = reopenedController.settingsViewController.connectionDiagnostics
    try expect(checking.connectionStatus == .checking, "Expected checking selected path")
    try expect(checking.path == nil, "Expected old executable details cleared")

    await diagnostics.finishSelectedProbe()
    try await waitForSettingsCondition {
        reopenedController.settingsViewController.connectionDiagnostics.path?.basename
            == "selected-codex"
    }
    let selectedURLs = await diagnostics.selectedURLs
    try expect(selectedURLs.last == selectedURL, "Expected probe for committed executable")
    reopenedController.close()
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
    let controller = try await showSettingsController(coordinator)
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
private func showSettingsController(
    _ coordinator: SettingsWindowCoordinator
) async throws -> SettingsWindowController {
    guard let controller = await coordinator.showSettings() else {
        throw TestFailure(description: "Expected settings window")
    }
    return controller
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

@MainActor
private final class SettingsWindowCoordinatorActivationSpy:
    SettingsWindowApplicationActivating {
    private(set) var ignoringOtherAppsValues = [Bool]()

    func activate(ignoringOtherApps: Bool) {
        ignoringOtherAppsValues.append(ignoringOtherApps)
    }
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

private actor StaleStatusSettingsDiagnosticsGate {
    private let version: CodexCLIVersion
    private(set) var hasStarted = false
    private var continuation: CheckedContinuation<Void, Never>?

    init() throws {
        version = try CodexCLIVersionParser().parse(
            Data("codex-cli 2.3.4\n".utf8)
        )
    }

    func snapshot(
        selectedURL: URL?,
        capturedStatus: CodexConnectionStatus
    ) async -> ConnectionDiagnosticsSnapshot {
        hasStarted = true
        await withCheckedContinuation { continuation in
            self.continuation = continuation
        }
        return ConnectionDiagnosticsSnapshot(
            path: CodexPathSummary(
                source: selectedURL == nil ? .automatic : .userSelected,
                category: .other,
                basename: "codex"
            ),
            cliVersion: version,
            cliVersionIssue: nil,
            connectionStatus: capturedStatus
        )
    }

    func finish() {
        continuation?.resume()
        continuation = nil
    }
}

private actor CancellationAwareSettingsDiagnosticsGate {
    private(set) var hasStarted = false
    private(set) var hasObservedCancellation = false
    private var cleanupContinuation: CheckedContinuation<Void, Never>?

    func snapshot() async -> ConnectionDiagnosticsSnapshot {
        hasStarted = true
        await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                cleanupContinuation = continuation
            }
        } onCancel: {
            Task { await self.observeCancellation() }
        }
        return .checking
    }

    func finishCleanup() {
        cleanupContinuation?.resume()
        cleanupContinuation = nil
    }

    private func observeCancellation() {
        hasObservedCancellation = true
    }
}

private actor SettingsFormSaveGate {
    private(set) var hasStarted = false
    private var continuation: CheckedContinuation<Void, Never>?

    func save(_ values: SettingsFormValues) async {
        _ = values
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

private actor ReopenedSelectionDiagnosticsProbe {
    private let selectedURL: URL
    private(set) var selectedURLs = [URL?]()
    private(set) var hasStartedSelectedProbe = false
    private var selectedContinuation: CheckedContinuation<Void, Never>?

    init(selectedURL: URL) {
        self.selectedURL = selectedURL
    }

    func snapshot(
        selectedURL: URL?,
        status: CodexConnectionStatus
    ) async -> ConnectionDiagnosticsSnapshot {
        selectedURLs.append(selectedURL)
        guard selectedURL == self.selectedURL else {
            return makeSnapshot(basename: "previous-codex", status: status)
        }
        hasStartedSelectedProbe = true
        await withCheckedContinuation { continuation in
            selectedContinuation = continuation
        }
        return makeSnapshot(basename: "selected-codex", status: status)
    }

    func finishSelectedProbe() {
        selectedContinuation?.resume()
        selectedContinuation = nil
    }

    private func makeSnapshot(
        basename: String,
        status: CodexConnectionStatus
    ) -> ConnectionDiagnosticsSnapshot {
        ConnectionDiagnosticsSnapshot(
            executableSource: .userSelected,
            path: CodexPathSummary(
                source: .userSelected,
                category: .other,
                basename: basename
            ),
            cliVersion: nil,
            cliVersionIssue: nil,
            connectionStatus: status
        )
    }
}

@MainActor
private final class SettingsExecutableSelectorStub: CodexExecutableSelecting {
    private let selectedURL: URL?
    private(set) var callCount = 0

    init(selectedURL: URL?) {
        self.selectedURL = selectedURL
    }

    func selectExecutable(attachedTo window: NSWindow?) async -> URL? {
        _ = window
        callCount += 1
        return selectedURL
    }
}

@MainActor
private final class SettingsPromptRecordingExecutableSelectorStub: CodexExecutableSelecting {
    private(set) var prompts = [String]()

    func selectExecutable(attachedTo window: NSWindow?) async -> URL? {
        _ = window
        return nil
    }

    func selectExecutable(
        attachedTo window: NSWindow?,
        prompt: String
    ) async -> URL? {
        _ = window
        prompts.append(prompt)
        return nil
    }
}

@MainActor
private final class SettingsExecutablePanelStub: CodexExecutablePanelPresenting {
    let selectedURL: URL?
    private(set) var presentCount = 0
    private(set) var dismissCount = 0
    private var completion: (@MainActor (NSApplication.ModalResponse) -> Void)?

    init(selectedURL: URL?) {
        self.selectedURL = selectedURL
    }

    func present(
        attachedTo window: NSWindow?,
        completion: @escaping @MainActor (NSApplication.ModalResponse) -> Void
    ) {
        _ = window
        presentCount += 1
        self.completion = completion
    }

    func dismiss() {
        dismissCount += 1
        completion?(.cancel)
    }

    func respond(_ response: NSApplication.ModalResponse) {
        completion?(response)
    }
}

@MainActor
private final class SettingsExecutablePanelFactoryStub {
    private var panels: [SettingsExecutablePanelStub]
    private(set) var makeCount = 0

    init(panels: [SettingsExecutablePanelStub]) {
        self.panels = panels
    }

    func makePanel() -> any CodexExecutablePanelPresenting {
        makeCount += 1
        guard let panel = panels.first else {
            return SettingsExecutablePanelStub(selectedURL: nil)
        }
        panels.removeFirst()
        return panel
    }
}

@MainActor
private final class SettingsShutdownCompletion {
    var didFinish = false
}

@MainActor
private final class SettingsWindowResult {
    var controller: SettingsWindowController?
}

@MainActor
private final class SettingsShowTaskCancellation {
    private var task: Task<Void, Never>?

    func install(_ task: Task<Void, Never>) {
        self.task = task
    }

    func cancel() {
        task?.cancel()
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
