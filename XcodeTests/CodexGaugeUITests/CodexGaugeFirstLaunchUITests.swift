import XCTest

final class CodexGaugeFirstLaunchUITests: XCTestCase {
    private let effectsEnvironmentKey =
        "CODEX_GAUGE_LOCAL_RELEASE_EFFECTS_ALLOWED"
    private let preferencesEnvironmentKey =
        "CODEX_GAUGE_UI_TEST_PREFERENCES_SUITE"
    private let preferencesSuiteName =
        "io.github.symflee.codex-gauge.uitest.\(UUID().uuidString)"
    private var launchedApplications = [XCUIApplication]()
    private let statusItemIdentifier = "codex-gauge.status-item"
    private let settingsMenuIdentifier = "codex-gauge.menu.action.settings"
    private let settingsWindowIdentifier = "codex-gauge.settings.window"
    private let settingsCloseIdentifier = "codex-gauge.settings.close"
    private let settingsLanguageIdentifier = "codex-gauge.settings.language"
    private let settingsGaugePresetIdentifier = "codex-gauge.settings.gauge-preset"
    private let statusAccessibilityLabel =
        "Codex 5시간 한도 남은 사용량 83퍼센트"

    override func setUpWithError() throws {
        continueAfterFailure = false
        guard ProcessInfo.processInfo.environment[effectsEnvironmentKey] == "1" else {
            throw NSError(
                domain: "CodexGaugeUITests",
                code: 1,
                userInfo: [
                    NSLocalizedDescriptionKey:
                        "UI tests require explicit local release effects approval"
                ]
            )
        }
    }

    override func tearDownWithError() throws {
        launchedApplications.reversed().forEach { $0.terminate() }
        launchedApplications.removeAll()
        UserDefaults(suiteName: preferencesSuiteName)?
            .removePersistentDomain(forName: preferencesSuiteName)
    }

    @MainActor
    func testFirstLaunchShowsSettingsWindowOnlyOnce() {
        let application = makeApplication(resetFirstLaunch: true)
        completeFirstLaunch(in: application)
        application.terminate()
        verifySubsequentLaunch()
    }

    @MainActor
    private func completeFirstLaunch(in application: XCUIApplication) {
        application.launch()
        let window = application.windows[settingsWindowIdentifier]
        XCTAssertTrue(
            window.waitForExistence(timeout: 10),
            "Expected the first-launch settings window"
        )
        selectKoreanLanguage(in: window, application: application)
        selectGaugePreset(
            named: "그라파이트",
            in: window,
            application: application
        )
        assertSyntheticStatus(in: application)
    }

    @MainActor
    private func verifySubsequentLaunch() {
        let application = makeApplication(resetFirstLaunch: false)
        application.launch()
        assertSyntheticStatus(in: application)
        XCTAssertFalse(
            application.windows[settingsWindowIdentifier]
                .waitForExistence(timeout: 3),
            "Expected later launches to keep settings closed"
        )
        assertSettingsMenuLifecycle(
            in: application,
            expectedGaugePreset: "그라파이트"
        )
        application.terminate()
    }

    @MainActor
    private func makeApplication(resetFirstLaunch: Bool) -> XCUIApplication {
        let application = XCUIApplication()
        application.launchEnvironment[effectsEnvironmentKey] = "1"
        application.launchEnvironment[preferencesEnvironmentKey] =
            preferencesSuiteName
        application.launchArguments = fixtureArguments(
            resetFirstLaunch: resetFirstLaunch
        )
        launchedApplications.append(application)
        return application
    }

    private func fixtureArguments(resetFirstLaunch: Bool) -> [String] {
        var arguments = [
            "-AppleLanguages",
            "(ko)",
            "--codex-gauge-ui-test-fixture-83"
        ]
        guard resetFirstLaunch else {
            return arguments
        }
        arguments.append(
            "--codex-gauge-ui-test-reset-first-launch"
        )
        return arguments
    }

    @MainActor
    private func assertSyntheticStatus(in application: XCUIApplication) {
        let predicate = NSPredicate(
            format: "identifier == %@ AND label == %@",
            statusItemIdentifier,
            statusAccessibilityLabel
        )
        let statusItem = application.statusItems.matching(predicate).firstMatch
        XCTAssertTrue(
            statusItem.waitForExistence(timeout: 10),
            "Expected status item \(statusItemIdentifier) to publish "
                + "accessibility label \(statusAccessibilityLabel) within 10 seconds"
        )
    }

    @MainActor
    private func selectKoreanLanguage(
        in settingsWindow: XCUIElement,
        application: XCUIApplication
    ) {
        let language = settingsWindow.popUpButtons[settingsLanguageIdentifier]
        XCTAssertTrue(
            language.waitForExistence(timeout: 5),
            "Expected the application language selector"
        )
        language.click()
        let korean = application.menuItems["한국어"]
        XCTAssertTrue(korean.waitForExistence(timeout: 5))
        korean.click()
    }

    @MainActor
    private func selectGaugePreset(
        named presetName: String,
        in settingsWindow: XCUIElement,
        application: XCUIApplication
    ) {
        let preset = settingsWindow.popUpButtons[settingsGaugePresetIdentifier]
        XCTAssertTrue(
            preset.waitForExistence(timeout: 5),
            "Expected the gauge color preset selector"
        )
        preset.click()
        let menuItem = application.menuItems[presetName]
        XCTAssertTrue(menuItem.waitForExistence(timeout: 5))
        menuItem.click()
        assertGaugePreset(presetName, in: settingsWindow)
    }

    @MainActor
    private func assertGaugePreset(
        _ presetName: String,
        in settingsWindow: XCUIElement
    ) {
        let preset = settingsWindow.popUpButtons[settingsGaugePresetIdentifier]
        XCTAssertTrue(preset.waitForExistence(timeout: 5))
        XCTAssertEqual(preset.value as? String, presetName)
    }

    @MainActor
    private func assertSettingsMenuLifecycle(
        in application: XCUIApplication,
        expectedGaugePreset: String
    ) {
        openSettingsFromStatusItem(in: application)
        let settingsWindow = application.windows[settingsWindowIdentifier]
        XCTAssertTrue(
            settingsWindow.waitForExistence(timeout: 10),
            "Expected the settings menu action to show the window"
        )
        assertGaugePreset(expectedGaugePreset, in: settingsWindow)

        let closeButton = settingsWindow.buttons[settingsCloseIdentifier]
        XCTAssertTrue(closeButton.waitForExistence(timeout: 5))
        closeButton.click()
        XCTAssertTrue(
            settingsWindow.waitForNonExistence(timeout: 5),
            "Expected closing settings to remove the window"
        )

        openSettingsFromStatusItem(in: application)
        XCTAssertTrue(
            application.windows[settingsWindowIdentifier]
                .waitForExistence(timeout: 10),
            "Expected settings to be recreated from the menu"
        )
        assertGaugePreset(
            expectedGaugePreset,
            in: application.windows[settingsWindowIdentifier]
        )
    }

    @MainActor
    private func openSettingsFromStatusItem(in application: XCUIApplication) {
        let statusItem = application.statusItems[statusItemIdentifier]
        XCTAssertTrue(statusItem.waitForExistence(timeout: 10))
        statusItem.click()

        let settingsMenuItem = application.menuItems[settingsMenuIdentifier]
        XCTAssertTrue(
            settingsMenuItem.waitForExistence(timeout: 5),
            "Expected the cached menu to expose Settings"
        )
        settingsMenuItem.click()
    }
}
