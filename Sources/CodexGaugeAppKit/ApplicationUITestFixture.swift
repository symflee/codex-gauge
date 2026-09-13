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
    public static let uiTestPreferencesSuiteEnvironmentKey =
        "CODEX_GAUGE_UI_TEST_PREFERENCES_SUITE"
    public static let uiTestPreferencesSuitePrefix =
        "io.github.symflee.codex-gauge.uitest."

    public let mode: Mode
    public let firstLaunchTestingOptions: FirstLaunchTestingOptions
    public let uiTestPreferencesSuiteName: String?

    public init(
        arguments: [String],
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) {
        #if DEBUG
        if arguments.contains(Self.uiTestFixture83Argument),
           let suiteName = Self.fixtureSuiteName(environment: environment) {
            mode = .uiTestFixture83
            firstLaunchTestingOptions = FirstLaunchTestingOptions(
                arguments: arguments
            )
            uiTestPreferencesSuiteName = suiteName
            return
        }
        #endif
        mode = .production
        firstLaunchTestingOptions = .production
        uiTestPreferencesSuiteName = nil
    }

    private static func fixtureSuiteName(
        environment: [String: String]
    ) -> String? {
        guard let value = environment[uiTestPreferencesSuiteEnvironmentKey] else {
            return nil
        }
        guard value.hasPrefix(uiTestPreferencesSuitePrefix) else {
            return nil
        }
        let suffix = String(value.dropFirst(uiTestPreferencesSuitePrefix.count))
        guard UUID(uuidString: suffix) != nil else {
            return nil
        }
        return value
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
        return RefreshPublication(
            products: [.codex: codex],
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
            hasCompletedFirstLaunch: stored.hasCompletedFirstLaunch,
            language: stored.language,
            statusGaugeAppearance: stored.statusGaugeAppearance
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
    public private(set) var currentStatus = LaunchAtLoginStatus.disabled

    public init() {}

    public func setEnabled(
        _ enabled: Bool
    ) async throws(LaunchAtLoginError) -> LaunchAtLoginStatus {
        requestedValues.append(enabled)
        currentStatus = enabled ? .enabled : .disabled
        return currentStatus
    }

    public func openApprovalSettingsIfNeeded() -> Bool {
        false
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
