import CodexGaugeProtocol
import Darwin
import Foundation

func appServerSmokeTests() -> [TestCase] {
    [
        appServerSmokeUsesProductionProtocolStackTest(),
        appServerSmokeReportsCategoricalProductStatesTest(),
        appServerSmokeRejectsIncompatibleEnvelopeTest(),
        appServerSmokeStopsAfterSessionFailureTest(),
        appServerSmokeStopsCancelledOperationTest(),
        appServerSmokeAwaitsSharedCancellationCleanupTest(),
        appServerSmokeMapsLocationFailuresTest(),
        appServerSmokeMapsTypedSessionFailuresTest(),
        appServerSmokeOutputNeverIncludesUnderlyingErrorTest()
    ]
}

private func appServerSmokeUsesProductionProtocolStackTest() -> TestCase {
    TestCase(name: "App Server smoke uses locator validation and production session") {
        let processIdentifierFile = FileManager.default.temporaryDirectory
            .appendingPathComponent("codex-gauge-smoke-pid-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: processIdentifierFile) }
        setenv(SyntheticAppServer.modeEnvironmentKey, SyntheticAppServerMode.happy.rawValue, 1)
        setenv(SyntheticAppServer.pidFileEnvironmentKey, processIdentifierFile.path, 1)
        defer {
            unsetenv(SyntheticAppServer.modeEnvironmentKey)
            unsetenv(SyntheticAppServer.pidFileEnvironmentKey)
        }

        let executableURL = URL(fileURLWithPath: CommandLine.arguments[0])
            .standardizedFileURL
        let locator = CodexExecutableLocator(
            selectedExecutableURL: executableURL,
            homeDirectoryURL: FileManager.default.temporaryDirectory
        )
        let provider = ProductionAppServerSmokeSessionProvider(
            locator: locator,
            configuration: smokeTestConfiguration
        )
        let result = await AppServerSmokeRunner(sessionProvider: provider).run()
        let processIdentifier = try smokeProcessIdentifier(in: processIdentifierFile)

        try expect(
            result == .success(codex: .available, spark: .available),
            "Expected the complete production protocol flow"
        )
        try expect(
            Darwin.kill(processIdentifier, 0) != 0,
            "Expected the production session to stop its child"
        )
    }
}

private func appServerSmokeMapsTypedSessionFailuresTest() -> TestCase {
    TestCase(name: "App Server smoke maps every session error to fixed output") {
        let cases: [(UsageSessionError, AppServerSmokeFailure, String, Int32)] = [
            (.notStarted, .internalFailure, "internal_failure", 6),
            (.requestInProgress, .internalFailure, "internal_failure", 6),
            (.requestIdentifierExhausted, .internalFailure, "internal_failure", 6),
            (.launchFailed, .processFailure, "process_failure", 5),
            (.processFailed(exitStatus: 19), .processFailure, "process_failure", 5),
            (.endOfFile, .processFailure, "process_failure", 5),
            (.timeout(.account), .timeout, "timeout", 5),
            (.malformedResponse, .protocolFailure, "protocol_failure", 4),
            (.responseTooLarge, .protocolFailure, "protocol_failure", 4),
            (.unsupportedVersion, .unsupportedVersion, "unsupported_version", 4),
            (
                .protocolIncompatible,
                .incompatibleProtocol,
                "incompatible_protocol",
                4
            ),
            (.signedOut, .signedOut, "signed_out", 3),
            (
                .unsupportedAuth,
                .unsupportedAuthentication,
                "unsupported_authentication",
                3
            ),
            (.rpcFailure(code: -32_601), .protocolFailure, "protocol_failure", 4),
            (.stopped, .internalFailure, "internal_failure", 6),
            (.cancelled, .cancelled, "cancelled", 6)
        ]

        for (error, expectedFailure, reason, exitCode) in cases {
            let session = SmokeSessionFake(error: error)
            let result = await makeSmokeRunner(session: session).run()
            let output = AppServerSmokeOutputFormatter().line(for: result)

            try expect(result == .failure(expectedFailure), "Expected mapped session error")
            try expect(
                output == "codex-gauge-smoke: failed reason=\(reason)",
                "Expected fixed failure output"
            )
            try expect(result.exitCode == exitCode, "Expected stable failure exit code")
            try await expectSmokeSessionStoppedOnce(session)
        }
    }
}

private func appServerSmokeReportsCategoricalProductStatesTest() -> TestCase {
    TestCase(name: "App Server smoke reports categorical product states only") {
        let session = SmokeSessionFake(
            result: smokeReadResult(codex: .available, spark: .partial)
        )
        let result = await makeSmokeRunner(session: session).run()

        try expect(
            result == .success(codex: .available, spark: .partial),
            "Expected categorical product states"
        )
        try expect(
            AppServerSmokeOutputFormatter().line(for: result)
                == "codex-gauge-smoke: ok codex=available spark=partial",
            "Expected a stable sanitized success line"
        )
        try expect(result.exitCode == 0, "Expected success exit code")
        try await expectSmokeSessionStoppedOnce(session)
    }
}

private func appServerSmokeRejectsIncompatibleEnvelopeTest() -> TestCase {
    TestCase(name: "App Server smoke rejects an incompatible quota envelope") {
        let session = SmokeSessionFake(
            result: smokeReadResult(
                responseStatus: .incompatible,
                codex: .malformed,
                spark: .malformed
            )
        )
        let result = await makeSmokeRunner(session: session).run()

        try expect(result == .failure(.incompatibleProtocol), "Expected protocol failure")
        try expect(result.exitCode == 4, "Expected compatibility exit code")
        try await expectSmokeSessionStoppedOnce(session)
    }
}

private func appServerSmokeStopsAfterSessionFailureTest() -> TestCase {
    TestCase(name: "App Server smoke stops its session after a typed failure") {
        let session = SmokeSessionFake(error: UsageSessionError.signedOut)
        let result = await makeSmokeRunner(session: session).run()

        try expect(result == .failure(.signedOut), "Expected signed-out category")
        try expect(result.exitCode == 3, "Expected authentication exit code")
        try await expectSmokeSessionStoppedOnce(session)
    }
}

private func appServerSmokeStopsCancelledOperationTest() -> TestCase {
    TestCase(name: "App Server smoke cancellation stops a pending session once") {
        let session = SmokeSessionFake(waitForStop: true)
        let operation = Task { await makeSmokeRunner(session: session).run() }
        await session.waitUntilReadStarts()
        operation.cancel()
        let result = await operation.value

        try expect(result == .failure(.cancelled), "Expected cancellation category")
        try expect(result.exitCode == 6, "Expected cancelled exit code")
        try await expectSmokeSessionStoppedOnce(session)
    }
}

private func appServerSmokeAwaitsSharedCancellationCleanupTest() -> TestCase {
    TestCase(name: "App Server smoke awaits shared cleanup after cancellation") {
        let session = SmokeSessionFake(
            waitForStop: true,
            delayStopCompletion: true
        )
        let recorder = SmokeResultRecorder()
        let operation = Task {
            let result = await makeSmokeRunner(session: session).run()
            await recorder.record(result)
            return result
        }
        await session.waitUntilReadStarts()
        operation.cancel()
        await session.waitUntilStopStarts()
        await drainSmokeTasks()

        let prematureResult = await recorder.result
        let stopCountBeforeCompletion = await session.stopCount
        try expect(prematureResult == nil, "Expected the runner to await child cleanup")
        try expect(stopCountBeforeCompletion == 1, "Expected one shared stop operation")

        await session.completeDelayedStop()
        let result = await operation.value
        try expect(result == .failure(.cancelled), "Expected cancellation after cleanup")
        try await expectSmokeSessionStoppedOnce(session)
    }
}

private func appServerSmokeMapsLocationFailuresTest() -> TestCase {
    TestCase(name: "App Server smoke maps locator failures without paths") {
        let missing = await AppServerSmokeRunner(
            sessionProvider: SmokeSessionProvider(error: CodexLocationError.notFound)
        ).run()
        let invalid = await AppServerSmokeRunner(
            sessionProvider: SmokeSessionProvider(error: CodexLocationError.invalidSelection)
        ).run()

        try expect(missing == .failure(.executableNotFound), "Expected not-found category")
        try expect(invalid == .failure(.invalidSelection), "Expected invalid-selection category")
        try expect(missing.exitCode == 2, "Expected executable exit code")
        try expect(invalid.exitCode == 2, "Expected executable exit code")
    }
}

private func appServerSmokeOutputNeverIncludesUnderlyingErrorTest() -> TestCase {
    TestCase(name: "App Server smoke does not render underlying error content") {
        let secret = "synthetic-token-and-path-marker"
        let session = SmokeSessionFake(error: SmokeSecretError(value: secret))
        let result = await makeSmokeRunner(session: session).run()
        let output = AppServerSmokeOutputFormatter().line(for: result)

        try expect(result == .failure(.internalFailure), "Expected internal category")
        try expect(output == "codex-gauge-smoke: failed reason=internal_failure", "Expected fixed output")
        try expect(output.contains(secret) == false, "Expected underlying content to be discarded")
        try await expectSmokeSessionStoppedOnce(session)
    }
}

private func makeSmokeRunner(session: SmokeSessionFake) -> AppServerSmokeRunner {
    AppServerSmokeRunner(sessionProvider: SmokeSessionProvider(session: session))
}

private func smokeReadResult(
    responseStatus: RateLimitResponseStatus = .accepted,
    codex: ProductRateLimitState,
    spark: ProductRateLimitState
) -> RateLimitReadResult {
    RateLimitReadResult(
        capturedAt: Date(timeIntervalSince1970: 1_900_000_000),
        responseStatus: responseStatus,
        rateLimitsByProduct: [
            .codex: ProductRateLimits(state: codex, windows: []),
            .spark: ProductRateLimits(state: spark, windows: [])
        ]
    )
}

private func expectSmokeSessionStoppedOnce(
    _ session: SmokeSessionFake
) async throws {
    let stopCount = await session.stopCount
    try expect(stopCount == 1, "Expected exactly one bounded stop")
}

private func drainSmokeTasks() async {
    for _ in 0..<10 {
        await Task.yield()
    }
}

private func smokeProcessIdentifier(in file: URL) throws -> pid_t {
    let data = try Data(contentsOf: file)
    guard let value = String(data: data, encoding: .utf8) else {
        throw TestFailure(description: "Expected a synthetic process identifier")
    }
    guard let processIdentifier = pid_t(value) else {
        throw TestFailure(description: "Expected a numeric process identifier")
    }
    return processIdentifier
}

private let smokeTestConfiguration = UsageSessionConfiguration(
    initializeTimeout: .milliseconds(180),
    requestTimeout: .seconds(1),
    stopGracePeriod: .milliseconds(180)
)

private struct SmokeSessionProvider: AppServerSmokeSessionProviding {
    let session: SmokeSessionFake?
    let error: (any Error & Sendable)?

    init(session: SmokeSessionFake) {
        self.session = session
        error = nil
    }

    init(error: any Error & Sendable) {
        session = nil
        self.error = error
    }

    func makeSmokeSession() throws -> any AppServerSmokeSession {
        if let error {
            throw error
        }
        guard let session else {
            throw SmokeSecretError(value: "synthetic-missing-session")
        }
        return session
    }
}

private actor SmokeSessionFake: AppServerSmokeSession {
    private let result: RateLimitReadResult?
    private let error: (any Error & Sendable)?
    private let waitsForStop: Bool
    private let delaysStopCompletion: Bool
    private var readStarted = false
    private var readWaiters: [CheckedContinuation<Void, Never>] = []
    private var stopWaiter: CheckedContinuation<RateLimitReadResult, any Error>?
    private var stopStarted = false
    private var stopStartWaiters: [CheckedContinuation<Void, Never>] = []
    private var stopCompletionWaiter: CheckedContinuation<Void, Never>?
    private(set) var stopCount = 0

    init(result: RateLimitReadResult) {
        self.result = result
        error = nil
        waitsForStop = false
        delaysStopCompletion = false
    }

    init(error: any Error & Sendable) {
        result = nil
        self.error = error
        waitsForStop = false
        delaysStopCompletion = false
    }

    init(
        waitForStop: Bool,
        delayStopCompletion: Bool = false
    ) {
        result = nil
        error = nil
        waitsForStop = waitForStop
        delaysStopCompletion = delayStopCompletion
    }

    func start() async throws {}

    func readRateLimits(capturedAt: Date) async throws -> RateLimitReadResult {
        readStarted = true
        readWaiters.forEach { $0.resume() }
        readWaiters.removeAll()
        if let error {
            throw error
        }
        if waitsForStop {
            return try await withCheckedThrowingContinuation { stopWaiter = $0 }
        }
        guard let result else {
            throw SmokeSecretError(value: "synthetic-missing-result")
        }
        return result
    }

    func stop() async {
        stopCount += 1
        stopStarted = true
        stopStartWaiters.forEach { $0.resume() }
        stopStartWaiters.removeAll()
        stopWaiter?.resume(throwing: UsageSessionError.stopped)
        stopWaiter = nil
        guard delaysStopCompletion else {
            return
        }
        await withCheckedContinuation { stopCompletionWaiter = $0 }
    }

    func waitUntilReadStarts() async {
        guard readStarted == false else {
            return
        }
        await withCheckedContinuation { readWaiters.append($0) }
    }

    func waitUntilStopStarts() async {
        guard stopStarted == false else {
            return
        }
        await withCheckedContinuation { stopStartWaiters.append($0) }
    }

    func completeDelayedStop() {
        stopCompletionWaiter?.resume()
        stopCompletionWaiter = nil
    }
}

private actor SmokeResultRecorder {
    private(set) var result: AppServerSmokeResult?

    func record(_ result: AppServerSmokeResult) {
        self.result = result
    }
}

private struct SmokeSecretError: Error, Sendable {
    let value: String
}
