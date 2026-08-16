import AppKit
import CodexGaugeAppKit
import Foundation

func applicationTerminationTests() -> [TestCase] {
    [
        applicationTerminatesImmediatelyWithoutRuntimeTest(),
        applicationSharesOneDeferredTerminationDrainTest()
    ]
}

private func applicationTerminatesImmediatelyWithoutRuntimeTest() -> TestCase {
    TestCase(name: "application terminates immediately before runtime creation") {
        try await applicationTerminatesImmediatelyWithoutRuntimeScenario()
    }
}

@MainActor
private func applicationTerminatesImmediatelyWithoutRuntimeScenario() async throws {
    let reply = TerminationReplySpy()
    let delegate = CodexGaugeApplicationDelegate(
        runtimeFactory: { TerminationRuntimeSpy() },
        terminationReply: reply.record
    )

    let result = delegate.applicationShouldTerminate(NSApplication.shared)

    try expect(result == .terminateNow, "Expected immediate termination without runtime")
    try expect(reply.values.isEmpty, "Expected no deferred reply")
}

private func applicationSharesOneDeferredTerminationDrainTest() -> TestCase {
    TestCase(name: "application shares one deferred runtime termination drain") {
        try await applicationSharesOneDeferredTerminationDrainScenario()
    }
}

@MainActor
private func applicationSharesOneDeferredTerminationDrainScenario() async throws {
    let gate = TerminationShutdownGate()
    let runtime = TerminationRuntimeSpy(shutdownGate: gate)
    let reply = TerminationReplySpy()
    let delegate = CodexGaugeApplicationDelegate(
        runtimeFactory: { runtime },
        terminationReply: reply.record
    )
    delegate.applicationDidFinishLaunching(
        Notification(name: NSApplication.didFinishLaunchingNotification)
    )

    let first = delegate.applicationShouldTerminate(NSApplication.shared)
    let second = delegate.applicationShouldTerminate(NSApplication.shared)
    try expect(first == .terminateLater, "Expected deferred termination")
    try expect(second == .terminateLater, "Expected duplicate request to share drain")
    try await waitForTerminationCondition { await gate.hasStarted }
    try expect(runtime.shutdownCount == 1, "Expected one runtime shutdown")
    try expect(reply.values.isEmpty, "Expected no early reply")

    await gate.resume()
    try await waitForTerminationCondition { reply.values == [true] }
    let completed = delegate.applicationShouldTerminate(NSApplication.shared)

    try expect(completed == .terminateNow, "Expected completed drain to stay terminal")
    try expect(runtime.shutdownCount == 1, "Expected no repeated shutdown")
    try expect(reply.values == [true], "Expected exactly one true reply")
    try expect(
        reply.applicationIdentifiers == [ObjectIdentifier(NSApplication.shared)],
        "Expected reply through the requesting application"
    )
}

@MainActor
private final class TerminationRuntimeSpy: CodexGaugeApplicationRunning {
    private(set) var startCount = 0
    private(set) var shutdownCount = 0
    private let shutdownGate: TerminationShutdownGate?

    init(shutdownGate: TerminationShutdownGate? = nil) {
        self.shutdownGate = shutdownGate
    }

    func start() {
        startCount += 1
    }

    func refreshLaunchAtLoginStatus() {}

    func shutdown() async {
        shutdownCount += 1
        await shutdownGate?.wait()
    }
}

@MainActor
private final class TerminationReplySpy {
    private(set) var values = [Bool]()
    private(set) var applicationIdentifiers = [ObjectIdentifier]()

    func record(application: NSApplication, shouldTerminate: Bool) {
        applicationIdentifiers.append(ObjectIdentifier(application))
        values.append(shouldTerminate)
    }
}

private actor TerminationShutdownGate {
    private(set) var hasStarted = false
    private var continuation: CheckedContinuation<Void, Never>?

    func wait() async {
        hasStarted = true
        await withCheckedContinuation { continuation in
            self.continuation = continuation
        }
    }

    func resume() {
        continuation?.resume()
        continuation = nil
    }
}

@MainActor
private func waitForTerminationCondition(
    _ condition: @escaping @MainActor () async -> Bool
) async throws {
    for _ in 0..<200 {
        if await condition() {
            return
        }
        await Task.yield()
    }
    throw TestFailure(description: "Timed out waiting for termination condition")
}
