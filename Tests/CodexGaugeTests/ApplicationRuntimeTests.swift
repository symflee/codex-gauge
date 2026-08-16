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
        applicationRuntimeDefersInitialWakeBaselineTest(),
        applicationRuntimePublishesOnePresentationTransactionTest(),
        applicationRuntimeRoutesMenuAndSettingsTest(),
        applicationRuntimeReplacesRefreshGenerationTest(),
        applicationRuntimeReplacesAcrossSystemTransitionTest(),
        applicationRuntimeOrdersOverlappingResumeTest(),
        applicationRuntimeHandlesPresentationOnlyDeadlinesTest(),
        applicationRuntimeRefreshesQuotaResetTest(),
        applicationRuntimeSharesShutdownDrainTest(),
        applicationRuntimeDrainsReplacementOnShutdownTest()
    ]
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

    try expect(runtime.startCount == 1, "Expected one retained runtime start")
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
            productMode: .spark,
            quotaSelection: .automatic
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
    try expect(displayedQuota.identifier.product == .spark, "Expected loaded product mode")
    let events = await harness.refreshBuilder.coordinators[0].events
    try expect(events == [.start], "Expected initial start")
    try expect(harness.launch.enabledValues == [true], "Expected login intent reconciliation")
    try expect(harness.startupRecorder.preferences == [preferences], "Expected post-start hook")
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
    try expect(harness.menu.models.last?.productSections.count == 2, "Expected complete menu")
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
        productMode: .both,
        quotaSelection: .automatic
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
    try expect(harness.status.pauseValues[.sleeping] == true, "Expected sleep pause")
    harness.systemMonitor.emit(.sessionLocked)
    try expect(harness.status.pauseValues[.screenLocked] == true, "Expected lock pause")
    harness.systemMonitor.emit(.wake)
    try expect(harness.status.pauseValues[.sleeping] == false, "Expected wake unpause")
    try expect(harness.status.pauseValues[.screenLocked] == true, "Expected lock pause retained")
    await harness.coordinator.waitForPendingOperations()

    let suspendedEvents = await refresh.events
    try expect(
        suspendedEvents.filter { $0 == .suspend }.count == 1,
        "Expected one suspend"
    )
    try expect(!suspendedEvents.contains(.resume), "Expected lock to prevent resume")
    harness.deadlineScheduler.deadlineOnWake = .quotaReset
    harness.systemMonitor.emit(.sessionUnlocked)
    try expect(harness.status.pauseValues[.screenLocked] == false, "Expected unlock unpause")
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
    harness.assistiveMonitor.emit(AssistiveDisplayState(
        isVoiceOverEnabled: true,
        shouldReduceMotion: true
    ))
    await harness.coordinator.waitForPendingOperations()

    let finalEventCount = await refresh.events.count
    try expect(finalEventCount == eventCount, "Expected no provider request")
    try expect(
        harness.workspace.applicationURLReadCount == workspaceReadCount,
        "Expected no workspace lookup"
    )
    try expect(harness.status.presentedFrames.count == presentationCount + 1, "Expected rerender")
    try expect(harness.status.pauseValues[.voiceOver] == true, "Expected VoiceOver pause")
    try expect(harness.status.pauseValues[.reduceMotion] == true, "Expected motion pause")
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
        harness.status.presentedFrames.count == presentationCount + 1,
        "Expected reset boundary rerender"
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
    try expect(events.filter { $0 == .stop }.count == 1, "Expected one refresh stop")
    try expect(harness.settings.shutdownCount == 1, "Expected one settings shutdown")
    try expect(harness.systemMonitor.stopCount == 1, "Expected one monitor shutdown")
}

@MainActor
private final class RuntimeHarness {
    let status = RuntimeStatusSpy()
    let menu = RuntimeMenuSpy()
    let settings = RuntimeSettingsSpy()
    let systemMonitor = RuntimeSystemMonitorSpy(initialLowPowerMode: true)
    let assistiveMonitor = RuntimeAssistiveMonitorSpy()
    let deadlineScheduler = RuntimeDeadlineSchedulerSpy()
    let launch = RuntimeLaunchSpy()
    let refreshBuilder: RuntimeRefreshBuilderSpy
    let workspace = RuntimeWorkspaceSpy()
    let terminator = RuntimeTerminatorSpy()
    let startupRecorder = RuntimeStartupRecorder()
    let coordinator: CodexGaugeApplicationCoordinator

    init(
        preferencesLoader: any ApplicationPreferencesLoading = RuntimePreferencesLoader(),
        firstStopGate: RuntimeStopGate? = nil
    ) {
        refreshBuilder = RuntimeRefreshBuilderSpy(firstStopGate: firstStopGate)
        let scheduler = deadlineScheduler
        coordinator = CodexGaugeApplicationCoordinator(
            statusRuntime: status,
            menuRuntime: menu,
            settingsRuntime: settings,
            systemActivityMonitor: systemMonitor,
            assistiveDisplayMonitor: assistiveMonitor,
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
            now: { Date(timeIntervalSince1970: 1_900_000_000) },
            startupHook: { [startupRecorder] preferences in
                startupRecorder.preferences.append(preferences)
            }
        )
    }
}

@MainActor
private final class RuntimeStartupRecorder {
    var preferences = [AppPreferences]()
}

@MainActor
private final class RuntimeApplicationSpy: CodexGaugeApplicationRunning {
    private(set) var startCount = 0

    func start() {
        startCount += 1
    }
}

@MainActor
private final class RuntimeStatusSpy: ApplicationStatusRuntime {
    private(set) var presentedFrames = [[DisplayFrame]]()
    private(set) var pauseValues = [StatusRotationPauseReason: Bool]()

    func present(frames: [DisplayFrame]) {
        presentedFrames.append(frames)
    }

    func setRotationPaused(_ paused: Bool, for reason: StatusRotationPauseReason) {
        pauseValues[reason] = paused
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
private final class RuntimeSettingsSpy: ApplicationSettingsRuntime {
    private(set) var discoveredQuotaIDs = [Set<QuotaSelectionID>]()
    private(set) var connectionStatuses = [CodexConnectionStatus]()
    private(set) var selectionRequestCount = 0
    private(set) var showCount = 0
    private(set) var shutdownCount = 0

    func showSettings() async {
        showCount += 1
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

    func shutdown() async {
        shutdownCount += 1
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
private final class RuntimeAssistiveMonitorSpy: ApplicationAssistiveDisplayMonitoring {
    private var handler: (@MainActor @Sendable (AssistiveDisplayEvent) -> Void)?

    func start(handler: @escaping @MainActor @Sendable (AssistiveDisplayEvent) -> Void) {
        self.handler = handler
    }

    func stop() {
        handler = nil
    }

    func emit(_ state: AssistiveDisplayState) {
        handler?(.changed(state))
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

    func setEnabled(_ enabled: Bool) async throws -> LaunchAtLoginStatus {
        enabledValues.append(enabled)
        return enabled ? .enabled : .disabled
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
    private let stopGate: RuntimeStopGate?

    init(stopGate: RuntimeStopGate?) {
        self.stopGate = stopGate
    }

    func start() async {
        events.append(.start)
    }

    func refreshManually() async {
        events.append(.manualRefresh)
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
        events.append(.suspend)
    }

    func resumeAfterSystemWake() async {
        events.append(.resume)
    }

    func stop() async {
        events.append(.stop)
        await stopGate?.wait()
    }
}

@MainActor
private final class RuntimeRefreshBuilderSpy: ApplicationRefreshCoordinatorBuilding {
    private(set) var configurations = [ApplicationRefreshConfiguration]()
    private(set) var coordinators = [RuntimeRefreshSpy]()
    private var handlers = [RefreshPublicationHandler]()
    private let firstStopGate: RuntimeStopGate?

    init(firstStopGate: RuntimeStopGate?) {
        self.firstStopGate = firstStopGate
    }

    func makeCoordinator(
        configuration: ApplicationRefreshConfiguration,
        publicationHandler: @escaping RefreshPublicationHandler
    ) -> any ApplicationRefreshCoordinating {
        let coordinator = RuntimeRefreshSpy(
            stopGate: coordinators.isEmpty ? firstStopGate : nil
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
    func load() -> AppPreferences {
        .default
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
    guard let spark = RefreshPublication.initial.products[.spark] else {
        throw TestFailure(description: "Expected initial Spark state")
    }
    return RefreshPublication(
        products: [.codex: product, .spark: spark],
        lastSuccessfulRefresh: capturedAt,
        failure: nil,
        isRefreshing: false
    )
}
