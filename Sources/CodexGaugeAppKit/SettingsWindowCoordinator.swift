import CodexGaugeCore
import CodexGaugeSettings
import Foundation

public typealias SettingsExecutableSelectionSaver = @Sendable (URL) async throws -> Void
public typealias SettingsFormValuesSaver = @Sendable (SettingsFormValues) async -> Void

@MainActor
public final class SettingsWindowCoordinator {
    public private(set) var activeWindowController: SettingsWindowController?

    private let repository: AppPreferencesRepository
    private let discoveredQuotaProvider: @MainActor () -> Set<QuotaSelectionID>
    private let foregroundPresenter: any SettingsWindowForegroundPresenting
    private let launchAtLoginStateProvider: @MainActor () -> LaunchAtLoginSettingsState
    private let connectionDiagnosticsProvider: SettingsConnectionDiagnosticsProvider
    private let settingsFormValuesSaver: SettingsFormValuesSaver
    private let executableSelector: (any CodexExecutableSelecting)?
    private let executableSelectionSaver: SettingsExecutableSelectionSaver
    private let clipboardWriter: (any DiagnosticClipboardWriting)?
    private let diagnosticEnvironment: DiagnosticEnvironment
    private let onSettingsFormValuesChanged: @MainActor (SettingsFormValues) -> Void
    private let onExecutableSelectionChanged: @MainActor (URL) -> Void
    private let onOpenLaunchAtLoginSystemSettings: @MainActor () -> Void
    private let onLaunchAtLoginIntentRequested: @MainActor (Bool) -> Void
    private let onSettingsWindowCreated: @MainActor (SettingsWindowController) -> Void
    private let reportBuilder = ConnectionDiagnosticReportBuilder()
    private var pendingSave: Task<Void, Never>?
    private var diagnosticsTask: Task<Void, Never>?
    private var selectionTask: Task<Void, Never>?
    private var selectionCleanupTask: Task<Void, Never>?
    private var shutdownTask: Task<Void, Never>?
    private var diagnosticsGeneration: UInt64 = 0
    private var connectionStatusRevision: UInt64 = 0
    private var selectionGeneration: UInt64 = 0
    private var selectionCleanupGeneration: UInt64 = 0
    private var committingSelectionGeneration: UInt64?
    private var selectedExecutableURL: URL?
    private var language: AppLanguage = .english
    private var latestConnectionStatus: CodexConnectionStatus
    private var latestConnectionDiagnostics = ConnectionDiagnosticsSnapshot.checking
    private var latestLaunchAtLoginState: LaunchAtLoginSettingsState

    public init(
        repository: AppPreferencesRepository,
        discoveredQuotaProvider: @escaping @MainActor () -> Set<QuotaSelectionID>,
        foregroundPresenter: any SettingsWindowForegroundPresenting =
            SettingsWindowForegroundPresenter(),
        connectionDiagnosticsProvider: @escaping SettingsConnectionDiagnosticsProvider = {
            selectedExecutableURL, status in
            ConnectionDiagnosticsSnapshot(
                executableSource: selectedExecutableURL == nil ? .automatic : .userSelected,
                path: nil,
                cliVersion: nil,
                cliVersionIssue: nil,
                connectionStatus: status
            )
        },
        connectionStatusProvider: @escaping @MainActor () -> CodexConnectionStatus = {
            .checking
        },
        launchAtLoginStateProvider: @escaping @MainActor () -> LaunchAtLoginSettingsState = {
            LaunchAtLoginSettingsState(status: .disabled)
        },
        settingsFormValuesSaver: SettingsFormValuesSaver? = nil,
        executableSelector: (any CodexExecutableSelecting)? = nil,
        executableSelectionSaver: SettingsExecutableSelectionSaver? = nil,
        clipboardWriter: (any DiagnosticClipboardWriting)? = nil,
        diagnosticEnvironment: DiagnosticEnvironment = .current(),
        onSettingsFormValuesChanged: @escaping @MainActor (SettingsFormValues) -> Void = {
            _ in
        },
        onExecutableSelectionChanged: @escaping @MainActor (URL) -> Void = { _ in },
        onOpenLaunchAtLoginSystemSettings: @escaping @MainActor () -> Void = {},
        onLaunchAtLoginIntentRequested: @escaping @MainActor (Bool) -> Void = {
            _ in
        },
        onSettingsWindowCreated: @escaping @MainActor (SettingsWindowController) -> Void = {
            _ in
        }
    ) {
        self.repository = repository
        self.discoveredQuotaProvider = discoveredQuotaProvider
        self.foregroundPresenter = foregroundPresenter
        self.launchAtLoginStateProvider = launchAtLoginStateProvider
        self.connectionDiagnosticsProvider = connectionDiagnosticsProvider
        self.settingsFormValuesSaver = settingsFormValuesSaver ?? { [repository] values in
            try? await repository.saveSettingsForm(values)
        }
        self.executableSelector = executableSelector
        self.executableSelectionSaver = executableSelectionSaver ?? { [repository] url in
            try await repository.saveSelectedExecutableURL(url)
        }
        self.clipboardWriter = clipboardWriter
        self.diagnosticEnvironment = diagnosticEnvironment
        self.onSettingsFormValuesChanged = onSettingsFormValuesChanged
        self.onExecutableSelectionChanged = onExecutableSelectionChanged
        self.onOpenLaunchAtLoginSystemSettings = onOpenLaunchAtLoginSystemSettings
        self.onLaunchAtLoginIntentRequested = onLaunchAtLoginIntentRequested
        self.onSettingsWindowCreated = onSettingsWindowCreated
        let initialStatus = connectionStatusProvider()
        latestConnectionStatus = initialStatus
        latestConnectionDiagnostics = ConnectionDiagnosticsSnapshot(
            path: nil,
            cliVersion: nil,
            cliVersionIssue: nil,
            connectionStatus: initialStatus
        )
        latestLaunchAtLoginState = launchAtLoginStateProvider()
    }

    @discardableResult
    public func showSettings() async -> SettingsWindowController? {
        guard canShowSettings else {
            return nil
        }
        refreshLaunchAtLoginState()
        if let controller = activeWindowController {
            return present(controller)
        }
        await pendingSave?.value
        guard canShowSettings else {
            return nil
        }
        let preferences = await repository.load()
        guard canShowSettings else {
            return nil
        }
        if let controller = activeWindowController {
            return present(controller)
        }
        let controller = makeWindowController(preferences: preferences)
        guard canShowSettings else {
            discardUnpresented(controller)
            return nil
        }
        guard let presentedController = present(controller) else {
            return nil
        }
        scheduleConnectionDiagnostics(
            selectedExecutableURL: preferences.selectedExecutableURL,
            controller: presentedController
        )
        return presentedController
    }

    public func flushPendingSave() async {
        await pendingSave?.value
    }

    public func shutdown() async {
        if let shutdownTask {
            await shutdownTask.value
            return
        }
        let task = Task { @MainActor [weak self] in
            guard let self else {
                return
            }
            await performShutdown()
        }
        shutdownTask = task
        await task.value
    }

    public func refreshConnectionDiagnostics() async {
        guard shutdownTask == nil, let controller = activeWindowController else {
            return
        }
        scheduleConnectionDiagnostics(
            selectedExecutableURL: selectedExecutableURL,
            controller: controller
        )
    }

    public func updateDiscoveredQuotaIDs(_ identifiers: Set<QuotaSelectionID>) {
        activeWindowController?.settingsViewController.updateDiscoveredQuotaIDs(
            identifiers
        )
    }

    public func updateConnectionStatus(_ status: CodexConnectionStatus) {
        connectionStatusRevision &+= 1
        latestConnectionStatus = status
        let diagnostics = replacingConnectionStatus(
            in: latestConnectionDiagnostics,
            with: status
        )
        latestConnectionDiagnostics = diagnostics
        activeWindowController?.settingsViewController.applyConnectionDiagnostics(
            diagnostics
        )
    }

    public func updateLaunchAtLoginState(
        _ state: LaunchAtLoginSettingsState
    ) {
        latestLaunchAtLoginState = state
        activeWindowController?.settingsViewController.applyLaunchAtLoginState(
            state
        )
    }

    public func updateLanguage(_ language: AppLanguage) {
        self.language = language
        activeWindowController?.updateLanguage(language)
    }

    private func refreshLaunchAtLoginState() {
        updateLaunchAtLoginState(launchAtLoginStateProvider())
    }

    private func makeWindowController(
        preferences: AppPreferences
    ) -> SettingsWindowController {
        selectedExecutableURL = preferences.selectedExecutableURL
        language = preferences.language
        let state = SettingsFormState(
            preferences: preferences,
            discoveredQuotaIDs: discoveredQuotaProvider()
        )
        let initialDiagnostics = ConnectionDiagnosticsSnapshot(
            executableSource: preferences.selectedExecutableURL == nil
                ? .automatic
                : .userSelected,
            path: nil,
            cliVersion: nil,
            cliVersionIssue: nil,
            connectionStatus: latestConnectionStatus
        )
        latestConnectionDiagnostics = initialDiagnostics
        let controller = SettingsWindowController(
            formState: state,
            connectionDiagnostics: initialDiagnostics,
            launchAtLoginState: latestLaunchAtLoginState,
            onSelectCodex: { [weak self] in
                self?.requestExecutableSelection()
            },
            onCopyDiagnostics: { [weak self] in
                self?.copyDiagnostics()
            },
            onOpenLaunchAtLoginSystemSettings: { [weak self] in
                self?.onOpenLaunchAtLoginSystemSettings()
            },
            onLaunchAtLoginIntentRequested: { [weak self] enabled in
                self?.onLaunchAtLoginIntentRequested(enabled)
            },
            onFormValuesChanged: { [weak self] values in
                self?.settingsFormValuesChanged(values)
            },
            onClose: { [weak self] closingController in
                self?.release(closingController)
            }
        )
        activeWindowController = controller
        onSettingsWindowCreated(controller)
        return controller
    }

    private func present(
        _ controller: SettingsWindowController
    ) -> SettingsWindowController? {
        guard canShowSettings else {
            return nil
        }
        guard foregroundPresenter.present(controller) else {
            discardUnpresented(controller)
            return nil
        }
        return controller
    }

    private func discardUnpresented(_ controller: SettingsWindowController) {
        controller.close()
        release(controller)
    }

    private func scheduleConnectionDiagnostics(
        selectedExecutableURL: URL?,
        controller: SettingsWindowController
    ) {
        guard shutdownTask == nil else {
            return
        }
        let previousTask = diagnosticsTask
        previousTask?.cancel()
        diagnosticsGeneration &+= 1
        let generation = diagnosticsGeneration
        let provider = connectionDiagnosticsProvider
        let connectionStatus = latestConnectionStatus
        let statusRevision = connectionStatusRevision
        diagnosticsTask = Task { [weak self, weak controller] in
            await previousTask?.value
            guard !Task.isCancelled else {
                return
            }
            let snapshot = await provider(selectedExecutableURL, connectionStatus)
            guard !Task.isCancelled else {
                return
            }
            self?.applyConnectionDiagnostics(
                snapshot,
                generation: generation,
                statusRevision: statusRevision,
                controller: controller
            )
        }
    }

    private func applyConnectionDiagnostics(
        _ snapshot: ConnectionDiagnosticsSnapshot,
        generation: UInt64,
        statusRevision: UInt64,
        controller: SettingsWindowController?
    ) {
        guard generation == diagnosticsGeneration else {
            return
        }
        guard let controller, activeWindowController === controller else {
            return
        }
        let diagnostics = mergedDiagnostics(
            snapshot,
            scheduledStatusRevision: statusRevision
        )
        latestConnectionDiagnostics = diagnostics
        controller.settingsViewController.applyConnectionDiagnostics(diagnostics)
        diagnosticsTask = nil
    }

    private func mergedDiagnostics(
        _ diagnostics: ConnectionDiagnosticsSnapshot,
        scheduledStatusRevision: UInt64
    ) -> ConnectionDiagnosticsSnapshot {
        guard scheduledStatusRevision != connectionStatusRevision else {
            return diagnostics
        }
        return replacingConnectionStatus(
            in: diagnostics,
            with: latestConnectionStatus
        )
    }

    private func replacingConnectionStatus(
        in diagnostics: ConnectionDiagnosticsSnapshot,
        with status: CodexConnectionStatus
    ) -> ConnectionDiagnosticsSnapshot {
        ConnectionDiagnosticsSnapshot(
            executableSource: diagnostics.executableSource,
            path: diagnostics.path,
            cliVersion: diagnostics.cliVersion,
            cliVersionIssue: diagnostics.cliVersionIssue,
            connectionStatus: status
        )
    }

    public func requestExecutableSelection() {
        guard shutdownTask == nil,
              selectionTask == nil,
              executableSelector != nil else {
            return
        }
        selectionGeneration &+= 1
        let generation = selectionGeneration
        selectionTask = Task { [weak self] in
            guard let self else {
                return
            }
            if activeWindowController == nil {
                guard let openedController = await showSettings() else {
                    finishExecutableSelection(generation: generation)
                    return
                }
                guard !Task.isCancelled, shutdownTask == nil else {
                    openedController.close()
                    finishExecutableSelection(generation: generation)
                    return
                }
            }
            guard !Task.isCancelled, shutdownTask == nil else {
                finishExecutableSelection(generation: generation)
                return
            }
            await runExecutableSelection(generation: generation)
        }
    }

    private func runExecutableSelection(generation: UInt64) async {
        guard let executableSelector else {
            finishExecutableSelection(generation: generation)
            return
        }
        weak let presentingController = activeWindowController
        let prompt = SettingsStrings(language: language).selectCodexAction
        let selectedURL = await executableSelector.selectExecutable(
            attachedTo: presentingController?.window,
            prompt: prompt
        )
        guard canCommitExecutableSelection(selectedURL, generation: generation) else {
            finishExecutableSelection(generation: generation)
            return
        }
        guard let selectedURL else {
            finishExecutableSelection(generation: generation)
            return
        }
        committingSelectionGeneration = generation
        do {
            try await executableSelectionSaver(selectedURL)
        } catch {
            finishExecutableSelection(generation: generation)
            return
        }
        self.selectedExecutableURL = selectedURL
        let currentController = activeWindowController
        beginCheckingSelectedExecutable(controller: currentController)
        onExecutableSelectionChanged(selectedURL)
        guard shutdownTask == nil else {
            finishExecutableSelection(generation: generation)
            return
        }
        guard generation == selectionGeneration,
              let currentController,
              activeWindowController === currentController else {
            finishExecutableSelection(generation: generation)
            return
        }
        scheduleConnectionDiagnostics(
            selectedExecutableURL: selectedURL,
            controller: currentController
        )
        finishExecutableSelection(generation: generation)
    }

    private func canCommitExecutableSelection(
        _ selectedURL: URL?,
        generation: UInt64
    ) -> Bool {
        guard generation == selectionGeneration, !Task.isCancelled else {
            return false
        }
        return selectedURL?.isFileURL == true
    }

    private func beginCheckingSelectedExecutable(
        controller: SettingsWindowController?
    ) {
        connectionStatusRevision &+= 1
        latestConnectionStatus = .checking
        let checking = ConnectionDiagnosticsSnapshot(
            executableSource: .userSelected,
            path: nil,
            cliVersion: nil,
            cliVersionIssue: nil,
            connectionStatus: .checking
        )
        latestConnectionDiagnostics = checking
        guard let controller, activeWindowController === controller else {
            return
        }
        controller.settingsViewController.applyConnectionDiagnostics(checking)
    }

    private func finishExecutableSelection(generation: UInt64) {
        guard generation == selectionGeneration else {
            return
        }
        selectionTask = nil
        committingSelectionGeneration = nil
    }

    private func copyDiagnostics() {
        guard let clipboardWriter else {
            return
        }
        let report = reportBuilder.makeReport(
            snapshot: latestConnectionDiagnostics,
            environment: diagnosticEnvironment
        )
        clipboardWriter.writeDiagnosticText(report)
    }

    private var canShowSettings: Bool {
        shutdownTask == nil && !Task.isCancelled
    }

    private func enqueueSave(_ values: SettingsFormValues) {
        let previousSave = pendingSave
        let settingsFormValuesSaver = settingsFormValuesSaver
        pendingSave = Task {
            await previousSave?.value
            await settingsFormValuesSaver(values)
        }
    }

    private func settingsFormValuesChanged(_ values: SettingsFormValues) {
        if language != values.language {
            updateLanguage(values.language)
        }
        onSettingsFormValuesChanged(values)
        enqueueSave(values)
    }

    private func release(_ controller: SettingsWindowController) {
        guard activeWindowController === controller else {
            return
        }
        diagnosticsGeneration &+= 1
        diagnosticsTask?.cancel()
        cancelPendingExecutableSelection()
        latestConnectionDiagnostics = ConnectionDiagnosticsSnapshot(
            executableSource: selectedExecutableURL == nil ? .automatic : .userSelected,
            path: nil,
            cliVersion: nil,
            cliVersionIssue: nil,
            connectionStatus: latestConnectionStatus
        )
        activeWindowController = nil
    }

    private func cancelPendingExecutableSelection() {
        guard selectionTask != nil else {
            return
        }
        guard committingSelectionGeneration != selectionGeneration else {
            return
        }
        let cancelledTask = selectionTask
        selectionGeneration &+= 1
        cancelledTask?.cancel()
        selectionTask = nil
        trackSelectionCleanup(cancelledTask)
    }

    private func trackSelectionCleanup(_ task: Task<Void, Never>?) {
        guard let task else {
            return
        }
        let previousCleanup = selectionCleanupTask
        selectionCleanupGeneration &+= 1
        let generation = selectionCleanupGeneration
        selectionCleanupTask = Task { [weak self] in
            await previousCleanup?.value
            await task.value
            self?.finishSelectionCleanup(generation: generation)
        }
    }

    private func finishSelectionCleanup(generation: UInt64) {
        guard generation == selectionCleanupGeneration else {
            return
        }
        selectionCleanupTask = nil
    }

    private func performShutdown() async {
        let diagnostics = diagnosticsTask
        diagnosticsGeneration &+= 1
        diagnostics?.cancel()
        let activeSelection = selectionTask
        let selectionIsCommitting = committingSelectionGeneration == selectionGeneration
        if !selectionIsCommitting {
            cancelPendingExecutableSelection()
        }
        activeWindowController?.close()
        let pendingFormSave = pendingSave
        let selectionCleanup = selectionCleanupTask

        await pendingFormSave?.value
        await diagnostics?.value
        if selectionIsCommitting {
            await activeSelection?.value
        }
        await selectionCleanup?.value
        diagnosticsTask = nil
        selectionTask = nil
        selectionCleanupTask = nil
        committingSelectionGeneration = nil
    }
}
