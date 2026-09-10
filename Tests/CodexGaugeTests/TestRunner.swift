import AppKit
import Darwin
import Foundation

private enum TestSuiteSelection: String {
    case core
    case `protocol`
    case process
    case refresh
    case settings
    case appkit
    case full
}

private enum TestSelectionError: Error {
    case invalidSelection
    case noMatches

    var message: String {
        switch self {
        case .invalidSelection:
            return "codex-gauge-tests: invalid selection"
        case .noMatches:
            return "codex-gauge-tests: no tests matched"
        }
    }
}

private struct TestSelection {
    var suite = TestSuiteSelection.full
    var nameFilter: String?
}

private struct TestOutputOptions {
    var isVerbose = false
    var listsTests = false
}

private struct TestRunnerOptions {
    var selection = TestSelection()
    var output = TestOutputOptions()
}

private struct TestGroup {
    let suite: TestSuiteSelection
    let tests: [TestCase]

    var requiresApplication: Bool {
        suite == .appkit
    }
}

private struct SelectedTests {
    let tests: [TestCase]
    let requiresApplication: Bool
}

@main
struct TestRunner {
    @MainActor
    static func main() async {
        guard SyntheticAppServer.runIfRequested() == false else {
            return
        }
        guard SyntheticCLIVersionCommand.runIfRequested() == false else {
            return
        }
        exit(await runSelectedTests())
    }

    @MainActor
    private static func runSelectedTests() async -> Int32 {
        let options = parseOptionsOrExit()
        let selected = selectTestsOrExit(options.selection)
        guard options.output.listsTests == false else {
            list(selected.tests)
            return EXIT_SUCCESS
        }
        guard !selected.requiresApplication || prepareApplication() else {
            return EXIT_FAILURE
        }
        return await executeTests(
            selected.tests,
            isVerbose: options.output.isVerbose
        )
    }

    @MainActor
    private static func prepareApplication() -> Bool {
        let application = NSApplication.shared
        _ = application.setActivationPolicy(.prohibited)
        let policy = application.activationPolicy()
        return policy != .regular && policy != .accessory
    }

    @MainActor
    private static func executeTests(
        _ tests: [TestCase],
        isVerbose: Bool
    ) async -> Int32 {
        let failureCount = await run(tests, isVerbose: isVerbose)
        let passCount = tests.count - Int(failureCount)
        report(
            "SUMMARY total=\(tests.count) pass=\(passCount) fail=\(failureCount)"
        )
        return failureCount == 0 ? EXIT_SUCCESS : EXIT_FAILURE
    }

    private static func testGroups() -> [TestGroup] {
        initialTestGroups()
            + serviceTestGroups()
            + settingsTestGroups()
            + applicationTestGroups()
    }

    private static func initialTestGroups() -> [TestGroup] {
        [
            TestGroup(suite: .core, tests: quotaDomainTests()),
            TestGroup(suite: .core, tests: quotaDisplayTests()),
            TestGroup(suite: .protocol, tests: protocolTests()),
            TestGroup(suite: .process, tests: appServerSmokeTests()),
            TestGroup(suite: .process, tests: codexExecutableLocatorTests()),
            TestGroup(suite: .process, tests: processLifecycleTests()),
            TestGroup(suite: .process, tests: usageSessionTests())
        ]
    }

    private static func serviceTestGroups() -> [TestGroup] {
        [
            TestGroup(suite: .refresh, tests: refreshTests()),
            TestGroup(suite: .settings, tests: appPreferencesTests()),
            TestGroup(suite: .process, tests: connectionDiagnosticsTests()),
            TestGroup(suite: .appkit, tests: statusItemRenderingTests()),
            TestGroup(suite: .settings, tests: launchAtLoginTests()),
            TestGroup(suite: .settings, tests: launchAtLoginSettingsTests()),
            TestGroup(suite: .appkit, tests: quotaDetailsMenuTests())
        ]
    }

    private static func settingsTestGroups() -> [TestGroup] {
        [
            TestGroup(suite: .refresh, tests: systemActivityMonitorTests()),
            TestGroup(suite: .refresh, tests: quotaResetRefreshSchedulerTests()),
            TestGroup(suite: .settings, tests: settingsFormTests()),
            TestGroup(suite: .appkit, tests: settingsWindowForegroundPresenterTests()),
            TestGroup(suite: .appkit, tests: settingsWindowTests()),
            TestGroup(suite: .settings, tests: firstLaunchSettingsTests()),
            TestGroup(suite: .appkit, tests: assistiveDisplayMonitorTests())
        ]
    }

    private static func applicationTestGroups() -> [TestGroup] {
        [
            TestGroup(suite: .refresh, tests: refreshPresentationAdapterTests()),
            TestGroup(suite: .refresh, tests: applicationActivityGateTests()),
            TestGroup(suite: .appkit, tests: applicationRuntimeTests()),
            TestGroup(suite: .appkit, tests: applicationTerminationTests()),
            TestGroup(suite: .appkit, tests: applicationUITestFixtureTests()),
            TestGroup(suite: .appkit, tests: applicationUpdateRuntimeTests())
        ]
    }

    @MainActor
    private static func run(
        _ tests: [TestCase],
        isVerbose: Bool
    ) async -> Int32 {
        var failureCount: Int32 = 0
        for test in tests {
            failureCount += await run(test, isVerbose: isVerbose)
        }
        return failureCount
    }

    @MainActor
    private static func run(
        _ test: TestCase,
        isVerbose: Bool
    ) async -> Int32 {
        reportProgress("RUN \(test.name)", isVerbose: isVerbose)
        do {
            try await test.body()
            reportProgress("PASS \(test.name)", isVerbose: isVerbose)
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

    private static func reportProgress(
        _ message: String,
        isVerbose: Bool
    ) {
        guard isVerbose else {
            return
        }
        report(message)
    }

    private static func list(_ tests: [TestCase]) {
        tests.forEach { report("TEST \($0.name)") }
    }

    private static func parseOptionsOrExit() -> TestRunnerOptions {
        do {
            return try parseOptions(Array(CommandLine.arguments.dropFirst()))
        } catch let error as TestSelectionError {
            reject(error)
        } catch {
            reject(.invalidSelection)
        }
    }

    private static func selectTestsOrExit(
        _ selection: TestSelection
    ) -> SelectedTests {
        do {
            return try selectedTests(selection)
        } catch let error as TestSelectionError {
            reject(error)
        } catch {
            reject(.invalidSelection)
        }
    }

    private static func parseOptions(
        _ arguments: [String]
    ) throws -> TestRunnerOptions {
        var options = TestRunnerOptions()
        var index = 0
        while index < arguments.count {
            index = try consume(arguments, at: index, into: &options)
        }
        return options
    }

    private static func consume(
        _ arguments: [String], at index: Int, into options: inout TestRunnerOptions
    ) throws -> Int {
        let argument = arguments[index]
        if setOutputOption(argument, output: &options.output) {
            return index + 1
        }
        if argument == "--suite" {
            return try consumeSuite(arguments, at: index, into: &options)
        }
        guard argument == "--filter" else {
            throw TestSelectionError.invalidSelection
        }
        return try consumeFilter(arguments, at: index, into: &options)
    }

    private static func setOutputOption(
        _ argument: String,
        output: inout TestOutputOptions
    ) -> Bool {
        if argument == "--verbose" {
            output.isVerbose = true
            return true
        }
        guard argument == "--list" else {
            return false
        }
        output.listsTests = true
        return true
    }

    private static func consumeSuite(
        _ arguments: [String],
        at index: Int,
        into options: inout TestRunnerOptions
    ) throws -> Int {
        let valueIndex = index + 1
        guard valueIndex < arguments.count else {
            throw TestSelectionError.invalidSelection
        }
        guard let suite = TestSuiteSelection(rawValue: arguments[valueIndex]) else {
            throw TestSelectionError.invalidSelection
        }
        options.selection.suite = suite
        return valueIndex + 1
    }

    private static func consumeFilter(
        _ arguments: [String],
        at index: Int,
        into options: inout TestRunnerOptions
    ) throws -> Int {
        let valueIndex = index + 1
        guard valueIndex < arguments.count else {
            throw TestSelectionError.invalidSelection
        }
        guard arguments[valueIndex].isEmpty == false else {
            throw TestSelectionError.invalidSelection
        }
        options.selection.nameFilter = arguments[valueIndex]
        return valueIndex + 1
    }

    private static func selectedTests(
        _ selection: TestSelection
    ) throws -> SelectedTests {
        let groups = groups(in: selection.suite).compactMap {
            selectedGroup($0, nameFilter: selection.nameFilter)
        }
        let tests = groups.flatMap(\.tests)
        guard tests.isEmpty == false else {
            throw TestSelectionError.noMatches
        }
        return SelectedTests(
            tests: tests,
            requiresApplication: groups.contains { $0.requiresApplication }
        )
    }

    private static func groups(
        in suite: TestSuiteSelection
    ) -> [TestGroup] {
        guard suite != .full else {
            return testGroups()
        }
        return testGroups()
            .filter { $0.suite == suite }
    }

    private static func selectedGroup(
        _ group: TestGroup,
        nameFilter: String?
    ) -> TestGroup? {
        guard let nameFilter else {
            return group
        }
        let tests = group.tests.filter {
            matchesTest($0, nameFilter: nameFilter)
        }
        guard tests.isEmpty == false else {
            return nil
        }
        return TestGroup(suite: group.suite, tests: tests)
    }

    private static func matchesTest(
        _ test: TestCase,
        nameFilter: String
    ) -> Bool {
        test.name.range(
            of: nameFilter,
            options: .caseInsensitive,
            locale: Locale(identifier: "en_US_POSIX")
        ) != nil
    }

    private static func reject(_ error: TestSelectionError) -> Never {
        fputs("\(error.message)\n", stderr)
        exit(64)
    }
}
