import AppKit
import CodexGaugeCore
import CodexGaugeProtocol
import CodexGaugeRefresh
import CodexGaugeSettings
import Foundation

public struct CodexGaugeApplicationLaunchOptions: Equatable, Sendable {
    public enum Mode: Equatable, Sendable {
        case production
        case uiTestFixture83
    }

    public static let uiTestFixture83Argument =
        "--codex-gauge-ui-test-fixture-83"

    public let mode: Mode
    public let firstLaunchTestingOptions: FirstLaunchTestingOptions

    public init(arguments: [String]) {
        #if DEBUG
        let usesFixture = arguments.contains(Self.uiTestFixture83Argument)
        mode = usesFixture ? .uiTestFixture83 : .production
        firstLaunchTestingOptions = Self.firstLaunchOptions(
            arguments: arguments,
            usesFixture: usesFixture
        )
        #else
        mode = .production
        firstLaunchTestingOptions = FirstLaunchTestingOptions(
            arguments: arguments
        )
        #endif
    }

    private static func firstLaunchOptions(
        arguments: [String],
        usesFixture: Bool
    ) -> FirstLaunchTestingOptions {
        guard usesFixture else {
            return FirstLaunchTestingOptions(arguments: arguments)
        }
        return FirstLaunchTestingOptions(
            arguments: [FirstLaunchTestingOptions.resetCompletionArgument]
        )
    }
}

@MainActor
public final class UITestFixtureRefreshCoordinatorBuilder:
    ApplicationRefreshCoordinatorBuilding {
    private let now: @MainActor () -> Date

    public init(now: @escaping @MainActor () -> Date = { Date() }) {
        self.now = now
    }

    public func makeCoordinator(
        configuration: ApplicationRefreshConfiguration,
        publicationHandler: @escaping RefreshPublicationHandler
    ) -> any ApplicationRefreshCoordinating {
        _ = configuration
        return UITestFixtureRefreshCoordinator(
            capturedAt: now(),
            publicationHandler: publicationHandler
        )
    }
}

public actor UITestFixtureRefreshCoordinator: ApplicationRefreshCoordinating {
    public private(set) var isStopped = false

    private let publication: RefreshPublication
    private let publicationHandler: RefreshPublicationHandler
    private var isSuspended = false

    public init(
        capturedAt: Date,
        publicationHandler: @escaping RefreshPublicationHandler
    ) {
        publication = Self.makePublication(capturedAt: capturedAt)
        self.publicationHandler = publicationHandler
    }

    public func start() async {
        guard !isStopped else {
            return
        }
        isSuspended = false
        await publish()
    }

    public func refreshManually() async {
        await publish()
    }

    public func refreshAfterQuotaReset() async {
        await publish()
    }

    public func updateProfile(_ profile: RefreshProfile) async {
        _ = profile
    }

    public func setLowPowerMode(_ enabled: Bool) async {
        _ = enabled
    }

    public func updateDisplayPreference(_ preference: DisplayPreference) async {
        _ = preference
    }

    public func suspend() async {
        guard !isStopped else {
            return
        }
        isSuspended = true
    }

    public func resumeAfterSystemWake() async {
        guard !isStopped else {
            return
        }
        isSuspended = false
    }

    public func isAwaitingSystemResume() async -> Bool {
        false
    }

    public func stop() async {
        isStopped = true
        isSuspended = true
    }

    private func publish() async {
        guard !isStopped, !isSuspended else {
            return
        }
        await publicationHandler(publication)
    }

    private static func makePublication(
        capturedAt: Date
    ) -> RefreshPublication {
        let window = makeQuotaWindow()
        let codex = RefreshProductResult(
            usageState: .value(
                ProductQuotaValue(capturedAt: capturedAt, quotaWindows: [window]),
                freshness: .fresh
            ),
            rateLimits: ProductRateLimits(state: .available, windows: [window]),
            issue: nil,
            lastSuccessfulRefresh: capturedAt
        )
        let spark = RefreshProductResult(
            usageState: .unavailable,
            rateLimits: ProductRateLimits(state: .unavailable, windows: []),
            issue: .unavailable,
            lastSuccessfulRefresh: nil
        )
        return RefreshPublication(
            products: [.codex: codex, .spark: spark],
            lastSuccessfulRefresh: capturedAt,
            lastAcceptedRateLimitResponse: capturedAt,
            failure: nil,
            isRefreshing: false
        )
    }

    private static func makeQuotaWindow() -> QuotaWindow {
        guard let window = QuotaWindow(
            slot: .primary,
            usedPercent: 17,
            windowDurationMinutes: 300
        ) else {
            preconditionFailure("The synthetic quota must be valid")
        }
        return window
    }
}

public struct UITestFixtureApplicationPreferencesLoader:
    ApplicationPreferencesLoading {
    private let repository: AppPreferencesRepository

    public init(repository: AppPreferencesRepository) {
        self.repository = repository
    }

    public func load() async -> AppPreferences {
        let stored = await repository.load()
        return AppPreferences(
            displayPreference: .default,
            refreshProfile: stored.refreshProfile,
            launchAtLoginIntent: stored.launchAtLoginIntent,
            selectedExecutableURL: stored.selectedExecutableURL,
            hasCompletedFirstLaunch: stored.hasCompletedFirstLaunch
        )
    }
}

@MainActor
public final class UITestFixtureCodexWorkspace: CodexApplicationWorkspacing {
    public private(set) var openRequestCount = 0

    public init() {}

    public var applicationURL: URL? {
        nil
    }

    public func openCodexApplication() {
        openRequestCount += 1
    }
}

@MainActor
public final class UITestFixtureLaunchAtLoginController:
    ApplicationLaunchAtLoginControlling {
    public private(set) var requestedValues = [Bool]()

    public init() {}

    public func setEnabled(_ enabled: Bool) async throws -> LaunchAtLoginStatus {
        requestedValues.append(enabled)
        return enabled ? .enabled : .disabled
    }
}

@MainActor
public final class UITestFixtureCodexExecutableSelector: CodexExecutableSelecting {
    public private(set) var selectionRequestCount = 0

    public init() {}

    public func selectExecutable(attachedTo window: NSWindow?) async -> URL? {
        _ = window
        selectionRequestCount += 1
        return nil
    }
}

public struct UITestFixtureConnectionDiagnosticsProvider: Sendable {
    public init() {}

    public func inspect(
        selectedExecutableURL: URL?,
        connectionStatus: CodexConnectionStatus
    ) async -> ConnectionDiagnosticsSnapshot {
        ConnectionDiagnosticsSnapshot(
            executableSource: selectedExecutableURL == nil
                ? .automatic
                : .userSelected,
            path: nil,
            cliVersion: nil,
            cliVersionIssue: nil,
            connectionStatus: connectionStatus
        )
    }

    public var provider: SettingsConnectionDiagnosticsProvider {
        { selectedExecutableURL, connectionStatus in
            await inspect(
                selectedExecutableURL: selectedExecutableURL,
                connectionStatus: connectionStatus
            )
        }
    }
}
