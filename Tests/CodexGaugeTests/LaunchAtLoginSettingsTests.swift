import AppKit
import CodexGaugeAppKit
import CodexGaugeSettings
import Foundation

func launchAtLoginSettingsTests() -> [TestCase] {
    [
        launchAtLoginSettingsStateTest(),
        launchAtLoginSettingsWindowUsesSystemStateTest(),
        launchAtLoginSettingsWindowUpdatesLiveTest(),
        launchAtLoginSettingsLocalizationParityTest()
    ]
}

private func launchAtLoginSettingsStateTest() -> TestCase {
    TestCase(name: "login launch settings derive controls from system state") {
        let disabled = LaunchAtLoginSettingsState(status: .disabled)
        let enabled = LaunchAtLoginSettingsState(status: .enabled)
        let approval = LaunchAtLoginSettingsState(status: .requiresApproval)
        let unavailable = LaunchAtLoginSettingsState(status: .unavailable)

        try expect(disabled.toggleValue == .off, "Expected disabled toggle")
        try expect(enabled.toggleValue == .on, "Expected enabled toggle")
        try expect(approval.toggleValue == .mixed, "Expected approval distinction")
        try expect(approval.showsSystemSettingsRecovery, "Expected approval recovery")
        try expect(!unavailable.allowsChanges, "Expected unavailable control disabled")
        requireLaunchSettingsSendable(approval)
    }
}

private func launchAtLoginSettingsWindowUsesSystemStateTest() -> TestCase {
    TestCase(name: "settings login toggle uses system status instead of saved intent") {
        try await launchAtLoginSettingsWindowUsesSystemStateScenario()
    }
}

@MainActor
private func launchAtLoginSettingsWindowUsesSystemStateScenario() async throws {
    _ = NSApplication.shared
    let store = try LaunchAtLoginSettingsStore()
    defer { store.cleanUp() }
    try await store.repository.save(
        AppPreferences(launchAtLoginIntent: false)
    )
    let systemState = LaunchAtLoginSettingsStateSource(status: .enabled)
    let coordinator = SettingsWindowCoordinator(
        repository: store.repository,
        discoveredQuotaProvider: { [] },
        launchAtLoginStateProvider: { systemState.state }
    )

    let controller = try await showLaunchSettingsController(coordinator)
    let viewController = controller.settingsViewController

    try expect(
        viewController.renderedLaunchAtLoginToggleValue == .on,
        "Expected actual enabled state despite saved disabled intent"
    )
    try expect(
        viewController.renderedLaunchAtLoginDetailText.hasPrefix("settings.") == false,
        "Expected localized system state detail"
    )
    controller.close()

    systemState.state = LaunchAtLoginSettingsState(status: .unavailable)
    let reopenedController = try await showLaunchSettingsController(coordinator)
    try expect(
        !reopenedController.settingsViewController.isLaunchAtLoginToggleEnabled,
        "Expected current system state when rebuilding settings"
    )
    reopenedController.close()
}

private func launchAtLoginSettingsWindowUpdatesLiveTest() -> TestCase {
    TestCase(name: "settings login status and recovery update without system access") {
        try await launchAtLoginSettingsWindowUpdatesLiveScenario()
    }
}

@MainActor
private func launchAtLoginSettingsWindowUpdatesLiveScenario() async throws {
    _ = NSApplication.shared
    let store = try LaunchAtLoginSettingsStore()
    defer { store.cleanUp() }
    var recoveryCount = 0
    var requestedValues = [Bool]()
    let coordinator = SettingsWindowCoordinator(
        repository: store.repository,
        discoveredQuotaProvider: { [] },
        launchAtLoginStateProvider: {
            LaunchAtLoginSettingsState(
                status: .enabled,
                failure: .unregistrationFailed
            )
        },
        onOpenLaunchAtLoginSystemSettings: { recoveryCount += 1 },
        onLaunchAtLoginIntentRequested: { requestedValues.append($0) }
    )
    let controller = try await showLaunchSettingsController(coordinator)
    let viewController = controller.settingsViewController
    let unregistrationFailureText = viewController.renderedLaunchAtLoginDetailText

    try expect(
        !unregistrationFailureText.hasPrefix("settings."),
        "Expected localized unregistration failure"
    )

    viewController.performLaunchAtLoginToggleClick()
    try expect(
        requestedValues == [false],
        "Expected enabled click to request disable despite saved disabled intent"
    )

    coordinator.updateLaunchAtLoginState(
        LaunchAtLoginSettingsState(status: .requiresApproval)
    )
    try expect(
        viewController.renderedLaunchAtLoginToggleValue == .mixed,
        "Expected live approval state"
    )
    try expect(
        viewController.renderedLaunchAtLoginRecoveryActionTitle?.hasPrefix("settings.") == false,
        "Expected localized recovery action"
    )
    viewController.performLaunchAtLoginRecoveryAction()
    try expect(recoveryCount == 1, "Expected injected recovery action")
    viewController.performLaunchAtLoginToggleClick()
    try expect(
        requestedValues == [false, false],
        "Expected approval-state click to request disable"
    )

    coordinator.updateLaunchAtLoginState(
        LaunchAtLoginSettingsState(
            status: .disabled,
            failure: .registrationFailed
        )
    )
    viewController.performLaunchAtLoginToggleClick()
    viewController.performLaunchAtLoginToggleClick()
    try expect(
        requestedValues == [false, false, true, true],
        "Expected off-state clicks to request enable and repeat the saved intent"
    )
    try expect(
        viewController.renderedLaunchAtLoginDetailText != unregistrationFailureText,
        "Expected registration and unregistration failures to remain distinct"
    )
    try expect(
        !viewController.renderedLaunchAtLoginDetailText.hasPrefix("settings."),
        "Expected localized registration failure without raw error text"
    )
    coordinator.updateLaunchAtLoginState(
        LaunchAtLoginSettingsState(status: .unavailable)
    )
    try expect(
        !viewController.isLaunchAtLoginToggleEnabled,
        "Expected unavailable login service disabled"
    )
    controller.close()
}

private func launchAtLoginSettingsLocalizationParityTest() -> TestCase {
    TestCase(name: "login launch settings keep Korean and English keys in parity") {
        let korean = try launchSettingsLocalizationKeys(language: "ko")
        let english = try launchSettingsLocalizationKeys(language: "en")
        let required = Set([
            "settings.launch-at-login.status.disabled",
            "settings.launch-at-login.status.enabled",
            "settings.launch-at-login.status.requires-approval",
            "settings.launch-at-login.status.unavailable",
            "settings.launch-at-login.failure.registration",
            "settings.launch-at-login.failure.unregistration",
            "settings.launch-at-login.open-system-settings"
        ])

        try expect(korean == english, "Expected complete localization key parity")
        try expect(required.isSubset(of: korean), "Expected login status localization keys")
    }
}

private struct LaunchAtLoginSettingsStore {
    let suiteName: String
    let inspectionDefaults: UserDefaults
    let repository: AppPreferencesRepository

    init() throws {
        let name = "io.github.symflee.codex-gauge.tests.launch-settings.\(UUID().uuidString)"
        guard let inspectionDefaults = UserDefaults(suiteName: name),
              let repositoryDefaults = UserDefaults(suiteName: name) else {
            throw TestFailure(description: "Unable to create launch settings defaults")
        }
        suiteName = name
        self.inspectionDefaults = inspectionDefaults
        repository = AppPreferencesRepository(userDefaults: repositoryDefaults)
    }

    func cleanUp() {
        inspectionDefaults.removePersistentDomain(forName: suiteName)
    }
}

@MainActor
private final class LaunchAtLoginSettingsStateSource {
    var state: LaunchAtLoginSettingsState

    init(status: LaunchAtLoginStatus) {
        state = LaunchAtLoginSettingsState(status: status)
    }
}

@MainActor
private func showLaunchSettingsController(
    _ coordinator: SettingsWindowCoordinator
) async throws -> SettingsWindowController {
    guard let controller = await coordinator.showSettings() else {
        throw TestFailure(description: "Expected settings controller")
    }
    return controller
}

private func launchSettingsLocalizationKeys(language: String) throws -> Set<String> {
    let root = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
    let file = root
        .appendingPathComponent("Sources/CodexGaugeAppKit/Resources")
        .appendingPathComponent("\(language).lproj/Localizable.strings")
    let contents = try String(contentsOf: file, encoding: .utf8)
    return Set(contents.split(separator: "\n").compactMap(localizationKey))
}

private func localizationKey(_ line: Substring) -> String? {
    guard line.first == "\"" else {
        return nil
    }
    let parts = line.split(separator: "\"", maxSplits: 2, omittingEmptySubsequences: false)
    guard parts.count > 1 else {
        return nil
    }
    return String(parts[1])
}

private func requireLaunchSettingsSendable<Value: Sendable>(_ value: Value) {
    _ = value
}
