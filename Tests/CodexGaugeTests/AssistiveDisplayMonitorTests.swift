import AppKit
import CodexGaugeAppKit
import Foundation

func assistiveDisplayMonitorTests() -> [TestCase] {
    [
        assistiveDisplayEmitsInitialStateTest(),
        assistiveDisplayObservesReduceMotionTest(),
        assistiveDisplayObservesVoiceOverTest(),
        assistiveDisplaySuppressesUnchangedStateTest(),
        assistiveDisplayStartIsIdempotentTest(),
        assistiveDisplayStopRemovesObservationsTest(),
        assistiveDisplayCanRestartTest(),
        assistiveDisplayValuesAreSendableTest()
    ]
}

private func assistiveDisplayEmitsInitialStateTest() -> TestCase {
    TestCase(name: "assistive display emits current state when monitoring starts") {
        try await MainActor.run {
            let source = SyntheticAssistiveDisplaySource(
                state: AssistiveDisplayState(
                    isVoiceOverEnabled: true,
                    shouldReduceMotion: false
                )
            )
            let recorder = AssistiveDisplayRecorder()
            let monitor = AssistiveDisplayMonitor(source: source)

            monitor.start(handler: recorder.record)

            try expect(recorder.events == [
                .initial(AssistiveDisplayState(
                    isVoiceOverEnabled: true,
                    shouldReduceMotion: false
                ))
            ], "Expected both current accessibility settings")
        }
    }
}

private func assistiveDisplayObservesReduceMotionTest() -> TestCase {
    TestCase(name: "assistive display resamples reduce motion after workspace notification") {
        try await MainActor.run {
            let source = SyntheticAssistiveDisplaySource(state: .disabled)
            let recorder = AssistiveDisplayRecorder()
            let monitor = AssistiveDisplayMonitor(source: source)
            monitor.start(handler: recorder.record)
            recorder.removeAll()

            source.state = AssistiveDisplayState(
                isVoiceOverEnabled: false,
                shouldReduceMotion: true
            )
            source.postDisplayOptionsChanged()

            try expect(recorder.events == [
                .changed(AssistiveDisplayState(
                    isVoiceOverEnabled: false,
                    shouldReduceMotion: true
                ))
            ], "Expected workspace display options to be resampled")
        }
    }
}

private func assistiveDisplayObservesVoiceOverTest() -> TestCase {
    TestCase(name: "assistive display resamples state after VoiceOver KVO change") {
        try await MainActor.run {
            let source = SyntheticAssistiveDisplaySource(state: .disabled)
            let recorder = AssistiveDisplayRecorder()
            let monitor = AssistiveDisplayMonitor(source: source)
            monitor.start(handler: recorder.record)
            recorder.removeAll()

            source.state = AssistiveDisplayState(
                isVoiceOverEnabled: true,
                shouldReduceMotion: false
            )
            source.postVoiceOverChanged()

            try expect(recorder.events == [
                .changed(AssistiveDisplayState(
                    isVoiceOverEnabled: true,
                    shouldReduceMotion: false
                ))
            ], "Expected VoiceOver observation to emit the new state")
        }
    }
}

private func assistiveDisplaySuppressesUnchangedStateTest() -> TestCase {
    TestCase(name: "assistive display ignores notifications with unchanged state") {
        try await MainActor.run {
            let source = SyntheticAssistiveDisplaySource(state: .disabled)
            let recorder = AssistiveDisplayRecorder()
            let monitor = AssistiveDisplayMonitor(source: source)
            monitor.start(handler: recorder.record)
            recorder.removeAll()

            source.postDisplayOptionsChanged()
            source.postVoiceOverChanged()

            try expect(recorder.events.isEmpty, "Expected no duplicate state delivery")
        }
    }
}

private func assistiveDisplayStartIsIdempotentTest() -> TestCase {
    TestCase(name: "assistive display start does not duplicate observations") {
        try await MainActor.run {
            let source = SyntheticAssistiveDisplaySource(state: .disabled)
            let recorder = AssistiveDisplayRecorder()
            let monitor = AssistiveDisplayMonitor(source: source)

            monitor.start(handler: recorder.record)
            monitor.start(handler: recorder.record)
            recorder.removeAll()
            source.state = .enabled
            source.postDisplayOptionsChanged()

            try expect(source.voiceOverObservationCount == 1, "Expected one KVO observation")
            try expect(recorder.events == [.changed(.enabled)], "Expected one event delivery")
        }
    }
}

private func assistiveDisplayStopRemovesObservationsTest() -> TestCase {
    TestCase(name: "assistive display stop removes notification and KVO observations") {
        try await MainActor.run {
            let source = SyntheticAssistiveDisplaySource(state: .disabled)
            let recorder = AssistiveDisplayRecorder()
            let monitor = AssistiveDisplayMonitor(source: source)
            monitor.start(handler: recorder.record)
            recorder.removeAll()

            monitor.stop()
            source.state = .enabled
            source.postDisplayOptionsChanged()
            source.postVoiceOverChanged()

            try expect(source.latestObservation?.invalidationCount == 1, "Expected KVO invalidation")
            try expect(recorder.events.isEmpty, "Expected no events after stop")
        }
    }
}

private func assistiveDisplayCanRestartTest() -> TestCase {
    TestCase(name: "assistive display can start again after stop") {
        try await MainActor.run {
            let source = SyntheticAssistiveDisplaySource(state: .disabled)
            let recorder = AssistiveDisplayRecorder()
            let monitor = AssistiveDisplayMonitor(source: source)
            monitor.start(handler: recorder.record)
            monitor.stop()
            recorder.removeAll()
            source.state = .enabled

            monitor.start(handler: recorder.record)

            try expect(source.voiceOverObservationCount == 2, "Expected a fresh KVO observation")
            try expect(recorder.events == [.initial(.enabled)], "Expected a fresh initial state")
        }
    }
}

private func assistiveDisplayValuesAreSendableTest() -> TestCase {
    TestCase(name: "assistive display event and state are immutable sendable values") {
        requireAssistiveDisplaySendable(AssistiveDisplayState.disabled)
        requireAssistiveDisplaySendable(
            AssistiveDisplayEvent.initial(.disabled)
        )
    }
}

@MainActor
private final class SyntheticAssistiveDisplaySource: AssistiveDisplayStateSourcing {
    let displayOptionsNotificationCenter = NotificationCenter()
    var state: AssistiveDisplayState
    private(set) var voiceOverObservationCount = 0
    private(set) var latestObservation: SyntheticAssistiveDisplayObservation?
    private var voiceOverHandler: (@MainActor @Sendable () -> Void)?

    init(state: AssistiveDisplayState) {
        self.state = state
    }

    func currentState() -> AssistiveDisplayState {
        state
    }

    func observeVoiceOverChanges(
        _ handler: @escaping @MainActor @Sendable () -> Void
    ) -> any AssistiveDisplayObservation {
        let observation = SyntheticAssistiveDisplayObservation()
        voiceOverObservationCount += 1
        latestObservation = observation
        voiceOverHandler = handler
        return observation
    }

    func postDisplayOptionsChanged() {
        displayOptionsNotificationCenter.post(
            name: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification,
            object: nil
        )
    }

    func postVoiceOverChanged() {
        guard latestObservation?.isActive == true else {
            return
        }
        voiceOverHandler?()
    }
}

@MainActor
private final class SyntheticAssistiveDisplayObservation: AssistiveDisplayObservation {
    private(set) var invalidationCount = 0

    var isActive: Bool {
        invalidationCount == 0
    }

    func invalidate() {
        invalidationCount += 1
    }
}

@MainActor
private final class AssistiveDisplayRecorder {
    private(set) var events: [AssistiveDisplayEvent] = []

    func record(_ event: AssistiveDisplayEvent) {
        events.append(event)
    }

    func removeAll() {
        events.removeAll()
    }
}

private func requireAssistiveDisplaySendable<Value: Sendable>(_ value: Value) {
    _ = value
}

private extension AssistiveDisplayState {
    static let disabled = AssistiveDisplayState(
        isVoiceOverEnabled: false,
        shouldReduceMotion: false
    )

    static let enabled = AssistiveDisplayState(
        isVoiceOverEnabled: true,
        shouldReduceMotion: true
    )
}
