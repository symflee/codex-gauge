import CodexGaugeProtocol
import Darwin
import Foundation

func processLifecycleTests() -> [TestCase] {
    [
        TestCase(name: "process lifecycle remembers exit before waiter registration") {
            let signals = ProcessSignalRecorder()
            let lifecycle = ProcessLifecycle(signal: { signals.record($0) })
            await lifecycle.receiveTermination(status: 17)

            let exited = await lifecycle.waitForExit(timeout: .zero)
            await lifecycle.waitForTermination()
            let result = await lifecycle.stop(gracePeriod: .zero)

            try expect(exited, "Expected the recorded event, even with a zero timeout")
            try expect(result == .exited, "Expected confirmed termination")
            try expect(signals.values.isEmpty, "An exited process must never be signalled")
        },
        TestCase(name: "process lifecycle serializes concurrent cancelled shutdowns") {
            let signals = ProcessSignalRecorder()
            let deadlines = ProcessDeadlineRecorder()
            let lifecycle = ProcessLifecycle(
                signal: { signals.record($0) },
                sleep: deadlines.sleep
            )
            let cancelledStop = Task { await lifecycle.stop(gracePeriod: .milliseconds(20)) }
            cancelledStop.cancel()
            let results = await withTaskGroup(of: UsageSessionStopResult.self) { group in
                for _ in 0..<20 {
                    group.addTask { await lifecycle.stop(gracePeriod: .milliseconds(20)) }
                }
                var results: [UsageSessionStopResult] = []
                for await result in group {
                    results.append(result)
                }
                return results
            }
            let cancelledResult = await cancelledStop.value
            let repeatedResult = await lifecycle.stop(gracePeriod: .milliseconds(20))

            try expect(results.count == 20, "Expected every stop caller to finish")
            try expect(results.allSatisfy { $0 == .unconfirmed }, "Signals do not prove exit")
            try expect(cancelledResult == .unconfirmed, "Cancellation must not skip cleanup")
            try expect(repeatedResult == .unconfirmed, "Expected the same shutdown result")
            try expect(signals.values == [SIGTERM, SIGKILL], "Expected one escalation only")
            try expect(
                deadlines.values == [.milliseconds(20), .milliseconds(20)],
                "Expected one deadline per grace period, without polling or cancellation shortcuts"
            )
            await lifecycle.receiveTermination(status: SIGKILL)
        },
        TestCase(name: "process lifecycle retains event waiters after shutdown deadlines") {
            let signals = ProcessSignalRecorder()
            let deadlines = ProcessDeadlineRecorder()
            let lifecycle = ProcessLifecycle(
                signal: { signals.record($0) },
                sleep: deadlines.sleep
            )
            let result = await lifecycle.stop(gracePeriod: .milliseconds(10))
            let prematureExit = await lifecycle.waitForExit(timeout: .milliseconds(10))
            try expect(result == .unconfirmed, "Expected both deadlines to expire")
            try expect(!prematureExit, "A timeout cannot complete an exit waiter successfully")

            let first = Task { await lifecycle.waitForTermination() }
            let second = Task { await lifecycle.waitForTermination() }
            first.cancel()
            await lifecycle.receiveTermination(status: SIGKILL)
            await lifecycle.receiveTermination(status: SIGKILL)
            await first.value
            await second.value
            let confirmed = await lifecycle.stop(gracePeriod: .zero)

            try expect(confirmed == .exited, "Expected late exit to supersede unconfirmed stop")
            try expect(signals.values == [SIGTERM, SIGKILL], "Late exit must not restart cleanup")
            try expect(deadlines.values.count == 3, "Event-only waiters must not schedule any timers")
        },
        TestCase(name: "process lifecycle does not lose racing exit registrations") {
            for _ in 0..<40 {
                let lifecycle = ProcessLifecycle(signal: { _ in })
                async let waiter = lifecycle.waitForExit(timeout: .seconds(1))
                await lifecycle.receiveTermination(status: 0)
                let exited = await waiter
                try expect(exited, "Expected either event order to confirm exit")
            }
        }
    ]
}

private final class ProcessDeadlineRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var deadlines: [Duration] = []

    var values: [Duration] {
        lock.withLock { deadlines }
    }

    func sleep(_ duration: Duration) async throws {
        lock.withLock { deadlines.append(duration) }
        try await ContinuousClock().sleep(for: duration)
    }
}

/// Only the signal boundary is faked; production exit callbacks still run.
final class ProcessSignalRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var recordedSignals: [Int32] = []
    private weak var process: Process?

    var values: [Int32] {
        lock.withLock { recordedSignals }
    }

    var hasTerminationObserver: Bool {
        lock.withLock { process?.terminationHandler != nil }
    }

    func record(_ signal: Int32) {
        lock.withLock { recordedSignals.append(signal) }
    }

    func suppress(_ process: Process, _ signal: Int32) {
        lock.withLock {
            self.process = process
            recordedSignals.append(signal)
        }
    }

    func forward(_ process: Process, _ signal: Int32) {
        suppress(process, signal)
        ProcessLifecycle.sendSignal(process, signal)
    }
}
