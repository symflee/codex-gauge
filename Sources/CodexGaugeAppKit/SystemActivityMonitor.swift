import AppKit
import Foundation

public enum SystemActivityEvent: Equatable, Sendable {
    case sleep
    case wake
    case sessionLocked
    case sessionUnlocked
    case lowPowerModeChanged(isEnabled: Bool)
}

@MainActor
public final class SystemActivityMonitor {
    private let workspaceNotificationCenter: NotificationCenter
    private let powerNotificationCenter: NotificationCenter
    private let lowPowerModeEnabled: @MainActor () -> Bool
    private var observations: [SystemActivityObservation] = []
    private var handler: (@MainActor (SystemActivityEvent) -> Void)?

    public convenience init(
        workspace: NSWorkspace = .shared,
        processInfo: ProcessInfo = .processInfo
    ) {
        self.init(
            workspaceNotificationCenter: workspace.notificationCenter,
            powerNotificationCenter: .default,
            lowPowerModeEnabled: { processInfo.isLowPowerModeEnabled }
        )
    }

    public init(
        workspaceNotificationCenter: NotificationCenter,
        powerNotificationCenter: NotificationCenter,
        lowPowerModeEnabled: @escaping @MainActor () -> Bool
    ) {
        self.workspaceNotificationCenter = workspaceNotificationCenter
        self.powerNotificationCenter = powerNotificationCenter
        self.lowPowerModeEnabled = lowPowerModeEnabled
    }

    public func start(
        handler: @escaping @MainActor (SystemActivityEvent) -> Void
    ) {
        guard observations.isEmpty else {
            return
        }
        self.handler = handler
        observeWorkspaceEvents()
        observePowerState()
        emitCurrentPowerState()
    }

    public func stop() {
        observations.forEach { observation in
            observation.center.removeObserver(observation.token)
        }
        observations.removeAll()
        handler = nil
    }

    private func observeWorkspaceEvents() {
        observe(
            center: workspaceNotificationCenter,
            name: NSWorkspace.willSleepNotification,
            event: .sleep
        )
        observe(
            center: workspaceNotificationCenter,
            name: NSWorkspace.didWakeNotification,
            event: .wake
        )
        observe(
            center: workspaceNotificationCenter,
            name: NSWorkspace.sessionDidResignActiveNotification,
            event: .sessionLocked
        )
        observe(
            center: workspaceNotificationCenter,
            name: NSWorkspace.sessionDidBecomeActiveNotification,
            event: .sessionUnlocked
        )
    }

    private func observePowerState() {
        let token = powerNotificationCenter.addObserver(
            forName: .NSProcessInfoPowerStateDidChange,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.emitCurrentPowerState()
            }
        }
        observations.append(SystemActivityObservation(
            center: powerNotificationCenter,
            token: token
        ))
    }

    private func observe(
        center: NotificationCenter,
        name: Notification.Name,
        event: SystemActivityEvent
    ) {
        let token = center.addObserver(
            forName: name,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.emit(event)
            }
        }
        observations.append(SystemActivityObservation(center: center, token: token))
    }

    private func emitCurrentPowerState() {
        emit(.lowPowerModeChanged(isEnabled: lowPowerModeEnabled()))
    }

    private func emit(_ event: SystemActivityEvent) {
        handler?(event)
    }
}

private struct SystemActivityObservation {
    let center: NotificationCenter
    let token: any NSObjectProtocol
}
