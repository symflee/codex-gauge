import AppKit
import CodexGaugeAppKit
import CodexGaugeCore
import CodexGaugeProtocol
import CodexGaugeRefresh
import CodexGaugeSettings
import Darwin
import Foundation

@main
struct PerformanceCommand {
    @MainActor
    static func main() {
        let arguments = Array(CommandLine.arguments.dropFirst())
        if arguments == ["--help"] {
            print(MeasurementOptions.usage)
            return
        }
        let options: MeasurementOptions
        do {
            options = try MeasurementOptions(arguments: arguments)
        } catch {
            // Do not echo arguments, which could accidentally contain a private path.
            print("{\"event\":\"error\",\"reason\":\"invalid_arguments\"}")
            exit(64)
        }
        let application = NSApplication.shared
        application.setActivationPolicy(.accessory)
        let delegate = PerformanceApplication(options: options, application: application)
        application.delegate = delegate
        withExtendedLifetime(delegate) { application.run() }
        exit(delegate.exitCode)
    }
}

private struct InitialRecord: Encodable {
    let event = "initial"
    let metadata: MeasurementMetadata
    let resources: ResourceSnapshot
}

private struct BurstCheckpoint: Encodable {
    let elapsedSeconds: Double
    let burstActive: Bool
    let cooldownActive: Bool
    let sessions: SessionCounters
}

private struct MenuCheckpoint: Encodable {
    let resourcesBeforeFirstOpen: ResourceSnapshot
    let resourcesAfterFirstClose: ResourceSnapshot
    let resourcesAfterSecondClose: ResourceSnapshot
    let rowsBeforeFirstOpen: Int
    let rowsAfterFirstClose: Int
    let modelRequestsBeforeFirstOpen: Int
    let modelRequestsAfterFirstClose: Int
    let modelRequestsAfterSecondClose: Int
    let unchangedNativeItems: Bool
    let trackingCancellations: Int
}

private struct FinalRecord: Encodable {
    let event = "final"
    let metadata: MeasurementMetadata
    let completionReason: String
    let scenarioCompleted: Bool
    let timingValidity: MeasurementTimingValidity
    let timingIncludingCleanup: MeasurementTimingValidity
    let resourcesBeforeCleanup: ResourceSnapshot
    let resourcesAfterCleanup: ResourceSnapshot
    let measurement: ResourceDelta
    let measurementIncludingCleanup: ResourceDelta
    let sessionsBeforeCleanup: SessionCounters
    let sessionsAfterCleanup: SessionCounters
    let presentation: PresentationCounters
    let burstCheckpoint: BurstCheckpoint?
    let menuCheckpoint: MenuCheckpoint?
    let burstActiveBeforeCleanup: Bool
    let cooldownActiveBeforeCleanup: Bool
    let cleanupConfirmed: Bool
}

@MainActor
private final class PerformanceApplication: NSObject, NSApplicationDelegate {
    private let options: MeasurementOptions
    private let application: NSApplication
    private let metadata: MeasurementMetadata
    private let measurements = PresentationMeasurements()
    private let presentationAdapter = RefreshPresentationAdapter()
    private lazy var menuBuilder = QuotaDetailsMenuModelBuilder.bundled(language: .english)
    private var menuCache = QuotaDetailsMenuModelCache()
    private let preference: DisplayPreference
    private var startedAt = ContinuousClock().now
    private var awakeStartedAt = SuspendingClock().now
    private var initialResources: ResourceSnapshot?
    private var endTimer: Timer?
    private var signalSources: [DispatchSourceSignal] = []
    private var startupTask: Task<Void, Never>?
    private var scenarioTask: Task<Void, Never>?
    private var manualTask: Task<Void, Never>?
    private var deadlineTask: Task<Void, Never>?
    private var shutdownTask: Task<Void, Never>?
    private var isFinishing = false
    private var completed = false
    private var diagnosticConfigured = false
    private var provider: MeasuredSessionProvider?
    private var coordinator: RefreshCoordinator?
    private var statusItem: NSStatusItem?
    private var statusController: StatusItemController?
    private var menuController: StatusMenuController?
    private var diagnosticMenu: NSMenu?
    private var menuRuntime: StatusMenuRuntimeAdapter?
    private var currentMenuInput: QuotaDetailsMenuInput?
    private var deadlineScheduler: QuotaResetRefreshScheduler?
    private var settingsRuntime: SettingsWindowRuntimeAdapter?
    private var settingsSuite: String?
    private var settingsGraphs: [WeakSettingsGraph] = []
    private var latestPublication = RefreshPublication.initial
    private var latestAcceptedAt: Date?
    private var discoveredQuotaIDs = Set<QuotaSelectionID>()
    private var burstCheckpoint: BurstCheckpoint?
    private var menuCheckpoint: MenuCheckpoint?
    private var menuTrackingCancellations = 0
    private(set) var exitCode: Int32 = 1

    init(options: MeasurementOptions, application: NSApplication) {
        self.options = options
        self.application = application
        metadata = MeasurementMetadata(options: options)
        if options.mode == .rotation {
            preference = DisplayPreference(productMode: .codex, quotaSelection: .manual([
                QuotaSelectionID(product: .codex, rawDurationMinutes: 300),
                QuotaSelectionID(product: .codex, rawDurationMinutes: 10_080)
            ]))
        } else {
            preference = .default
        }
        super.init()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        startedAt = ContinuousClock().now
        awakeStartedAt = SuspendingClock().now
        initialResources = .capture()
        writeMeasurement(InitialRecord(metadata: metadata, resources: initialResources!))
        installShutdownTriggers()
        switch options.mode {
        case .empty:
            return
        case .native:
            configureNativeDiagnostic()
            return
        case .badge:
            configureBadgeDiagnostic()
            return
        case .menuShell, .menuAttached:
            configureEmptyMenuDiagnostic(attached: options.mode == .menuAttached)
            return
        case .model, .legacyModel:
            configureModelDiagnostic()
            return
        default:
            break
        }
        startupTask = Task { [weak self] in
            guard let self, !isFinishing else { return }
            if options.mode != .engine { configurePresentation() }
            let provider = MeasuredSessionProvider(mode: options.mode)
            self.provider = provider
            let coordinator = RefreshCoordinator(
                provider: provider,
                profile: .balanced,
                lowPowerModeEnabled: false,
                displayPreference: preference,
                publicationHandler: { [weak self] publication in self?.receive(publication) }
            )
            self.coordinator = coordinator
            if options.mode == .settings { configureSettings() }
            await coordinator.start()
            guard !Task.isCancelled, !isFinishing else { return }
            if options.mode == .settings { beginSettingsScenario() }
        }
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        if completed { return .terminateNow }
        requestShutdown(reason: "application_termination")
        return .terminateCancel
    }

    private func installShutdownTriggers() {
        let timer = Timer(
            timeInterval: Double(options.duration), target: self,
            selector: #selector(durationElapsed), userInfo: nil, repeats: false
        )
        timer.tolerance = 0.1
        endTimer = timer
        RunLoop.main.add(timer, forMode: .common)
        for number in [SIGINT, SIGTERM] {
            signal(number, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: number, queue: .main)
            source.setEventHandler { [weak self] in
                MainActor.assumeIsolated { self?.requestShutdown(reason: "signal") }
            }
            source.resume()
            signalSources.append(source)
        }
    }

    @objc private func durationElapsed() { requestShutdown(reason: "duration_elapsed") }

    private func configureNativeDiagnostic() {
        // Deliberately bypass every product presenter/renderer and leave AppKit's
        // default empty button untouched. This is not an alternative baseline.
        let item = NSStatusBar.system.statusItem(withLength: 48)
        statusItem = item
        diagnosticConfigured = item.button != nil
    }

    private func configureBadgeDiagnostic() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem = item
        let system = SystemStatusItemPresenter(statusItem: item)
        let controller = StatusItemController(
            presenter: MeasuredStatusPresenter(system: system, measurements: measurements),
            renderer: MeasuredStatusRenderer(measurements: measurements),
            scheduler: MeasuredRotationScheduler(measurements: measurements)
        )
        statusController = controller
        // Exercise the production image cache, text, width prototypes and settled
        // appearance path once, without constructing a menu, provider or date formatter.
        controller.setFrames([.single(DisplayQuota(
            identifier: QuotaSelectionID(product: .codex, rawDurationMinutes: 300),
            value: .fresh(83)
        ))])
        diagnosticConfigured = item.button?.image != nil
    }

    private func configureEmptyMenuDiagnostic(attached: Bool) {
        configureBadgeDiagnostic()
        let menu = NSMenu()
        diagnosticMenu = menu
        if attached { statusItem?.menu = menu }
        diagnosticConfigured = diagnosticConfigured && menu.numberOfItems == 0
            && (attached ? statusItem?.menu === menu : statusItem?.menu == nil)
    }

    private func configureModelDiagnostic() {
        configureBadgeDiagnostic()
        let capturedAt = Date()
        let windows = [
            QuotaWindow(slot: .primary, usedPercent: 17, windowDurationMinutes: 300)!,
            QuotaWindow(slot: .secondary, usedPercent: 29, windowDurationMinutes: 10_080)!
        ]
        // Match idle's synthetic publication, including its success timestamp, so
        // the actual menu builder exercises Date.FormatStyle and retains its cache.
        latestPublication = RefreshPublication(
            products: [
                .codex: RefreshProductResult(
                    usageState: .value(
                        ProductQuotaValue(capturedAt: capturedAt, quotaWindows: windows),
                        freshness: .fresh
                    ),
                    rateLimits: ProductRateLimits(state: .available, windows: windows),
                    issue: nil,
                    lastSuccessfulRefresh: capturedAt
                ),
                .spark: RefreshProductResult(
                    usageState: .unavailable,
                    rateLimits: ProductRateLimits(state: .unavailable, windows: []),
                    issue: .unavailable,
                    lastSuccessfulRefresh: nil
                )
            ],
            lastSuccessfulRefresh: capturedAt,
            lastAcceptedRateLimitResponse: capturedAt,
            failure: nil,
            isRefreshing: false
        )
        let presentation = presentationAdapter.makePresentation(
            publication: latestPublication, preference: preference,
            canOpenCodexApplication: false, now: capturedAt
        )
        let builder: QuotaDetailsMenuModelBuilder
        if options.mode == .legacyModel {
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US")
            formatter.dateStyle = .medium
            formatter.timeStyle = .short
            builder = QuotaDetailsMenuModelBuilder(
                localization: .bundled(language: .english),
                dateFormatter: QuotaMenuDateFormatter { formatter.string(from: $0) }
            )
        } else {
            builder = menuBuilder
        }
        let model = menuCache.build(presentation.menuInput, using: builder)
        diagnosticConfigured = diagnosticConfigured && !model.productSections.isEmpty
        // Do not call present(_:): that path also owns the native menu/deadlines.
    }

    private func configurePresentation() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem = item
        let system = SystemStatusItemPresenter(statusItem: item)
        let controller = StatusItemController(
            presenter: MeasuredStatusPresenter(system: system, measurements: measurements),
            renderer: MeasuredStatusRenderer(measurements: measurements),
            scheduler: MeasuredRotationScheduler(measurements: measurements)
        )
        statusController = controller
        menuController = StatusMenuController(
            presenter: system, statusItemController: controller,
            actions: StatusMenuActions(
                refresh: {}, openCodex: {}, selectCodex: {}, checkForUpdates: {}, settings: {},
                quit: { [weak self] in self?.requestShutdown(reason: "menu_quit") }
            )
        )
        if let menuController { menuRuntime = StatusMenuRuntimeAdapter(controller: menuController) }
        deadlineScheduler = QuotaResetRefreshScheduler { [weak self] reason in
            guard let self, !isFinishing else { return }
            if reason == .validityExpired {
                present(latestPublication)
            } else if deadlineTask == nil {
                deadlineTask = Task { [weak self] in
                    guard let self else { return }
                    await coordinator?.refreshAfterQuotaReset()
                    deadlineTask = nil
                }
            }
        }
        present(.initial)
    }

    private func receive(_ publication: RefreshPublication) {
        guard !isFinishing else { return }
        measurements.counters.publications += 1
        latestPublication = publication
        if options.mode != .engine { present(publication) }
        guard let accepted = publication.lastAcceptedRateLimitResponse,
              accepted != latestAcceptedAt else { return }
        latestAcceptedAt = accepted
        measurements.counters.acceptedResponses += 1
        if options.mode == .menu {
            if measurements.counters.acceptedResponses == 1 { beginMenuScenario() }
            return
        }
        guard options.mode == .burst else { return }
        if measurements.counters.acceptedResponses == 1 {
            // One prompt manual read supplies growth after startup established the baseline.
            manualTask = Task { [weak self] in
                guard let self else { return }
                await coordinator?.refreshManually()
            }
        } else if measurements.counters.acceptedResponses == 2 {
            // Observe actual expiry/cooldown once, after 300 real seconds. No accelerated clock.
            scenarioTask = Task { [weak self] in
                do { try await ContinuousClock().sleep(for: .seconds(310)) } catch { return }
                guard let self, !isFinishing, let coordinator, let provider else { return }
                let state = await coordinator.state
                burstCheckpoint = BurstCheckpoint(
                    elapsedSeconds: elapsedSeconds(since: startedAt),
                    burstActive: state.burstDeadline != nil,
                    cooldownActive: Self.cooldownActive(state),
                    sessions: await provider.snapshot()
                )
            }
        }
    }

    private func present(_ publication: RefreshPublication) {
        let presentation = presentationAdapter.makePresentation(
            publication: publication, preference: preference,
            canOpenCodexApplication: false, now: Date()
        )
        statusController?.setFrames(presentation.frames)
        currentMenuInput = presentation.menuInput
        menuRuntime?.updateDeferred { [weak self] in
            guard let self, !isFinishing, let currentMenuInput else { return nil }
            measurements.counters.menuModelRequests += 1
            return menuCache.build(currentMenuInput.replacingCurrentDate(Date()), using: menuBuilder)
        }
        discoveredQuotaIDs = presentation.discoveredQuotaIDs
        settingsRuntime?.updateDiscoveredQuotaIDs(discoveredQuotaIDs)
        settingsRuntime?.updateConnectionStatus(publication.failure == nil ? .connected : .processFailure)
        deadlineScheduler?.publish(productStates: publication.products.mapValues(\.usageState))
    }

    private func beginMenuScenario() {
        scenarioTask = Task { @MainActor [weak self] in
            do { try await ContinuousClock().sleep(for: .milliseconds(200)) } catch { return }
            guard let self, !isFinishing, let menu = statusItem?.menu,
                  let button = statusItem?.button else { return }
            let before = ResourceSnapshot.capture()
            let rowsBefore = menu.numberOfItems
            let requestsBefore = measurements.counters.menuModelRequests
            trackMenuOnce(menu, at: button)
            let afterFirst = ResourceSnapshot.capture()
            let firstItems = menu.items
            let requestsAfterFirst = measurements.counters.menuModelRequests
            do { try await ContinuousClock().sleep(for: .milliseconds(200)) } catch { return }
            guard !isFinishing else { return }
            trackMenuOnce(menu, at: button)
            menuCheckpoint = MenuCheckpoint(
                resourcesBeforeFirstOpen: before,
                resourcesAfterFirstClose: afterFirst,
                resourcesAfterSecondClose: ResourceSnapshot.capture(),
                rowsBeforeFirstOpen: rowsBefore,
                rowsAfterFirstClose: firstItems.count,
                modelRequestsBeforeFirstOpen: requestsBefore,
                modelRequestsAfterFirstClose: requestsAfterFirst,
                modelRequestsAfterSecondClose: measurements.counters.menuModelRequests,
                unchangedNativeItems: firstItems.count == menu.numberOfItems
                    && zip(firstItems, menu.items).allSatisfy { pair in pair.0 === pair.1 },
                trackingCancellations: menuTrackingCancellations
            )
        }
    }

    private func trackMenuOnce(_ menu: NSMenu, at button: NSStatusBarButton) {
        // This runs AppKit's real tracking loop, including menuNeedsUpdate. The
        // common-mode timer only cancels our own menu and cannot trigger an action.
        let cancellation = Timer(timeInterval: 0.2, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.menuTrackingCancellations += 1
                self?.statusItem?.menu?.cancelTracking()
            }
        }
        RunLoop.main.add(cancellation, forMode: .common)
        defer { cancellation.invalidate() }
        menu.popUp(positioning: nil, at: NSPoint(x: button.bounds.minX, y: button.bounds.minY), in: button)
    }

    private func configureSettings() {
        let suite = "io.github.symflee.codex-gauge.performance.\(UUID().uuidString)"
        settingsSuite = suite
        guard let defaults = UserDefaults(suiteName: suite) else { return }
        let repository = AppPreferencesRepository(userDefaults: defaults, defaultLanguage: .english)
        let coordinator = SettingsWindowCoordinator(
            repository: repository,
            discoveredQuotaProvider: { [weak self] in self?.discoveredQuotaIDs ?? [] },
            foregroundPresenter: SettingsWindowForegroundPresenter(
                applicationActivator: NSApplicationSettingsWindowActivator(application: application)
            ),
            // The initializer's default diagnostics are metadata-only. Supplying this
            // explicitly prevents future production diagnostics from entering the harness.
            connectionDiagnosticsProvider: { _, status in
                ConnectionDiagnosticsSnapshot(
                    path: nil, cliVersion: nil, cliVersionIssue: nil, connectionStatus: status
                )
            },
            connectionStatusProvider: { .connected }
        )
        settingsRuntime = SettingsWindowRuntimeAdapter(coordinator: coordinator)
    }

    private func beginSettingsScenario() {
        scenarioTask = Task { [weak self] in
            guard let self, let runtime = settingsRuntime else { return }
            for _ in 0..<10 {
                guard !Task.isCancelled, !isFinishing, await runtime.showSettings() else { return }
                measurements.counters.settingsOpened += 1
                do { try await ContinuousClock().sleep(for: .milliseconds(500)) } catch { return }
                autoreleasepool {
                    if let controller = runtime.coordinator.activeWindowController {
                        settingsGraphs.append(WeakSettingsGraph(controller: controller))
                        controller.close()
                        measurements.counters.settingsClosed += 1
                    }
                }
                // A bounded scenario delay gives AppKit an event-loop turn to drain
                // temporary window references. It is not a lifetime polling loop.
                do { try await ContinuousClock().sleep(for: .milliseconds(500)) } catch { return }
            }
            measurements.counters.settingsGraphsReleased = settingsGraphs.filter(\.isReleased).count
        }
    }

    private func requestShutdown(reason: String) {
        guard !isFinishing else { return }
        isFinishing = true
        endTimer?.invalidate()
        endTimer = nil
        shutdownTask = Task { [weak self] in
            guard let self else { return }
            await finish(reason: reason)
        }
    }

    private func finish(reason: String) async {
        let measurementElapsed = elapsedSeconds(since: startedAt)
        let timingValidity = MeasurementTimingValidity(
            requestedDuration: options.duration,
            continuousElapsed: measurementElapsed,
            awakeElapsed: awakeElapsedSeconds(since: awakeStartedAt)
        )
        let measurementEnd = ResourceSnapshot.capture()
        let beforeState = await coordinator?.state
        let beforeSessions = await provider?.snapshot() ?? SessionCounters()
        startupTask?.cancel()
        scenarioTask?.cancel()
        manualTask?.cancel()
        deadlineTask?.cancel()
        deadlineScheduler?.stop()
        await startupTask?.value
        await scenarioTask?.value
        await manualTask?.value
        await deadlineTask?.value
        await coordinator?.stop()
        await coordinator?.waitForTermination()
        // Coordinator.stop performs a bounded attempt. The harness additionally waits
        // for every owned lease to confirm termination before child CPU is finalized.
        await provider?.shutdown()
        await settingsRuntime?.shutdown()
        settingsRuntime = nil
        if let settingsSuite {
            UserDefaults(suiteName: settingsSuite)?.removePersistentDomain(forName: settingsSuite)
        }
        statusController?.setFrames([])
        if diagnosticMenu != nil {
            statusItem?.menu = nil
            diagnosticMenu = nil
        }
        menuRuntime = nil
        menuController = nil
        statusController = nil
        if let statusItem { NSStatusBar.system.removeStatusItem(statusItem) }
        statusItem = nil
        coordinator = nil
        deadlineScheduler = nil
        startupTask = nil
        scenarioTask = nil
        manualTask = nil
        deadlineTask = nil
        // Let any deferred AppKit releases finish before final weak-reference checks.
        try? await ContinuousClock().sleep(for: .milliseconds(100))
        measurements.counters.settingsGraphsReleased = settingsGraphs.filter(\.isReleased).count
        let afterSessions = await provider?.snapshot() ?? SessionCounters()
        let cleanupConfirmed = afterSessions.activeLeases == 0 && afterSessions.activeReads == 0
        let resourcesAfterCleanup = ResourceSnapshot.capture()
        let timingIncludingCleanup = MeasurementTimingValidity(
            requestedDuration: options.duration,
            continuousElapsed: elapsedSeconds(since: startedAt),
            awakeElapsed: awakeElapsedSeconds(since: awakeStartedAt)
        )
        let scenarioCompleted = timingValidity.isValid && timingIncludingCleanup.isValid
            && scenarioSucceeded(reason: reason, sessions: afterSessions)
        if let initialResources {
            writeMeasurement(FinalRecord(
                metadata: metadata, completionReason: reason,
                scenarioCompleted: scenarioCompleted,
                timingValidity: timingValidity, timingIncludingCleanup: timingIncludingCleanup,
                resourcesBeforeCleanup: measurementEnd, resourcesAfterCleanup: resourcesAfterCleanup,
                measurement: ResourceDelta(
                    initial: initialResources, final: measurementEnd, elapsed: measurementElapsed
                ),
                measurementIncludingCleanup: ResourceDelta(
                    initial: initialResources, final: resourcesAfterCleanup,
                    elapsed: timingIncludingCleanup.continuousElapsedSeconds
                ),
                sessionsBeforeCleanup: beforeSessions, sessionsAfterCleanup: afterSessions,
                presentation: measurements.counters, burstCheckpoint: burstCheckpoint,
                menuCheckpoint: menuCheckpoint,
                burstActiveBeforeCleanup: beforeState?.burstDeadline != nil,
                cooldownActiveBeforeCleanup: beforeState.map(Self.cooldownActive) ?? false,
                cleanupConfirmed: cleanupConfirmed
            ))
        }
        completed = true
        exitCode = scenarioCompleted && cleanupConfirmed ? 0 : 2
        signalSources.forEach { $0.cancel() }
        signalSources.removeAll()
        application.stop(nil)
        // stop() alone can leave run() waiting for its next event in a menu-bar app.
        if let event = NSEvent.otherEvent(
            with: .applicationDefined, location: .zero, modifierFlags: [], timestamp: 0,
            windowNumber: 0, context: nil, subtype: 0, data1: 0, data2: 0
        ) {
            application.postEvent(event, atStart: true)
        }
    }

    private func scenarioSucceeded(reason: String, sessions: SessionCounters) -> Bool {
        guard reason == "duration_elapsed" else { return false }
        if options.mode == .empty { return true }
        if options.mode == .engine {
            return sessions.successfulReads > 0 && sessions.failedReads == 0
                && sessions.maximumActiveReads <= 1 && sessions.maximumActiveLeases <= 1
                && measurements.counters.acceptedResponses > 0
                && measurements.counters.renderCalls == 0 && measurements.counters.presentCalls == 0
                && measurements.counters.widthChanges == 0 && measurements.counters.menuModelRequests == 0
                && measurements.counters.settingsOpened == 0 && measurements.counters.rotationTicks == 0
        }
        if metadata.diagnosticOnly {
            guard diagnosticConfigured, sessions.created == 0,
                  measurements.counters.publications == 0,
                  measurements.counters.settingsOpened == 0,
                  measurements.counters.rotationTicks == 0 else { return false }
            if options.mode == .native {
                return measurements.counters.renderCalls == 0
                    && measurements.counters.presentCalls == 0
            }
            return measurements.counters.renderCalls > 0
                && measurements.counters.presentCalls > 0
        }
        guard sessions.successfulReads > 0, sessions.failedReads == 0,
              sessions.maximumActiveReads <= 1, sessions.maximumActiveLeases <= 1 else { return false }
        switch options.mode {
        case .burst:
            guard let checkpoint = burstCheckpoint else { return false }
            return !checkpoint.burstActive && checkpoint.cooldownActive
                && checkpoint.sessions.activeLeases == 0 && checkpoint.sessions.successfulReads >= 3
        case .rotation:
            return measurements.counters.rotationTicks > 0
        case .settings:
            return measurements.counters.settingsOpened == 10
                && measurements.counters.settingsClosed == 10
                && measurements.counters.settingsGraphsReleased == 10
        case .menu:
            guard let checkpoint = menuCheckpoint else { return false }
            return checkpoint.rowsBeforeFirstOpen == 0 && checkpoint.rowsAfterFirstClose > 0
                && checkpoint.modelRequestsBeforeFirstOpen == 0
                && checkpoint.modelRequestsAfterFirstClose == 1
                && checkpoint.modelRequestsAfterSecondClose == 1
                && checkpoint.unchangedNativeItems && checkpoint.trackingCancellations == 2
        default:
            return true
        }
    }

    private static func cooldownActive(_ state: RefreshState) -> Bool {
        guard let deadline = state.burstCooldownDeadline else { return false }
        return deadline > ContinuousClock().now
    }
}
