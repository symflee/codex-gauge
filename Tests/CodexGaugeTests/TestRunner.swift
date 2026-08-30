import AppKit
import Darwin
import Foundation

@main
struct TestRunner {
    @MainActor
    static func main() {
        guard SyntheticAppServer.runIfRequested() == false else {
            return
        }
        guard SyntheticCLIVersionCommand.runIfRequested() == false else {
            return
        }

        let application = NSApplication.shared
        var completionStatus: Int32?
        Task { @MainActor in
            completionStatus = await executeTests()
            stop(application)
        }
        application.run()
        exit(completionStatus ?? EXIT_FAILURE)
    }

    @MainActor
    private static func executeTests() async -> Int32 {
        let tests = allTests()
        let failureCount = await run(tests)
        let passCount = tests.count - Int(failureCount)
        report(
            "SUMMARY total=\(tests.count) pass=\(passCount) fail=\(failureCount)"
        )
        return failureCount == 0 ? EXIT_SUCCESS : EXIT_FAILURE
    }

    @MainActor
    private static func stop(_ application: NSApplication) {
        application.stop(nil)
        guard let event = wakeEvent() else {
            exit(EXIT_FAILURE)
        }
        application.postEvent(event, atStart: false)
    }

    private static func wakeEvent() -> NSEvent? {
        NSEvent.otherEvent(
            with: .applicationDefined,
            location: .zero,
            modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: 0,
            context: nil,
            subtype: 0,
            data1: 0,
            data2: 0
        )
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
            + applicationUpdateRuntimeTests()
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
