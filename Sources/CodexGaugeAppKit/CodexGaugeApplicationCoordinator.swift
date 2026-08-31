import CodexGaugeCore
import CodexGaugeRefresh
import CodexGaugeSettings
import Foundation

@MainActor
public final class CodexGaugeApplicationCoordinator {
    public typealias StartupHook = @MainActor (AppPreferences) async -> Void

    @usableFromInline
    nonisolated static let noOpStartupHook: StartupHook = { _ in }

    public private(set) var publication = RefreshPublication.initial
    public private(set) var discoveredQuotaIDs = Set<QuotaSelectionID>()
    public private(set) var launchAtLoginState = LaunchAtLoginSettingsState(
        status: .disabled
    )

    private let statusRuntime: any ApplicationStatusRuntime
    private let menuRuntime: any ApplicationMenuRuntime
    private let settingsRuntime: any ApplicationSettingsRuntime
    private let systemActivityMonitor: any ApplicationSystemActivityMonitoring
    private let assistiveDisplayMonitor: any ApplicationAssistiveDisplayMonitoring
    private let deadlineSchedulerBuilder: ApplicationUsageDeadlineSchedulerBuilder
    private let launchAtLoginController: any ApplicationLaunchAtLoginControlling
    private let refreshCoordinatorBuilder: any ApplicationRefreshCoordinatorBuilding
    private let preferencesLoader: any ApplicationPreferencesLoading
    private let workspace: any CodexApplicationWorkspacing
    private let canOpenCodexApplication: Bool
    private let terminator: any ApplicationTerminating
    private let now: @MainActor () -> Date
    private let startupHook: StartupHook

    private let activityReducer = ApplicationActivityReducer()
    private let presentationAdapter = RefreshPresentationAdapter()
    private let connectionStatusResolver = ConnectionStatusResolver()

    private var menuModelBuilder: QuotaDetailsMenuModelBuilder
    private var preferences: AppPreferences
    private var pendingFormValues: SettingsFormValues?
    private var pendingSelectedExecutableURL: URL?
    private var activityState = ApplicationActivityState.active
    private var lowPowerModeEnabled = false
    private var refreshCoordinator: (any ApplicationRefreshCoordinating)?
    private var deadlineScheduler: (any ApplicationUsageDeadlineScheduling)?
    private var pendingOperation: Task<Void, Never>?
    private var shutdownTask: Task<Void, Never>?
    private var enqueuedOperationIdentifier: UInt64 = 0
    private var completedOperationIdentifier: UInt64 = 0
    private var refreshGeneration: UInt64 = 0
    private var activityCommandRevision: UInt64 = 0
    private var pendingInitialSystemResume = false
    private var hasLoadedPreferences = false
    private var hasReconciledLaunchAtLogin = false
    private var hasRunStartupHook = false
    private var isStarted = false
    private var isShuttingDown = false

    public init(
        statusRuntime: any ApplicationStatusRuntime,
        menuRuntime: any ApplicationMenuRuntime,
        settingsRuntime: any ApplicationSettingsRuntime,
        systemActivityMonitor: any ApplicationSystemActivityMonitoring,
        assistiveDisplayMonitor: any ApplicationAssistiveDisplayMonitoring,
        deadlineSchedulerBuilder: ApplicationUsageDeadlineSchedulerBuilder,
        launchAtLoginController: any ApplicationLaunchAtLoginControlling,
        refreshCoordinatorBuilder: any ApplicationRefreshCoordinatorBuilding,
        preferencesLoader: any ApplicationPreferencesLoading,
        workspace: any CodexApplicationWorkspacing,
        terminator: any ApplicationTerminating,
        initialLanguage: AppLanguage = PreferredAppLanguageResolver().resolve(
            preferredLanguages: Locale.preferredLanguages
        ),
        now: @escaping @MainActor () -> Date = { Date() },
        startupHook: @escaping StartupHook =
            CodexGaugeApplicationCoordinator.noOpStartupHook
    ) {
        self.statusRuntime = statusRuntime
        self.menuRuntime = menuRuntime
        self.settingsRuntime = settingsRuntime
        self.systemActivityMonitor = systemActivityMonitor
        self.assistiveDisplayMonitor = assistiveDisplayMonitor
        self.deadlineSchedulerBuilder = deadlineSchedulerBuilder
        self.launchAtLoginController = launchAtLoginController
        launchAtLoginState = LaunchAtLoginSettingsState(
            status: launchAtLoginController.currentStatus
        )
        self.refreshCoordinatorBuilder = refreshCoordinatorBuilder
        self.preferencesLoader = preferencesLoader
        self.workspace = workspace
        self.canOpenCodexApplication = workspace.applicationURL != nil
        self.terminator = terminator
        menuModelBuilder = .bundled(language: initialLanguage)
        preferences = AppPreferences(language: initialLanguage)
        self.now = now
        self.startupHook = startupHook
        statusRuntime.updateRenderingConfiguration(
            language: initialLanguage,
            statusGaugeAppearance: preferences.statusGaugeAppearance
        )
        settingsRuntime.updateLanguage(initialLanguage)
    }

    public var connectionStatus: CodexConnectionStatus {
        connectionStatusResolver.resolve(publication)
    }

    public var currentLaunchAtLoginState: LaunchAtLoginSettingsState {
        let currentStatus = launchAtLoginController.currentStatus
        guard currentStatus == launchAtLoginState.status else {
            return LaunchAtLoginSettingsState(status: currentStatus)
        }
        return launchAtLoginState
    }

    public func start() {
        guard !isStarted, !isShuttingDown else {
            return
        }
        isStarted = true
        presentCurrentPublication(publishDeadlines: false)
        publishLaunchAtLoginState()
        installDeadlineScheduler()
        startMonitors()
        enqueueOperation { coordinator in
            await coordinator.loadPreferencesAndStartRefresh()
        }
    }

    public func performMenuAction(_ action: QuotaMenuAction) {
        switch action {
        case .refresh:
            enqueueRefreshOperation { refresh in
                await refresh.refreshManually()
            }
        case .openCodex:
            workspace.openCodexApplication()
        case .selectCodex:
            settingsRuntime.requestExecutableSelection()
        case .settings:
            enqueueOperation { coordinator in
                _ = await coordinator.settingsRuntime.showSettings()
            }
        case .quit:
            terminator.terminate()
        }
    }

    public func settingsFormValuesDidChange(_ values: SettingsFormValues) {
        let previous = SettingsFormValues(preferences: preferences)
        guard values != previous else {
            return
        }
        if !hasLoadedPreferences {
            pendingFormValues = values
        }
        preferences = preferences.merging(values)
        applySettingsChanges(from: previous, to: values)
    }

    public func selectedExecutableDidChange(_ url: URL) {
        guard url.isFileURL, preferences.selectedExecutableURL != url else {
            return
        }
        preferences = preferences.replacingSelectedExecutableURL(url)
        if !hasLoadedPreferences {
            pendingSelectedExecutableURL = url
            return
        }
        replaceRefreshCoordinator()
    }

    public func openLaunchAtLoginApprovalSettings() {
        let currentState = currentLaunchAtLoginState
        guard currentState.showsSystemSettingsRecovery else {
            updateLaunchAtLoginState(
                status: currentState.status,
                failure: currentState.failure
            )
            return
        }
        _ = launchAtLoginController.openApprovalSettingsIfNeeded()
        refreshLaunchAtLoginStatus()
    }

    public func launchAtLoginIntentDidChange(_ enabled: Bool) {
        enqueueLaunchAtLoginChange(enabled)
    }

    public func refreshLaunchAtLoginStatus() {
        let currentState = currentLaunchAtLoginState
        updateLaunchAtLoginState(
            status: currentState.status,
            failure: currentState.failure
        )
    }

    public func waitForPendingOperations() async {
        while completedOperationIdentifier < enqueuedOperationIdentifier {
            let operation = pendingOperation
            await operation?.value
        }
    }

    public func shutdown() async {
        if let shutdownTask {
            await shutdownTask.value
            return
        }
        isShuttingDown = true
        refreshGeneration &+= 1
        systemActivityMonitor.stop()
        assistiveDisplayMonitor.stop()
        deadlineScheduler?.stop()
        deadlineScheduler = nil
        pendingOperation?.cancel()
        let initialRefresh = refreshCoordinator
        refreshCoordinator = nil
        let pendingOperation = pendingOperation
        let settingsRuntime = settingsRuntime
        let task = Task { @MainActor [weak self] in
            await initialRefresh?.stop()
            await pendingOperation?.value
            await initialRefresh?.stop()
            let lateRefresh = self?.refreshCoordinator
            self?.refreshCoordinator = nil
            await lateRefresh?.stop()
            await settingsRuntime.shutdown()
        }
        shutdownTask = task
        await task.value
    }

    private func installDeadlineScheduler() {
        deadlineScheduler = deadlineSchedulerBuilder.make { [weak self] reason in
            self?.usageDeadlineReached(reason)
        }
    }

    private func startMonitors() {
        systemActivityMonitor.start { [weak self] event in
            self?.systemActivityChanged(event)
        }
        assistiveDisplayMonitor.start { [weak self] event in
            self?.assistiveDisplayChanged(event)
        }
    }

    private func loadPreferencesAndStartRefresh() async {
        let loadedPreferences = await preferencesLoader.load()
        guard !isShuttingDown else {
            return
        }
        preferences = effectivePreferences(from: loadedPreferences)
        pendingFormValues = nil
        pendingSelectedExecutableURL = nil
        hasLoadedPreferences = true
        updateLanguage(preferences.language)
        presentCurrentPublication(publishDeadlines: false)
        await installAndStartRefreshCoordinator()
    }

    private func effectivePreferences(
        from loadedPreferences: AppPreferences
    ) -> AppPreferences {
        var result = loadedPreferences
        if let pendingFormValues {
            result = result.merging(pendingFormValues)
        }
        if let pendingSelectedExecutableURL {
            result = result.replacingSelectedExecutableURL(
                pendingSelectedExecutableURL
            )
        }
        return result
    }

    private func installAndStartRefreshCoordinator() async {
        refreshGeneration &+= 1
        let generation = refreshGeneration
        let refresh = makeRefreshCoordinator(generation: generation)
        refreshCoordinator = refresh
        await startInitialRefresh(refresh)
        await finishStartupIfNeeded(generation: generation)
    }

    private func startInitialRefresh(
        _ refresh: any ApplicationRefreshCoordinating
    ) async {
        let shouldResume = pendingInitialSystemResume && !activityState.isSuspended
        pendingInitialSystemResume = false
        guard shouldResume else {
            await start(refresh)
            return
        }
        await refresh.suspend()
        await refresh.resumeAfterSystemWake()
    }

    private func finishStartupIfNeeded(generation: UInt64) async {
        guard generation == refreshGeneration, !isShuttingDown else {
            return
        }
        await reconcileLaunchAtLoginIfNeeded()
        guard generation == refreshGeneration, !isShuttingDown else {
            return
        }
        guard !hasRunStartupHook else {
            return
        }
        hasRunStartupHook = true
        await startupHook(preferences)
    }

    private func reconcileLaunchAtLoginIfNeeded() async {
        guard !hasReconciledLaunchAtLogin else {
            return
        }
        hasReconciledLaunchAtLogin = true
        await applyLaunchAtLoginIntent(preferences.launchAtLoginIntent)
    }

    private func makeRefreshCoordinator(
        generation: UInt64
    ) -> any ApplicationRefreshCoordinating {
        let configuration = ApplicationRefreshConfiguration(
            preferences: preferences,
            lowPowerModeEnabled: lowPowerModeEnabled
        )
        return refreshCoordinatorBuilder.makeCoordinator(
            configuration: configuration
        ) { [weak self] publication in
            self?.receive(publication, from: generation)
        }
    }

    private func start(_ refresh: any ApplicationRefreshCoordinating) async {
        guard activityState.isSuspended else {
            await refresh.start()
            return
        }
        await refresh.suspend()
    }

    private func receive(
        _ publication: RefreshPublication,
        from generation: UInt64
    ) {
        guard generation == refreshGeneration, !isShuttingDown else {
            return
        }
        self.publication = publication
        presentCurrentPublication(publishDeadlines: true)
    }

    private func presentCurrentPublication(publishDeadlines: Bool) {
        let presentation = presentationAdapter.makePresentation(
            publication: publication,
            preference: preferences.displayPreference,
            canOpenCodexApplication: canOpenCodexApplication,
            now: now()
        )
        statusRuntime.present(frames: presentation.frames)
        menuRuntime.update(menuModelBuilder.build(presentation.menuInput))
        discoveredQuotaIDs = presentation.discoveredQuotaIDs
        settingsRuntime.updateDiscoveredQuotaIDs(discoveredQuotaIDs)
        settingsRuntime.updateConnectionStatus(connectionStatus)
        guard publishDeadlines else {
            return
        }
        deadlineScheduler?.publish(
            productStates: presentation.menuInput.productStates
        )
    }

    private func applySettingsChanges(
        from previous: SettingsFormValues,
        to current: SettingsFormValues
    ) {
        let displayChanged = previous.displayPreference != current.displayPreference
        let languageChanged = previous.language != current.language
        let appearanceChanged = previous.statusGaugeAppearance
            != current.statusGaugeAppearance
        if languageChanged {
            updateLanguage(current.language)
        }
        if appearanceChanged, !languageChanged {
            updateStatusRenderingConfiguration()
        }
        if displayChanged || languageChanged || appearanceChanged {
            presentCurrentPublication(publishDeadlines: false)
        }
        if displayChanged {
            enqueueRefreshOperation { refresh in
                await refresh.updateDisplayPreference(current.displayPreference)
            }
        }
        if previous.refreshProfile != current.refreshProfile {
            enqueueRefreshOperation { refresh in
                await refresh.updateProfile(current.refreshProfile)
            }
        }
    }

    private func updateLanguage(_ language: AppLanguage) {
        menuModelBuilder = .bundled(language: language)
        updateStatusRenderingConfiguration()
        settingsRuntime.updateLanguage(language)
    }

    private func updateStatusRenderingConfiguration() {
        statusRuntime.updateRenderingConfiguration(
            language: preferences.language,
            statusGaugeAppearance: preferences.statusGaugeAppearance
        )
    }

    private func enqueueLaunchAtLoginChange(_ enabled: Bool) {
        enqueueOperation { coordinator in
            await coordinator.applyLaunchAtLoginIntent(enabled)
        }
    }

    private func applyLaunchAtLoginIntent(_ enabled: Bool) async {
        do {
            let status = try await launchAtLoginController.setEnabled(enabled)
            updateLaunchAtLoginState(status: status)
        } catch {
            updateLaunchAtLoginState(
                status: launchAtLoginController.currentStatus,
                failure: error
            )
        }
    }

    private func updateLaunchAtLoginState(
        status: LaunchAtLoginStatus,
        failure: LaunchAtLoginError? = nil
    ) {
        launchAtLoginState = LaunchAtLoginSettingsState(
            status: status,
            failure: failure
        )
        publishLaunchAtLoginState()
    }

    private func publishLaunchAtLoginState() {
        settingsRuntime.updateLaunchAtLoginState(launchAtLoginState)
    }

    private func replaceRefreshCoordinator() {
        refreshGeneration &+= 1
        let generation = refreshGeneration
        let activityRevision = activityCommandRevision
        publication = .initial
        presentCurrentPublication(publishDeadlines: true)
        enqueueOperation { coordinator in
            await coordinator.replaceRefreshCoordinator(
                generation: generation,
                activityRevision: activityRevision
            )
        }
    }

    private func replaceRefreshCoordinator(
        generation: UInt64,
        activityRevision: UInt64
    ) async {
        guard generation == refreshGeneration, !isShuttingDown else {
            return
        }
        let previous = refreshCoordinator
        refreshCoordinator = nil
        let preservesPendingResume = await previous?.isAwaitingSystemResume() ?? false
        await previous?.stop()
        guard generation == refreshGeneration, !isShuttingDown else {
            return
        }
        let replacement = makeRefreshCoordinator(generation: generation)
        refreshCoordinator = replacement
        await startReplacement(
            replacement,
            activityRevision: activityRevision,
            preservesPendingResume: preservesPendingResume
        )
        await finishStartupIfNeeded(generation: generation)
    }

    private func startReplacement(
        _ refresh: any ApplicationRefreshCoordinating,
        activityRevision: UInt64,
        preservesPendingResume: Bool
    ) async {
        guard activityRevision == activityCommandRevision else {
            await refresh.suspend()
            return
        }
        guard !preservesPendingResume else {
            await refresh.suspend()
            await refresh.resumeAfterSystemWake()
            return
        }
        await start(refresh)
    }

    private func systemActivityChanged(_ event: SystemActivityEvent) {
        switch event {
        case .sleep:
            statusRuntime.setRotationPaused(true, for: .sleeping)
            applyActivityEvent(.began(.sleep))
        case .wake:
            statusRuntime.setRotationPaused(false, for: .sleeping)
            applyActivityEvent(.ended(.sleep))
        case .sessionLocked:
            statusRuntime.setRotationPaused(true, for: .screenLocked)
            applyActivityEvent(.began(.sessionLocked))
        case .sessionUnlocked:
            statusRuntime.setRotationPaused(false, for: .screenLocked)
            applyActivityEvent(.ended(.sessionLocked))
        case .lowPowerModeChanged(let enabled):
            lowPowerModeChanged(enabled)
        }
    }

    private func applyActivityEvent(_ event: ApplicationActivityEvent) {
        let transition = activityReducer.reduce(state: activityState, event: event)
        activityState = transition.state
        guard let command = transition.command else {
            return
        }
        activityCommandRevision &+= 1
        rememberInitialResumeIfNeeded(command)
        applyActivityCommand(command)
    }

    private func rememberInitialResumeIfNeeded(
        _ command: ApplicationActivityCommand
    ) {
        guard command == .resume, !hasLoadedPreferences else {
            return
        }
        pendingInitialSystemResume = true
    }

    private func applyActivityCommand(_ command: ApplicationActivityCommand) {
        switch command {
        case .suspend:
            deadlineScheduler?.systemDidSleep()
            enqueueRefreshOperation { refresh in
                await refresh.suspend()
            }
        case .resume:
            deadlineScheduler?.systemDidWake()
            enqueueRefreshOperation { refresh in
                await refresh.resumeAfterSystemWake()
            }
        }
    }

    private func lowPowerModeChanged(_ enabled: Bool) {
        guard enabled != lowPowerModeEnabled else {
            return
        }
        lowPowerModeEnabled = enabled
        guard refreshCoordinator != nil else {
            return
        }
        enqueueRefreshOperation { refresh in
            await refresh.setLowPowerMode(enabled)
        }
    }

    private func assistiveDisplayChanged(_ event: AssistiveDisplayEvent) {
        let state = event.state
        statusRuntime.setRotationPaused(
            state.isVoiceOverEnabled,
            for: .voiceOver
        )
        statusRuntime.setRotationPaused(
            state.shouldReduceMotion,
            for: .reduceMotion
        )
    }

    private func usageDeadlineReached(_ reason: UsageDeadlineReason) {
        switch reason {
        case .quotaReset:
            presentCurrentPublication(publishDeadlines: false)
            enqueueRefreshOperation { refresh in
                await refresh.refreshAfterQuotaReset()
            }
        case .validityExpired:
            presentCurrentPublication(publishDeadlines: false)
        }
    }

    private func enqueueRefreshOperation(
        _ operation: @escaping @MainActor (
            any ApplicationRefreshCoordinating
        ) async -> Void
    ) {
        let generation = refreshGeneration
        enqueueOperation { coordinator in
            guard generation == coordinator.refreshGeneration,
                  let refresh = coordinator.refreshCoordinator else {
                return
            }
            await operation(refresh)
        }
    }

    private func enqueueOperation(
        _ operation: @escaping @MainActor (
            CodexGaugeApplicationCoordinator
        ) async -> Void
    ) {
        enqueuedOperationIdentifier &+= 1
        let identifier = enqueuedOperationIdentifier
        let previous = pendingOperation
        pendingOperation = Task { @MainActor [weak self] in
            await previous?.value
            guard let self else {
                return
            }
            if !self.isShuttingDown {
                await operation(self)
            }
            self.completedOperationIdentifier = identifier
        }
    }
}

private extension AppPreferences {
    func merging(_ values: SettingsFormValues) -> AppPreferences {
        AppPreferences(
            displayPreference: values.displayPreference,
            refreshProfile: values.refreshProfile,
            launchAtLoginIntent: values.launchAtLoginIntent,
            selectedExecutableURL: selectedExecutableURL,
            hasCompletedFirstLaunch: hasCompletedFirstLaunch,
            language: values.language,
            statusGaugeAppearance: values.statusGaugeAppearance
        )
    }

    func replacingSelectedExecutableURL(_ url: URL) -> AppPreferences {
        AppPreferences(
            displayPreference: displayPreference,
            refreshProfile: refreshProfile,
            launchAtLoginIntent: launchAtLoginIntent,
            selectedExecutableURL: url,
            hasCompletedFirstLaunch: hasCompletedFirstLaunch,
            language: language,
            statusGaugeAppearance: statusGaugeAppearance
        )
    }
}
