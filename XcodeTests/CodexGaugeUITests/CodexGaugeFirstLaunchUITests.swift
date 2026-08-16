import XCTest

final class CodexGaugeFirstLaunchUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    func testFirstLaunchShowsSettingsWindowOnlyOnce() {
        let application = XCUIApplication()
        application.launchArguments = [
            "-AppleLanguages",
            "(ko)",
            "--codex-gauge-ui-test-reset-first-launch"
        ]

        application.launch()

        let settingsWindow = application.windows["Codex Gauge 설정"]
        XCTAssertTrue(
            settingsWindow.waitForExistence(timeout: 10),
            "Expected the first-launch settings window"
        )

        application.terminate()
        let subsequentApplication = XCUIApplication()
        subsequentApplication.launchArguments = ["-AppleLanguages", "(ko)"]
        subsequentApplication.launch()

        XCTAssertFalse(
            subsequentApplication.windows["Codex Gauge 설정"]
                .waitForExistence(timeout: 3),
            "Expected later launches to keep settings closed"
        )
    }
}
