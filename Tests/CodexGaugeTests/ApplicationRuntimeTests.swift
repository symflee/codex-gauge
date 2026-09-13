import AppKit
import CodexGaugeAppKit
import CodexGaugeCore
import CodexGaugeProtocol
import CodexGaugeRefresh
import CodexGaugeSettings
import Foundation

func applicationRuntimeTests() -> [TestCase] {
    [
        applicationDelegateStartsOneRuntimeTest(),
        applicationRuntimeStartsStatusBeforePreferencesTest(),
        applicationRuntimeStartsFirstLaunchAfterRefreshTest(),
        applicationRuntimeDefersInitialWakeBaselineTest(),
        applicationRuntimePublishesOnePresentationTransactionTest(),
        applicationRuntimePartitionsUnchangedPublicationsTest(),
        applicationRuntimeDefersNativeMenuTest(),
        applicationRuntimeCoalescesRefreshDispatchTest(),
        applicationRuntimeMergesDuringActiveDispatchTest(),
        applicationRuntimeExpiresCachedValuesTest(),
        applicationRuntimeRoutesMenuAndSettingsTest(),
        applicationRuntimeRoutesUpdatesWithoutQuotaRefreshTest(),
        applicationRuntimeRelocalizesWithoutRefreshingTest(),
        applicationRuntimeRestylesWithoutRefreshingTest(),
        applicationRuntimePublishesLaunchAtLoginStateTest(),
        applicationRuntimeReplacesRefreshGenerationTest(),
        applicationRuntimeWaitsForConfirmedRetirementTest(),
        applicationRuntimeBoundsExecutableReplacementTest(),
        applicationRuntimeReplacesBeforeFirstStartupHookTest(),
        applicationRuntimeShutdownSkipsUnconfirmedRetirementTest(),
        applicationRuntimePreservesPendingWakeAcrossReplacementTest(),
        applicationRuntimePreservesSameTurnWakeAcrossReplacementTest(),
        applicationRuntimeReplacesAcrossSystemTransitionTest(),
        applicationRuntimeOrdersOverlappingResumeTest(),
        applicationRuntimeHandlesPresentationOnlyDeadlinesTest(),
        applicationRuntimeRefreshesQuotaResetTest(),
        applicationRuntimeSharesShutdownDrainTest(),
        applicationRuntimeStopsStartThatResumesDuringShutdownTest(),
        applicationRuntimeDrainsReplacementOnShutdownTest()
    ]
}

private func applicationRuntimeDefersNativeMenuTest() -> TestCase {
    TestCase(name: "application runtime defers native menu with latest language metadata and open-time validity") {
        try await applicationRuntimeDefersNativeMenuScenario()
    }
}

@MainActor
private func applicationRuntimeDefersNativeMenuScenario() async throws {
    let presenter = RuntimeNativeMenuPresenter()
    let controller = StatusMenuController(
        presenter: presenter,
        actions: StatusMenuActions(refresh: {}, openCodex: {}, selectCodex: {},
                                   checkForUpdates: {}, settings: {}, quit: {})
    )
    let harness = RuntimeHarness(menuRuntime: StatusMenuRuntimeAdapter(controller: controller))
    harness.coordinator.start()
    await harness.coordinator.waitForPendingOperations()
    await harness.refreshBuilder.emit(try runtimePublication(usedPercent: 17), from: 0)
    await harness.refreshBuilder.emit(try runtimePublication(usedPercent: 29), from: 0)
    harness.coordinator.settingsFormValuesDidChange(SettingsFormValues(
        displayPreference: .default, refreshProfile: .balanced,
        launchAtLoginIntent: false, language: .korean,
        statusGaugeAppearance: .default
    ))
    harness.update.emit(ApplicationUpdateState(currentVersion: "9.1.0", status: .failed))
    await harness.coordinator.waitForPendingOperations()
    guard let menu = presenter.menu else { throw TestFailure(description: "Expected native menu attached") }
    try expect(menu.items.isEmpty, "Expected no native rows for closed publications or language changes")
    let refreshEvents = await harness.refreshBuilder.coordinators[0].events
    controller.menuNeedsUpdate(menu)
    let items = menu.items
    try expect(items.contains { $0.title.contains("71%") }, "Expected latest quota at first open")
    try expect(items.contains { $0.title == "새로 고침" }, "Expected latest language at first open")
    try expect(items.contains { $0.title.contains("9.1.0") }, "Expected latest updater metadata")

    // Queue a closed publication before advancing the clock. First materialization
    // must use request time even when the deadline callback has not yet run.
    await harness.refreshBuilder.emit(try runtimePublication(usedPercent: 29), from: 0)
    harness.clock.date = Date(timeIntervalSince1970: 1_900_003_600)
    controller.menuNeedsUpdate(menu)
    try expect(!menu.items.contains { $0.title.contains("71%") }, "Expected exact reset expiry at deferred materialization")
    try expect(zip(items, menu.items).allSatisfy { pair in pair.0 === pair.1 }, "Expected validity updates to preserve native row identities")
    let finalRefreshEvents = await harness.refreshBuilder.coordinators[0].events
    try expect(finalRefreshEvents == refreshEvents, "Expected menu opening without provider or refresh work")
    await harness.coordinator.shutdown()
}

private func applicationRuntimePartitionsUnchangedPublicationsTest() -> TestCase {
    TestCase(name: "application runtime routes metadata changes only to affected consumers") {
        try await applicationRuntimePartitionsUnchangedPublicationsScenario()
    }
}

@MainActor
private func applicationRuntimePartitionsUnchangedPublicationsScenario() async throws {
    let harness = RuntimeHarness()
    harness.coordinator.start()
    await harness.coordinator.waitForPendingOperations()
    let original = try runtimePublication(usedPercent: 17)
    await harness.refreshBuilder.emit(original, from: 0)
    let statusCount = harness.status.presentedFrames.count
    let menuCount = harness.menu.models.count
    let settingsCount = harness.settings.connectionStatuses.count
    let quotaCount = harness.settings.discoveredQuotaIDs.count
    let deadlineCount = harness.deadlineScheduler.productStates.count
    let refreshing = RefreshPublication(
        products: original.products,
        lastSuccessfulRefresh: original.lastSuccessfulRefresh,
        failure: nil,
        isRefreshing: true
    )
    for _ in 0..<100 {
        await harness.refreshBuilder.emit(refreshing, from: 0)
    }
    try expect(harness.status.presentedFrames.count == statusCount, "Expected no status render for refresh flags")
    try expect(harness.menu.models.count == menuCount, "Expected no menu work for refresh flags")
    try expect(harness.settings.connectionStatuses.count == settingsCount + 1, "Expected checking status delivered once")
    try expect(harness.settings.discoveredQuotaIDs.count == quotaCount, "Expected unchanged quota discovery skipped")
    try expect(harness.deadlineScheduler.productStates.count == deadlineCount, "Expected unchanged deadlines skipped")

    let later = Date(timeIntervalSince1970: 1_900_000_180)
    let products = original.products.mapValues { product in
        guard case .value(let value, let freshness) = product.usageState else { return product }
        return RefreshProductResult(
            usageState: .value(ProductQuotaValue(capturedAt: later, quotaWindows: value.quotaWindows), freshness: freshness),
            rateLimits: product.rateLimits,
            issue: product.issue,
            lastSuccessfulRefresh: later
        )
    }
    await harness.refreshBuilder.emit(RefreshPublication(
        products: products, lastSuccessfulRefresh: later, failure: nil, isRefreshing: false
    ), from: 0)
    try expect(harness.status.presentedFrames.count == statusCount, "Expected identical quota values to preserve status presentation")
    try expect(harness.menu.models.count == menuCount + 1, "Expected new last-success details")
    try expect(harness.deadlineScheduler.productStates.count == deadlineCount + 1, "Expected capture time to update validity deadlines")
    await harness.coordinator.shutdown()
}

private func applicationRuntimeCoalescesRefreshDispatchTest() -> TestCase {
    TestCase(name: "application runtime bounds queued refresh signals and keeps latest configuration") {
        try await applicationRuntimeCoalescesRefreshDispatchScenario()
    }
}

@MainActor
private func applicationRuntimeCoalescesRefreshDispatchScenario() async throws {
    let loader = RuntimePreferencesGate(preferences: .default)
    let harness = RuntimeHarness(preferencesLoader: loader)
    harness.coordinator.start()
    try await waitForRuntimeCondition { await loader.hasStarted }
    for index in 0..<100 {
        harness.coordinator.performMenuAction(.refresh)
        harness.systemMonitor.emit(.lowPowerModeChanged(isEnabled: index.isMultiple(of: 2)))
        harness.coordinator.settingsFormValuesDidChange(SettingsFormValues(
            displayPreference: .default,
            refreshProfile: index.isMultiple(of: 2) ? .eco : .fast,
            launchAtLoginIntent: false
        ))
    }
    await loader.resume()
    await harness.coordinator.waitForPendingOperations()
    let events = await harness.refreshBuilder.coordinators[0].events
    try expect(events.filter { $0 == .manualRefresh }.count == 1, "Expected one merged manual request")
    try expect(!events.contains(.profile(.eco)), "Expected intermediate profiles discarded")
    try expect(!events.contains(.lowPowerMode(true)), "Expected intermediate power states discarded")
    try expect(harness.refreshBuilder.configurations[0].preferences.refreshProfile == .fast, "Expected latest profile at startup")
    try expect(!harness.refreshBuilder.configurations[0].lowPowerModeEnabled, "Expected latest power state at startup")
    await harness.coordinator.shutdown()
}

private func applicationRuntimeMergesDuringActiveDispatchTest() -> TestCase {
    TestCase(name: "application runtime merges signals while dispatch is suspended") {
        try await applicationRuntimeMergesDuringActiveDispatchScenario()
    }
}

@MainActor
private func applicationRuntimeMergesDuringActiveDispatchScenario() async throws {
    let gate = RuntimeStopGate()
    let harness = RuntimeHarness(firstManualGate: gate)
    harness.coordinator.start()
    await harness.coordinator.waitForPendingOperations()
    harness.coordinator.performMenuAction(.refresh)
    try await waitForRuntimeCondition { await gate.hasStarted }
    for index in 0..<100 {
        harness.coordinator.performMenuAction(.refresh)
        harness.coordinator.settingsFormValuesDidChange(SettingsFormValues(
            displayPreference: .default,
            refreshProfile: index.isMultiple(of: 2) ? .eco : .fast,
            launchAtLoginIntent: false
        ))
        harness.systemMonitor.emit(.lowPowerModeChanged(isEnabled: index.isMultiple(of: 2)))
    }
    await gate.resume()
    await harness.coordinator.waitForPendingOperations()
    let events = await harness.refreshBuilder.coordinators[0].events
    try expect(events.filter { $0 == .manualRefresh }.count == 1, "Expected active manual request shared")
    try expect(events.filter { $0 == .profile(.fast) }.count == 1 && !events.contains(.profile(.eco)), "Expected only latest pending profile")
    try expect(events.filter { $0 == .lowPowerMode(false) }.count == 1 && !events.contains(.lowPowerMode(true)), "Expected only latest pending power state")
    await harness.coordinator.shutdown()
}

private func applicationRuntimeExpiresCachedValuesTest() -> TestCase {
    TestCase(name: "application presentation cache reevaluates validity without a new response") {
        try await applicationRuntimeExpiresCachedValuesScenario()
    }
}

@MainActor
private func applicationRuntimeExpiresCachedValuesScenario() async throws {
    let harness = RuntimeHarness()
    harness.coordinator.start()
    await harness.coordinator.waitForPendingOperations()
    await harness.refreshBuilder.emit(try runtimePublication(usedPercent: 17), from: 0)
    let frames = harness.status.presentedFrames.last
    let events = await harness.refreshBuilder.coordinators[0].events
    harness.clock.date = Date(timeIntervalSince1970: 1_900_003_600)
    harness.deadlineScheduler.emit(.validityExpired)
    try expect(harness.status.presentedFrames.last != frames, "Expected reset boundary to expire cached percent")
    guard case .single(let quota)? = harness.status.presentedFrames.last?.first else {
        throw TestFailure(description: "Expected single expired frame")
    }
    try expect(quota.value == .unavailable, "Expected expired value unavailable")
    harness.clock.date = Date(timeIntervalSince1970: 1_900_003_599)
    harness.deadlineScheduler.emit(.validityExpired)
    try expect(harness.status.presentedFrames.last == frames, "Expected backward clock movement to reevaluate cache")
    let after = await harness.refreshBuilder.coordinators[0].events
    try expect(after == events, "Expected validity-only reevaluation without IO")
    await harness.coordinator.shutdown()
}

private func applicationRuntimeWaitsForConfirmedRetirementTest() -> TestCase {
    TestCase(name: "application replacement awaits actual exit across queued executable changes") {
        try await applicationRuntimeWaitsForConfirmedRetirementScenario()
    }
}

@MainActor
private func applicationRuntimeWaitsForConfirmedRetirementScenario() async throws {
    let gate = RuntimeStopGate()
    let harness = RuntimeHarness(firstTerminationGate: gate)
    harness.coordinator.start()
    await harness.coordinator.waitForPendingOperations()
    harness.coordinator.selectedExecutableDidChange(URL(fileURLWithPath: "/Synthetic/first/codex"))
    try await waitForRuntimeCondition { await gate.hasStarted }
    let stopped = await harness.refreshBuilder.coordinators[0].events
    try expect(stopped.contains(.stop), "Expected stop returned before termination confirmation")
    try expect(harness.refreshBuilder.coordinators.count == 1, "Expected no replacement while child exit is unconfirmed")
    let latest = URL(fileURLWithPath: "/Synthetic/latest/codex")
    harness.coordinator.selectedExecutableDidChange(latest)
    await Task.yield()
    try expect(harness.refreshBuilder.coordinators.count == 1, "Expected queued replacement to retain retiring predecessor")
    await gate.resume()
    await harness.coordinator.waitForPendingOperations()
    try expect(harness.refreshBuilder.coordinators.count == 2, "Expected only latest replacement after confirmed exit")
    try expect(harness.refreshBuilder.configurations.last?.preferences.selectedExecutableURL == latest, "Expected latest executable after retirement")
    await harness.coordinator.shutdown()
}

private func applicationRuntimeBoundsExecutableReplacementTest() -> TestCase {
    TestCase(name: "application executable replacement has one task while exit confirmation is blocked") {
        try await applicationRuntimeBoundsExecutableReplacementScenario()
    }
}

@MainActor
private func applicationRuntimeBoundsExecutableReplacementScenario() async throws {
    let gate = RuntimeStopGate()
    let harness = RuntimeHarness(firstTerminationGate: gate)
    harness.coordinator.start()
    await harness.coordinator.waitForPendingOperations()
    harness.coordinator.selectedExecutableDidChange(URL(fileURLWithPath: "/Synthetic/first/codex"))
    try await waitForRuntimeCondition { await gate.hasStarted }
    try expect(harness.coordinator.pendingRuntimeOperationCount == 1, "Expected one active replacement task")
    for index in 0..<1_000 {
        harness.coordinator.selectedExecutableDidChange(
            URL(fileURLWithPath: "/Synthetic/replacement-\(index)/codex")
        )
        try expect(harness.coordinator.pendingRuntimeOperationCount == 1, "Expected bounded task count during unconfirmed exit")
    }
    try expect(harness.refreshBuilder.coordinators.count == 1, "Expected original child to retain exclusive admission")
    await gate.resume()
    await harness.coordinator.waitForPendingOperations()
    try expect(harness.coordinator.pendingRuntimeOperationCount == 0, "Expected replacement mailbox drained")
    try expect(harness.refreshBuilder.coordinators.count == 2, "Expected one replacement for the latest URL")
    try expect(harness.refreshBuilder.configurations.last?.preferences.selectedExecutableURL
        == URL(fileURLWithPath: "/Synthetic/replacement-999/codex"), "Expected latest executable only")
    let oldEvents = await harness.refreshBuilder.coordinators[0].events
    try expect(oldEvents.filter { $0 == .stop }.count == 1, "Expected one retirement attempt for the predecessor")
    try expect(harness.startupRecorder.preferences.count == 1, "Expected no repeated first-launch hook")
    await harness.coordinator.shutdown()
}

private func applicationRuntimeReplacesBeforeFirstStartupHookTest() -> TestCase {
    TestCase(name: "application coalesces executable changes before the first startup hook") {
        try await applicationRuntimeReplacesBeforeFirstStartupHookScenario()
    }
}

@MainActor
private func applicationRuntimeReplacesBeforeFirstStartupHookScenario() async throws {
    let gate = RuntimeStartGate()
    let harness = RuntimeHarness(firstStartGate: gate)
    harness.coordinator.start()
    try await waitForRuntimeCondition { await gate.hasStarted }
    for index in 0..<100 {
        harness.coordinator.selectedExecutableDidChange(
            URL(fileURLWithPath: "/Synthetic/startup-\(index)/codex")
        )
    }
    try expect(harness.coordinator.pendingRuntimeOperationCount == 2, "Expected initial startup and one queued replacement")
    try expect(harness.startupRecorder.preferences.isEmpty, "Expected superseded startup not to run the first-launch hook")
    await gate.resume()
    await harness.coordinator.waitForPendingOperations()
    try expect(harness.refreshBuilder.coordinators.count == 2, "Expected one latest replacement after initial startup drains")
    try expect(harness.startupRecorder.preferences.count == 1, "Expected the first-launch hook exactly once")
    try expect(harness.startupRecorder.preferences.first?.selectedExecutableURL
        == URL(fileURLWithPath: "/Synthetic/startup-99/codex"), "Expected first launch to use the admitted executable")
    await harness.coordinator.shutdown()
}

private func applicationRuntimeShutdownSkipsUnconfirmedRetirementTest() -> TestCase {
    TestCase(name: "application shutdown does not await unconfirmed process exit forever") {
        try await applicationRuntimeShutdownSkipsUnconfirmedRetirementScenario()
    }
}

@MainActor
private func applicationRuntimeShutdownSkipsUnconfirmedRetirementScenario() async throws {
    let gate = RuntimeStopGate()
    let harness = RuntimeHarness(firstTerminationGate: gate)
    harness.coordinator.start()
    await harness.coordinator.waitForPendingOperations()
    harness.coordinator.selectedExecutableDidChange(URL(fileURLWithPath: "/Synthetic/replacement/codex"))
    try await waitForRuntimeCondition { await gate.hasStarted }
    for index in 0..<100 {
        harness.coordinator.selectedExecutableDidChange(
            URL(fileURLWithPath: "/Synthetic/shutdown-\(index)/codex")
        )
    }
    try expect(harness.coordinator.pendingRuntimeOperationCount == 1, "Expected one retirement task before shutdown")
    let shutdown = Task { @MainActor in await harness.coordinator.shutdown() }
    try await waitForRuntimeCondition { harness.settings.shutdownCount == 1 }
    await shutdown.value
    try expect(harness.refreshBuilder.coordinators.count == 1, "Expected shutdown to cancel replacement admission")
    await gate.resume()
    await Task.yield()
    try expect(harness.refreshBuilder.coordinators.count == 1, "Expected late exit confirmation not to launch a replacement")
}

private func applicationRuntimeRoutesUpdatesWithoutQuotaRefreshTest() -> TestCase {
    TestCase(name: "application runtime keeps updater state outside quota IO") {
        try await applicationRuntimeRoutesUpdatesWithoutQuotaRefreshScenario()
    }
}

@MainActor
private func applicationRuntimeRoutesUpdatesWithoutQuotaRefreshScenario() async throws {
    let harness = RuntimeHarness()
    harness.coordinator.start()
    await harness.coordinator.waitForPendingOperations()
    let refreshEvents = await harness.refreshBuilder.coordinators[0].events
    let statusCount = harness.status.presentedFrames.count
    let deadlineCount = harness.deadlineScheduler.productStates.count

    try expect(harness.update.startCount == 1, "Expected updater startup")
    try expect(
        menuAction(.checkForUpdates, in: harness.menu.models.last)?.isEnabled == true,
        "Expected initial update action enabled"
    )
    let checking = ApplicationUpdateState(
        currentVersion: "1.2.0",
        status: .checking
    )
    harness.update.emit(checking)

    try expect(
        menuAction(.checkForUpdates, in: harness.menu.models.last)?.isEnabled == false,
        "Expected cached menu state update"
    )
    try expect(
        menuActionTitle(.checkForUpdates, in: harness.menu.models.last)
            == "Current version: v1.2.0 (checking latest…)",
        "Expected cached update title"
    )
    try expect(
        harness.status.presentedFrames.count == statusCount,
        "Expected updater state to leave the status frame untouched"
    )
    try expect(
        harness.deadlineScheduler.productStates.count == deadlineCount,
        "Expected updater state to leave quota deadlines untouched"
    )
    let finalRefreshEvents = await harness.refreshBuilder.coordinators[0].events
    try expect(
        finalRefreshEvents == refreshEvents,
        "Expected updater state to make no quota request"
    )

    harness.update.emit(ApplicationUpdateState(
        currentVersion: "1.2.0",
        status: .updateAvailable(latestVersion: "1.3.0")
    ))
    harness.coordinator.performMenuAction(.checkForUpdates)
    try expect(harness.update.checkCount == 1, "Expected update prompt routing")

    await harness.coordinator.shutdown()
    try expect(harness.update.stopCount == 1, "Expected updater observation shutdown")
}

private func applicationRuntimeRelocalizesWithoutRefreshingTest() -> TestCase {
    TestCase(name: "application runtime relocalizes cached UI without refreshing") {
        try await applicationRuntimeRelocalizesWithoutRefreshingScenario()
    }
}

@MainActor
private func applicationRuntimeRelocalizesWithoutRefreshingScenario() async throws {
    let appearance = StatusGaugeAppearance.preset(.purple)
    let preferences = AppPreferences(
        language: .korean,
        statusGaugeAppearance: appearance
    )
    let harness = RuntimeHarness(
        preferencesLoader: RuntimePreferencesLoader(preferences: preferences)
    )
    harness.coordinator.start()
    await harness.coordinator.waitForPendingOperations()

    try expect(harness.status.languages.last == .korean, "Expected stored Korean status")
    try expect(harness.settings.languages.last == .korean, "Expected stored Korean settings")
    try expect(
        menuActionTitle(.refresh, in: harness.menu.models.last) == "새로 고침",
        "Expected stored Korean menu"
    )
    let refreshEventsBeforeChange = await harness.refreshBuilder.coordinators[0].events
    let deadlineCountBeforeChange = harness.deadlineScheduler.productStates.count

    harness.coordinator.settingsFormValuesDidChange(
        SettingsFormValues(
            displayPreference: preferences.displayPreference,
            refreshProfile: preferences.refreshProfile,
            launchAtLoginIntent: preferences.launchAtLoginIntent,
            language: .english,
            statusGaugeAppearance: preferences.statusGaugeAppearance
        )
    )

    try expect(harness.status.languages.last == .english, "Expected English status")
    try expect(
        harness.status.appearances.last == appearance,
        "Expected language change to preserve the gauge appearance"
    )
    try expect(harness.settings.languages.last == .english, "Expected English settings")
    try expect(
        menuActionTitle(.refresh, in: harness.menu.models.last) == "Refresh",
        "Expected English cached menu"
    )
    let refreshEventsAfterChange = await harness.refreshBuilder.coordinators[0].events
    try expect(
        refreshEventsAfterChange == refreshEventsBeforeChange,
        "Expected no provider or refresh command for language changes"
    )
    try expect(
        harness.deadlineScheduler.productStates.count == deadlineCountBeforeChange,
        "Expected no deadline publication for language changes"
    )
}

private func applicationRuntimeRestylesWithoutRefreshingTest() -> TestCase {
    TestCase(name: "application runtime restyles cached status without refreshing") {
        try await applicationRuntimeRestylesWithoutRefreshingScenario()
    }
}

@MainActor
private func applicationRuntimeRestylesWithoutRefreshingScenario() async throws {
    let preferences = AppPreferences(
        language: .korean,
        statusGaugeAppearance: .preset(.blue)
    )
    let harness = RuntimeHarness(
        preferencesLoader: RuntimePreferencesLoader(preferences: preferences)
    )
    harness.coordinator.start()
    await harness.coordinator.waitForPendingOperations()
    let refreshEventsBeforeChange = await harness.refreshBuilder.coordinators[0].events
    let deadlineCountBeforeChange = harness.deadlineScheduler.productStates.count
    let presentationCountBeforeChange = harness.status.presentedFrames.count

    harness.coordinator.settingsFormValuesDidChange(
        SettingsFormValues(
            displayPreference: preferences.displayPreference,
            refreshProfile: preferences.refreshProfile,
            launchAtLoginIntent: preferences.launchAtLoginIntent,
            language: preferences.language,
            statusGaugeAppearance: .preset(.green)
        )
    )

    try expect(
        harness.status.appearances.last == .preset(.green),
        "Expected updated gauge appearance"
    )
    try expect(
        harness.status.languages.last == .korean,
        "Expected appearance change to preserve the language"
    )
    try expect(
        harness.status.presentedFrames.count == presentationCountBeforeChange + 1,
        "Expected one cached status presentation"
    )
    let refreshEventsAfterChange = await harness.refreshBuilder.coordinators[0].events
    try expect(
        refreshEventsAfterChange == refreshEventsBeforeChange,
        "Expected no provider or refresh command for appearance changes"
    )
    try expect(
        harness.deadlineScheduler.productStates.count == deadlineCountBeforeChange,
        "Expected no deadline publication for appearance changes"
    )
}

private func menuActionTitle(
    _ action: QuotaMenuAction,
    in model: QuotaDetailsMenuModel?
) -> String? {
    model?.actionGroups
        .flatMap { $0 }
        .first { $0.action == action }?
        .title
}

private func menuAction(
    _ action: QuotaMenuAction,
    in model: QuotaDetailsMenuModel?
) -> QuotaMenuActionItem? {
    model?.actionGroups
        .flatMap { $0 }
        .first { $0.action == action }
}

private func applicationRuntimePublishesLaunchAtLoginStateTest() -> TestCase {
    TestCase(name: "application runtime publishes login launch results and recovery") {
        try await applicationRuntimePublishesLaunchAtLoginStateScenario()
    }
}

@MainActor
private func applicationRuntimePublishesLaunchAtLoginStateScenario() async throws {
    let preferences = AppPreferences(launchAtLoginIntent: true)
    let harness = RuntimeHarness(
        preferencesLoader: RuntimePreferencesLoader(preferences: preferences)
    )
    harness.launch.nextStatus = .requiresApproval

    harness.coordinator.start()
    await harness.coordinator.waitForPendingOperations()

    try expect(
        harness.settings.launchAtLoginStates.last == LaunchAtLoginSettingsState(
            status: .requiresApproval
        ),
        "Expected startup reconciliation result in settings"
    )
    harness.coordinator.openLaunchAtLoginApprovalSettings()
    try expect(harness.launch.openSettingsCount == 1, "Expected routed recovery action")

    harness.launch.nextFailure = .unregistrationFailed
    harness.coordinator.settingsFormValuesDidChange(
        SettingsFormValues(
            displayPreference: preferences.displayPreference,
            refreshProfile: preferences.refreshProfile,
            launchAtLoginIntent: false
        )
    )
    harness.coordinator.launchAtLoginIntentDidChange(false)
    await harness.coordinator.waitForPendingOperations()
    try expect(
        harness.settings.launchAtLoginStates.last == LaunchAtLoginSettingsState(
            status: .requiresApproval,
            failure: .unregistrationFailed
        ),
        "Expected typed unregistration failure with actual system status"
    )

    harness.launch.nextStatus = .disabled
    harness.coordinator.launchAtLoginIntentDidChange(false)
    await harness.coordinator.waitForPendingOperations()
    try expect(
        harness.settings.launchAtLoginStates.last == LaunchAtLoginSettingsState(
            status: .disabled
        ),
        "Expected retry of an unchanged disabled intent"
    )

    harness.launch.nextFailure = .registrationFailed
    harness.coordinator.settingsFormValuesDidChange(
        SettingsFormValues(
            displayPreference: preferences.displayPreference,
            refreshProfile: preferences.refreshProfile,
            launchAtLoginIntent: true
        )
    )
    harness.coordinator.launchAtLoginIntentDidChange(true)
    await harness.coordinator.waitForPendingOperations()
    try expect(
        harness.settings.launchAtLoginStates.last == LaunchAtLoginSettingsState(
            status: .disabled,
            failure: .registrationFailed
        ),
        "Expected typed failure with the unchanged actual status"
    )

    harness.coordinator.refreshLaunchAtLoginStatus()
    try expect(
        harness.settings.launchAtLoginStates.last == LaunchAtLoginSettingsState(
            status: .disabled,
            failure: .registrationFailed
        ),
        "Expected unchanged activation sample to preserve the typed failure"
    )
    harness.launch.currentStatus = .enabled
    harness.coordinator.refreshLaunchAtLoginStatus()
    try expect(
        harness.settings.launchAtLoginStates.last == LaunchAtLoginSettingsState(
            status: .enabled
        ),
        "Expected changed activation sample to clear the obsolete failure"
    )

    harness.launch.currentStatus = .requiresApproval
    harness.coordinator.openLaunchAtLoginApprovalSettings()
    try expect(
        harness.launch.openSettingsCount == 2,
        "Expected recovery to follow a newly observed approval state"
    )
    harness.launch.currentStatus = .enabled
    harness.coordinator.openLaunchAtLoginApprovalSettings()
    try expect(
        harness.settings.launchAtLoginStates.last == LaunchAtLoginSettingsState(
            status: .enabled
        ),
        "Expected recovery action to publish a changed actual state"
    )
}

private func applicationRuntimeStartsFirstLaunchAfterRefreshTest() -> TestCase {
    TestCase(name: "application runtime opens first launch settings after refresh start") {
        try await applicationRuntimeStartsFirstLaunchAfterRefreshScenario()
    }
}

@MainActor
private func applicationRuntimeStartsFirstLaunchAfterRefreshScenario() async throws {
    let suiteName = "io.github.symflee.codex-gauge.tests.runtime-first-launch.\(UUID().uuidString)"
    guard let cleanupDefaults = UserDefaults(suiteName: suiteName) else {
        throw TestFailure(description: "Unable to create runtime first-launch defaults")
    }
    defer { cleanupDefaults.removePersistentDomain(forName: suiteName) }
    guard let repositoryDefaults = UserDefaults(suiteName: suiteName) else {
        throw TestFailure(description: "Unable to inject runtime first-launch defaults")
    }
    let repository = AppPreferencesRepository(userDefaults: repositoryDefaults)
    let firstLaunchSettings = RuntimeSettingsSpy()
    let firstLaunch = FirstLaunchSettingsCoordinator(
        repository: repository,
        settingsRuntime: firstLaunchSettings
    )
    let harness = RuntimeHarness { _ in
        await firstLaunch.runAfterInitialRefreshStarted()
    }

    harness.coordinator.start()
    await harness.coordinator.waitForPendingOperations()

    try expect(firstLaunchSettings.showCount == 1, "Expected first-launch settings")
    try expect(
        harness.startupRecorder.statusPresentationCounts.first ?? 0 > 0,
        "Expected status before first-launch settings"
    )
    try expect(
        harness.startupRecorder.refreshEvents.first == [.start],
        "Expected refresh start before first-launch settings"
    )
}

private func applicationRuntimeDefersInitialWakeBaselineTest() -> TestCase {
    TestCase(name: "application runtime preserves wake while preferences load") {
        try await applicationRuntimeDefersInitialWakeBaselineScenario()
    }
}

@MainActor
private func applicationRuntimeDefersInitialWakeBaselineScenario() async throws {
    let loader = RuntimePreferencesGate(preferences: .default)
    let harness = RuntimeHarness(preferencesLoader: loader)
    harness.coordinator.start()
    try await waitForRuntimeCondition { await loader.hasStarted }

    harness.systemMonitor.emit(.sleep)
    harness.systemMonitor.emit(.wake)
    await loader.resume()
    await harness.coordinator.waitForPendingOperations()

    let events = await harness.refreshBuilder.coordinators[0].events
    try expect(!events.contains(.start), "Expected no immediate startup query after wake")
    try expect(
        events.prefix(2).elementsEqual([.suspend, .resume]),
        "Expected delayed wake baseline"
    )
}

private func applicationDelegateStartsOneRuntimeTest() -> TestCase {
    TestCase(name: "application delegate starts and retains one runtime") {
        try await applicationDelegateStartsOneRuntimeScenario()
    }
}

@MainActor
private func applicationDelegateStartsOneRuntimeScenario() async throws {
    let runtime = RuntimeApplicationSpy()
    let delegate = CodexGaugeApplicationDelegate(runtimeFactory: { runtime })
    let notification = Notification(name: NSApplication.didFinishLaunchingNotification)

    delegate.applicationDidFinishLaunching(notification)
    delegate.applicationDidFinishLaunching(notification)
    delegate.applicationDidBecomeActive(
        Notification(name: NSApplication.didBecomeActiveNotification)
    )

    try expect(runtime.startCount == 1, "Expected one retained runtime start")
    try expect(
        runtime.launchAtLoginRefreshCount == 1,
        "Expected app activation to refresh login launch status"
    )
}

private func applicationRuntimeStartsStatusBeforePreferencesTest() -> TestCase {
    TestCase(name: "application runtime presents status before loading preferences") {
        try await applicationRuntimeStartsStatusBeforePreferencesScenario()
    }
}

@MainActor
private func applicationRuntimeStartsStatusBeforePreferencesScenario() async throws {
    let preferences = AppPreferences(
        displayPreference: DisplayPreference(
            quotaSelection: .manual(QuotaSelectionID(product: .codex, rawDurationMinutes: 10_080))
        ),
        refreshProfile: .fast,
        launchAtLoginIntent: true,
        selectedExecutableURL: URL(fileURLWithPath: "/Synthetic/bin/codex")
    )
    let loader = RuntimePreferencesGate(preferences: preferences)
    let harness = RuntimeHarness(preferencesLoader: loader)

    harness.coordinator.start()

    try expect(harness.status.presentedFrames.count == 1, "Expected loading status synchronously")
    try expect(
        harness.refreshBuilder.configurations.isEmpty,
        "Expected preferences before provider"
    )
    try await waitForRuntimeCondition { await loader.hasStarted }
    await loader.resume()
    await harness.coordinator.waitForPendingOperations()

    guard let configuration = harness.refreshBuilder.configurations.first else {
        throw TestFailure(description: "Expected refresh configuration")
    }
    try expect(configuration.preferences == preferences, "Expected loaded preferences")
    try expect(configuration.lowPowerModeEnabled, "Expected initial low power state")
    guard let displayedFrame = harness.status.presentedFrames.last?.first,
          case .single(let displayedQuota) = displayedFrame else {
        throw TestFailure(description: "Expected one loaded-preference frame")
    }
    try expect(displayedQuota.identifier.rawDurationMinutes == 10_080, "Expected loaded manual period")
    let events = await harness.refreshBuilder.coordinators[0].events
    try expect(events == [.start], "Expected initial start")
    try expect(harness.launch.enabledValues == [true], "Expected login intent reconciliation")
    try expect(harness.startupRecorder.preferences == [preferences], "Expected post-start hook")
    try expect(
        harness.startupRecorder.statusPresentationCounts.first ?? 0 > 0,
        "Expected status before the startup hook"
    )
    try expect(
        harness.startupRecorder.refreshEvents.first == [.start],
        "Expected initial refresh start before the startup hook"
    )
}

private func applicationRuntimePublishesOnePresentationTransactionTest() -> TestCase {
    TestCase(name: "application runtime publishes status menu settings and deadlines together") {
        try await applicationRuntimePublishesOnePresentationTransactionScenario()
    }
}

@MainActor
private func applicationRuntimePublishesOnePresentationTransactionScenario() async throws {
    let harness = RuntimeHarness()
    harness.coordinator.start()
    await harness.coordinator.waitForPendingOperations()
    let publication = try runtimePublication(usedPercent: 17)

    await harness.refreshBuilder.emit(publication, from: 0)

    let identifier = QuotaSelectionID(product: .codex, rawDurationMinutes: 300)
    try expect(harness.status.presentedFrames.last?.count == 1, "Expected one rendered frame")
    let sections = harness.menu.models.last?.productSections
    try expect(sections?.map(\.product) == [.codex], "Expected only the Codex menu section")
    try expect(sections?.first?.quotaRows.count == 1, "Expected the complete Codex quota details")
    try expect(sections?.first?.quotaRows.first?.contains("83%") == true, "Expected the same remaining quota in the menu")
    try expect(
        harness.settings.discoveredQuotaIDs.last == [identifier],
        "Expected discovered quota"
    )
    try expect(harness.deadlineScheduler.productStates.last?[.codex] != nil, "Expected deadlines")
    try expect(harness.settings.connectionStatuses.last == .connected, "Expected connection status")
}

private func applicationRuntimeRoutesMenuAndSettingsTest() -> TestCase {
    TestCase(name: "application runtime routes menu and settings changes") {
        try await applicationRuntimeRoutesMenuAndSettingsScenario()
    }
}

@MainActor
private func applicationRuntimeRoutesMenuAndSettingsScenario() async throws {
    let harness = RuntimeHarness()
    harness.coordinator.start()
    await harness.coordinator.waitForPendingOperations()
    let preference = DisplayPreference(
        quotaSelection: .manual(QuotaSelectionID(product: .codex, rawDurationMinutes: 10_080))
    )
    let values = SettingsFormValues(
        displayPreference: preference,
        refreshProfile: .eco,
        launchAtLoginIntent: true
    )

    harness.coordinator.performMenuAction(.refresh)
    harness.coordinator.performMenuAction(.openCodex)
    harness.coordinator.performMenuAction(.selectCodex)
    harness.coordinator.performMenuAction(.settings)
    harness.coordinator.settingsFormValuesDidChange(values)
    harness.coordinator.launchAtLoginIntentDidChange(true)
    await harness.coordinator.waitForPendingOperations()
    harness.coordinator.performMenuAction(.quit)

    let events = await harness.refreshBuilder.coordinators[0].events
    try expect(events.contains(.manualRefresh), "Expected manual refresh")
    try expect(events.contains(.displayPreference(preference)), "Expected display update")
    try expect(events.contains(.profile(.eco)), "Expected profile update")
    try expect(harness.workspace.openCount == 1, "Expected workspace open")
    try expect(harness.settings.selectionRequestCount == 1, "Expected Codex selection")
    try expect(harness.settings.showCount == 1, "Expected settings window")
    try expect(harness.launch.enabledValues == [false, true], "Expected login launch update")
    try expect(harness.terminator.terminationCount == 1, "Expected termination action")
}

private func applicationRuntimeReplacesRefreshGenerationTest() -> TestCase {
    TestCase(name: "application runtime stops old provider before starting replacement") {
        try await applicationRuntimeReplacesRefreshGenerationScenario()
    }
}

private func applicationRuntimePreservesPendingWakeAcrossReplacementTest() -> TestCase {
    TestCase(name: "application runtime preserves pending wake delay across replacement") {
        try await applicationRuntimePreservesPendingWakeAcrossReplacementScenario()
    }
}

@MainActor
private func applicationRuntimePreservesPendingWakeAcrossReplacementScenario() async throws {
    let harness = RuntimeHarness()
    harness.coordinator.start()
    await harness.coordinator.waitForPendingOperations()

    harness.systemMonitor.emit(.sleep)
    harness.systemMonitor.emit(.wake)
    await harness.coordinator.waitForPendingOperations()
    harness.coordinator.selectedExecutableDidChange(
        URL(fileURLWithPath: "/Synthetic/replacement/codex")
    )
    await harness.coordinator.waitForPendingOperations()

    let replacementEvents = await harness.refreshBuilder.coordinators[1].events
    try expect(
        replacementEvents == [.suspend, .resume],
        "Expected replacement to inherit the pending five-second wake phase"
    )
}

private func applicationRuntimePreservesSameTurnWakeAcrossReplacementTest() -> TestCase {
    TestCase(name: "application runtime preserves same-turn wake delay across replacement") {
        try await applicationRuntimePreservesSameTurnWakeAcrossReplacementScenario()
    }
}

@MainActor
private func applicationRuntimePreservesSameTurnWakeAcrossReplacementScenario() async throws {
    let harness = RuntimeHarness()
    harness.coordinator.start()
    await harness.coordinator.waitForPendingOperations()

    // No suspension point between these callbacks: the old generation's activity
    // dispatch cannot run before the executable replacement invalidates it.
    harness.systemMonitor.emit(.sleep)
    harness.systemMonitor.emit(.wake)
    harness.coordinator.selectedExecutableDidChange(
        URL(fileURLWithPath: "/Synthetic/same-turn-wake/codex")
    )
    await harness.coordinator.waitForPendingOperations()

    try expect(harness.refreshBuilder.coordinators.count == 2, "Expected one replacement")
    let previousEvents = await harness.refreshBuilder.coordinators[0].events
    try expect(previousEvents == [.start, .stop], "Expected queued activity not to reach the retired generation")
    let replacementEvents = await harness.refreshBuilder.coordinators[1].events
    try expect(
        replacementEvents == [.suspend, .resume],
        "Expected pending wake to establish the five-second resume phase without an immediate start; got \(replacementEvents)"
    )
}

@MainActor
private func applicationRuntimeReplacesRefreshGenerationScenario() async throws {
    let stopGate = RuntimeStopGate()
    let harness = RuntimeHarness(firstStopGate: stopGate)
    harness.coordinator.start()
    await harness.coordinator.waitForPendingOperations()
    let oldPublication = try runtimePublication(usedPercent: 17)
    await harness.refreshBuilder.emit(oldPublication, from: 0)
    let replacementURL = URL(fileURLWithPath: "/Synthetic/replacement/codex")

    harness.coordinator.selectedExecutableDidChange(replacementURL)
    try await waitForRuntimeCondition { await stopGate.hasStarted }
    let latePublication = try runtimePublication(usedPercent: 91)
    await harness.refreshBuilder.emit(latePublication, from: 0)

    try expect(harness.refreshBuilder.coordinators.count == 1, "Expected replacement to await stop")
    try expect(
        harness.coordinator.publication == .initial,
        "Expected late publication from old generation discarded"
    )
    await stopGate.resume()
    await harness.coordinator.waitForPendingOperations()

    try expect(harness.refreshBuilder.coordinators.count == 2, "Expected replacement built")
    try expect(
        harness.refreshBuilder.configurations.last?
            .preferences.selectedExecutableURL == replacementURL,
        "Expected replacement path"
    )
    let replacementEvents = await harness.refreshBuilder.coordinators[1].events
    try expect(replacementEvents == [.start], "Expected new start")
}

private func applicationRuntimeOrdersOverlappingResumeTest() -> TestCase {
    TestCase(name: "application runtime resumes once after sleep and lock with reset first") {
        try await applicationRuntimeOrdersOverlappingResumeScenario()
    }
}

private func applicationRuntimeReplacesAcrossSystemTransitionTest() -> TestCase {
    TestCase(name: "application runtime does not start replacement across sleep wake") {
        try await applicationRuntimeReplacesAcrossSystemTransitionScenario()
    }
}

@MainActor
private func applicationRuntimeReplacesAcrossSystemTransitionScenario() async throws {
    let stopGate = RuntimeStopGate()
    let harness = RuntimeHarness(firstStopGate: stopGate)
    harness.coordinator.start()
    await harness.coordinator.waitForPendingOperations()

    harness.coordinator.selectedExecutableDidChange(
        URL(fileURLWithPath: "/Synthetic/replacement/codex")
    )
    try await waitForRuntimeCondition { await stopGate.hasStarted }
    harness.systemMonitor.emit(.sleep)
    harness.systemMonitor.emit(.wake)
    for index in 0..<100 {
        harness.coordinator.selectedExecutableDidChange(
            URL(fileURLWithPath: "/Synthetic/wake-\(index)/codex")
        )
    }
    try expect(harness.coordinator.pendingRuntimeOperationCount == 2, "Expected one replacement plus one merged activity dispatch")
    await stopGate.resume()
    await harness.coordinator.waitForPendingOperations()

    let replacementEvents = await harness.refreshBuilder.coordinators[1].events
    try expect(
        !replacementEvents.contains(.start),
        "Expected no immediate replacement query"
    )
    try expect(replacementEvents.contains(.suspend), "Expected resumable replacement")
    try expect(replacementEvents.last == .resume, "Expected one delayed wake request")
}

@MainActor
private func applicationRuntimeOrdersOverlappingResumeScenario() async throws {
    let harness = RuntimeHarness()
    harness.coordinator.start()
    await harness.coordinator.waitForPendingOperations()
    let refresh = harness.refreshBuilder.coordinators[0]

    harness.systemMonitor.emit(.sleep)
    harness.systemMonitor.emit(.sessionLocked)
    harness.systemMonitor.emit(.wake)
    await harness.coordinator.waitForPendingOperations()

    let suspendedEvents = await refresh.events
    try expect(
        suspendedEvents.filter { $0 == .suspend }.count == 1,
        "Expected one suspend"
    )
    try expect(!suspendedEvents.contains(.resume), "Expected lock to prevent resume")
    harness.deadlineScheduler.deadlineOnWake = .quotaReset
    harness.systemMonitor.emit(.sessionUnlocked)
    await harness.coordinator.waitForPendingOperations()

    let events = await refresh.events
    guard let resetIndex = events.firstIndex(of: .quotaReset),
          let resumeIndex = events.firstIndex(of: .resume) else {
        throw TestFailure(description: "Expected reset and resume")
    }
    try expect(resetIndex < resumeIndex, "Expected reset latched before resume")
    try expect(harness.deadlineScheduler.sleepCount == 1, "Expected one scheduler sleep")
    try expect(harness.deadlineScheduler.wakeCount == 1, "Expected one scheduler wake")
}

private func applicationRuntimeHandlesPresentationOnlyDeadlinesTest() -> TestCase {
    TestCase(name: "application runtime invalidates presentation without quota IO") {
        try await applicationRuntimeHandlesPresentationOnlyDeadlinesScenario()
    }
}

@MainActor
private func applicationRuntimeHandlesPresentationOnlyDeadlinesScenario() async throws {
    let harness = RuntimeHarness()
    harness.coordinator.start()
    await harness.coordinator.waitForPendingOperations()
    let refresh = harness.refreshBuilder.coordinators[0]
    let eventCount = await refresh.events.count
    let presentationCount = harness.status.presentedFrames.count
    let workspaceReadCount = harness.workspace.applicationURLReadCount

    harness.deadlineScheduler.emit(.validityExpired)
    await harness.coordinator.waitForPendingOperations()

    let finalEventCount = await refresh.events.count
    try expect(finalEventCount == eventCount, "Expected no provider request")
    try expect(
        harness.workspace.applicationURLReadCount == workspaceReadCount,
        "Expected no workspace lookup"
    )
    try expect(harness.status.presentedFrames.count == presentationCount, "Expected unchanged loading frame to remain cached")
}

private func applicationRuntimeSharesShutdownDrainTest() -> TestCase {
    TestCase(name: "application runtime shares one shutdown drain") {
        try await applicationRuntimeSharesShutdownDrainScenario()
    }
}

private func applicationRuntimeDrainsReplacementOnShutdownTest() -> TestCase {
    TestCase(name: "application runtime drains replacement before settings shutdown") {
        try await applicationRuntimeDrainsReplacementOnShutdownScenario()
    }
}

private func applicationRuntimeStopsStartThatResumesDuringShutdownTest() -> TestCase {
    TestCase(name: "application runtime terminally stops startup resumed during shutdown") {
        try await applicationRuntimeStopsStartThatResumesDuringShutdownScenario()
    }
}

@MainActor
private func applicationRuntimeStopsStartThatResumesDuringShutdownScenario() async throws {
    let startGate = RuntimeStartGate()
    let harness = RuntimeHarness(firstStartGate: startGate)
    harness.coordinator.start()
    try await waitForRuntimeCondition { await startGate.hasStarted }

    let shutdown = Task { @MainActor in
        await harness.coordinator.shutdown()
    }
    let refresh = harness.refreshBuilder.coordinators[0]
    try await waitForRuntimeCondition {
        await refresh.events.contains(.stop)
    }
    await startGate.resume()
    await shutdown.value

    let events = await refresh.events
    try expect(events == [.stop, .start, .stop], "Expected a terminal stop after late start")
    try expect(harness.settings.shutdownCount == 1, "Expected settings after refresh drain")
}

@MainActor
private func applicationRuntimeDrainsReplacementOnShutdownScenario() async throws {
    let stopGate = RuntimeStopGate()
    let harness = RuntimeHarness(firstStopGate: stopGate)
    harness.coordinator.start()
    await harness.coordinator.waitForPendingOperations()
    harness.coordinator.selectedExecutableDidChange(
        URL(fileURLWithPath: "/Synthetic/replacement/codex")
    )
    try await waitForRuntimeCondition { await stopGate.hasStarted }

    let shutdown = Task { @MainActor in
        await harness.coordinator.shutdown()
    }
    await Task.yield()
    try expect(harness.settings.shutdownCount == 0, "Expected replacement stop drain")
    await stopGate.resume()
    await shutdown.value

    try expect(harness.refreshBuilder.coordinators.count == 1, "Expected no late replacement")
    try expect(harness.settings.shutdownCount == 1, "Expected settings shutdown after drain")
}

private func applicationRuntimeRefreshesQuotaResetTest() -> TestCase {
    TestCase(name: "application runtime rerenders and refreshes a quota reset") {
        try await applicationRuntimeRefreshesQuotaResetScenario()
    }
}

@MainActor
private func applicationRuntimeRefreshesQuotaResetScenario() async throws {
    let harness = RuntimeHarness()
    harness.coordinator.start()
    await harness.coordinator.waitForPendingOperations()
    let refresh = harness.refreshBuilder.coordinators[0]
    let presentationCount = harness.status.presentedFrames.count

    harness.deadlineScheduler.emit(.quotaReset)
    await harness.coordinator.waitForPendingOperations()

    let events = await refresh.events
    try expect(events.contains(.quotaReset), "Expected quota reset refresh")
    try expect(
        harness.status.presentedFrames.count == presentationCount,
        "Expected unchanged loading presentation at reset"
    )
}

@MainActor
private func applicationRuntimeSharesShutdownDrainScenario() async throws {
    let stopGate = RuntimeStopGate()
    let harness = RuntimeHarness(firstStopGate: stopGate)
    harness.coordinator.start()
    await harness.coordinator.waitForPendingOperations()

    let first = Task { @MainActor in
        await harness.coordinator.shutdown()
    }
    try await waitForRuntimeCondition { await stopGate.hasStarted }
    let second = Task { @MainActor in
        await harness.coordinator.shutdown()
    }
    await Task.yield()

    try expect(harness.settings.shutdownCount == 0, "Expected shutdown to await refresh stop")
    await stopGate.resume()
    await first.value
    await second.value

    let events = await harness.refreshBuilder.coordinators[0].events
    try expect(
        events.filter { $0 == .stop }.count == 2,
        "Expected initial and terminal refresh stops in one shared drain"
    )
    try expect(harness.settings.shutdownCount == 1, "Expected one settings shutdown")
    try expect(harness.systemMonitor.stopCount == 1, "Expected one monitor shutdown")
}

@MainActor
private final class RuntimeHarness {
    let status = RuntimeStatusSpy()
    let menu = RuntimeMenuSpy()
    let settings = RuntimeSettingsSpy()
    let update = RuntimeUpdateSpy()
    let systemMonitor = RuntimeSystemMonitorSpy(initialLowPowerMode: true)
    let deadlineScheduler = RuntimeDeadlineSchedulerSpy()
    let launch = RuntimeLaunchSpy()
    let refreshBuilder: RuntimeRefreshBuilderSpy
    let workspace = RuntimeWorkspaceSpy()
    let terminator = RuntimeTerminatorSpy()
    let startupRecorder = RuntimeStartupRecorder()
    let clock = RuntimeClock()
    let coordinator: CodexGaugeApplicationCoordinator

    init(
        preferencesLoader: any ApplicationPreferencesLoading = RuntimePreferencesLoader(),
        menuRuntime: (any ApplicationMenuRuntime)? = nil,
        firstStartGate: RuntimeStartGate? = nil,
        firstStopGate: RuntimeStopGate? = nil,
        firstManualGate: RuntimeStopGate? = nil,
        firstTerminationGate: RuntimeStopGate? = nil,
        afterStartupRecorded: @escaping CodexGaugeApplicationCoordinator.StartupHook = {
            _ in
        }
    ) {
        refreshBuilder = RuntimeRefreshBuilderSpy(
            firstStartGate: firstStartGate,
            firstStopGate: firstStopGate,
            firstManualGate: firstManualGate,
            firstTerminationGate: firstTerminationGate
        )
        let clock = clock
        let scheduler = deadlineScheduler
        let statusRuntime = status
        let refreshBuilder = refreshBuilder
        coordinator = CodexGaugeApplicationCoordinator(
            statusRuntime: status,
            menuRuntime: menuRuntime ?? menu,
            settingsRuntime: settings,
            applicationUpdateRuntime: update,
            systemActivityMonitor: systemMonitor,
            deadlineSchedulerBuilder: ApplicationUsageDeadlineSchedulerBuilder { emitter in
                scheduler.handler = { reason in
                    emitter.emit(reason)
                }
                return scheduler
            },
            launchAtLoginController: launch,
            refreshCoordinatorBuilder: refreshBuilder,
            preferencesLoader: preferencesLoader,
            workspace: workspace,
            terminator: terminator,
            now: { clock.date },
            startupHook: { [startupRecorder] preferences in
                let refreshEvents = await refreshBuilder.coordinators.last?.events ?? []
                startupRecorder.record(
                    preferences: preferences,
                    statusPresentationCount: statusRuntime.presentedFrames.count,
                    refreshEvents: refreshEvents
                )
                await afterStartupRecorded(preferences)
            }
        )
    }
}

@MainActor
private final class RuntimeClock {
    var date = Date(timeIntervalSince1970: 1_900_000_000)
}

@MainActor
private final class RuntimeStartupRecorder {
    private(set) var preferences = [AppPreferences]()
    private(set) var statusPresentationCounts = [Int]()
    private(set) var refreshEvents = [[RuntimeRefreshSpy.Event]]()

    func record(
        preferences: AppPreferences,
        statusPresentationCount: Int,
        refreshEvents: [RuntimeRefreshSpy.Event]
    ) {
        self.preferences.append(preferences)
        statusPresentationCounts.append(statusPresentationCount)
        self.refreshEvents.append(refreshEvents)
    }
}

@MainActor
private final class RuntimeApplicationSpy: CodexGaugeApplicationRunning {
    private(set) var startCount = 0
    private(set) var launchAtLoginRefreshCount = 0

    func start() {
        startCount += 1
    }

    func refreshLaunchAtLoginStatus() {
        launchAtLoginRefreshCount += 1
    }

    func shutdown() async {}
}

@MainActor
private final class RuntimeStatusSpy: ApplicationStatusRuntime {
    private struct RenderingConfiguration {
        let language: AppLanguage
        let appearance: StatusGaugeAppearance
    }

    private(set) var presentedFrames = [[DisplayFrame]]()
    private var renderingConfigurations = [RenderingConfiguration]()

    var languages: [AppLanguage] {
        renderingConfigurations.map(\.language)
    }

    var appearances: [StatusGaugeAppearance] {
        renderingConfigurations.map(\.appearance)
    }

    func present(frames: [DisplayFrame]) {
        presentedFrames.append(frames)
    }

    func updateRenderingConfiguration(
        language: AppLanguage,
        statusGaugeAppearance: StatusGaugeAppearance
    ) {
        renderingConfigurations.append(
            RenderingConfiguration(
                language: language,
                appearance: statusGaugeAppearance
            )
        )
    }
}

@MainActor
private final class RuntimeMenuSpy: ApplicationMenuRuntime {
    private(set) var models = [QuotaDetailsMenuModel]()

    func update(_ model: QuotaDetailsMenuModel) {
        models.append(model)
    }
}

@MainActor
private final class RuntimeNativeMenuPresenter: StatusMenuPresenting, StatusItemPresenting {
    private(set) var menu: NSMenu?
    let effectiveAppearance = NSAppearance(named: .aqua)
    func setMenu(_ menu: NSMenu) { self.menu = menu }
    func setLength(_ length: CGFloat) {}
    func present(_ frame: RenderedStatusFrame) {}
}

@MainActor
private final class RuntimeSettingsSpy: ApplicationSettingsRuntime {
    private(set) var discoveredQuotaIDs = [Set<QuotaSelectionID>]()
    private(set) var connectionStatuses = [CodexConnectionStatus]()
    private(set) var launchAtLoginStates = [LaunchAtLoginSettingsState]()
    private(set) var selectionRequestCount = 0
    private(set) var showCount = 0
    private(set) var shutdownCount = 0
    private(set) var languages = [AppLanguage]()

    func showSettings() async -> Bool {
        showCount += 1
        return true
    }

    func requestExecutableSelection() {
        selectionRequestCount += 1
    }

    func updateDiscoveredQuotaIDs(_ identifiers: Set<QuotaSelectionID>) {
        discoveredQuotaIDs.append(identifiers)
    }

    func updateConnectionStatus(_ status: CodexConnectionStatus) {
        connectionStatuses.append(status)
    }

    func updateLaunchAtLoginState(_ state: LaunchAtLoginSettingsState) {
        launchAtLoginStates.append(state)
    }

    func updateLanguage(_ language: AppLanguage) {
        languages.append(language)
    }

    func shutdown() async {
        shutdownCount += 1
    }
}

@MainActor
private final class RuntimeUpdateSpy: ApplicationUpdateRuntime {
    private(set) var state = ApplicationUpdateState(
        currentVersion: "1.2.0",
        status: .updateAvailable(latestVersion: "1.3.0")
    )
    private(set) var startCount = 0
    private(set) var checkCount = 0
    private(set) var stopCount = 0
    private var handler: (@MainActor (ApplicationUpdateState) -> Void)?

    func start(
        stateHandler: @escaping @MainActor (ApplicationUpdateState) -> Void
    ) {
        startCount += 1
        handler = stateHandler
        stateHandler(state)
    }

    func checkForUpdates() {
        checkCount += 1
    }

    func stop() {
        stopCount += 1
        handler = nil
    }

    func emit(_ state: ApplicationUpdateState) {
        self.state = state
        handler?(state)
    }
}

@MainActor
private final class RuntimeSystemMonitorSpy: ApplicationSystemActivityMonitoring {
    private let initialLowPowerMode: Bool
    private var handler: (@MainActor (SystemActivityEvent) -> Void)?
    private(set) var stopCount = 0

    init(initialLowPowerMode: Bool) {
        self.initialLowPowerMode = initialLowPowerMode
    }

    func start(handler: @escaping @MainActor (SystemActivityEvent) -> Void) {
        self.handler = handler
        handler(.lowPowerModeChanged(isEnabled: initialLowPowerMode))
    }

    func stop() {
        stopCount += 1
        handler = nil
    }

    func emit(_ event: SystemActivityEvent) {
        handler?(event)
    }
}

@MainActor
private final class RuntimeDeadlineSchedulerSpy: ApplicationUsageDeadlineScheduling {
    var handler: (@MainActor (UsageDeadlineReason) -> Void)?
    var deadlineOnWake: UsageDeadlineReason?
    private(set) var productStates = [[UsageProduct: ProductUsageState]]()
    private(set) var sleepCount = 0
    private(set) var wakeCount = 0

    func publish(productStates: [UsageProduct: ProductUsageState]) {
        self.productStates.append(productStates)
    }

    func systemDidSleep() {
        sleepCount += 1
    }

    func systemDidWake() {
        wakeCount += 1
        if let deadlineOnWake {
            handler?(deadlineOnWake)
        }
    }

    func stop() {}

    func emit(_ reason: UsageDeadlineReason) {
        handler?(reason)
    }
}

@MainActor
private final class RuntimeLaunchSpy: ApplicationLaunchAtLoginControlling {
    private(set) var enabledValues = [Bool]()
    private(set) var openSettingsCount = 0
    var currentStatus = LaunchAtLoginStatus.disabled
    var nextStatus: LaunchAtLoginStatus?
    var nextFailure: LaunchAtLoginError?

    func setEnabled(
        _ enabled: Bool
    ) async throws(LaunchAtLoginError) -> LaunchAtLoginStatus {
        enabledValues.append(enabled)
        if let nextFailure {
            self.nextFailure = nil
            throw nextFailure
        }
        currentStatus = nextStatus ?? (enabled ? .enabled : .disabled)
        nextStatus = nil
        return currentStatus
    }

    func openApprovalSettingsIfNeeded() -> Bool {
        guard currentStatus == .requiresApproval else {
            return false
        }
        openSettingsCount += 1
        return true
    }
}

private actor RuntimeRefreshSpy: ApplicationRefreshCoordinating {
    enum Event: Equatable {
        case start
        case manualRefresh
        case quotaReset
        case profile(RefreshProfile)
        case lowPowerMode(Bool)
        case displayPreference(DisplayPreference)
        case suspend
        case resume
        case stop
    }

    private(set) var events = [Event]()
    private let startGate: RuntimeStartGate?
    private let stopGate: RuntimeStopGate?
    private let manualGate: RuntimeStopGate?
    private let terminationGate: RuntimeStopGate?
    private var awaitingSystemResume = false

    init(
        startGate: RuntimeStartGate?, stopGate: RuntimeStopGate?,
        manualGate: RuntimeStopGate?, terminationGate: RuntimeStopGate?
    ) {
        self.startGate = startGate
        self.stopGate = stopGate
        self.manualGate = manualGate
        self.terminationGate = terminationGate
    }

    func start() async {
        await startGate?.wait()
        awaitingSystemResume = false
        events.append(.start)
    }

    func refreshManually() async {
        events.append(.manualRefresh)
        await manualGate?.wait()
    }

    func refreshAfterQuotaReset() async {
        events.append(.quotaReset)
    }

    func updateProfile(_ profile: RefreshProfile) async {
        events.append(.profile(profile))
    }

    func setLowPowerMode(_ enabled: Bool) async {
        events.append(.lowPowerMode(enabled))
    }

    func updateDisplayPreference(_ preference: DisplayPreference) async {
        events.append(.displayPreference(preference))
    }

    func suspend() async {
        awaitingSystemResume = false
        events.append(.suspend)
    }

    func resumeAfterSystemWake() async {
        awaitingSystemResume = true
        events.append(.resume)
    }

    func isAwaitingSystemResume() -> Bool {
        awaitingSystemResume
    }

    func stop() async {
        awaitingSystemResume = false
        events.append(.stop)
        await stopGate?.wait()
    }

    func waitForTermination() async {
        await terminationGate?.wait()
    }
}

@MainActor
private final class RuntimeRefreshBuilderSpy: ApplicationRefreshCoordinatorBuilding {
    private(set) var configurations = [ApplicationRefreshConfiguration]()
    private(set) var coordinators = [RuntimeRefreshSpy]()
    private var handlers = [RefreshPublicationHandler]()
    private let firstStartGate: RuntimeStartGate?
    private let firstStopGate: RuntimeStopGate?
    private let firstManualGate: RuntimeStopGate?
    private let firstTerminationGate: RuntimeStopGate?

    init(
        firstStartGate: RuntimeStartGate?,
        firstStopGate: RuntimeStopGate?,
        firstManualGate: RuntimeStopGate?,
        firstTerminationGate: RuntimeStopGate?
    ) {
        self.firstStartGate = firstStartGate
        self.firstStopGate = firstStopGate
        self.firstManualGate = firstManualGate
        self.firstTerminationGate = firstTerminationGate
    }

    func makeCoordinator(
        configuration: ApplicationRefreshConfiguration,
        publicationHandler: @escaping RefreshPublicationHandler
    ) -> any ApplicationRefreshCoordinating {
        let coordinator = RuntimeRefreshSpy(
            startGate: coordinators.isEmpty ? firstStartGate : nil,
            stopGate: coordinators.isEmpty ? firstStopGate : nil,
            manualGate: coordinators.isEmpty ? firstManualGate : nil,
            terminationGate: coordinators.isEmpty ? firstTerminationGate : nil
        )
        configurations.append(configuration)
        coordinators.append(coordinator)
        handlers.append(publicationHandler)
        return coordinator
    }

    func emit(_ publication: RefreshPublication, from index: Int) async {
        handlers[index](publication)
    }
}

private actor RuntimePreferencesLoader: ApplicationPreferencesLoading {
    private let preferences: AppPreferences

    init(preferences: AppPreferences = .default) {
        self.preferences = preferences
    }

    func load() -> AppPreferences {
        preferences
    }
}

private actor RuntimePreferencesGate: ApplicationPreferencesLoading {
    private let preferences: AppPreferences
    private var continuation: CheckedContinuation<Void, Never>?
    private(set) var hasStarted = false
    private var isReleased = false

    init(preferences: AppPreferences) {
        self.preferences = preferences
    }

    func load() async -> AppPreferences {
        hasStarted = true
        guard !isReleased else {
            return preferences
        }
        await withCheckedContinuation { continuation in
            self.continuation = continuation
        }
        return preferences
    }

    func resume() {
        isReleased = true
        continuation?.resume()
        continuation = nil
    }
}

private actor RuntimeStopGate {
    private(set) var hasStarted = false
    private var continuation: CheckedContinuation<Void, Never>?
    private var isReleased = false

    func wait() async {
        hasStarted = true
        guard !isReleased else {
            return
        }
        await withCheckedContinuation { continuation in
            self.continuation = continuation
        }
    }

    func resume() {
        isReleased = true
        continuation?.resume()
        continuation = nil
    }
}

private actor RuntimeStartGate {
    private(set) var hasStarted = false
    private var continuation: CheckedContinuation<Void, Never>?

    func wait() async {
        hasStarted = true
        await withCheckedContinuation { continuation in
            self.continuation = continuation
        }
    }

    func resume() {
        continuation?.resume()
        continuation = nil
    }
}

@MainActor
private final class RuntimeWorkspaceSpy: CodexApplicationWorkspacing {
    private let storedApplicationURL: URL? = URL(
        fileURLWithPath: "/Synthetic/Codex.app",
        isDirectory: true
    )
    private(set) var applicationURLReadCount = 0
    private(set) var openCount = 0

    var applicationURL: URL? {
        applicationURLReadCount += 1
        return storedApplicationURL
    }

    func openCodexApplication() {
        openCount += 1
    }
}

@MainActor
private final class RuntimeTerminatorSpy: ApplicationTerminating {
    private(set) var terminationCount = 0

    func terminate() {
        terminationCount += 1
    }
}

@MainActor
private func waitForRuntimeCondition(
    _ condition: @escaping @MainActor () async -> Bool
) async throws {
    for _ in 0..<200 {
        if await condition() {
            return
        }
        await Task.yield()
    }
    throw TestFailure(description: "Timed out waiting for runtime condition")
}

private func runtimePublication(usedPercent: Double) throws -> RefreshPublication {
    guard let window = QuotaWindow(
        slot: .primary,
        usedPercent: usedPercent,
        windowDurationMinutes: 300,
        resetUnixSeconds: 1_900_003_600
    ) else {
        throw TestFailure(description: "Expected synthetic quota")
    }
    let capturedAt = Date(timeIntervalSince1970: 1_900_000_000)
    let product = RefreshProductResult(
        usageState: .value(
            ProductQuotaValue(capturedAt: capturedAt, quotaWindows: [window]),
            freshness: .fresh
        ),
        rateLimits: ProductRateLimits(state: .available, windows: [window]),
        issue: nil,
        lastSuccessfulRefresh: capturedAt
    )
    return RefreshPublication(
        products: [.codex: product],
        lastSuccessfulRefresh: capturedAt,
        failure: nil,
        isRefreshing: false
    )
}
