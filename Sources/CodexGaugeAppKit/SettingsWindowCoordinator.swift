import CodexGaugeCore
import CodexGaugeSettings
import Foundation

public typealias SettingsExecutableSelectionSaver = @Sendable (URL) async throws -> Void

@MainActor
public final class SettingsWindowCoordinator {
    public private(set) var activeWindowController: SettingsWindowController?

    private let repository: AppPreferencesRepository
    private let discoveredQuotaProvider: @MainActor () -> Set<QuotaSelectionID>
    private let connectionDiagnosticsProvider: SettingsConnectionDiagnosticsProvider
    private let connectionStatusProvider: @MainActor () -> CodexConnectionStatus
    private let executableSelector: (any CodexExecutableSelecting)?
    private let executableSelectionSaver: SettingsExecutableSelectionSaver
    private let clipboardWriter: (any DiagnosticClipboardWriting)?
    private let diagnosticEnvironment: DiagnosticEnvironment
    private let onSettingsFormValuesChanged: @MainActor (SettingsFormValues) -> Void
    private let onExecutableSelectionChanged: @MainActor (URL) -> Void
    private let reportBuilder = ConnectionDiagnosticReportBuilder()
    private var pendingSave: Task<Void, Never>?
    private var diagnosticsTask: Task<Void, Never>?
    private var selectionTask: Task<Void, Never>?
    private var diagnosticsGeneration: UInt64 = 0
    private var selectionGeneration: UInt64 = 0
    private var committingSelectionGeneration: UInt64?
    private var selectedExecutableURL: URL?
    private var latestConnectionDiagnostics = ConnectionDiagnosticsSnapshot.checking

    public init(
        repository: AppPreferencesRepository,
        discoveredQuotaProvider: @escaping @MainActor () -> Set<QuotaSelectionID>,
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
        executableSelector: (any CodexExecutableSelecting)? = nil,
        executableSelectionSaver: SettingsExecutableSelectionSaver? = nil,
        clipboardWriter: (any DiagnosticClipboardWriting)? = nil,
        diagnosticEnvironment: DiagnosticEnvironment = .current(),
        onSettingsFormValuesChanged: @escaping @MainActor (SettingsFormValues) -> Void = {
            _ in
        },
        onExecutableSelectionChanged: @escaping @MainActor (URL) -> Void = { _ in }
    ) {
        self.repository = repository
        self.discoveredQuotaProvider = discoveredQuotaProvider
        self.connectionDiagnosticsProvider = connectionDiagnosticsProvider
        self.connectionStatusProvider = connectionStatusProvider
        self.executableSelector = executableSelector
        self.executableSelectionSaver = executableSelectionSaver ?? { [repository] url in
            try await repository.saveSelectedExecutableURL(url)
        }
        self.clipboardWriter = clipboardWriter
        self.diagnosticEnvironment = diagnosticEnvironment
        self.onSettingsFormValuesChanged = onSettingsFormValuesChanged
        self.onExecutableSelectionChanged = onExecutableSelectionChanged
    }

    @discardableResult
    public func showSettings() async -> SettingsWindowController {
        if let controller = activeWindowController {
            controller.showWindow(nil)
            controller.window?.makeKeyAndOrderFront(nil)
            return controller
        }
        await pendingSave?.value
        let preferences = await repository.load()
        if let controller = activeWindowController {
            return controller
        }
        return makeWindowController(preferences: preferences)
    }

    public func flushPendingSave() async {
        await pendingSave?.value
    }

    public func refreshConnectionDiagnostics() async {
        guard let controller = activeWindowController else {
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

    private func makeWindowController(
        preferences: AppPreferences
    ) -> SettingsWindowController {
        selectedExecutableURL = preferences.selectedExecutableURL
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
            connectionStatus: connectionStatusProvider()
        )
        let controller = SettingsWindowController(
            formState: state,
            connectionDiagnostics: initialDiagnostics,
            onSelectCodex: { [weak self] in
                self?.requestExecutableSelection()
            },
            onCopyDiagnostics: { [weak self] in
                self?.copyDiagnostics()
            },
            onFormValuesChanged: { [weak self] values in
                self?.settingsFormValuesChanged(values)
            },
            onClose: { [weak self] closingController in
                self?.release(closingController)
            }
        )
        activeWindowController = controller
        controller.showWindow(nil)
        controller.window?.makeKeyAndOrderFront(nil)
        scheduleConnectionDiagnostics(
            selectedExecutableURL: preferences.selectedExecutableURL,
            controller: controller
        )
        return controller
    }

    private func scheduleConnectionDiagnostics(
        selectedExecutableURL: URL?,
        controller: SettingsWindowController
    ) {
        let previousTask = diagnosticsTask
        previousTask?.cancel()
        diagnosticsGeneration &+= 1
        let generation = diagnosticsGeneration
        let provider = connectionDiagnosticsProvider
        let connectionStatus = connectionStatusProvider()
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
                controller: controller
            )
        }
    }

    private func applyConnectionDiagnostics(
        _ snapshot: ConnectionDiagnosticsSnapshot,
        generation: UInt64,
        controller: SettingsWindowController?
    ) {
        guard generation == diagnosticsGeneration else {
            return
        }
        guard let controller, activeWindowController === controller else {
            return
        }
        latestConnectionDiagnostics = snapshot
        controller.settingsViewController.applyConnectionDiagnostics(snapshot)
        diagnosticsTask = nil
    }

    public func requestExecutableSelection() {
        guard selectionTask == nil, executableSelector != nil else {
            return
        }
        selectionGeneration &+= 1
        let generation = selectionGeneration
        selectionTask = Task { [weak self] in
            guard let self else {
                return
            }
            if activeWindowController == nil {
                _ = await showSettings()
            }
            await runExecutableSelection(generation: generation)
        }
    }

    private func runExecutableSelection(generation: UInt64) async {
        guard let executableSelector else {
            finishExecutableSelection(generation: generation)
            return
        }
        weak let controller = activeWindowController
        let selectedURL = await executableSelector.selectExecutable(
            attachedTo: controller?.window
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
        onExecutableSelectionChanged(selectedURL)
        guard generation == selectionGeneration,
              let controller,
              activeWindowController === controller else {
            finishExecutableSelection(generation: generation)
            return
        }
        let checking = ConnectionDiagnosticsSnapshot(
            executableSource: .userSelected,
            path: nil,
            cliVersion: nil,
            cliVersionIssue: nil,
            connectionStatus: .checking
        )
        controller.settingsViewController.applyConnectionDiagnostics(checking)
        latestConnectionDiagnostics = checking
        scheduleConnectionDiagnostics(
            selectedExecutableURL: selectedURL,
            controller: controller
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

    private func enqueueSave(_ values: SettingsFormValues) {
        let previousSave = pendingSave
        let repository = repository
        pendingSave = Task {
            await previousSave?.value
            try? await repository.saveSettingsForm(values)
        }
    }

    private func settingsFormValuesChanged(_ values: SettingsFormValues) {
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
        latestConnectionDiagnostics = .checking
        activeWindowController = nil
    }

    private func cancelPendingExecutableSelection() {
        guard selectionTask != nil else {
            return
        }
        guard committingSelectionGeneration != selectionGeneration else {
            return
        }
        selectionGeneration &+= 1
        selectionTask?.cancel()
        selectionTask = nil
    }
}
