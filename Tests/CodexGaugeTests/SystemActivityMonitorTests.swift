import AppKit
import CodexGaugeAppKit
import Foundation

func systemActivityMonitorTests() -> [TestCase] {
    [
        systemActivityMapsWorkspaceNotificationsTest(),
        systemActivitySamplesLowPowerModeTest(),
        systemActivityStartIsIdempotentTest(),
        systemActivityStopRemovesObserversTest(),
        systemActivityValuesAreSendableTest()
    ]
}

private func systemActivityMapsWorkspaceNotificationsTest() -> TestCase {
    TestCase(name: "system activity maps sleep wake lock and unlock notifications") {
        try await MainActor.run {
            let workspaceCenter = NotificationCenter()
            let powerCenter = NotificationCenter()
            let recorder = SystemActivityRecorder()
            let monitor = SystemActivityMonitor(
                workspaceNotificationCenter: workspaceCenter,
                powerNotificationCenter: powerCenter,
                lowPowerModeEnabled: { false }
            )
            monitor.start(handler: recorder.record)
            recorder.removeAll()

            postWorkspaceEvents(to: workspaceCenter)

            try expect(recorder.events == [
                .sleep,
                .wake,
                .sessionLocked,
                .sessionUnlocked
            ], "Expected exact workspace event mapping")
        }
    }
}

private func systemActivitySamplesLowPowerModeTest() -> TestCase {
    TestCase(name: "system activity samples low power mode initially and on changes") {
        try await MainActor.run {
            let workspaceCenter = NotificationCenter()
            let powerCenter = NotificationCenter()
            let powerState = MutablePowerState(isEnabled: true)
            let recorder = SystemActivityRecorder()
            let monitor = SystemActivityMonitor(
                workspaceNotificationCenter: workspaceCenter,
                powerNotificationCenter: powerCenter,
                lowPowerModeEnabled: powerState.read
            )

            monitor.start(handler: recorder.record)
            powerState.isEnabled = false
            powerCenter.post(name: .NSProcessInfoPowerStateDidChange, object: nil)

            try expect(recorder.events == [
                .lowPowerModeChanged(isEnabled: true),
                .lowPowerModeChanged(isEnabled: false)
            ], "Expected current power state instead of notification payload")
        }
    }
}

private func systemActivityStartIsIdempotentTest() -> TestCase {
    TestCase(name: "system activity start does not duplicate observers") {
        try await MainActor.run {
            let workspaceCenter = NotificationCenter()
            let recorder = SystemActivityRecorder()
            let monitor = SystemActivityMonitor(
                workspaceNotificationCenter: workspaceCenter,
                powerNotificationCenter: NotificationCenter(),
                lowPowerModeEnabled: { false }
            )

            monitor.start(handler: recorder.record)
            monitor.start(handler: recorder.record)
            recorder.removeAll()
            workspaceCenter.post(name: NSWorkspace.willSleepNotification, object: nil)

            try expect(recorder.events == [.sleep], "Expected one observer registration")
        }
    }
}

private func systemActivityStopRemovesObserversTest() -> TestCase {
    TestCase(name: "system activity stop prevents later event delivery") {
        try await MainActor.run {
            let workspaceCenter = NotificationCenter()
            let powerCenter = NotificationCenter()
            let recorder = SystemActivityRecorder()
            let monitor = SystemActivityMonitor(
                workspaceNotificationCenter: workspaceCenter,
                powerNotificationCenter: powerCenter,
                lowPowerModeEnabled: { false }
            )
            monitor.start(handler: recorder.record)
            recorder.removeAll()

            monitor.stop()
            workspaceCenter.post(name: NSWorkspace.didWakeNotification, object: nil)
            powerCenter.post(name: .NSProcessInfoPowerStateDidChange, object: nil)

            try expect(recorder.events.isEmpty, "Expected observers to be removed")
        }
    }
}

private func systemActivityValuesAreSendableTest() -> TestCase {
    TestCase(name: "system activity event is an immutable sendable value") {
        requireSystemActivitySendable(SystemActivityEvent.sleep)
    }
}

@MainActor
private func postWorkspaceEvents(to center: NotificationCenter) {
    center.post(name: NSWorkspace.willSleepNotification, object: nil)
    center.post(name: NSWorkspace.didWakeNotification, object: nil)
    center.post(name: NSWorkspace.sessionDidResignActiveNotification, object: nil)
    center.post(name: NSWorkspace.sessionDidBecomeActiveNotification, object: nil)
}

@MainActor
private final class SystemActivityRecorder {
    private(set) var events: [SystemActivityEvent] = []

    func record(_ event: SystemActivityEvent) {
        events.append(event)
    }

    func removeAll() {
        events.removeAll()
    }
}

@MainActor
private final class MutablePowerState {
    var isEnabled: Bool

    init(isEnabled: Bool) {
        self.isEnabled = isEnabled
    }

    func read() -> Bool {
        isEnabled
    }
}

private func requireSystemActivitySendable<Value: Sendable>(_ value: Value) {
    _ = value
}
