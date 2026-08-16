import CodexGaugeAppKit
import Foundation

func launchAtLoginTests() -> [TestCase] {
    [
        launchStatusMappingTest(),
        launchEnableRegistrationTest(),
        launchEnableIdempotenceTest(),
        launchApprovalGuidanceTest(),
        launchDisableRegistrationTest(),
        launchUnavailableServiceTest(),
        launchFailureRedactionTest(),
        launchConcurrentStatusChangeTest(),
        launchValueSendabilityTest()
    ]
}

private func launchStatusMappingTest() -> TestCase {
    TestCase(name: "login launch reports every system service status") {
        try await MainActor.run {
            for status in LaunchAtLoginStatus.allCases {
                let controller = LaunchAtLoginController(
                    service: RecordingLaunchAtLoginService(status: status)
                )
                try expect(controller.currentStatus == status, "Expected exact status mapping")
            }
        }
    }
}

private func launchEnableRegistrationTest() -> TestCase {
    TestCase(name: "enabling login launch registers the main application once") {
        try await withLaunchController(status: .disabled) { controller, service in
            service.statusAfterRegistration = .enabled

            let status = try await controller.setEnabled(true)

            try expect(status == .enabled, "Expected enabled system status")
            try expect(service.registrationCount == 1, "Expected one registration")
            try expect(service.unregistrationCount == 0, "Expected no unregistration")
        }
    }
}

private func launchEnableIdempotenceTest() -> TestCase {
    TestCase(name: "enabling an active login item does not register twice") {
        try await withLaunchController(status: .enabled) { controller, service in
            let status = try await controller.setEnabled(true)

            try expect(status == .enabled, "Expected unchanged enabled status")
            try expect(service.registrationCount == 0, "Expected idempotent enable")
        }
    }
}

private func launchApprovalGuidanceTest() -> TestCase {
    TestCase(name: "approval-required login items open settings without re-registering") {
        try await withLaunchController(status: .requiresApproval) { controller, service in
            let status = try await controller.setEnabled(true)
            let opened = controller.openApprovalSettingsIfNeeded()

            try expect(status == .requiresApproval, "Expected approval-required status")
            try expect(service.registrationCount == 0, "Expected no duplicate registration")
            try expect(opened, "Expected System Settings action")
            try expect(service.openSettingsCount == 1, "Expected one settings request")

            service.status = .enabled
            try expect(!controller.openApprovalSettingsIfNeeded(), "Expected no settings outside approval")
        }
    }
}

private func launchDisableRegistrationTest() -> TestCase {
    TestCase(name: "disabling login launch unregisters enabled and approval states") {
        for initialStatus in [LaunchAtLoginStatus.enabled, .requiresApproval] {
            try await withLaunchController(status: initialStatus) { controller, service in
                service.statusAfterUnregistration = .disabled

                let status = try await controller.setEnabled(false)

                try expect(status == .disabled, "Expected disabled system status")
                try expect(service.unregistrationCount == 1, "Expected one unregistration")
            }
        }
    }
}

private func launchUnavailableServiceTest() -> TestCase {
    TestCase(name: "unavailable login service fails without mutation") {
        try await withLaunchController(status: .unavailable) { controller, service in
            try await expectLaunchError(.serviceUnavailable) {
                _ = try await controller.setEnabled(true)
            }
            try await expectLaunchError(.serviceUnavailable) {
                _ = try await controller.setEnabled(false)
            }

            try expect(service.registrationCount == 0, "Expected no unavailable registration")
            try expect(service.unregistrationCount == 0, "Expected no unavailable unregistration")
        }
    }
}

private func launchFailureRedactionTest() -> TestCase {
    TestCase(name: "login launch exposes typed failures without system error details") {
        try await withLaunchController(status: .disabled) { controller, service in
            service.registrationError = SyntheticLaunchServiceError()
            try await expectLaunchError(.registrationFailed) {
                _ = try await controller.setEnabled(true)
            }
        }
        try await withLaunchController(status: .enabled) { controller, service in
            service.unregistrationError = SyntheticLaunchServiceError()
            try await expectLaunchError(.unregistrationFailed) {
                _ = try await controller.setEnabled(false)
            }
        }
    }
}

private func launchConcurrentStatusChangeTest() -> TestCase {
    TestCase(name: "login launch accepts an already-achieved status after a system race") {
        try await withLaunchController(status: .disabled) { controller, service in
            service.statusAfterRegistration = .enabled
            service.registrationError = SyntheticLaunchServiceError()

            let status = try await controller.setEnabled(true)
            try expect(status == .enabled, "Expected concurrently enabled state")
        }
        try await withLaunchController(status: .enabled) { controller, service in
            service.statusAfterUnregistration = .disabled
            service.unregistrationError = SyntheticLaunchServiceError()

            let status = try await controller.setEnabled(false)
            try expect(status == .disabled, "Expected concurrently disabled state")
        }
    }
}

private func launchValueSendabilityTest() -> TestCase {
    TestCase(name: "login launch statuses and errors are immutable sendable values") {
        requireLaunchSendable(LaunchAtLoginStatus.enabled)
        requireLaunchSendable(LaunchAtLoginError.registrationFailed)
    }
}

@MainActor
private func withLaunchController(
    status: LaunchAtLoginStatus,
    operation: @MainActor (
        LaunchAtLoginController,
        RecordingLaunchAtLoginService
    ) async throws -> Void
) async throws {
    let service = RecordingLaunchAtLoginService(status: status)
    let controller = LaunchAtLoginController(service: service)
    try await operation(controller, service)
}

@MainActor
private func expectLaunchError(
    _ expected: LaunchAtLoginError,
    operation: @MainActor () async throws -> Void
) async throws {
    do {
        try await operation()
        throw TestFailure(description: "Expected login launch failure")
    } catch let error as LaunchAtLoginError {
        try expect(error == expected, "Unexpected login launch error")
    }
}

@MainActor
private final class RecordingLaunchAtLoginService: LaunchAtLoginServicing {
    var status: LaunchAtLoginStatus
    var statusAfterRegistration: LaunchAtLoginStatus?
    var statusAfterUnregistration: LaunchAtLoginStatus?
    var registrationError: (any Error)?
    var unregistrationError: (any Error)?
    private(set) var registrationCount = 0
    private(set) var unregistrationCount = 0
    private(set) var openSettingsCount = 0

    init(status: LaunchAtLoginStatus) {
        self.status = status
    }

    func register() throws {
        registrationCount += 1
        status = statusAfterRegistration ?? status
        if let registrationError {
            throw registrationError
        }
    }

    func unregister() async throws {
        unregistrationCount += 1
        status = statusAfterUnregistration ?? status
        if let unregistrationError {
            throw unregistrationError
        }
    }

    func openSystemSettings() {
        openSettingsCount += 1
    }
}

private struct SyntheticLaunchServiceError: Error {}

private func requireLaunchSendable<Value: Sendable>(_ value: Value) {
    _ = value
}
