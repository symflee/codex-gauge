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
    public private(set) var applicationUpdateState: ApplicationUpdateState

    private let statusRuntime: any ApplicationStatusRuntime
    private let menuRuntime: any ApplicationMenuRuntime
    private let settingsRuntime: any ApplicationSettingsRuntime
    private let applicationUpdateRuntime: any ApplicationUpdateRuntime
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

    private var menuModelBuilder: QuotaDetailsMenuModelBuilder?
    private var currentMenuInput: QuotaDetailsMenuInput?
    private var menuModelCache = QuotaDetailsMenuModelCache()
    private var lastMenuModel: QuotaDetailsMenuModel?
    private var lastStatusFrames: [DisplayFrame]?
    private var lastConnectionStatus: CodexConnectionStatus?
    private var lastDiscoveredQuotaIDs: Set<QuotaSelectionID>?
    private var lastDeadlineInput: RefreshDeadlineInput?
    private var preferences: AppPreferences
    private var pendingFormValues: SettingsFormValues?
    private var pendingSelectedExecutableURL: URL?
    private var activityState = ApplicationActivityState.active
    private var lowPowerModeEnabled = false
    private var refreshCoordinator: (any ApplicationRefreshCoordinating)?
    private var retiringRefresh: (any ApplicationRefreshCoordinating)?
    private var retirementWaitTask: Task<Void, Never>?
    private var retirementContinuation: CheckedContinuation<Void, Never>?
    private var deadlineScheduler: (any ApplicationUsageDeadlineScheduling)?
    private var pendingOperation: Task<Void, Never>?
    private var pendingRefreshDispatch = RefreshDispatch()
    private var activeRefreshDispatch = RefreshDispatch()
    private var isRefreshDispatchEnqueued = false
    private var pendingRefreshReplacement: RefreshReplacement?
    private var isRefreshReplacementEnqueued = false
    private var installedRefreshGeneration: UInt64?
    private var appliedRefreshProfile: RefreshProfile?
    private var appliedDisplayPreference: DisplayPreference?
    private var appliedLowPowerMode: Bool?
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
        applicationUpdateRuntime: any ApplicationUpdateRuntime =
            DisabledApplicationUpdateRuntime(),
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
        self.applicationUpdateRuntime = applicationUpdateRuntime
        applicationUpdateState = applicationUpdateRuntime.state
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
        startApplicationUpdateRuntime()
        installDeadlineScheduler()
        startMonitors()
        enqueueOperation { coordinator in
            await coordinator.loadPreferencesAndStartRefresh()
        }
    }

    public func performMenuAction(_ action: QuotaMenuAction) {
        guard !isShuttingDown else { return }
        switch action {
        case .refresh:
            if !activeRefreshDispatch.manual {
                pendingRefreshDispatch.manual = true
                scheduleRefreshDispatch()
            }
        case .openCodex:
            workspace.openCodexApplication()
        case .selectCodex:
            settingsRuntime.requestExecutableSelection()
        case .checkForUpdates:
            applicationUpdateRuntime.checkForUpdates()
        case .settings:
            enqueueOperation { coordinator in
                _ = await coordinator.settingsRuntime.showSettings()
            }
        case .quit:
            terminator.terminate()
        }
    }

    public func settingsFormValuesDidChange(_ values: SettingsFormValues) {
        guard !isShuttingDown else { return }
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
        guard !isShuttingDown else { return }
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

    /// Package-only lifecycle diagnostic derived from the actual operation queue.
    /// It counts active plus queued operations, without adding logging or counters.
    package var pendingRuntimeOperationCount: UInt64 {
        enqueuedOperationIdentifier &- completedOperationIdentifier
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
        statusRuntime.setRotationPaused(true, for: .sleeping)
        pendingRefreshDispatch = RefreshDispatch()
        pendingRefreshReplacement = nil
        installedRefreshGeneration = nil
        // Shutdown stops boundedly; only replacement must wait for actual exit.
        retirementContinuation?.resume()
        retirementContinuation = nil
        applicationUpdateRuntime.stop()
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
            let lateRefresh = self?.refreshCoordinator ?? self?.retiringRefresh
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

    private func startApplicationUpdateRuntime() {
        applicationUpdateRuntime.start { [weak self] state in
            self?.receiveApplicationUpdateState(state)
        }
    }

    private func receiveApplicationUpdateState(
        _ state: ApplicationUpdateState
    ) {
        guard !isShuttingDown, state != applicationUpdateState else {
            return
        }
        applicationUpdateState = state
        updateCachedMenu()
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
        recordInstalledRefresh(generation: generation, consumesInitialActivity: true)
        await startInitialRefresh(refresh)
        await finishStartupIfNeeded(generation: generation)
        scheduleRefreshDispatch()
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
        if lastStatusFrames != presentation.frames {
            lastStatusFrames = presentation.frames
            statusRuntime.present(frames: presentation.frames)
        }
        currentMenuInput = presentation.menuInput
        updateCachedMenu()
        discoveredQuotaIDs = presentation.discoveredQuotaIDs
        if lastDiscoveredQuotaIDs != discoveredQuotaIDs {
            lastDiscoveredQuotaIDs = discoveredQuotaIDs
            settingsRuntime.updateDiscoveredQuotaIDs(discoveredQuotaIDs)
        }
        let status = connectionStatus
        if lastConnectionStatus != status {
            lastConnectionStatus = status
            settingsRuntime.updateConnectionStatus(status)
        }
        guard publishDeadlines else { return }
        let deadlines = RefreshDeadlineInput(productStates: presentation.menuInput.productStates)
        if lastDeadlineInput != deadlines {
            lastDeadlineInput = deadlines
            deadlineScheduler?.publish(productStates: presentation.menuInput.productStates)
        }
    }

    private func updateCachedMenu() {
        guard currentMenuInput != nil else { return }
        menuRuntime.updateDeferred { [weak self] in
            self?.makeCurrentMenuModel()
        }
    }

    private func makeCurrentMenuModel() -> QuotaDetailsMenuModel? {
        guard !isShuttingDown, let currentMenuInput else { return nil }
        let builder = menuModelBuilder ?? .bundled(language: preferences.language)
        menuModelBuilder = builder
        let model = menuModelCache.build(
            currentMenuInput.replacingCurrentDate(now()), using: builder,
            applicationUpdateState: applicationUpdateState
        )
        guard lastMenuModel != model else { return nil }
        lastMenuModel = model
        return model
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
            pendingRefreshDispatch.displayPreference = current.displayPreference
            scheduleRefreshDispatch()
        }
        if previous.refreshProfile != current.refreshProfile {
            pendingRefreshDispatch.profile = current.refreshProfile
            scheduleRefreshDispatch()
        }
    }

    private func updateLanguage(_ language: AppLanguage) {
        menuModelBuilder = nil
        updateStatusRenderingConfiguration()
        settingsRuntime.updateLanguage(language)
    }

    private func updateStatusRenderingConfiguration() {
        lastStatusFrames = nil
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

    private struct RefreshReplacement {
        let generation: UInt64
        let activityRevision: UInt64
    }

    private func replaceRefreshCoordinator() {
        refreshGeneration &+= 1
        installedRefreshGeneration = nil
        // Query signals belong to the old executable; activity and current settings
        // remain relevant across replacement, including wake while retirement waits.
        pendingRefreshDispatch.manual = false
        pendingRefreshDispatch.quotaReset = false
        activeRefreshDispatch = RefreshDispatch()
        pendingRefreshReplacement = RefreshReplacement(
            generation: refreshGeneration,
            activityRevision: pendingRefreshReplacement?.activityRevision ?? activityCommandRevision
        )
        publication = .initial
        presentCurrentPublication(publishDeadlines: true)
        guard !isRefreshReplacementEnqueued else { return }
        isRefreshReplacementEnqueued = true
        enqueueOperation { coordinator in
            await coordinator.drainRefreshReplacements()
            coordinator.isRefreshReplacementEnqueued = false
        }
    }

    private func drainRefreshReplacements() async {
        while pendingRefreshReplacement != nil, !isShuttingDown {
            let previous = retiringRefresh ?? refreshCoordinator
            retiringRefresh = previous
            refreshCoordinator = nil
            let preservesPendingResume = await previous?.isAwaitingSystemResume() ?? false
            await previous?.stop()
            if let previous, !isShuttingDown {
                await waitForRefreshRetirement(previous)
            }
            guard !isShuttingDown, let request = pendingRefreshReplacement else { return }
            pendingRefreshReplacement = nil
            guard request.generation == refreshGeneration else { continue }
            // The mailbox remains occupied throughout retirement. Admission reads
            // the latest URL from preferences only after actual exit is confirmed.
            let replacement = makeRefreshCoordinator(generation: request.generation)
            refreshCoordinator = replacement
            recordInstalledRefresh(generation: request.generation)
            await startReplacement(
                replacement,
                activityRevision: request.activityRevision,
                preservesPendingResume: preservesPendingResume
            )
            await finishStartupIfNeeded(generation: request.generation)
            scheduleRefreshDispatch()
        }
    }

    private func waitForRefreshRetirement(
        _ previous: any ApplicationRefreshCoordinating
    ) async {
        await withCheckedContinuation { continuation in
            retirementContinuation = continuation
            retirementWaitTask = Task { @MainActor [weak self] in
                await previous.waitForTermination()
                self?.finishRefreshRetirement()
            }
        }
    }

    private func finishRefreshRetirement() {
        retiringRefresh = nil
        retirementWaitTask = nil
        retirementContinuation?.resume()
        retirementContinuation = nil
    }

    private func startReplacement(
        _ refresh: any ApplicationRefreshCoordinating,
        activityRevision: UInt64,
        preservesPendingResume: Bool
    ) async {
        if pendingRefreshDispatch.activity != nil || pendingRefreshDispatch.needsSuspend {
            // Same-turn sleep/wake may still be in the mailbox when replacement
            // invalidates the old dispatch. Establish suspension on the new owner
            // before that mailbox schedules its delayed resume; never start a query.
            pendingRefreshDispatch.needsSuspend = true
            await drainRefreshDispatch()
            return
        }
        guard activityRevision == activityCommandRevision else {
            await refresh.suspend()
            return
        }
        guard !preservesPendingResume else {
            let generation = refreshGeneration
            await refresh.suspend()
            guard canDispatchRefresh(generation),
                  activityRevision == activityCommandRevision else { return }
            await refresh.resumeAfterSystemWake()
            return
        }
        await start(refresh)
    }

    private func systemActivityChanged(_ event: SystemActivityEvent) {
        guard !isShuttingDown else { return }
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
            pendingRefreshDispatch.needsSuspend = true
            pendingRefreshDispatch.activity = .suspend
            scheduleRefreshDispatch()
        case .resume:
            deadlineScheduler?.systemDidWake()
            pendingRefreshDispatch.activity = .resume
            scheduleRefreshDispatch()
        }
    }

    private func lowPowerModeChanged(_ enabled: Bool) {
        guard enabled != lowPowerModeEnabled else {
            return
        }
        lowPowerModeEnabled = enabled
        pendingRefreshDispatch.lowPowerMode = enabled
        scheduleRefreshDispatch()
    }

    private func assistiveDisplayChanged(_ event: AssistiveDisplayEvent) {
        guard !isShuttingDown else { return }
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
        guard !isShuttingDown else { return }
        switch reason {
        case .quotaReset:
            presentCurrentPublication(publishDeadlines: false)
            if !activeRefreshDispatch.quotaReset {
                pendingRefreshDispatch.quotaReset = true
                scheduleRefreshDispatch()
            }
        case .validityExpired:
            presentCurrentPublication(publishDeadlines: false)
        }
    }

    private struct RefreshDispatch {
        var profile: RefreshProfile?
        var displayPreference: DisplayPreference?
        var lowPowerMode: Bool?
        var activity: ApplicationActivityCommand?
        var needsSuspend = false
        var manual = false
        var quotaReset = false

        var isEmpty: Bool {
            profile == nil && displayPreference == nil && lowPowerMode == nil
                && activity == nil && !needsSuspend && !manual && !quotaReset
        }
    }

    private func recordInstalledRefresh(
        generation: UInt64,
        consumesInitialActivity: Bool = false
    ) {
        installedRefreshGeneration = generation
        appliedRefreshProfile = preferences.refreshProfile
        appliedDisplayPreference = preferences.displayPreference
        appliedLowPowerMode = lowPowerModeEnabled
        // Initial startup already reconciles activity observed while preferences loaded.
        // Replacement retains transitions observed during the old coordinator's stop.
        if consumesInitialActivity {
            pendingRefreshDispatch.activity = nil
            pendingRefreshDispatch.needsSuspend = false
        }
    }

    private func scheduleRefreshDispatch() {
        guard !isShuttingDown, !pendingRefreshDispatch.isEmpty,
              !isRefreshDispatchEnqueued else { return }
        isRefreshDispatchEnqueued = true
        // One queue entry preserves ordering with executable/settings operations.
        // Further refresh events overwrite this bounded mailbox, not another Task.
        enqueueOperation { coordinator in
            await coordinator.drainRefreshDispatch()
            coordinator.isRefreshDispatchEnqueued = false
            if coordinator.installedRefreshGeneration == coordinator.refreshGeneration {
                coordinator.scheduleRefreshDispatch()
            }
        }
    }

    private func drainRefreshDispatch() async {
        while !pendingRefreshDispatch.isEmpty {
            let generation = refreshGeneration
            guard canDispatchRefresh(generation), let refresh = refreshCoordinator else { return }
            let dispatch = pendingRefreshDispatch
            pendingRefreshDispatch = RefreshDispatch()
            activeRefreshDispatch = dispatch
            await applyRefreshDispatch(dispatch, to: refresh, generation: generation)
            activeRefreshDispatch = RefreshDispatch()
        }
    }

    private func canDispatchRefresh(_ generation: UInt64) -> Bool {
        !isShuttingDown && generation == refreshGeneration
            && installedRefreshGeneration == generation
    }

    private func applyRefreshDispatch(
        _ dispatch: RefreshDispatch,
        to refresh: any ApplicationRefreshCoordinating,
        generation: UInt64
    ) async {
        if dispatch.needsSuspend || dispatch.activity == .suspend {
            await refresh.suspend()
            guard canDispatchRefresh(generation) else { return }
        }
        if let profile = dispatch.profile, profile != appliedRefreshProfile {
            await refresh.updateProfile(profile)
            guard canDispatchRefresh(generation) else { return }
            appliedRefreshProfile = profile
        }
        if let enabled = dispatch.lowPowerMode, enabled != appliedLowPowerMode {
            await refresh.setLowPowerMode(enabled)
            guard canDispatchRefresh(generation) else { return }
            appliedLowPowerMode = enabled
        }
        if let preference = dispatch.displayPreference, preference != appliedDisplayPreference {
            await refresh.updateDisplayPreference(preference)
            guard canDispatchRefresh(generation) else { return }
            appliedDisplayPreference = preference
        }
        // Reset is latched before wake, preserving the delayed resume baseline.
        if dispatch.manual {
            await refresh.refreshManually()
        } else if dispatch.quotaReset {
            await refresh.refreshAfterQuotaReset()
        }
        guard canDispatchRefresh(generation) else { return }
        if dispatch.activity == .resume, !activityState.isSuspended {
            await refresh.resumeAfterSystemWake()
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
