public enum ApplicationSuspensionReason: Hashable, Sendable {
    case sleep
    case sessionLocked
}

public enum ApplicationActivityEvent: Equatable, Sendable {
    case began(ApplicationSuspensionReason)
    case ended(ApplicationSuspensionReason)
}

public enum ApplicationActivityCommand: Equatable, Sendable {
    case suspend
    case resume
}

public struct ApplicationActivityState: Equatable, Sendable {
    public static let active = ApplicationActivityState(reasons: [])

    public let reasons: Set<ApplicationSuspensionReason>

    public init(reasons: Set<ApplicationSuspensionReason>) {
        self.reasons = reasons
    }

    public var isSuspended: Bool {
        !reasons.isEmpty
    }
}

public struct ApplicationActivityTransition: Equatable, Sendable {
    public let state: ApplicationActivityState
    public let command: ApplicationActivityCommand?

    public init(
        state: ApplicationActivityState,
        command: ApplicationActivityCommand? = nil
    ) {
        self.state = state
        self.command = command
    }
}

public struct ApplicationActivityReducer: Sendable {
    public init() {}

    public func reduce(
        state: ApplicationActivityState,
        event: ApplicationActivityEvent
    ) -> ApplicationActivityTransition {
        switch event {
        case .began(let reason):
            begin(reason, state: state)
        case .ended(let reason):
            end(reason, state: state)
        }
    }

    private func begin(
        _ reason: ApplicationSuspensionReason,
        state: ApplicationActivityState
    ) -> ApplicationActivityTransition {
        var reasons = state.reasons
        let inserted = reasons.insert(reason).inserted
        guard inserted else {
            return ApplicationActivityTransition(state: state)
        }
        let command: ApplicationActivityCommand? = state.isSuspended ? nil : .suspend
        return ApplicationActivityTransition(
            state: ApplicationActivityState(reasons: reasons),
            command: command
        )
    }

    private func end(
        _ reason: ApplicationSuspensionReason,
        state: ApplicationActivityState
    ) -> ApplicationActivityTransition {
        var reasons = state.reasons
        guard reasons.remove(reason) != nil else {
            return ApplicationActivityTransition(state: state)
        }
        let command: ApplicationActivityCommand? = reasons.isEmpty ? .resume : nil
        return ApplicationActivityTransition(
            state: ApplicationActivityState(reasons: reasons),
            command: command
        )
    }
}
