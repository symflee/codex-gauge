import AppKit
import Foundation

public struct AssistiveDisplayState: Equatable, Sendable {
    public let isVoiceOverEnabled: Bool
    public let shouldReduceMotion: Bool

    public init(
        isVoiceOverEnabled: Bool,
        shouldReduceMotion: Bool
    ) {
        self.isVoiceOverEnabled = isVoiceOverEnabled
        self.shouldReduceMotion = shouldReduceMotion
    }
}

public enum AssistiveDisplayEvent: Equatable, Sendable {
    case initial(AssistiveDisplayState)
    case changed(AssistiveDisplayState)

    public var state: AssistiveDisplayState {
        switch self {
        case .initial(let state), .changed(let state):
            state
        }
    }
}

@MainActor
public protocol AssistiveDisplayObservation: AnyObject {
    func invalidate()
}

@MainActor
public protocol AssistiveDisplayStateSourcing: AnyObject {
    var displayOptionsNotificationCenter: NotificationCenter { get }

    func currentState() -> AssistiveDisplayState

    func observeVoiceOverChanges(
        _ handler: @escaping @MainActor @Sendable () -> Void
    ) -> any AssistiveDisplayObservation
}

@MainActor
public final class AssistiveDisplayMonitor {
    private let source: any AssistiveDisplayStateSourcing
    private var displayOptionsObservation: (any NSObjectProtocol)?
    private var voiceOverObservation: (any AssistiveDisplayObservation)?
    private var handler: (@MainActor @Sendable (AssistiveDisplayEvent) -> Void)?
    private var lastState: AssistiveDisplayState?
    private var isStarted = false

    public convenience init(workspace: NSWorkspace = .shared) {
        self.init(source: WorkspaceAssistiveDisplayStateSource(workspace: workspace))
    }

    public init(source: any AssistiveDisplayStateSourcing) {
        self.source = source
    }

    public func start(
        handler: @escaping @MainActor @Sendable (AssistiveDisplayEvent) -> Void
    ) {
        guard !isStarted else {
            return
        }
        isStarted = true
        self.handler = handler
        observeDisplayOptions()
        observeVoiceOver()
        emitInitialState()
    }

    public func stop() {
        guard isStarted else {
            return
        }
        removeDisplayOptionsObservation()
        voiceOverObservation?.invalidate()
        voiceOverObservation = nil
        handler = nil
        lastState = nil
        isStarted = false
    }

    private func observeDisplayOptions() {
        displayOptionsObservation = source.displayOptionsNotificationCenter.addObserver(
            forName: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.emitChangedStateIfNeeded()
            }
        }
    }

    private func observeVoiceOver() {
        voiceOverObservation = source.observeVoiceOverChanges { [weak self] in
            self?.emitChangedStateIfNeeded()
        }
    }

    private func emitInitialState() {
        let state = source.currentState()
        lastState = state
        handler?(.initial(state))
    }

    private func emitChangedStateIfNeeded() {
        guard isStarted else {
            return
        }
        let state = source.currentState()
        guard state != lastState else {
            return
        }
        lastState = state
        handler?(.changed(state))
    }

    private func removeDisplayOptionsObservation() {
        guard let displayOptionsObservation else {
            return
        }
        source.displayOptionsNotificationCenter.removeObserver(displayOptionsObservation)
        self.displayOptionsObservation = nil
    }
}

@MainActor
private final class WorkspaceAssistiveDisplayStateSource: AssistiveDisplayStateSourcing {
    private let workspace: NSWorkspace

    init(workspace: NSWorkspace) {
        self.workspace = workspace
    }

    var displayOptionsNotificationCenter: NotificationCenter {
        workspace.notificationCenter
    }

    func currentState() -> AssistiveDisplayState {
        AssistiveDisplayState(
            isVoiceOverEnabled: workspace.isVoiceOverEnabled,
            shouldReduceMotion: workspace.accessibilityDisplayShouldReduceMotion
        )
    }

    func observeVoiceOverChanges(
        _ handler: @escaping @MainActor @Sendable () -> Void
    ) -> any AssistiveDisplayObservation {
        WorkspaceVoiceOverObservation(workspace: workspace, handler: handler)
    }
}

@MainActor
private final class WorkspaceVoiceOverObservation: AssistiveDisplayObservation {
    private var observation: NSKeyValueObservation?
    private var handler: (@MainActor @Sendable () -> Void)?

    init(
        workspace: NSWorkspace,
        handler: @escaping @MainActor @Sendable () -> Void
    ) {
        self.handler = handler
        observation = workspace.observe(\.isVoiceOverEnabled, options: []) { [weak self] _, _ in
            Task { @MainActor [weak self] in
                self?.emitIfActive()
            }
        }
    }

    func invalidate() {
        observation?.invalidate()
        observation = nil
        handler = nil
    }

    private func emitIfActive() {
        guard observation != nil else {
            return
        }
        handler?()
    }
}
