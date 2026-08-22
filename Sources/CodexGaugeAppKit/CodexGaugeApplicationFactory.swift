import AppKit
import CodexGaugeCore
import CodexGaugeSettings
import Foundation

@MainActor
public protocol CodexGaugeApplicationRunning: AnyObject {
    func start()
    func refreshLaunchAtLoginStatus()
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
        startupHook: @escaping CodexGaugeApplicationCoordinator.StartupHook =
            CodexGaugeApplicationCoordinator.noOpStartupHook
    ) -> CodexGaugeApplicationCoordinator {
        let launchOptions = CodexGaugeApplicationLaunchOptions(
            arguments: launchArguments
        )
        switch launchOptions.mode {
        case .production:
            return makeProduction(
                repository: repository,
                workspace: workspace,
                application: application,
                launchOptions: launchOptions,
                startupHook: startupHook
            )
        case .uiTestFixture83:
            return makeUITestFixture(
                repository: repository,
                workspace: workspace,
                application: application,
                launchOptions: launchOptions,
                startupHook: startupHook
            )
        }
    }

    private static func makeProduction(
        repository: AppPreferencesRepository,
        workspace: NSWorkspace,
        application: NSApplication,
        launchOptions: CodexGaugeApplicationLaunchOptions,
        startupHook: @escaping CodexGaugeApplicationCoordinator.StartupHook
    ) -> CodexGaugeApplicationCoordinator {
        let workspaceRuntime = NSWorkspaceCodexApplicationAdapter(
            workspace: workspace
        )
        let diagnosticsProvider = SystemConnectionDiagnosticsProvider()
        let refreshBuilder = SystemApplicationRefreshCoordinatorBuilder {
            workspaceRuntime.applicationURL
        }
        return makeApplication(
            repository: repository,
            workspace: workspace,
            application: application,
            workspaceRuntime: workspaceRuntime,
            refreshBuilder: refreshBuilder,
            preferencesLoader: RepositoryApplicationPreferencesLoader(
                repository: repository
            ),
            launchAtLoginController: LaunchAtLoginController(),
            diagnosticsProvider: diagnosticsProvider.provider,
            executableSelector: NSOpenPanelCodexExecutableSelector(),
            launchOptions: launchOptions,
            startupHook: startupHook
        )
    }

    private static func makeUITestFixture(
        repository: AppPreferencesRepository,
        workspace: NSWorkspace,
        application: NSApplication,
        launchOptions: CodexGaugeApplicationLaunchOptions,
        startupHook: @escaping CodexGaugeApplicationCoordinator.StartupHook
    ) -> CodexGaugeApplicationCoordinator {
        let diagnosticsProvider = UITestFixtureConnectionDiagnosticsProvider()
        return makeApplication(
            repository: repository,
            workspace: workspace,
            application: application,
            workspaceRuntime: UITestFixtureCodexWorkspace(),
            refreshBuilder: UITestFixtureRefreshCoordinatorBuilder(),
            preferencesLoader: UITestFixtureApplicationPreferencesLoader(
                repository: repository
            ),
            launchAtLoginController: UITestFixtureLaunchAtLoginController(),
            diagnosticsProvider: diagnosticsProvider.provider,
            executableSelector: UITestFixtureCodexExecutableSelector(),
            launchOptions: launchOptions,
            startupHook: startupHook
        )
    }

    private static func makeApplication(
        repository: AppPreferencesRepository,
        workspace: NSWorkspace,
        application: NSApplication,
        workspaceRuntime: any CodexApplicationWorkspacing,
        refreshBuilder: any ApplicationRefreshCoordinatorBuilding,
        preferencesLoader: any ApplicationPreferencesLoading,
        launchAtLoginController: any ApplicationLaunchAtLoginControlling,
        diagnosticsProvider: @escaping SettingsConnectionDiagnosticsProvider,
        executableSelector: (any CodexExecutableSelecting)?,
        launchOptions: CodexGaugeApplicationLaunchOptions,
        startupHook: @escaping CodexGaugeApplicationCoordinator.StartupHook
    ) -> CodexGaugeApplicationCoordinator {
        let eventRelay = CodexGaugeApplicationEventRelay()
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
            eventRelay: eventRelay,
            application: application,
            diagnosticsProvider: diagnosticsProvider,
            executableSelector: executableSelector
        )
        let firstLaunchSettings = FirstLaunchSettingsCoordinator(
            repository: repository,
            settingsRuntime: settingsRuntime,
            testingOptions: launchOptions.firstLaunchTestingOptions
        )
        let applicationStartupHook: CodexGaugeApplicationCoordinator.StartupHook = {
            preferences in
            await firstLaunchSettings.runAfterInitialRefreshStarted()
            await startupHook(preferences)
        }
        let coordinator = CodexGaugeApplicationCoordinator(
            statusRuntime: statusRuntime,
            menuRuntime: menuRuntime,
            settingsRuntime: settingsRuntime,
            systemActivityMonitor: SystemActivityMonitor(workspace: workspace),
            assistiveDisplayMonitor: AssistiveDisplayMonitor(workspace: workspace),
            deadlineSchedulerBuilder: .system(),
            launchAtLoginController: launchAtLoginController,
            refreshCoordinatorBuilder: refreshBuilder,
            preferencesLoader: preferencesLoader,
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
        eventRelay: CodexGaugeApplicationEventRelay,
        application: NSApplication,
        diagnosticsProvider: @escaping SettingsConnectionDiagnosticsProvider,
        executableSelector: (any CodexExecutableSelecting)?
    ) -> SettingsWindowRuntimeAdapter {
        let coordinator = SettingsWindowCoordinator(
            repository: repository,
            discoveredQuotaProvider: { eventRelay.discoveredQuotaIDs },
            foregroundPresenter: SettingsWindowForegroundPresenter(
                applicationActivator: NSApplicationSettingsWindowActivator(
                    application: application
                )
            ),
            connectionDiagnosticsProvider: diagnosticsProvider,
            connectionStatusProvider: { eventRelay.connectionStatus },
            launchAtLoginStateProvider: { eventRelay.launchAtLoginState },
            executableSelector: executableSelector,
            clipboardWriter: SystemDiagnosticClipboardWriter(),
            onSettingsFormValuesChanged: { values in
                eventRelay.settingsFormValuesDidChange(values)
            },
            onExecutableSelectionChanged: { url in
                eventRelay.selectedExecutableDidChange(url)
            },
            onOpenLaunchAtLoginSystemSettings: {
                eventRelay.openLaunchAtLoginApprovalSettings()
            },
            onLaunchAtLoginIntentRequested: { enabled in
                eventRelay.launchAtLoginIntentDidChange(enabled)
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

    var launchAtLoginState: LaunchAtLoginSettingsState {
        coordinator?.currentLaunchAtLoginState ?? LaunchAtLoginSettingsState(
            status: .disabled
        )
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

    func openLaunchAtLoginApprovalSettings() {
        coordinator?.openLaunchAtLoginApprovalSettings()
    }

    func launchAtLoginIntentDidChange(_ enabled: Bool) {
        coordinator?.launchAtLoginIntentDidChange(enabled)
    }
}
