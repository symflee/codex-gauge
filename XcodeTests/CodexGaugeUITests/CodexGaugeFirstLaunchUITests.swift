import XCTest

final class CodexGaugeFirstLaunchUITests: XCTestCase {
    private let settingsWindowTitle = "Codex Gauge 설정"
    private let statusAccessibilityLabel =
        "Codex 5시간 한도 남은 사용량 83퍼센트"

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    @MainActor
    func testFirstLaunchShowsSettingsWindowOnlyOnce() {
        let application = makeApplication(resetFirstLaunch: true)

        application.launch()

        let settingsWindow = application.windows[settingsWindowTitle]
        XCTAssertTrue(
            settingsWindow.waitForExistence(timeout: 10),
            "Expected the first-launch settings window"
        )
        assertSyntheticStatus(in: application)

        application.terminate()
        let subsequentApplication = makeApplication(resetFirstLaunch: false)
        subsequentApplication.launch()
        assertSyntheticStatus(in: subsequentApplication)

        XCTAssertFalse(
            subsequentApplication.windows[settingsWindowTitle]
                .waitForExistence(timeout: 3),
            "Expected later launches to keep settings closed"
        )
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
        let statusItem = application.statusItems
            .matching(
                NSPredicate(
                    format: "label == %@",
                    statusAccessibilityLabel
                )
            )
            .firstMatch
        XCTAssertTrue(
            statusItem.waitForExistence(timeout: 10),
            "Expected the synthetic Codex status accessibility label"
        )
    }
}
