import Foundation
import Sparkle

public enum ApplicationUpdateStatus: Equatable, Sendable {
    case unavailable
    case checking
    case current(latestVersion: String)
    case updateAvailable(latestVersion: String)
    case failed

    public var isUpdateAvailable: Bool {
        guard case .updateAvailable = self else {
            return false
        }
        return true
    }
}

public struct ApplicationUpdateState: Equatable, Sendable {
    public static let unavailable = ApplicationUpdateState(
        currentVersion: "?",
        status: .unavailable
    )

    public let currentVersion: String
    public let status: ApplicationUpdateStatus

    public init(
        currentVersion: String,
        status: ApplicationUpdateStatus
    ) {
        self.currentVersion = currentVersion
        self.status = status
    }
}

public struct ApplicationUpdateConfiguration: Equatable, Sendable {
    public let feedURL: URL?
    public let publicKey: String?

    public init(infoDictionary: [String: Any]?) {
        feedURL = Self.feedURL(from: infoDictionary?["SUFeedURL"])
        publicKey = Self.resolvedValue(infoDictionary?["SUPublicEDKey"])
    }

    public var isUsable: Bool {
        guard let feedURL, publicKey != nil else {
            return false
        }
        return feedURL.scheme?.lowercased() == "https" && feedURL.host != nil
    }

    private static func feedURL(from value: Any?) -> URL? {
        guard let value = resolvedValue(value) else {
            return nil
        }
        return URL(string: value)
    }

    private static func resolvedValue(_ value: Any?) -> String? {
        guard let value = value as? String else {
            return nil
        }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !trimmed.contains("$(") else {
            return nil
        }
        return trimmed
    }
}

public enum ApplicationUpdateDriverEvent: Equatable, Sendable {
    case updateAvailable(latestVersion: String)
    case upToDate(latestVersion: String?)
    case failed
}

@MainActor
public protocol ApplicationUpdateDriving: AnyObject {
    var canCheckForUpdates: Bool { get }

    func disableScheduledChecks()
    func start(
        eventHandler: @escaping @MainActor (ApplicationUpdateDriverEvent) -> Void
    ) -> Bool
    func checkForUpdateInformation()
    func checkForUpdates()
    func stop()
}

@MainActor
public protocol ApplicationUpdateRuntime: AnyObject {
    var state: ApplicationUpdateState { get }

    func start(
        stateHandler: @escaping @MainActor (ApplicationUpdateState) -> Void
    )
    func checkForUpdates()
    func stop()
}

@MainActor
public final class DisabledApplicationUpdateRuntime: ApplicationUpdateRuntime {
    public let state: ApplicationUpdateState

    public init(currentVersion: String = "?") {
        state = ApplicationUpdateState(
            currentVersion: normalizedVersion(currentVersion),
            status: .unavailable
        )
    }

    public func start(
        stateHandler: @escaping @MainActor (ApplicationUpdateState) -> Void
    ) {
        stateHandler(state)
    }

    public func checkForUpdates() {}

    public func stop() {}
}

@MainActor
public final class SparkleApplicationUpdateRuntime: ApplicationUpdateRuntime {
    public private(set) var state: ApplicationUpdateState

    private let driver: any ApplicationUpdateDriving
    private var stateHandler: (@MainActor (ApplicationUpdateState) -> Void)?
    private var hasStarted = false

    public convenience init(currentVersion: String) {
        self.init(
            currentVersion: currentVersion,
            driver: SparkleApplicationUpdateDriver()
        )
    }

    public init(
        currentVersion: String,
        driver: any ApplicationUpdateDriving
    ) {
        self.driver = driver
        state = ApplicationUpdateState(
            currentVersion: normalizedVersion(currentVersion),
            status: .checking
        )
    }

    public func start(
        stateHandler: @escaping @MainActor (ApplicationUpdateState) -> Void
    ) {
        self.stateHandler = stateHandler
        guard !hasStarted else {
            stateHandler(state)
            return
        }
        hasStarted = true
        publish(status: .checking)
        startLaunchCheck()
    }

    public func checkForUpdates() {
        guard state.status.isUpdateAvailable,
              driver.canCheckForUpdates else {
            return
        }
        driver.checkForUpdates()
    }

    public func stop() {
        driver.stop()
        stateHandler = nil
    }

    private func startLaunchCheck() {
        driver.disableScheduledChecks()
        let started = driver.start { [weak self] event in
            self?.receive(event)
        }
        guard started, driver.canCheckForUpdates else {
            publish(status: .failed)
            return
        }
        driver.checkForUpdateInformation()
    }

    private func receive(_ event: ApplicationUpdateDriverEvent) {
        switch event {
        case .updateAvailable(let latestVersion):
            publish(status: .updateAvailable(
                latestVersion: normalizedVersion(latestVersion)
            ))
        case .upToDate(let latestVersion):
            publishCurrent(latestVersion: latestVersion)
        case .failed:
            publish(status: .failed)
        }
    }

    private func publishCurrent(latestVersion: String?) {
        let resolvedVersion = latestVersion.map(normalizedVersion)
            ?? state.currentVersion
        publish(status: .current(latestVersion: resolvedVersion))
    }

    private func publish(status: ApplicationUpdateStatus) {
        let next = ApplicationUpdateState(
            currentVersion: state.currentVersion,
            status: status
        )
        state = next
        stateHandler?(next)
    }
}

@MainActor
public final class SparkleApplicationUpdateDriver: NSObject,
    ApplicationUpdateDriving, SPUUpdaterDelegate {
    public var canCheckForUpdates: Bool {
        updater.canCheckForUpdates
    }

    private lazy var updaterController = SPUStandardUpdaterController(
        startingUpdater: false,
        updaterDelegate: self,
        userDriverDelegate: nil
    )
    private var eventHandler: (@MainActor (ApplicationUpdateDriverEvent) -> Void)?
    private var pendingProbeEvent: ApplicationUpdateDriverEvent?
    private var isProbeInProgress = false

    private var updater: SPUUpdater {
        updaterController.updater
    }

    public func disableScheduledChecks() {
        updater.automaticallyChecksForUpdates = false
    }

    public func start(
        eventHandler: @escaping @MainActor (ApplicationUpdateDriverEvent) -> Void
    ) -> Bool {
        self.eventHandler = eventHandler
        updaterController.startUpdater()
        return updater.canCheckForUpdates
    }

    public func checkForUpdateInformation() {
        isProbeInProgress = true
        pendingProbeEvent = nil
        updater.checkForUpdateInformation()
    }

    public func checkForUpdates() {
        updater.checkForUpdates()
    }

    public func stop() {
        eventHandler = nil
        pendingProbeEvent = nil
        isProbeInProgress = false
    }

    public func updater(
        _ updater: SPUUpdater,
        didFindValidUpdate item: SUAppcastItem
    ) {
        _ = updater
        handle(.updateAvailable(latestVersion: item.displayVersionString))
    }

    public func updaterDidNotFindUpdate(
        _ updater: SPUUpdater,
        error: Error
    ) {
        _ = updater
        let latestItem = (error as NSError)
            .userInfo[SPULatestAppcastItemFoundKey] as? SUAppcastItem
        handle(.upToDate(latestVersion: latestItem?.displayVersionString))
    }

    public func updater(
        _ updater: SPUUpdater,
        didFinishUpdateCycleFor updateCheck: SPUUpdateCheck,
        error: Error?
    ) {
        _ = updater
        guard updateCheck == .updateInformation else {
            return
        }
        finishProbe(error: error)
    }

    private func handle(_ event: ApplicationUpdateDriverEvent) {
        guard isProbeInProgress else {
            eventHandler?(event)
            return
        }
        pendingProbeEvent = event
    }

    private func finishProbe(error: Error?) {
        isProbeInProgress = false
        if let pendingProbeEvent {
            self.pendingProbeEvent = nil
            eventHandler?(pendingProbeEvent)
            return
        }
        guard error != nil else {
            return
        }
        eventHandler?(.failed)
    }
}

@MainActor
public enum ApplicationUpdateRuntimeFactory {
    public static func makeDefault(
        bundle: Bundle = .main
    ) -> any ApplicationUpdateRuntime {
        let version = currentVersion(in: bundle)
        let configuration = ApplicationUpdateConfiguration(
            infoDictionary: bundle.infoDictionary
        )
        guard configuration.isUsable else {
            return DisabledApplicationUpdateRuntime(currentVersion: version)
        }
        return SparkleApplicationUpdateRuntime(currentVersion: version)
    }

    private static func currentVersion(in bundle: Bundle) -> String {
        let value = bundle.infoDictionary?["CFBundleShortVersionString"] as? String
        return normalizedVersion(value ?? "?")
    }
}

private func normalizedVersion(_ value: String) -> String {
    let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
    guard trimmed.count > 1,
          trimmed.first?.lowercased() == "v" else {
        return trimmed.isEmpty ? "?" : trimmed
    }
    return String(trimmed.dropFirst())
}
