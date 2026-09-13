import CodexGaugeAppKit
import CodexGaugeCore
import CodexGaugeRefresh
import CodexGaugeSettings
import Foundation

func applicationUITestFixtureTests() -> [TestCase] {
    [
        applicationUITestFixtureRecognizesOnlyExactArgumentTest(),
        applicationUITestFixtureForcesCodexDisplayInMemoryTest(),
        applicationUITestFixturePublishesCodex83PercentTest(),
        applicationUITestFixtureUsesIsolatedExternalBoundariesTest(),
        applicationUITestFixtureStopsPublicationTerminallyTest()
    ]
}

private func applicationUITestFixtureRecognizesOnlyExactArgumentTest() -> TestCase {
    TestCase(name: "UI fixture is exact-match and Debug-only") {
        let argument = CodexGaugeApplicationLaunchOptions.uiTestFixture83Argument
        let suiteName = CodexGaugeApplicationLaunchOptions.uiTestPreferencesSuitePrefix
            + UUID().uuidString
        let environment = [
            CodexGaugeApplicationLaunchOptions.uiTestPreferencesSuiteEnvironmentKey:
                suiteName
        ]
        let enabled = CodexGaugeApplicationLaunchOptions(
            arguments: ["Codex Gauge", argument],
            environment: environment
        )
        let nearMatches = [
            argument + "-extra",
            "prefix-" + argument,
            "--codex-gauge-ui-test-fixture-8",
            FirstLaunchTestingOptions.resetCompletionArgument
        ]

        #if DEBUG
        try expect(enabled.mode == .uiTestFixture83, "Expected exact fixture mode")
        try expect(
            enabled.uiTestPreferencesSuiteName == suiteName,
            "Expected an isolated fixture preferences suite"
        )
        try expect(
            !enabled.firstLaunchTestingOptions.shouldResetCompletion,
            "Expected fixture activation not to reset first-launch completion"
        )
        #else
        try expect(enabled.mode == .production, "Expected Release production mode")
        try expect(
            !enabled.firstLaunchTestingOptions.shouldResetCompletion,
            "Expected Release fixture argument ignored"
        )
        #endif
        let resetOnly = CodexGaugeApplicationLaunchOptions(
            arguments: [
                "Codex Gauge",
                FirstLaunchTestingOptions.resetCompletionArgument
            ]
        )
        try expect(resetOnly.mode == .production, "Expected reset-only production mode")
        try expect(
            !resetOnly.firstLaunchTestingOptions.shouldResetCompletion,
            "Expected production reset argument ignored"
        )
        let fixtureWithReset = CodexGaugeApplicationLaunchOptions(
            arguments: [
                "Codex Gauge",
                argument,
                FirstLaunchTestingOptions.resetCompletionArgument
            ],
            environment: environment
        )
        #if DEBUG
        try expect(
            fixtureWithReset.mode == .uiTestFixture83,
            "Expected fixture mode with an independent reset"
        )
        #else
        try expect(
            fixtureWithReset.mode == .production,
            "Expected Release to ignore fixture activation"
        )
        #endif
        #if DEBUG
        try expect(
            fixtureWithReset.firstLaunchTestingOptions.shouldResetCompletion,
            "Expected reset only inside the exact Debug fixture"
        )
        #else
        try expect(
            !fixtureWithReset.firstLaunchTestingOptions.shouldResetCompletion,
            "Expected Release reset argument ignored"
        )
        #endif
        let invalidSuite = CodexGaugeApplicationLaunchOptions(
            arguments: ["Codex Gauge", argument],
            environment: [
                CodexGaugeApplicationLaunchOptions.uiTestPreferencesSuiteEnvironmentKey:
                    "io.github.symflee.codex-gauge"
            ]
        )
        try expect(
            invalidSuite.uiTestPreferencesSuiteName == nil,
            "Expected production-like suite names rejected"
        )
        try expect(
            invalidSuite.mode == .production,
            "Expected fixture mode to require an isolated suite"
        )
        for nearMatch in nearMatches {
            let options = CodexGaugeApplicationLaunchOptions(
                arguments: ["Codex Gauge", nearMatch]
            )
            try expect(options.mode == .production, "Expected near match rejected")
        }
    }
}

private func applicationUITestFixtureForcesCodexDisplayInMemoryTest() -> TestCase {
    TestCase(name: "UI fixture forces Codex display without rewriting preferences") {
        try await applicationUITestFixtureForcesCodexDisplayInMemoryScenario()
    }
}

private func applicationUITestFixtureForcesCodexDisplayInMemoryScenario() async throws {
    let suiteName = "io.github.symflee.codex-gauge.tests.ui-fixture.\(UUID().uuidString)"
    guard let cleanupDefaults = UserDefaults(suiteName: suiteName) else {
        throw TestFailure(description: "Unable to create UI fixture defaults")
    }
    defer { cleanupDefaults.removePersistentDomain(forName: suiteName) }
    guard let repositoryDefaults = UserDefaults(suiteName: suiteName) else {
        throw TestFailure(description: "Unable to inject UI fixture defaults")
    }
    let repository = AppPreferencesRepository(
        userDefaults: repositoryDefaults,
        defaultLanguage: .english
    )
    let stored = AppPreferences(
        displayPreference: DisplayPreference(
            quotaSelection: .manual(QuotaSelectionID(product: .codex, rawDurationMinutes: 10_080))
        ),
        refreshProfile: .eco,
        launchAtLoginIntent: true,
        selectedExecutableURL: URL(fileURLWithPath: "/Synthetic/ignored/codex"),
        hasCompletedFirstLaunch: true,
        language: .korean,
        statusGaugeAppearance: .preset(.purple)
    )
    try await repository.save(stored)
    let loader = UITestFixtureApplicationPreferencesLoader(repository: repository)

    let loaded = await loader.load()
    let persisted = await repository.load()

    try expect(loaded.displayPreference == .default, "Expected stable Codex display")
    try expect(loaded.refreshProfile == stored.refreshProfile, "Expected profile preserved")
    try expect(
        loaded.launchAtLoginIntent == stored.launchAtLoginIntent,
        "Expected login intent preserved in memory"
    )
    try expect(
        loaded.selectedExecutableURL == stored.selectedExecutableURL,
        "Expected selected executable preserved in memory"
    )
    try expect(loaded.language == .korean, "Expected stored language preserved in memory")
    try expect(
        loaded.statusGaugeAppearance == stored.statusGaugeAppearance,
        "Expected stored gauge appearance preserved in memory"
    )
    try expect(persisted == stored, "Expected stored preferences untouched")
}

private func applicationUITestFixturePublishesCodex83PercentTest() -> TestCase {
    TestCase(name: "UI fixture publishes an in-memory Codex 5h 83 percent frame") {
        try await applicationUITestFixturePublishesCodex83PercentScenario()
    }
}

@MainActor
private func applicationUITestFixturePublishesCodex83PercentScenario() async throws {
    let capturedAt = Date(timeIntervalSince1970: 1_900_000_000)
    let recorder = ApplicationUITestFixturePublicationRecorder()
    let builder = UITestFixtureRefreshCoordinatorBuilder(now: { capturedAt })
    let configuration = ApplicationRefreshConfiguration(
        preferences: .default,
        lowPowerModeEnabled: false
    )
    let runtime = builder.makeCoordinator(configuration: configuration) {
        recorder.record($0)
    }

    await runtime.start()

    guard let publication = recorder.publications.last else {
        throw TestFailure(description: "Expected synthetic publication")
    }
    let frames = DisplayFrameBuilder().makeFrames(
        preference: .default,
        productStates: publication.products.mapValues(\.usageState),
        now: capturedAt
    )
    guard let frame = frames.first else {
        throw TestFailure(description: "Expected synthetic status frame")
    }
    let formatted = DisplayFrameFormatter().format(frame)
    try expect(formatted.title == "[5h] 83%", "Expected exact fixture title")
    try expect(publication.failure == nil, "Expected successful fixture publication")
    try expect(publication.lastSuccessfulRefresh == capturedAt, "Expected memory timestamp")
    try expect(
        publication.products[.codex]?.rateLimits?.windows.first?.usedPercent == 17,
        "Expected synthetic used percent"
    )
}

private func applicationUITestFixtureUsesIsolatedExternalBoundariesTest() -> TestCase {
    TestCase(name: "UI fixture external boundaries never use production services") {
        try await applicationUITestFixtureUsesIsolatedExternalBoundariesScenario()
    }
}

@MainActor
private func applicationUITestFixtureUsesIsolatedExternalBoundariesScenario() async throws {
    let workspace = UITestFixtureCodexWorkspace()
    let launchAtLogin = UITestFixtureLaunchAtLoginController()
    let executableSelector = UITestFixtureCodexExecutableSelector()
    let diagnostics = UITestFixtureConnectionDiagnosticsProvider()
    let snapshot = await diagnostics.inspect(
        selectedExecutableURL: URL(fileURLWithPath: "/Synthetic/ignored/codex"),
        connectionStatus: .connected
    )

    try expect(workspace.applicationURL == nil, "Expected no Codex discovery")
    workspace.openCodexApplication()
    try expect(workspace.openRequestCount == 1, "Expected only an in-memory open request")
    let status = try await launchAtLogin.setEnabled(true)
    try expect(status == .enabled, "Expected in-memory launch status")
    try expect(
        launchAtLogin.requestedValues == [true],
        "Expected no system login item adapter"
    )
    try expect(
        !launchAtLogin.openApprovalSettingsIfNeeded(),
        "Expected no System Settings recovery in the fixture"
    )
    let selectedURL = await executableSelector.selectExecutable(attachedTo: nil)
    try expect(selectedURL == nil, "Expected no system executable panel result")
    try expect(
        executableSelector.selectionRequestCount == 1,
        "Expected only an in-memory selection request"
    )
    try expect(snapshot.path == nil, "Expected diagnostics not to locate an executable")
    try expect(snapshot.cliVersion == nil, "Expected diagnostics not to launch a process")
    try expect(snapshot.connectionStatus == .connected, "Expected supplied connection state")
}

private func applicationUITestFixtureStopsPublicationTerminallyTest() -> TestCase {
    TestCase(name: "UI fixture shutdown prevents every later publication") {
        try await applicationUITestFixtureStopsPublicationTerminallyScenario()
    }
}

@MainActor
private func applicationUITestFixtureStopsPublicationTerminallyScenario() async throws {
    let recorder = ApplicationUITestFixturePublicationRecorder()
    let coordinator = UITestFixtureRefreshCoordinator(
        capturedAt: Date(timeIntervalSince1970: 1_900_000_000)
    ) {
        recorder.record($0)
    }

    await coordinator.start()
    await coordinator.stop()
    await coordinator.start()
    await coordinator.refreshManually()
    await coordinator.resumeAfterSystemWake()

    let isStopped = await coordinator.isStopped
    try expect(recorder.publications.count == 1, "Expected terminal fixture stop")
    try expect(isStopped, "Expected stopped lifecycle state")
}

@MainActor
private final class ApplicationUITestFixturePublicationRecorder {
    private(set) var publications = [RefreshPublication]()

    func record(_ publication: RefreshPublication) {
        publications.append(publication)
    }
}
