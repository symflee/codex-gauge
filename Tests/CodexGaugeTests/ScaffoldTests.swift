import AppKit
import CodexGaugeAppKit

func scaffoldTests() -> [TestCase] {
    [
        TestCase(name: "application delegate can be created") {
            let delegate = await MainActor.run {
                CodexGaugeApplicationDelegate()
            }

            try expect(
                String(describing: type(of: delegate)) == "CodexGaugeApplicationDelegate",
                "Expected the Codex Gauge application delegate"
            )
        }
    ]
}
