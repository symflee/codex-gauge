import ServiceManagement

public enum LaunchAtLoginStatus: Equatable, Sendable, CaseIterable {
    case disabled
    case enabled
    case requiresApproval
    case unavailable
}

public enum LaunchAtLoginError: Error, Equatable, Sendable {
    case serviceUnavailable
    case registrationFailed
    case unregistrationFailed
}

@MainActor
public protocol LaunchAtLoginServicing: AnyObject {
    var status: LaunchAtLoginStatus { get }

    func register() throws
    func unregister() async throws
    func openSystemSettings()
}

@MainActor
public final class LaunchAtLoginController {
    private let service: any LaunchAtLoginServicing

    public convenience init() {
        self.init(service: SystemLaunchAtLoginService())
    }

    public init(service: any LaunchAtLoginServicing) {
        self.service = service
    }

    public var currentStatus: LaunchAtLoginStatus {
        service.status
    }

    public func setEnabled(
        _ enabled: Bool
    ) async throws(LaunchAtLoginError) -> LaunchAtLoginStatus {
        guard service.status != .unavailable else {
            throw .serviceUnavailable
        }
        if enabled {
            try enableIfNeeded()
            return service.status
        }
        try await disableIfNeeded()
        return service.status
    }

    @discardableResult
    public func openApprovalSettingsIfNeeded() -> Bool {
        guard service.status == .requiresApproval else {
            return false
        }
        service.openSystemSettings()
        return true
    }

    private func enableIfNeeded() throws(LaunchAtLoginError) {
        guard service.status == .disabled else {
            return
        }
        do {
            try service.register()
        } catch {
            if service.status == .enabled || service.status == .requiresApproval {
                return
            }
            throw .registrationFailed
        }
    }

    private func disableIfNeeded() async throws(LaunchAtLoginError) {
        guard service.status != .disabled else {
            return
        }
        do {
            try await service.unregister()
        } catch {
            guard service.status != .disabled else {
                return
            }
            throw .unregistrationFailed
        }
    }
}

@MainActor
private final class SystemLaunchAtLoginService: LaunchAtLoginServicing {
    private let service = SMAppService.mainApp

    var status: LaunchAtLoginStatus {
        switch service.status {
        case .notRegistered:
            .disabled
        case .enabled:
            .enabled
        case .requiresApproval:
            .requiresApproval
        case .notFound:
            .unavailable
        @unknown default:
            .unavailable
        }
    }

    func register() throws {
        try service.register()
    }

    func unregister() async throws {
        try await service.unregister()
    }

    func openSystemSettings() {
        SMAppService.openSystemSettingsLoginItems()
    }
}
