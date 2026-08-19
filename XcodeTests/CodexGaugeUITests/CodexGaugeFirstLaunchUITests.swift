import XCTest

final class CodexGaugeFirstLaunchUITests: XCTestCase {
    private let statusItemIdentifier = "codex-gauge.status-item"
    private let settingsMenuIdentifier = "codex-gauge.menu.action.settings"
    private let settingsWindowIdentifier = "codex-gauge.settings.window"
    private let settingsCloseIdentifier = "codex-gauge.settings.close"
    private let settingsLanguageIdentifier = "codex-gauge.settings.language"
    private let statusAccessibilityLabel =
        "Codex 5시간 한도 남은 사용량 83퍼센트"

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    @MainActor
    func testFirstLaunchShowsSettingsWindowOnlyOnce() {
        let application = makeApplication(resetFirstLaunch: true)

        application.launch()

        let settingsWindow = application.windows[settingsWindowIdentifier]
        XCTAssertTrue(
            settingsWindow.waitForExistence(timeout: 10),
            "Expected the first-launch settings window"
        )
        selectKoreanLanguage(in: settingsWindow, application: application)
        assertSyntheticStatus(in: application)

        application.terminate()
        let subsequentApplication = makeApplication(resetFirstLaunch: false)
        subsequentApplication.launch()
        assertSyntheticStatus(in: subsequentApplication)

        XCTAssertFalse(
            subsequentApplication.windows[settingsWindowIdentifier]
                .waitForExistence(timeout: 3),
            "Expected later launches to keep settings closed"
        )
        assertSettingsMenuLifecycle(in: subsequentApplication)
    }

    @MainActor
    private func makeApplication(resetFirstLaunch: Bool) -> XCUIApplication {
        let application = XCUIApplication()
        application.launchArguments = [
            "-AppleLanguages",
            "(ko)",
            "--codex-gauge-ui-test-fixture-83"
        ]
        guard resetFirstLaunch else {
            return application
        }
        application.launchArguments.append(
            "--codex-gauge-ui-test-reset-first-launch"
        )
        return application
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
    private func assertSettingsMenuLifecycle(in application: XCUIApplication) {
        openSettingsFromStatusItem(in: application)
        let settingsWindow = application.windows[settingsWindowIdentifier]
        XCTAssertTrue(
            settingsWindow.waitForExistence(timeout: 10),
            "Expected the settings menu action to show the window"
        )

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
