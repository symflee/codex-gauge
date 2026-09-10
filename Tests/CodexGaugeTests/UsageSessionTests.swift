import CodexGaugeCore
import CodexGaugeProtocol
import Darwin
import Foundation

func usageSessionTests() -> [TestCase] {
    [
        providerCreatesSessionFromLocatorTest(),
        sessionUsesProductionEnvironmentBoundaryTest(),
        sessionLaunchesEnvInterpreterWrapperTest(),
        sessionCompletesProtocolFlowTest(),
        sessionIgnoresUnrelatedMessagesTest(),
        sessionAllowsUnknownProviderTest(),
        sessionClassifiesAccountFailuresTest(),
        sessionClassifiesUnsupportedVersionTest(),
        sessionClassifiesDeterministicProtocolFailuresTest(),
        sessionPreservesTransientRPCFailuresTest(),
        sessionClassifiesMalformedAndOversizedOutputTest(),
        sessionClassifiesEOFAndProcessFailureTest(),
        sessionTimesOutAndCancelsTest(),
        sessionDiscardsStderrWithoutDeadlockTest(),
        sessionBackpressuresStdoutFloodTest(),
        sessionCompletesPendingRequestWhenStoppedTest(),
        sessionStopsChildWithoutOrphanTest(),
        sessionSharesConcurrentStopAndEscalatesTest(),
        sessionRetainsUnconfirmedChildUntilExitTest(),
        sessionSharesCancellationAndStopCleanupTest(),
        sessionCleansUpFailedChildWithoutExplicitStopTest()
    ] + processLifecycleTests()
}

private func sessionUsesProductionEnvironmentBoundaryTest() -> TestCase {
    TestCase(name: "usage session fixes PATH while preserving the authentication environment") {
        let inheritedEnvironment = [
            "PATH": "/synthetic/hostile/path",
            "HOME": SyntheticAppServer.expectedHomeDirectory,
            SyntheticAppServer.modeEnvironmentKey:
                SyntheticAppServerMode.environmentBoundary.rawValue,
            SyntheticAppServer.secretEnvironmentKey:
                SyntheticAppServer.expectedSecretValue
        ]
        let configuration = UsageSessionConfiguration.production(
            inheriting: inheritedEnvironment
        )
        try expect(
            configuration.environment == [
                "PATH": SyntheticAppServer.productionSafeSearchPath,
                "HOME": SyntheticAppServer.expectedHomeDirectory,
                SyntheticAppServer.modeEnvironmentKey:
                    SyntheticAppServerMode.environmentBoundary.rawValue,
                SyntheticAppServer.secretEnvironmentKey:
                    SyntheticAppServer.expectedSecretValue
            ],
            "Expected only the inherited PATH to be replaced"
        )
        let session = UsageSession(
            executableURL: syntheticExecutableURL,
            configuration: configuration
        )

        try await session.start()
        _ = try await session.readRateLimits(capturedAt: syntheticDate)
        await session.stop()
    }
}

private func sessionLaunchesEnvInterpreterWrapperTest() -> TestCase {
    TestCase(name: "usage session resolves an env interpreter for the full App Server flow") {
        let store = try SyntheticAppServerPathStore()
        defer { store.cleanUp() }
        let configuration = UsageSessionConfiguration.production(
            inheriting: [
                SyntheticAppServer.modeEnvironmentKey:
                    SyntheticAppServerMode.safeSearchPath.rawValue
            ],
            safeSearchPath: store.directoryURL.path
        )
        let locator = CodexExecutableLocator(
            selectedExecutableURL: store.wrapperURL,
            homeDirectoryURL: store.directoryURL
        )
        let provider = CodexUsageProvider(
            locator: locator,
            configuration: configuration
        )
        let session = try provider.makeSession()

        try await session.start()
        let result = try await session.readRateLimits(capturedAt: syntheticDate)
        try expect(
            result.rateLimits(for: .codex).state == .available,
            "Expected the wrapper-backed App Server response"
        )
        await session.stop()
    }
}

private func providerCreatesSessionFromLocatorTest() -> TestCase {
    TestCase(name: "usage provider creates a session from a validated locator") {
        try await withSyntheticMode(.happy) {
            let session = try makeSession()
            try await session.start()
            let state = await session.state
            try expect(state == .ready, "Expected a ready session")
            await session.stop()
        }
    }
}

private func sessionCompletesProtocolFlowTest() -> TestCase {
    TestCase(name: "usage session performs handshake account and rate-limit requests") {
        try await withSyntheticSession(.happy) { session in
            let first = try await session.readRateLimits(capturedAt: syntheticDate)
            let second = try await session.readRateLimits(capturedAt: syntheticDate)

            try expect(first.rateLimits(for: .codex).state == .available, "Expected Codex quota")
            try expect(first.rateLimits(for: .spark).state == .available, "Expected Spark quota")
            try expect(second == first, "Expected reusable session with monotonic request IDs")
        }
    }
}

private func sessionIgnoresUnrelatedMessagesTest() -> TestCase {
    TestCase(name: "usage session ignores notifications server requests and mismatched IDs") {
        try await withSyntheticSession(.unrelatedMessages) { session in
            let result = try await session.readRateLimits(capturedAt: syntheticDate)

            try expect(result.rateLimits(for: .codex).windows.count == 1, "Expected matching response")
        }
    }
}

private func sessionAllowsUnknownProviderTest() -> TestCase {
    TestCase(name: "usage session continues for an unknown account provider") {
        try await withSyntheticSession(.unknownProvider) { session in
            let result = try await session.readRateLimits(capturedAt: syntheticDate)

            try expect(result.rateLimits(for: .spark).state == .available, "Expected rate-limit attempt")
        }
    }
}

private func sessionClassifiesAccountFailuresTest() -> TestCase {
    TestCase(name: "usage session distinguishes signed-out and unsupported authentication") {
        try await expectReadError(.signedOut, mode: .signedOut)
        try await expectReadError(.unsupportedAuth, mode: .unsupportedAuth)
    }
}

private func sessionClassifiesUnsupportedVersionTest() -> TestCase {
    TestCase(name: "usage session maps method-not-found and handshake mismatch") {
        try await expectReadError(.unsupportedVersion, mode: .methodNotFound)
        try await expectStartError(.unsupportedVersion, mode: .handshakeMismatch)
    }
}

private func sessionClassifiesDeterministicProtocolFailuresTest() -> TestCase {
    TestCase(name: "usage session classifies deterministic JSON-RPC shape failures") {
        try await expectReadError(.protocolIncompatible, mode: .parseError)
        try await expectReadError(.protocolIncompatible, mode: .invalidRequest)
        try await expectReadError(.protocolIncompatible, mode: .invalidParameters)
    }
}

private func sessionPreservesTransientRPCFailuresTest() -> TestCase {
    TestCase(name: "usage session preserves server and internal JSON-RPC failures") {
        try await expectReadError(.rpcFailure(code: -32_603), mode: .internalError)
        try await expectReadError(.rpcFailure(code: -32_001), mode: .serverError)
        try await expectReadError(.rpcFailure(code: 42), mode: .positiveError)
    }
}

private func sessionClassifiesMalformedAndOversizedOutputTest() -> TestCase {
    TestCase(name: "usage session distinguishes malformed and oversized protocol output") {
        try await expectReadError(.malformedResponse, mode: .malformed)
        try await expectReadError(.responseTooLarge, mode: .oversized)
        try await withSyntheticSession(.finalLineWithoutNewline) { session in
            _ = try await session.readRateLimits(capturedAt: syntheticDate)
        }
    }
}

private func sessionClassifiesEOFAndProcessFailureTest() -> TestCase {
    TestCase(name: "usage session distinguishes clean EOF and nonzero process exit") {
        try await expectStartError(.endOfFile, mode: .endOfFile)
        try await expectStartError(.processFailed(exitStatus: 17), mode: .nonzeroExit)

        let missing = FileManager.default.temporaryDirectory
            .appendingPathComponent("codex-gauge-missing-\(UUID().uuidString)")
        let session = UsageSession(executableURL: missing, configuration: testConfiguration)
        try await expectSessionError(.launchFailed) {
            try await session.start()
        }
    }
}

private func sessionTimesOutAndCancelsTest() -> TestCase {
    TestCase(name: "usage session distinguishes timeout and caller cancellation") {
        try await expectStartError(.timeout(.initialize), mode: .timeout)

        try await withConfiguredSyntheticSession(.timeout) { session in
            let operation = Task { try await session.start() }
            try await ContinuousClock().sleep(for: .milliseconds(20))
            operation.cancel()
            try await expectTaskError(.cancelled, task: operation)
            await session.stop()
        }
    }
}

private func sessionDiscardsStderrWithoutDeadlockTest() -> TestCase {
    TestCase(name: "usage session discards a stderr flood without blocking") {
        try await withSyntheticSession(.stderrFlood) { session in
            let result = try await session.readRateLimits(capturedAt: syntheticDate)

            try expect(result.rateLimits(for: .codex).state == .available, "Expected completed request")
        }
    }
}

private func sessionBackpressuresStdoutFloodTest() -> TestCase {
    TestCase(name: "usage session backpressures a stdout flood without losing its response") {
        try await withSyntheticSession(
            .stdoutFlood,
            configuration: stdoutFloodTestConfiguration
        ) { session in
            let result = try await session.readRateLimits(capturedAt: syntheticDate)
            try expect(result.rateLimits(for: .codex).state == .available, "Expected flood-safe response")
        }
    }
}

private func sessionCompletesPendingRequestWhenStoppedTest() -> TestCase {
    TestCase(name: "stopping a session completes one pending request exactly once") {
        try await withConfiguredSyntheticSession(.stopDuringRequest) { session in
            try await session.start()
            let operation = Task {
                try await session.readRateLimits(capturedAt: syntheticDate)
            }
            try await ContinuousClock().sleep(for: .milliseconds(20))
            try await expectSessionError(.requestInProgress) {
                _ = try await session.readRateLimits(capturedAt: syntheticDate)
            }
            await session.stop()
            try await expectTaskError(.stopped, task: operation)
            let state = await session.state
            try expect(state == .stopped, "Expected terminal stopped state")
        }
    }
}

private func sessionStopsChildWithoutOrphanTest() -> TestCase {
    TestCase(name: "usage session stop leaves no synthetic child process") {
        let pidFile = FileManager.default.temporaryDirectory
            .appendingPathComponent("codex-gauge-pid-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: pidFile) }

        try await withConfiguredSyntheticSession(.waitForStop, pidFile: pidFile) { session in
            try await session.start()
            let processIdentifier = try await readProcessIdentifier(from: pidFile)
            let result = await session.stop()
            try expect(result == .exited, "Expected stop to confirm the child's exit")
            try expect(processIsAlive(processIdentifier) == false, "Expected no orphan process")
        }
    }
}

private func sessionSharesConcurrentStopAndEscalatesTest() -> TestCase {
    TestCase(name: "usage session shares concurrent stop and escalates ignored TERM once") {
        try await withSyntheticPIDFile { pidFile in
            try await withSyntheticMode(.ignoreTermination, pidFile: pidFile) {
                let signals = ProcessSignalRecorder()
                let session = UsageSession(
                    executableURL: syntheticExecutableURL,
                    configuration: testConfiguration,
                    terminationSignal: signals.forward
                )
                try await session.start()
                let identifier = try await readProcessIdentifier(from: pidFile)
                defer { if processIsAlive(identifier) { Darwin.kill(identifier, SIGKILL) } }
                let cancelled = Task { await session.stop() }
                cancelled.cancel()
                let results = await withTaskGroup(of: UsageSessionStopResult.self) { group in
                    for _ in 0..<10 {
                        group.addTask { await session.stop() }
                    }
                    var results: [UsageSessionStopResult] = []
                    for await result in group {
                        results.append(result)
                    }
                    return results
                }
                let cancelledResult = await cancelled.value
                await session.waitForTermination()
                let state = await session.state

                try expect(results.allSatisfy { $0 == .exited }, "Every caller must observe exit")
                try expect(cancelledResult == .exited, "Cancelled stop must still finish cleanup")
                try expect(signals.values == [SIGTERM, SIGKILL], "Expected one TERM/KILL sequence")
                try expect(state == .stopped, "Expected stopped only after exit")
                try expect(!processIsAlive(identifier), "Expected SIGKILL escalation to reap child")
            }
        }
    }
}

private func sessionRetainsUnconfirmedChildUntilExitTest() -> TestCase {
    TestCase(name: "usage session retains unconfirmed child and completes on late exit") {
        try await withSyntheticPIDFile { pidFile in
            try await withSyntheticMode(.ignoreTermination, pidFile: pidFile) {
                let signals = ProcessSignalRecorder()
                let session = UsageSession(
                    executableURL: syntheticExecutableURL,
                    configuration: testConfiguration,
                    terminationSignal: signals.suppress
                )
                try await session.start()
                let identifier = try await readProcessIdentifier(from: pidFile)
                defer { if processIsAlive(identifier) { Darwin.kill(identifier, SIGKILL) } }
                let result = await session.stop()
                let repeated = await session.stop()
                let state = await session.state

                try expect(result == .unconfirmed && repeated == .unconfirmed, "Expected bounded stop")
                try expect(state == .stopping, "A live child must not be reported stopped")
                try expect(processIsAlive(identifier), "Expected the suppressed signals to leave child alive")
                try expect(signals.hasTerminationObserver, "A live child must retain its exit observer")
                try expect(signals.values == [SIGTERM, SIGKILL], "Repeated stop cannot resend signals")

                let first = Task { await session.waitForTermination() }
                let second = Task { await session.waitForTermination() }
                first.cancel()
                Darwin.kill(identifier, SIGKILL)
                await first.value
                await second.value
                let confirmed = await session.stop()
                let stopped = await session.state

                try expect(confirmed == .exited && stopped == .stopped, "Late exit must complete cleanup")
                try expect(!processIsAlive(identifier), "Expected confirmed process exit")
                try expect(!signals.hasTerminationObserver, "Release the observer after actual exit")
            }
        }
    }
}

private func sessionSharesCancellationAndStopCleanupTest() -> TestCase {
    TestCase(name: "usage session request cancellation and explicit stop share cleanup") {
        try await withSyntheticPIDFile { pidFile in
            try await withSyntheticMode(.timeout, pidFile: pidFile) {
                let signals = ProcessSignalRecorder()
                let session = UsageSession(
                    executableURL: syntheticExecutableURL,
                    configuration: UsageSessionConfiguration(
                        initializeTimeout: .seconds(2),
                        requestTimeout: .seconds(1),
                        stopGracePeriod: .milliseconds(20)
                    ),
                    terminationSignal: signals.suppress
                )
                let operation = Task { try await session.start() }
                let identifier = try await readProcessIdentifier(from: pidFile)
                defer { if processIsAlive(identifier) { Darwin.kill(identifier, SIGKILL) } }
                operation.cancel()
                try await expectTaskError(.cancelled, task: operation)
                let stopResult = await session.stop()
                try expect(stopResult == .unconfirmed, "Expected the retained live child")
                try expect(signals.values == [SIGTERM, SIGKILL], "Failure and stop must share escalation")
                Darwin.kill(identifier, SIGKILL)
                await session.waitForTermination()
                let state = await session.state
                try expect(state == .stopped, "Expected cleanup after the real exit event")
            }
        }
    }
}

private func sessionCleansUpFailedChildWithoutExplicitStopTest() -> TestCase {
    TestCase(name: "failed start and read clean up children without explicit stop") {
        try await withSyntheticPIDFile { pidFile in
            try await withConfiguredSyntheticSession(.timeout, pidFile: pidFile) { session in
                try await expectSessionError(.timeout(.initialize)) {
                    try await session.start()
                }
                let processIdentifier = try await readProcessIdentifier(from: pidFile)
                try await expectProcessExit(processIdentifier)
            }
        }
        try await withSyntheticPIDFile { pidFile in
            try await withConfiguredSyntheticSession(
                .stopDuringRequest,
                pidFile: pidFile,
                configuration: cleanupTestConfiguration
            ) { session in
                try await session.start()
                try await expectSessionError(.timeout(.account)) {
                    _ = try await session.readRateLimits(capturedAt: syntheticDate)
                }
                let processIdentifier = try await readProcessIdentifier(from: pidFile)
                try await expectProcessExit(processIdentifier)
            }
        }
    }
}

private func withSyntheticPIDFile(
    operation: (URL) async throws -> Void
) async throws {
    let pidFile = FileManager.default.temporaryDirectory
        .appendingPathComponent("codex-gauge-failed-pid-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: pidFile) }
    try await operation(pidFile)
}

private let syntheticDate = Date(timeIntervalSince1970: 1_899_000_000)

private var syntheticExecutableURL: URL {
    URL(fileURLWithPath: CommandLine.arguments[0]).standardizedFileURL
}

private let testConfiguration = UsageSessionConfiguration(
    initializeTimeout: .milliseconds(180),
    requestTimeout: .seconds(1),
    stopGracePeriod: .milliseconds(180)
)

private let stdoutFloodTestConfiguration = UsageSessionConfiguration(
    initializeTimeout: .milliseconds(180),
    requestTimeout: .seconds(5),
    stopGracePeriod: .milliseconds(180)
)

private let cleanupTestConfiguration = UsageSessionConfiguration(
    initializeTimeout: .milliseconds(180),
    requestTimeout: .milliseconds(120),
    stopGracePeriod: .milliseconds(180)
)

private func makeSession(
    configuration: UsageSessionConfiguration = testConfiguration
) throws -> UsageSession {
    let locator = CodexExecutableLocator(
        selectedExecutableURL: syntheticExecutableURL,
        homeDirectoryURL: FileManager.default.temporaryDirectory
    )
    let provider = CodexUsageProvider(locator: locator, configuration: configuration)
    return try provider.makeSession()
}

private func withSyntheticSession(
    _ mode: SyntheticAppServerMode,
    configuration: UsageSessionConfiguration = testConfiguration,
    operation: (UsageSession) async throws -> Void
) async throws {
    try await withConfiguredSyntheticSession(
        mode,
        configuration: configuration
    ) { session in
        try await session.start()
        do {
            try await operation(session)
            await session.stop()
        } catch {
            await session.stop()
            throw error
        }
    }
}

private func withConfiguredSyntheticSession(
    _ mode: SyntheticAppServerMode,
    pidFile: URL? = nil,
    configuration: UsageSessionConfiguration = testConfiguration,
    operation: (UsageSession) async throws -> Void
) async throws {
    try await withSyntheticMode(mode, pidFile: pidFile) {
        let session = try makeSession(configuration: configuration)
        try await operation(session)
    }
}

private func withSyntheticMode(
    _ mode: SyntheticAppServerMode,
    pidFile: URL? = nil,
    operation: () async throws -> Void
) async throws {
    setenv(SyntheticAppServer.modeEnvironmentKey, mode.rawValue, 1)
    if let pidFile {
        setenv(SyntheticAppServer.pidFileEnvironmentKey, pidFile.path, 1)
    }
    defer {
        unsetenv(SyntheticAppServer.modeEnvironmentKey)
        unsetenv(SyntheticAppServer.pidFileEnvironmentKey)
    }
    try await operation()
}

private func expectReadError(
    _ expected: UsageSessionError,
    mode: SyntheticAppServerMode
) async throws {
    try await withSyntheticSession(mode) { session in
        try await expectSessionError(expected) {
            _ = try await session.readRateLimits(capturedAt: syntheticDate)
        }
    }
}

private func expectStartError(
    _ expected: UsageSessionError,
    mode: SyntheticAppServerMode
) async throws {
    try await withConfiguredSyntheticSession(mode) { session in
        try await expectSessionError(expected) {
            try await session.start()
        }
        await session.stop()
    }
}

private func expectSessionError(
    _ expected: UsageSessionError,
    operation: () async throws -> Void
) async throws {
    do {
        try await operation()
        throw TestFailure(description: "Expected a typed session failure")
    } catch let error as UsageSessionError {
        try expect(
            error == expected,
            "Unexpected typed session failure: expected \(expected), received \(error)"
        )
    }
}

private func expectTaskError<Success: Sendable>(
    _ expected: UsageSessionError,
    task: Task<Success, Error>
) async throws {
    do {
        _ = try await task.value
        throw TestFailure(description: "Expected task failure")
    } catch let error as UsageSessionError {
        try expect(
            error == expected,
            "Unexpected task session failure: expected \(expected), received \(error)"
        )
    }
}

private func readProcessIdentifier(from file: URL) async throws -> pid_t {
    let clock = ContinuousClock()
    let deadline = clock.now.advanced(by: .milliseconds(150))
    while clock.now < deadline {
        if let identifier = processIdentifier(in: file) {
            return identifier
        }
        try await clock.sleep(for: .milliseconds(5))
    }
    throw TestFailure(description: "Expected synthetic child process identifier")
}

private func processIdentifier(in file: URL) -> pid_t? {
    guard let data = try? Data(contentsOf: file) else {
        return nil
    }
    guard let value = String(data: data, encoding: .utf8) else {
        return nil
    }
    return pid_t(value)
}

private func processIsAlive(_ processIdentifier: pid_t) -> Bool {
    Darwin.kill(processIdentifier, 0) == 0
}

private func expectProcessExit(_ processIdentifier: pid_t) async throws {
    let clock = ContinuousClock()
    let deadline = clock.now.advanced(by: .seconds(1))
    while clock.now < deadline {
        guard processIsAlive(processIdentifier) else {
            return
        }
        try await clock.sleep(for: .milliseconds(10))
    }
    throw TestFailure(description: "Expected failed session child cleanup")
}

private struct SyntheticAppServerPathStore {
    static let interpreterName = "codex-gauge-synthetic-app-server-interpreter"

    let directoryURL: URL
    let wrapperURL: URL

    init() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("codex-gauge-session-path-\(UUID().uuidString)")
        let interpreter = directory.appendingPathComponent(Self.interpreterName)
        let wrapper = directory.appendingPathComponent("synthetic-codex")
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: false
        )
        try Self.copyInterpreter(to: interpreter, in: directory)
        try Self.makeExecutable(interpreter)
        try Self.writeWrapper(to: wrapper)
        directoryURL = directory
        wrapperURL = wrapper
    }

    func cleanUp() {
        try? FileManager.default.removeItem(at: directoryURL)
    }

    private static func copyInterpreter(to url: URL, in directory: URL) throws {
        let executableDirectory = syntheticExecutableURL.deletingLastPathComponent()
        let framework = executableDirectory.appendingPathComponent("Sparkle.framework")
        let frameworkDestination = directory.appendingPathComponent("Sparkle.framework")
        try FileManager.default.copyItem(at: syntheticExecutableURL, to: url)
        try FileManager.default.copyItem(at: framework, to: frameworkDestination)
    }

    private static func writeWrapper(to url: URL) throws {
        let contents = "#!/usr/bin/env \(interpreterName)\n"
        try Data(contents.utf8).write(to: url, options: .atomic)
        try makeExecutable(url)
    }

    private static func makeExecutable(_ url: URL) throws {
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: url.path
        )
    }
}
