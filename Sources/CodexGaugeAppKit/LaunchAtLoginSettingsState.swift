public enum LaunchAtLoginToggleValue: Equatable, Sendable {
    case off
    case on
    case mixed
}

public struct LaunchAtLoginSettingsState: Equatable, Sendable {
    public let status: LaunchAtLoginStatus
    public let failure: LaunchAtLoginError?

    public init(
        status: LaunchAtLoginStatus,
        failure: LaunchAtLoginError? = nil
    ) {
        self.status = status
        self.failure = failure
    }

    public var toggleValue: LaunchAtLoginToggleValue {
        switch status {
        case .enabled:
            .on
        case .requiresApproval:
            .mixed
        case .disabled, .unavailable:
            .off
        }
    }

    public var allowsChanges: Bool {
        status != .unavailable
    }

    public var showsSystemSettingsRecovery: Bool {
        status == .requiresApproval
    }
}
