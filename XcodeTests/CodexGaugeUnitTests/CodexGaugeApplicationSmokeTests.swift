import CodexGaugeAppKit
import Testing
import XCTest

@Test("UI fixture activation requires the exact launch argument")
func uiFixtureLaunchArgumentIsExact() {
    let exact = CodexGaugeApplicationLaunchOptions(
        arguments: [CodexGaugeApplicationLaunchOptions.uiTestFixture83Argument]
    )
    let similar = CodexGaugeApplicationLaunchOptions(
        arguments: ["--codex-gauge-ui-test-fixture-83-similar"]
    )

    #if DEBUG
    #expect(exact.mode == .uiTestFixture83)
    #else
    #expect(exact.mode == .production)
    #endif
    #expect(similar.mode == .production)
}

final class CodexGaugeApplicationSmokeTests: XCTestCase {
    @MainActor
    func testApplicationDelegateCanBeCreated() {
        let delegate = CodexGaugeApplicationDelegate()

        XCTAssertNotNil(delegate)
    }
}
