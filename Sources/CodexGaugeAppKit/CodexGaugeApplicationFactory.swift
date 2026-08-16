import AppKit
import CodexGaugeCore
import CodexGaugeSettings
import Foundation

@MainActor
public protocol CodexGaugeApplicationRunning: AnyObject {
    func start()
    func shutdown() async
}

extension CodexGaugeApplicationCoordinator: CodexGaugeApplicationRunning {}

@MainActor
public enum CodexGaugeApplicationFactory {
    public static func makeDefault(
        repository: AppPreferencesRepository = AppPreferencesRepository(
            userDefaults: .standard
        ),
        workspace: NSWorkspace = .shared,
        application: NSApplication = .shared,
        launchArguments: [String] = ProcessInfo.processInfo.arguments,
        startupHook: @escaping CodexGaugeApplicationCoordinator.StartupHook = {
            _ in
        }
    ) -> CodexGaugeApplicationCoordinator {
        let eventRelay = CodexGaugeApplicationEventRelay()
        let workspaceRuntime = NSWorkspaceCodexApplicationAdapter(
            workspace: workspace
        )
        let presenter = SystemStatusItemPresenter()
        let statusController = StatusItemController(presenter: presenter)
        let statusRuntime = StatusItemRuntimeAdapter(controller: statusController)
        let menuRuntime = makeMenuRuntime(
            presenter: presenter,
            statusController: statusController,
            eventRelay: eventRelay
        )
        let settingsRuntime = makeSettingsRuntime(
            repository: repository,
            eventRelay: eventRelay
        )
        let firstLaunchSettings = FirstLaunchSettingsCoordinator(
            repository: repository,
            settingsRuntime: settingsRuntime,
            testingOptions: FirstLaunchTestingOptions(arguments: launchArguments)
        )
        let applicationStartupHook: CodexGaugeApplicationCoordinator.StartupHook = {
            preferences in
            await firstLaunchSettings.runAfterInitialRefreshStarted()
            await startupHook(preferences)
        }
        let refreshBuilder = SystemApplicationRefreshCoordinatorBuilder {
            workspaceRuntime.applicationURL
        }
        let coordinator = CodexGaugeApplicationCoordinator(
            statusRuntime: statusRuntime,
            menuRuntime: menuRuntime,
            settingsRuntime: settingsRuntime,
            systemActivityMonitor: SystemActivityMonitor(workspace: workspace),
            assistiveDisplayMonitor: AssistiveDisplayMonitor(workspace: workspace),
            deadlineSchedulerBuilder: .system(),
            launchAtLoginController: LaunchAtLoginController(),
            refreshCoordinatorBuilder: refreshBuilder,
            preferencesLoader: RepositoryApplicationPreferencesLoader(
                repository: repository
            ),
            workspace: workspaceRuntime,
            terminator: NSApplicationTerminator(application: application),
            startupHook: applicationStartupHook
        )
        eventRelay.coordinator = coordinator
        return coordinator
    }

    private static func makeMenuRuntime(
        presenter: SystemStatusItemPresenter,
        statusController: StatusItemController,
        eventRelay: CodexGaugeApplicationEventRelay
    ) -> StatusMenuRuntimeAdapter {
        let actions = StatusMenuActions(
            refresh: { eventRelay.perform(.refresh) },
            openCodex: { eventRelay.perform(.openCodex) },
            selectCodex: { eventRelay.perform(.selectCodex) },
            settings: { eventRelay.perform(.settings) },
            quit: { eventRelay.perform(.quit) }
        )
        let controller = StatusMenuController(
            presenter: presenter,
            statusItemController: statusController,
            actions: actions
        )
        return StatusMenuRuntimeAdapter(controller: controller)
    }

    private static func makeSettingsRuntime(
        repository: AppPreferencesRepository,
        eventRelay: CodexGaugeApplicationEventRelay
    ) -> SettingsWindowRuntimeAdapter {
        let diagnosticsProvider = SystemConnectionDiagnosticsProvider()
        let coordinator = SettingsWindowCoordinator(
            repository: repository,
            discoveredQuotaProvider: { eventRelay.discoveredQuotaIDs },
            connectionDiagnosticsProvider: diagnosticsProvider.provider,
            connectionStatusProvider: { eventRelay.connectionStatus },
            executableSelector: NSOpenPanelCodexExecutableSelector(),
            clipboardWriter: SystemDiagnosticClipboardWriter(),
            onSettingsFormValuesChanged: { values in
                eventRelay.settingsFormValuesDidChange(values)
            },
            onExecutableSelectionChanged: { url in
                eventRelay.selectedExecutableDidChange(url)
            }
        )
        return SettingsWindowRuntimeAdapter(coordinator: coordinator)
    }
}

@MainActor
private final class CodexGaugeApplicationEventRelay {
    weak var coordinator: CodexGaugeApplicationCoordinator?

    var discoveredQuotaIDs: Set<QuotaSelectionID> {
        coordinator?.discoveredQuotaIDs ?? []
    }

    var connectionStatus: CodexConnectionStatus {
        coordinator?.connectionStatus ?? .checking
    }

    func perform(_ action: QuotaMenuAction) {
        coordinator?.performMenuAction(action)
    }

    func settingsFormValuesDidChange(_ values: SettingsFormValues) {
        coordinator?.settingsFormValuesDidChange(values)
    }

    func selectedExecutableDidChange(_ url: URL) {
        coordinator?.selectedExecutableDidChange(url)
    }
}
