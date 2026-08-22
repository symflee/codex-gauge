import Darwin
import Foundation

@main
struct TestRunner {
    static func main() async {
        guard SyntheticAppServer.runIfRequested() == false else {
            return
        }
        guard SyntheticCLIVersionCommand.runIfRequested() == false else {
            return
        }
        let failures = await run(allTests())
        guard failures == 0 else {
            exit(EXIT_FAILURE)
        }
    }

    private static func allTests() -> [TestCase] {
        scaffoldTests()
            + quotaDomainTests()
            + quotaDisplayTests()
            + protocolTests()
            + appServerSmokeTests()
            + codexExecutableLocatorTests()
            + usageSessionTests()
            + refreshTests()
            + appPreferencesTests()
            + connectionDiagnosticsTests()
            + statusItemRenderingTests()
            + launchAtLoginTests()
            + launchAtLoginSettingsTests()
            + quotaDetailsMenuTests()
            + systemActivityMonitorTests()
            + quotaResetRefreshSchedulerTests()
            + settingsFormTests()
            + settingsWindowForegroundPresenterTests()
            + settingsWindowTests()
            + firstLaunchSettingsTests()
            + assistiveDisplayMonitorTests()
            + refreshPresentationAdapterTests()
            + applicationActivityGateTests()
            + applicationRuntimeTests()
            + applicationTerminationTests()
            + applicationUITestFixtureTests()
    }

    private static func run(_ tests: [TestCase]) async -> Int32 {
        var failureCount: Int32 = 0
        for test in tests {
            failureCount += await run(test)
        }
        return failureCount
    }

    private static func run(_ test: TestCase) async -> Int32 {
        report("RUN \(test.name)")
        do {
            try await test.body()
            report("PASS \(test.name)")
            return 0
        } catch {
            report("FAIL \(test.name): \(error)")
            return 1
        }
    }

    private static func report(_ message: String) {
        print(message)
        fflush(stdout)
    }
}
