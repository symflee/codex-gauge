import CodexGaugeAppKit
import XCTest

final class CodexGaugeApplicationSmokeTests: XCTestCase {
    @MainActor
    func testApplicationDelegateCanBeCreated() {
        let delegate = CodexGaugeApplicationDelegate()

        XCTAssertNotNil(delegate)
    }
}
