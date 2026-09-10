import Darwin
import Foundation

public enum UsageSessionStopResult: Sendable, Equatable {
    case exited
    case unconfirmed
}

/// A single child's exit event and cancellation-independent shutdown procedure.
/// Neither a successful signal nor an elapsed deadline confirms termination.
package actor ProcessLifecycle {
    package typealias Signal = @Sendable (Process, Int32) -> Void
    package typealias Sleep = @Sendable (Duration) async throws -> Void

    private var signal: (@Sendable (Int32) -> Void)?
    private let sleep: Sleep
    private var exitStatus: Int32?
    private var waiters: [UUID: ExitWaiter] = [:]
    private var stopTask: Task<UsageSessionStopResult, Never>?

    package init(
        signal: @escaping @Sendable (Int32) -> Void,
        sleep: @escaping Sleep = { try await ContinuousClock().sleep(for: $0) }
    ) {
        self.signal = signal
        self.sleep = sleep
    }

    /// Install before `run()`. The observer deliberately retains the lifecycle
    /// and owner until an actual exit, including after an unconfirmed stop.
    /// If `run()` throws, the caller must remove this observer.
    package nonisolated static func observe(
        _ child: Process,
        signal: @escaping Signal = ProcessLifecycle.sendSignal,
        onTermination: @escaping @Sendable (Int32) async -> Void
    ) -> ProcessLifecycle {
        let lifecycle = ProcessLifecycle(signal: { signal(child, $0) })
        child.terminationHandler = { terminatedChild in
            let status = terminatedChild.terminationStatus
            // This callback is the confirmation; it is now safe to release it.
            terminatedChild.terminationHandler = nil
            Task {
                await lifecycle.receiveTermination(status: status)
                await onTermination(status)
            }
        }
        return lifecycle
    }

    package nonisolated static func sendSignal(_ child: Process, _ signal: Int32) {
        guard child.isRunning else {
            return
        }
        if signal == SIGTERM {
            child.terminate()
        } else {
            Darwin.kill(child.processIdentifier, signal)
        }
    }

    package func receiveTermination(status: Int32) {
        guard exitStatus == nil else {
            return
        }
        exitStatus = status
        signal = nil
        let completed = waiters.values
        waiters.removeAll()
        for waiter in completed {
            waiter.timeoutTask?.cancel()
            waiter.continuation.resume(returning: true)
        }
    }

    package func stop(gracePeriod: Duration) async -> UsageSessionStopResult {
        if exitStatus != nil {
            return .exited
        }
        if let stopTask {
            return await stopTask.value
        }
        // An unstructured task does not inherit the calling task's cancellation.
        // Keep its result after the deadlines so another stop cannot resend signals.
        let task = Task { await performStop(gracePeriod: gracePeriod) }
        stopTask = task
        return await task.value
    }

    package func waitForTermination() async {
        _ = await waitForExit(timeout: nil)
    }

    package func waitForExit(timeout: Duration?) async -> Bool {
        if exitStatus != nil {
            return true
        }
        // Registration and the early-exit check are on the same actor. An exit
        // cannot slip between checking the latch and installing the continuation.
        return await withCheckedContinuation { continuation in
            let identifier = UUID()
            let timeoutTask: Task<Void, Never>? = timeout.map { duration in
                Task { [weak self, sleep] in
                    do {
                        try await sleep(duration)
                    } catch {
                        return
                    }
                    await self?.expireWaiter(identifier)
                }
            }
            waiters[identifier] = ExitWaiter(
                continuation: continuation,
                timeoutTask: timeoutTask
            )
        }
    }

    private func performStop(gracePeriod: Duration) async -> UsageSessionStopResult {
        if exitStatus != nil {
            return .exited
        }
        signal?(SIGTERM)
        if await waitForExit(timeout: gracePeriod) {
            return .exited
        }
        signal?(SIGKILL)
        if await waitForExit(timeout: gracePeriod) {
            return .exited
        }
        return .unconfirmed
    }

    private func expireWaiter(_ identifier: UUID) {
        guard let waiter = waiters.removeValue(forKey: identifier) else {
            return
        }
        waiter.continuation.resume(returning: false)
    }
}

private struct ExitWaiter {
    let continuation: CheckedContinuation<Bool, Never>
    let timeoutTask: Task<Void, Never>?
}
