import AppKit
import CodexGaugeCore
import CodexGaugeProtocol
import CodexGaugeRefresh
import CodexGaugeSettings
import Foundation

@MainActor
public protocol ApplicationStatusRuntime: AnyObject {
    func present(frames: [DisplayFrame])

    func updateRenderingConfiguration(
        language: AppLanguage,
        statusGaugeAppearance: StatusGaugeAppearance
    )

    func setRotationPaused(
        _ paused: Bool,
        for reason: StatusRotationPauseReason
    )
}

public extension ApplicationStatusRuntime {
    func updateRenderingConfiguration(
        language: AppLanguage,
        statusGaugeAppearance: StatusGaugeAppearance
    ) {
        _ = language
        _ = statusGaugeAppearance
    }
}

@MainActor
public final class StatusItemRuntimeAdapter: ApplicationStatusRuntime {
    public let controller: StatusItemController
    private let imageCache = StatusGaugeImageCache()

    public init(controller: StatusItemController) {
        self.controller = controller
    }

    public func present(frames: [DisplayFrame]) {
        controller.setFrames(frames)
    }

    public func updateRenderingConfiguration(
        language: AppLanguage,
        statusGaugeAppearance: StatusGaugeAppearance
    ) {
        controller.replaceRenderer(
            StatusFrameRenderer(
                language: language,
                statusGaugeAppearance: statusGaugeAppearance,
                cache: imageCache
            )
        )
    }

    public func setRotationPaused(
        _ paused: Bool,
        for reason: StatusRotationPauseReason
    ) {
        controller.setPaused(paused, for: reason)
    }
}

@MainActor
public protocol ApplicationMenuRuntime: AnyObject {
    func update(_ model: QuotaDetailsMenuModel)
    func updateDeferred(_ modelProvider: @escaping @MainActor () -> QuotaDetailsMenuModel?)
}

public extension ApplicationMenuRuntime {
    // Eager compatibility for runtimes without a native menu lifecycle. Production
    // adapters must forward the provider without evaluating it while the menu is closed.
    func updateDeferred(_ modelProvider: @escaping @MainActor () -> QuotaDetailsMenuModel?) {
        if let model = modelProvider() { update(model) }
    }
}

@MainActor
public final class StatusMenuRuntimeAdapter: ApplicationMenuRuntime {
    public let controller: StatusMenuController

    public init(controller: StatusMenuController) {
        self.controller = controller
    }

    public func update(_ model: QuotaDetailsMenuModel) {
        controller.update(model)
    }

    public func updateDeferred(_ modelProvider: @escaping @MainActor () -> QuotaDetailsMenuModel?) {
        controller.updateDeferred(modelProvider)
    }
}

@MainActor
public protocol ApplicationSettingsRuntime: AnyObject {
    func showSettings() async -> Bool
    func requestExecutableSelection()
    func updateDiscoveredQuotaIDs(_ identifiers: Set<QuotaSelectionID>)
    func updateConnectionStatus(_ status: CodexConnectionStatus)
    func updateLaunchAtLoginState(_ state: LaunchAtLoginSettingsState)
    func updateLanguage(_ language: AppLanguage)
    func shutdown() async
}

public extension ApplicationSettingsRuntime {
    func updateLanguage(_ language: AppLanguage) {
        _ = language
    }
}

@MainActor
public final class SettingsWindowRuntimeAdapter: ApplicationSettingsRuntime {
    public let coordinator: SettingsWindowCoordinator

    public init(coordinator: SettingsWindowCoordinator) {
        self.coordinator = coordinator
    }

    public func showSettings() async -> Bool {
        guard let controller = await coordinator.showSettings() else {
            return false
        }
        return controller.window?.isVisible == true
    }

    public func requestExecutableSelection() {
        coordinator.requestExecutableSelection()
    }

    public func updateDiscoveredQuotaIDs(_ identifiers: Set<QuotaSelectionID>) {
        coordinator.updateDiscoveredQuotaIDs(identifiers)
    }

    public func updateConnectionStatus(_ status: CodexConnectionStatus) {
        coordinator.updateConnectionStatus(status)
    }

    public func updateLaunchAtLoginState(_ state: LaunchAtLoginSettingsState) {
        coordinator.updateLaunchAtLoginState(state)
    }

    public func updateLanguage(_ language: AppLanguage) {
        coordinator.updateLanguage(language)
    }

    public func shutdown() async {
        await coordinator.shutdown()
    }
}

@MainActor
public protocol ApplicationSystemActivityMonitoring: AnyObject {
    func start(handler: @escaping @MainActor (SystemActivityEvent) -> Void)
    func stop()
}

extension SystemActivityMonitor: ApplicationSystemActivityMonitoring {}

@MainActor
public protocol ApplicationAssistiveDisplayMonitoring: AnyObject {
    func start(
        handler: @escaping @MainActor @Sendable (AssistiveDisplayEvent) -> Void
    )
    func stop()
}

extension AssistiveDisplayMonitor: ApplicationAssistiveDisplayMonitoring {}

@MainActor
public protocol ApplicationUsageDeadlineScheduling: AnyObject {
    func publish(productStates: [UsageProduct: ProductUsageState])
    func systemDidSleep()
    func systemDidWake()
    func stop()
}

extension QuotaResetRefreshScheduler: ApplicationUsageDeadlineScheduling {}

@MainActor
public struct ApplicationUsageDeadlineSchedulerBuilder {
    public typealias Handler = @MainActor (UsageDeadlineReason) -> Void
    public typealias Factory = @MainActor (
        ApplicationUsageDeadlineEmitter
    ) -> any ApplicationUsageDeadlineScheduling

    private let factory: Factory

    public init(_ factory: @escaping Factory) {
        self.factory = factory
    }

    public func make(
        handler: @escaping Handler
    ) -> any ApplicationUsageDeadlineScheduling {
        factory(ApplicationUsageDeadlineEmitter(handler: handler))
    }

    public static func system(
        now: @escaping @MainActor () -> Date = { Date() }
    ) -> ApplicationUsageDeadlineSchedulerBuilder {
        ApplicationUsageDeadlineSchedulerBuilder { emitter in
            QuotaResetRefreshScheduler(now: now) { reason in
                emitter.emit(reason)
            }
        }
    }
}

@MainActor
public final class ApplicationUsageDeadlineEmitter {
    private let handler: ApplicationUsageDeadlineSchedulerBuilder.Handler

    fileprivate init(
        handler: @escaping ApplicationUsageDeadlineSchedulerBuilder.Handler
    ) {
        self.handler = handler
    }

    public func emit(_ reason: UsageDeadlineReason) {
        handler(reason)
    }
}

@MainActor
public protocol ApplicationLaunchAtLoginControlling: AnyObject {
    var currentStatus: LaunchAtLoginStatus { get }

    func setEnabled(
        _ enabled: Bool
    ) async throws(LaunchAtLoginError) -> LaunchAtLoginStatus

    @discardableResult
    func openApprovalSettingsIfNeeded() -> Bool
}

extension LaunchAtLoginController: ApplicationLaunchAtLoginControlling {}

public protocol ApplicationRefreshCoordinating: Sendable {
    func start() async
    func refreshManually() async
    func refreshAfterQuotaReset() async
    func updateProfile(_ profile: RefreshProfile) async
    func setLowPowerMode(_ enabled: Bool) async
    func updateDisplayPreference(_ preference: DisplayPreference) async
    func suspend() async
    func resumeAfterSystemWake() async
    func isAwaitingSystemResume() async -> Bool
    func stop() async
    func waitForTermination() async
}

public extension ApplicationRefreshCoordinating {
    /// Only lightweight runtimes/fakes that own no child process may use this default.
    func waitForTermination() async {}
}

public struct RefreshCoordinatorRuntimeAdapter: ApplicationRefreshCoordinating {
    private let coordinator: RefreshCoordinator

    public init(coordinator: RefreshCoordinator) {
        self.coordinator = coordinator
    }

    public func start() async {
        await coordinator.start()
    }

    public func refreshManually() async {
        await coordinator.refreshManually()
    }

    public func refreshAfterQuotaReset() async {
        await coordinator.refreshAfterQuotaReset()
    }

    public func updateProfile(_ profile: RefreshProfile) async {
        await coordinator.updateProfile(profile)
    }

    public func setLowPowerMode(_ enabled: Bool) async {
        await coordinator.setLowPowerMode(enabled)
    }

    public func updateDisplayPreference(_ preference: DisplayPreference) async {
        await coordinator.updateDisplayPreference(preference)
    }

    public func suspend() async {
        await coordinator.suspend()
    }

    public func resumeAfterSystemWake() async {
        await coordinator.resumeAfterSystemWake()
    }

    public func isAwaitingSystemResume() async -> Bool {
        await coordinator.isAwaitingSystemResume()
    }

    public func stop() async {
        await coordinator.stop()
    }

    public func waitForTermination() async {
        await coordinator.waitForTermination()
    }
}

public struct ApplicationRefreshConfiguration: Equatable, Sendable {
    public let preferences: AppPreferences
    public let lowPowerModeEnabled: Bool

    public init(
        preferences: AppPreferences,
        lowPowerModeEnabled: Bool
    ) {
        self.preferences = preferences
        self.lowPowerModeEnabled = lowPowerModeEnabled
    }
}

@MainActor
public protocol ApplicationRefreshCoordinatorBuilding: AnyObject {
    func makeCoordinator(
        configuration: ApplicationRefreshConfiguration,
        publicationHandler: @escaping RefreshPublicationHandler
    ) -> any ApplicationRefreshCoordinating
}

@MainActor
public final class SystemApplicationRefreshCoordinatorBuilder:
    ApplicationRefreshCoordinatorBuilding {
    private let bundleApplicationURL: @MainActor () -> URL?
    private let homeDirectoryURL: URL

    public init(
        bundleApplicationURL: @escaping @MainActor () -> URL?,
        homeDirectoryURL: URL = FileManager.default.homeDirectoryForCurrentUser
    ) {
        self.bundleApplicationURL = bundleApplicationURL
        self.homeDirectoryURL = homeDirectoryURL
    }

    public func makeCoordinator(
        configuration: ApplicationRefreshConfiguration,
        publicationHandler: @escaping RefreshPublicationHandler
    ) -> any ApplicationRefreshCoordinating {
        let locator = CodexExecutableLocator(
            selectedExecutableURL: configuration.preferences.selectedExecutableURL,
            bundleApplicationURL: bundleApplicationURL(),
            homeDirectoryURL: homeDirectoryURL
        )
        let usageProvider = CodexUsageProvider(locator: locator)
        let sessionProvider = CodexRefreshSessionProvider(provider: usageProvider)
        let coordinator = RefreshCoordinator(
            provider: sessionProvider,
            profile: configuration.preferences.refreshProfile,
            lowPowerModeEnabled: configuration.lowPowerModeEnabled,
            displayPreference: configuration.preferences.displayPreference,
            publicationHandler: publicationHandler
        )
        return RefreshCoordinatorRuntimeAdapter(coordinator: coordinator)
    }
}

public protocol ApplicationPreferencesLoading: Sendable {
    func load() async -> AppPreferences
}

public struct RepositoryApplicationPreferencesLoader: ApplicationPreferencesLoading {
    private let repository: AppPreferencesRepository

    public init(repository: AppPreferencesRepository) {
        self.repository = repository
    }

    public func load() async -> AppPreferences {
        await repository.load()
    }
}

@MainActor
public protocol CodexApplicationWorkspacing: AnyObject {
    var applicationURL: URL? { get }

    func openCodexApplication()
}

@MainActor
public final class NSWorkspaceCodexApplicationAdapter: CodexApplicationWorkspacing {
    public static let codexBundleIdentifier = "com.openai.codex"

    private let workspace: NSWorkspace
    private lazy var cachedApplicationURL = workspace.urlForApplication(
        withBundleIdentifier: Self.codexBundleIdentifier
    )

    public init(workspace: NSWorkspace = .shared) {
        self.workspace = workspace
    }

    public var applicationURL: URL? {
        cachedApplicationURL
    }

    public func openCodexApplication() {
        guard let applicationURL else {
            return
        }
        let configuration = NSWorkspace.OpenConfiguration()
        workspace.openApplication(
            at: applicationURL,
            configuration: configuration,
            completionHandler: nil
        )
    }
}

@MainActor
public protocol ApplicationTerminating: AnyObject {
    func terminate()
}

@MainActor
public final class NSApplicationTerminator: ApplicationTerminating {
    private let application: NSApplication

    public init(application: NSApplication = .shared) {
        self.application = application
    }

    public func terminate() {
        application.terminate(nil)
    }
}
