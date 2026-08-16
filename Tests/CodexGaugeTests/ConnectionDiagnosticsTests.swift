import CodexGaugeProtocol
import CodexGaugeRefresh
import CodexGaugeSettings
import Darwin
import Foundation

func connectionDiagnosticsTests() -> [TestCase] {
    [
        cliVersionParserTest(),
        cliVersionProbeTest(),
        cliVersionProbeFailureTest(),
        cliVersionProbeCleanupTest(),
        cliVersionProbeCancellationTest(),
        connectionInspectorTest(),
        connectionInspectorFailureTest(),
        connectionStatusResolverTest(),
        diagnosticReportRedactionTest(),
        connectionDiagnosticValuesAreSendableTest()
    ]
}

private func cliVersionParserTest() -> TestCase {
    TestCase(name: "CLI version parser keeps only a bounded version token") {
        let parser = CodexCLIVersionParser()
        let version = try parser.parse(Data("codex-cli 1.2.3-beta.1+7\n".utf8))

        try expect(version.value == "1.2.3-beta.1+7", "Expected normalized version token")
        try expect(
            String(describing: version) == "1.2.3-beta.1+7",
            "Expected no raw command output"
        )
        try await expectVersionError(.invalidOutput) {
            _ = try parser.parse(Data("synthetic-account.example\n".utf8))
        }
        try await expectVersionError(.invalidOutput) {
            _ = try parser.parse(Data("codex-cli /Synthetic/Private/codex\n".utf8))
        }
    }
}

private func cliVersionProbeTest() -> TestCase {
    TestCase(name: "CLI version probe executes the validated URL with version argument") {
        let valid = try await probeVersion(mode: .valid)
        try expect(valid.value == "1.2.3", "Expected synthetic CLI version")

        let stderrFlood = try await probeVersion(mode: .stderrFlood)
        try expect(stderrFlood.value == "2.3.4", "Expected stderr to be discarded")
    }
}

private func cliVersionProbeFailureTest() -> TestCase {
    TestCase(name: "CLI version probe classifies output and process failures") {
        try await expectProbeError(.invalidOutput, mode: .malformed)
        try await expectProbeError(.outputTooLarge, mode: .oversized)
        try await expectProbeError(.processFailed, mode: .nonzeroExit)

        let missing = FileManager.default.temporaryDirectory
            .appendingPathComponent("codex-gauge-missing-version-(UUID().uuidString)")
        let probe = CodexCLIVersionProbe(configuration: versionProbeConfiguration(.valid))
        try await expectVersionError(.launchFailed) {
            _ = try await probe.version(of: missing)
        }
    }
}

private func cliVersionProbeCleanupTest() -> TestCase {
    TestCase(name: "CLI version timeout terminates the synthetic child") {
        let pidFile = FileManager.default.temporaryDirectory
            .appendingPathComponent("codex-gauge-version-pid-(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: pidFile) }
        let configuration = versionProbeConfiguration(.timeout, pidFile: pidFile)
        let probe = CodexCLIVersionProbe(configuration: configuration)

        try await expectVersionError(.timeout) {
            _ = try await probe.version(of: syntheticExecutableURL)
        }
        let processIdentifier = try await readSyntheticVersionProcessIdentifier(from: pidFile)
        try expect(
            Darwin.kill(processIdentifier, 0) != 0,
            "Expected timeout cleanup to leave no child"
        )
    }
}

private func cliVersionProbeCancellationTest() -> TestCase {
    TestCase(name: "CLI version cancellation terminates the synthetic child") {
        let pidFile = FileManager.default.temporaryDirectory
            .appendingPathComponent("codex-gauge-version-cancel-pid-(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: pidFile) }
        let environment = [
            SyntheticCLIVersionCommand.modeEnvironmentKey: SyntheticCLIVersionMode.timeout.rawValue,
            SyntheticCLIVersionCommand.pidFileEnvironmentKey: pidFile.path
        ]
        let probe = CodexCLIVersionProbe(
            configuration: CodexCLIVersionProbeConfiguration(
                timeout: .seconds(2),
                stopGracePeriod: .milliseconds(150),
                maximumOutputBytes: 256,
                environment: environment
            )
        )
        let operation: Task<CodexCLIVersion, any Error> = Task {
            try await probe.version(of: syntheticExecutableURL)
        }
        let processIdentifier = try await readSyntheticVersionProcessIdentifier(from: pidFile)

        operation.cancel()
        try await expectVersionTaskError(.cancelled, operation: operation)
        try expect(
            Darwin.kill(processIdentifier, 0) != 0,
            "Expected cancellation cleanup to leave no child"
        )
    }
}

private func connectionInspectorTest() -> TestCase {
    TestCase(name: "connection inspector exposes only a generalized executable location") {
        let executable = URL(
            fileURLWithPath: "/Synthetic/Applications/Codex.app/Contents/Resources/codex"
        )
        let locator = StubCodexLocator(result: .success(executable))
        let probe = StubVersionProbe(result: .success(try parsedVersion("4.5.6")))
        let inspector = ConnectionDiagnosticsInspector(versionProbe: probe)
        let snapshot = await inspector.inspect(
            locator: locator,
            source: .userSelected,
            connectionStatus: .connected
        )

        try expect(snapshot.path?.source == .userSelected, "Expected selected source")
        try expect(snapshot.path?.category == .applicationBundle, "Expected app category")
        try expect(snapshot.path?.basename == "codex", "Expected safe basename only")
        try expect(snapshot.cliVersion?.value == "4.5.6", "Expected CLI version")
        try expect(snapshot.connectionStatus == .connected, "Expected cached connection status")
        try expect(
            !String(describing: snapshot).contains("/Synthetic/"),
            "Expected no absolute path in the value description"
        )
    }
}

private func connectionInspectorFailureTest() -> TestCase {
    TestCase(name: "connection inspector preserves typed locator and probe failures") {
        let probe = StubVersionProbe(result: .failure(.timeout))
        let inspector = ConnectionDiagnosticsInspector(versionProbe: probe)
        let notFound = await inspector.inspect(
            locator: StubCodexLocator(result: .failure(.notFound)),
            source: .automatic,
            connectionStatus: .checking
        )
        let invalid = await inspector.inspect(
            locator: StubCodexLocator(result: .failure(.invalidSelection)),
            source: .userSelected,
            connectionStatus: .connected
        )
        let timeout = await inspector.inspect(
            locator: StubCodexLocator(
                result: .success(URL(fileURLWithPath: "/Synthetic/bin/codex"))
            ),
            source: .automatic,
            connectionStatus: .checking
        )

        try expect(notFound.connectionStatus == .notFound, "Expected not-found status")
        try expect(notFound.executableSource == .automatic, "Expected automatic source")
        try expect(invalid.connectionStatus == .invalidSelection, "Expected invalid selection")
        try expect(invalid.executableSource == .userSelected, "Expected selected source")
        try expect(timeout.connectionStatus == .timeout, "Expected probe timeout status")
        try expect(timeout.cliVersionIssue == .timeout, "Expected typed version issue")
    }
}

private func connectionStatusResolverTest() -> TestCase {
    TestCase(name: "connection status resolver maps refresh state without raw errors") {
        let resolver = ConnectionStatusResolver()
        try expect(resolver.resolve(.initial) == .checking, "Expected initial checking")
        try expect(
            resolver.resolve(publication(failure: .codexNotFound)) == .notFound,
            "Expected not found"
        )
        try expect(
            resolver.resolve(publication(failure: .invalidCodexSelection)) == .invalidSelection,
            "Expected invalid selection"
        )
        try expect(
            resolver.resolve(publication(failure: .signedOut)) == .signedOut,
            "Expected signed out"
        )
        try expect(
            resolver.resolve(publication(failure: .unsupportedAuthentication)) == .unsupportedAuth,
            "Expected unsupported auth"
        )
        try expect(
            resolver.resolve(publication(failure: .protocolIncompatible)) == .incompatible,
            "Expected incompatible protocol"
        )
        try expect(
            resolver.resolve(publication(failure: .timeout)) == .timeout,
            "Expected timeout"
        )
        try expect(
            resolver.resolve(publication(failure: .processUnavailable)) == .processFailure,
            "Expected process failure"
        )
        let connected = RefreshPublication(
            products: RefreshPublication.initial.products,
            lastSuccessfulRefresh: Date(timeIntervalSince1970: 1_900_000_000),
            failure: nil,
            isRefreshing: false
        )
        try expect(resolver.resolve(connected) == .connected, "Expected connected")
    }
}

private func diagnosticReportRedactionTest() -> TestCase {
    TestCase(name: "diagnostic report contains typed metadata without absolute paths") {
        let executable = URL(
            fileURLWithPath: "/Synthetic/Private/Account/private-workspace-codex"
        )
        let inspector = ConnectionDiagnosticsInspector(
            versionProbe: StubVersionProbe(result: .success(try parsedVersion("7.8.9")))
        )
        let snapshot = await inspector.inspect(
            locator: StubCodexLocator(result: .success(executable)),
            source: .userSelected,
            connectionStatus: .signedOut
        )
        let environment = DiagnosticEnvironment(
            appVersion: "0.1.0",
            macOSVersion: "15.4.1",
            architecture: .arm64
        )
        let report = ConnectionDiagnosticReportBuilder().makeReport(
            snapshot: snapshot,
            environment: environment
        )

        try expect(report.contains("app-version: 0.1.0"), "Expected app version")
        try expect(report.contains("connection-status: signed-out"), "Expected typed status")
        try expect(report.contains("path-source: user-selected"), "Expected path source")
        try expect(report.contains("path-category: other"), "Expected generalized path")
        try expect(!report.contains("executable-name:"), "Expected no executable basename")
        try expect(!report.contains("private-workspace"), "Expected no selected filename")
        try expect(report.contains("cli-version: 7.8.9"), "Expected CLI version")
        try expect(!report.contains("/Synthetic/"), "Expected no absolute path")
        try expect(!report.lowercased().contains("email"), "Expected no account field")
        try expect(!report.lowercased().contains("token"), "Expected no token field")
    }
}

private func connectionDiagnosticValuesAreSendableTest() -> TestCase {
    TestCase(name: "connection diagnostic values and services are sendable") {
        requireConnectionSendable(CodexCLIVersionProbeConfiguration.production)
        requireConnectionSendable(CodexCLIVersionProbeError.timeout)
        requireConnectionSendable(CodexConnectionStatus.connected)
        requireConnectionSendable(DiagnosticArchitecture.x86_64)
        requireConnectionSendable(ConnectionDiagnosticsSnapshot.checking)
    }
}

private var syntheticExecutableURL: URL {
    URL(fileURLWithPath: CommandLine.arguments[0]).standardizedFileURL
}

private func versionProbeConfiguration(
    _ mode: SyntheticCLIVersionMode,
    pidFile: URL? = nil
) -> CodexCLIVersionProbeConfiguration {
    var environment = [SyntheticCLIVersionCommand.modeEnvironmentKey: mode.rawValue]
    if let pidFile {
        environment[SyntheticCLIVersionCommand.pidFileEnvironmentKey] = pidFile.path
    }
    return CodexCLIVersionProbeConfiguration(
        timeout: .milliseconds(150),
        stopGracePeriod: .milliseconds(150),
        maximumOutputBytes: 256,
        environment: environment
    )
}

private func probeVersion(
    mode: SyntheticCLIVersionMode
) async throws -> CodexCLIVersion {
    let probe = CodexCLIVersionProbe(configuration: versionProbeConfiguration(mode))
    return try await probe.version(of: syntheticExecutableURL)
}

private func expectProbeError(
    _ expected: CodexCLIVersionProbeError,
    mode: SyntheticCLIVersionMode
) async throws {
    let probe = CodexCLIVersionProbe(configuration: versionProbeConfiguration(mode))
    try await expectVersionError(expected) {
        _ = try await probe.version(of: syntheticExecutableURL)
    }
}

private func expectVersionError(
    _ expected: CodexCLIVersionProbeError,
    operation: () async throws -> Void
) async throws {
    do {
        try await operation()
        throw TestFailure(description: "Expected typed CLI version failure")
    } catch let error as CodexCLIVersionProbeError {
        try expect(error == expected, "Unexpected CLI version failure: \(error)")
    }
}

private func expectVersionTaskError(
    _ expected: CodexCLIVersionProbeError,
    operation: Task<CodexCLIVersion, any Error>
) async throws {
    do {
        _ = try await operation.value
        throw TestFailure(description: "Expected cancelled CLI version task")
    } catch let error as CodexCLIVersionProbeError {
        try expect(error == expected, "Unexpected CLI version task failure: \(error)")
    }
}

private func parsedVersion(_ value: String) throws -> CodexCLIVersion {
    try CodexCLIVersionParser().parse(Data(value.utf8))
}

private func readSyntheticVersionProcessIdentifier(
    from file: URL
) async throws -> pid_t {
    let clock = ContinuousClock()
    let deadline = clock.now.advanced(by: .milliseconds(150))
    while clock.now < deadline {
        if let identifier = syntheticVersionProcessIdentifier(in: file) {
            return identifier
        }
        try await clock.sleep(for: .milliseconds(5))
    }
    throw TestFailure(description: "Expected synthetic version PID")
}

private func syntheticVersionProcessIdentifier(in file: URL) -> pid_t? {
    guard let data = try? Data(contentsOf: file) else {
        return nil
    }
    guard let value = String(data: data, encoding: .utf8) else {
        return nil
    }
    return pid_t(value)
}

private struct StubCodexLocator: CodexLocating {
    let result: Result<URL, CodexLocationError>

    func locate() throws(CodexLocationError) -> URL {
        switch result {
        case .success(let url):
            url
        case .failure(let error):
            throw error
        }
    }
}

private struct StubVersionProbe: CodexCLIVersionProbing {
    let result: Result<CodexCLIVersion, CodexCLIVersionProbeError>

    func version(
        of executableURL: URL
    ) async throws(CodexCLIVersionProbeError) -> CodexCLIVersion {
        _ = executableURL
        switch result {
        case .success(let version):
            return version
        case .failure(let error):
            throw error
        }
    }
}

private func publication(failure: RefreshFailure) -> RefreshPublication {
    RefreshPublication(
        products: RefreshPublication.initial.products,
        lastSuccessfulRefresh: nil,
        failure: failure,
        isRefreshing: false
    )
}

private func requireConnectionSendable<Value: Sendable>(_ value: Value) {
    _ = value
}
