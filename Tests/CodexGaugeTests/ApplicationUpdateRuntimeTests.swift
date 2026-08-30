import CodexGaugeAppKit
import Foundation

func applicationUpdateRuntimeTests() -> [TestCase] {
    [
        applicationUpdateConfigurationRequiresReleaseMetadataTest(),
        applicationUpdateRuntimeChecksOnceAtLaunchTest(),
        applicationUpdateRuntimeMapsProbeResultsTest(),
        disabledApplicationUpdateRuntimePublishesUnavailableStateTest()
    ]
}

private func applicationUpdateConfigurationRequiresReleaseMetadataTest() -> TestCase {
    TestCase(name: "application updater requires only resolved release metadata") {
        let publicKey = Data(repeating: 42, count: 32).base64EncodedString()
        let values = applicationUpdateInfoDictionary(publicKey: publicKey)
        let valid = ApplicationUpdateConfiguration(infoDictionary: values)
        var relaxedValues = values
        relaxedValues["SUEnableAutomaticChecks"] = true
        relaxedValues["SUScheduledCheckInterval"] = 86_400
        relaxedValues["SUAutomaticallyUpdate"] = true
        let relaxedPolicy = ApplicationUpdateConfiguration(
            infoDictionary: relaxedValues
        )
        var invalidValues = values
        invalidValues["SUPublicEDKey"] = ""
        let emptyKey = ApplicationUpdateConfiguration(
            infoDictionary: invalidValues
        )
        invalidValues["SUPublicEDKey"] = "$(SPARKLE_PUBLIC_ED_KEY)"
        let unresolvedKey = ApplicationUpdateConfiguration(
            infoDictionary: invalidValues
        )
        invalidValues = values
        invalidValues["SUFeedURL"] = "http://github.com/example/appcast.xml"
        let insecureFeed = ApplicationUpdateConfiguration(
            infoDictionary: invalidValues
        )

        try expect(valid.isUsable, "Expected a resolved key and HTTPS feed")
        try expect(
            relaxedPolicy.isUsable,
            "Expected runtime startup to ignore release policy duplication"
        )
        try expect(!emptyKey.isUsable, "Expected an empty key to fail closed")
        try expect(!unresolvedKey.isUsable, "Expected a build variable to fail closed")
        try expect(!insecureFeed.isUsable, "Expected a non-HTTPS feed to fail closed")
    }
}

private func applicationUpdateInfoDictionary(publicKey: String) -> [String: Any] {
    [
        "SUFeedURL": "https://github.com/example/releases/latest/download/appcast.xml",
        "SUPublicEDKey": publicKey
    ]
}

private func applicationUpdateRuntimeChecksOnceAtLaunchTest() -> TestCase {
    TestCase(name: "application updater probes once and only presents updates on click") {
        try await MainActor.run {
            let driver = ApplicationUpdateDriverSpy()
            let runtime = SparkleApplicationUpdateRuntime(
                currentVersion: "v1.2.0",
                driver: driver
            )
            var states = [ApplicationUpdateState]()

            runtime.start { states.append($0) }
            runtime.start { states.append($0) }
            runtime.checkForUpdates()
            driver.emit(.updateAvailable(latestVersion: "v1.3.0"))
            runtime.checkForUpdates()

            try expect(
                driver.operations == [.disableScheduledChecks, .start, .probe, .present],
                "Expected one launch probe and one user-initiated presentation"
            )
            try expect(states.first?.status == .checking, "Expected checking state")
            try expect(
                runtime.state == ApplicationUpdateState(
                    currentVersion: "1.2.0",
                    status: .updateAvailable(latestVersion: "1.3.0")
                ),
                "Expected normalized update versions"
            )
        }
    }
}

private func applicationUpdateRuntimeMapsProbeResultsTest() -> TestCase {
    TestCase(name: "application updater maps current and failed probe results") {
        try await MainActor.run {
            let driver = ApplicationUpdateDriverSpy()
            let runtime = SparkleApplicationUpdateRuntime(
                currentVersion: "1.2.0",
                driver: driver
            )
            runtime.start { _ in }

            driver.emit(.upToDate(latestVersion: nil))
            try expect(
                runtime.state.status == .current(latestVersion: "1.2.0"),
                "Expected current version fallback"
            )
            driver.emit(.upToDate(latestVersion: "v1.2.1"))
            try expect(
                runtime.state.status == .current(latestVersion: "1.2.1"),
                "Expected the latest feed version"
            )
            driver.emit(.failed)
            try expect(runtime.state.status == .failed, "Expected failed state")
        }
    }
}

private func disabledApplicationUpdateRuntimePublishesUnavailableStateTest() -> TestCase {
    TestCase(name: "disabled application updater never starts an update session") {
        try await MainActor.run {
            let runtime = DisabledApplicationUpdateRuntime(currentVersion: "1.2.0")
            var states = [ApplicationUpdateState]()

            runtime.start { states.append($0) }
            runtime.checkForUpdates()

            let unavailable = ApplicationUpdateState(
                currentVersion: "1.2.0",
                status: .unavailable
            )
            try expect(states == [unavailable], "Expected one unavailable state")
            try expect(runtime.state == unavailable, "Expected immutable unavailable state")
        }
    }
}

@MainActor
private final class ApplicationUpdateDriverSpy: ApplicationUpdateDriving {
    enum Operation: Equatable {
        case disableScheduledChecks
        case start
        case probe
        case present
        case stop
    }

    private(set) var operations = [Operation]()
    private var eventHandler: (@MainActor (ApplicationUpdateDriverEvent) -> Void)?

    var canCheckForUpdates: Bool {
        true
    }

    func disableScheduledChecks() {
        operations.append(.disableScheduledChecks)
    }

    func start(
        eventHandler: @escaping @MainActor (ApplicationUpdateDriverEvent) -> Void
    ) -> Bool {
        operations.append(.start)
        self.eventHandler = eventHandler
        return true
    }

    func checkForUpdateInformation() {
        operations.append(.probe)
    }

    func checkForUpdates() {
        operations.append(.present)
    }

    func stop() {
        operations.append(.stop)
        eventHandler = nil
    }

    func emit(_ event: ApplicationUpdateDriverEvent) {
        eventHandler?(event)
    }
}
