import CodexGaugeProtocol
import CodexGaugeRefresh
import Foundation

public enum CodexExecutableSource: String, Equatable, Sendable {
    case automatic
    case userSelected = "user-selected"
}

public enum CodexPathCategory: String, Equatable, Sendable {
    case applicationBundle = "application-bundle"
    case homebrew
    case userLocal = "user-local"
    case other
}

public struct CodexPathSummary: Equatable, Sendable {
    public let source: CodexExecutableSource
    public let category: CodexPathCategory
    public let basename: String?

    public init(
        source: CodexExecutableSource,
        category: CodexPathCategory,
        basename: String?
    ) {
        self.source = source
        self.category = category
        self.basename = Self.safeBasename(basename)
    }

    init(executableURL: URL, source: CodexExecutableSource) {
        self.init(
            source: source,
            category: Self.category(for: executableURL),
            basename: executableURL.lastPathComponent
        )
    }

    private static func safeBasename(_ value: String?) -> String? {
        guard let value, !value.isEmpty, value.count <= 64 else {
            return nil
        }
        guard value.allSatisfy(isSafeBasenameCharacter) else {
            return nil
        }
        return value
    }

    private static func isSafeBasenameCharacter(_ character: Character) -> Bool {
        character.isASCII && (
            character.isLetter
                || character.isNumber
                || character == "."
                || character == "_"
                || character == "-"
                || character == "+"
        )
    }

    private static func category(for url: URL) -> CodexPathCategory {
        let path = url.standardizedFileURL.path
        if path.contains(".app/Contents/Resources/") {
            return .applicationBundle
        }
        if path.hasPrefix("/opt/homebrew/") || path.hasPrefix("/usr/local/") {
            return .homebrew
        }
        if path.contains("/.local/bin/") {
            return .userLocal
        }
        return .other
    }
}

public enum CodexConnectionStatus: String, Equatable, Sendable {
    case connected
    case checking
    case notFound = "not-found"
    case invalidSelection = "invalid-selection"
    case signedOut = "signed-out"
    case unsupportedAuth = "unsupported-auth"
    case incompatible
    case timeout
    case processFailure = "process-failure"
}

public enum CLIVersionIssue: String, Equatable, Sendable {
    case timeout
    case processFailure = "process-failure"
    case incompatibleOutput = "incompatible-output"
    case cancelled

    init(_ error: CodexCLIVersionProbeError) {
        switch error {
        case .timeout:
            self = .timeout
        case .invalidOutput, .outputTooLarge:
            self = .incompatibleOutput
        case .cancelled:
            self = .cancelled
        case .launchFailed, .processFailed:
            self = .processFailure
        }
    }

    var connectionFallback: CodexConnectionStatus {
        switch self {
        case .timeout:
            .timeout
        case .incompatibleOutput:
            .incompatible
        case .processFailure:
            .processFailure
        case .cancelled:
            .checking
        }
    }
}

public struct ConnectionDiagnosticsSnapshot: Equatable, Sendable {
    public static let checking = ConnectionDiagnosticsSnapshot(
        executableSource: nil,
        path: nil,
        cliVersion: nil,
        cliVersionIssue: nil,
        connectionStatus: .checking
    )

    public let executableSource: CodexExecutableSource?
    public let path: CodexPathSummary?
    public let cliVersion: CodexCLIVersion?
    public let cliVersionIssue: CLIVersionIssue?
    public let connectionStatus: CodexConnectionStatus

    public init(
        executableSource: CodexExecutableSource? = nil,
        path: CodexPathSummary?,
        cliVersion: CodexCLIVersion?,
        cliVersionIssue: CLIVersionIssue?,
        connectionStatus: CodexConnectionStatus
    ) {
        self.executableSource = executableSource ?? path?.source
        self.path = path
        self.cliVersion = cliVersion
        self.cliVersionIssue = cliVersionIssue
        self.connectionStatus = connectionStatus
    }
}

public protocol ConnectionDiagnosticsInspecting: Sendable {
    func inspect(
        locator: any CodexLocating,
        source: CodexExecutableSource,
        connectionStatus: CodexConnectionStatus
    ) async -> ConnectionDiagnosticsSnapshot
}

public actor ConnectionDiagnosticsInspector: ConnectionDiagnosticsInspecting {
    private let versionProbe: any CodexCLIVersionProbing

    public init(versionProbe: any CodexCLIVersionProbing) {
        self.versionProbe = versionProbe
    }

    public func inspect(
        locator: any CodexLocating,
        source: CodexExecutableSource,
        connectionStatus: CodexConnectionStatus
    ) async -> ConnectionDiagnosticsSnapshot {
        let executableURL: URL
        do {
            executableURL = try locator.locate()
        } catch let error {
            return locationFailure(error, source: source)
        }
        let path = CodexPathSummary(executableURL: executableURL, source: source)
        do {
            let version = try await versionProbe.version(of: executableURL)
            return ConnectionDiagnosticsSnapshot(
                executableSource: source,
                path: path,
                cliVersion: version,
                cliVersionIssue: nil,
                connectionStatus: connectionStatus
            )
        } catch let error {
            return versionFailure(error, path: path, connectionStatus: connectionStatus)
        }
    }

    private func locationFailure(
        _ error: CodexLocationError,
        source: CodexExecutableSource
    ) -> ConnectionDiagnosticsSnapshot {
        let status: CodexConnectionStatus = error == .notFound
            ? .notFound
            : .invalidSelection
        return ConnectionDiagnosticsSnapshot(
            executableSource: source,
            path: nil,
            cliVersion: nil,
            cliVersionIssue: nil,
            connectionStatus: status
        )
    }

    private func versionFailure(
        _ error: CodexCLIVersionProbeError,
        path: CodexPathSummary,
        connectionStatus: CodexConnectionStatus
    ) -> ConnectionDiagnosticsSnapshot {
        let issue = CLIVersionIssue(error)
        let status = connectionStatus == .checking
            ? issue.connectionFallback
            : connectionStatus
        return ConnectionDiagnosticsSnapshot(
            executableSource: path.source,
            path: path,
            cliVersion: nil,
            cliVersionIssue: issue,
            connectionStatus: status
        )
    }
}

public struct ConnectionStatusResolver: Sendable {
    public init() {}

    public func resolve(
        _ publication: RefreshPublication
    ) -> CodexConnectionStatus {
        if publication.isRefreshing {
            return .checking
        }
        if let failure = publication.failure {
            return status(for: failure)
        }
        if publication.lastSuccessfulRefresh != nil {
            return .connected
        }
        return .checking
    }

    private func status(for failure: RefreshFailure) -> CodexConnectionStatus {
        switch failure {
        case .codexNotFound:
            .notFound
        case .invalidCodexSelection:
            .invalidSelection
        case .timeout:
            .timeout
        case .protocolIncompatible:
            .incompatible
        case .signedOut:
            .signedOut
        case .unsupportedAuthentication:
            .unsupportedAuth
        case .processUnavailable, .connectionInterrupted, .server:
            .processFailure
        }
    }
}

public enum DiagnosticArchitecture: String, Equatable, Sendable {
    case arm64
    case x86_64
    case other
}

public struct DiagnosticEnvironment: Equatable, Sendable {
    public let appVersion: String
    public let macOSVersion: String
    public let architecture: DiagnosticArchitecture

    public init(
        appVersion: String,
        macOSVersion: String,
        architecture: DiagnosticArchitecture
    ) {
        self.appVersion = Self.safeMetadata(appVersion)
        self.macOSVersion = Self.safeMetadata(macOSVersion)
        self.architecture = architecture
    }

    public static func current(bundle: Bundle = .main) -> DiagnosticEnvironment {
        let system = ProcessInfo.processInfo.operatingSystemVersion
        let macOSVersion = "\(system.majorVersion).\(system.minorVersion).\(system.patchVersion)"
        let appVersion = bundle.object(
            forInfoDictionaryKey: "CFBundleShortVersionString"
        ) as? String ?? "development"
        return DiagnosticEnvironment(
            appVersion: appVersion,
            macOSVersion: macOSVersion,
            architecture: currentArchitecture
        )
    }

    private static var currentArchitecture: DiagnosticArchitecture {
        #if arch(arm64)
        .arm64
        #elseif arch(x86_64)
        .x86_64
        #else
        .other
        #endif
    }

    private static func safeMetadata(_ value: String) -> String {
        guard !value.isEmpty, value.count <= 64 else {
            return "unknown"
        }
        guard value.allSatisfy(isSafeMetadataCharacter) else {
            return "unknown"
        }
        return value
    }

    private static func isSafeMetadataCharacter(_ character: Character) -> Bool {
        character.isASCII && (
            character.isLetter
                || character.isNumber
                || character == "."
                || character == "_"
                || character == "-"
                || character == "+"
        )
    }
}

public struct ConnectionDiagnosticReportBuilder: Sendable {
    public init() {}

    public func makeReport(
        snapshot: ConnectionDiagnosticsSnapshot,
        environment: DiagnosticEnvironment
    ) -> String {
        [
            "Codex Gauge diagnostics",
            "app-version: \(environment.appVersion)",
            "macOS-version: \(environment.macOSVersion)",
            "architecture: \(environment.architecture.rawValue)",
            "connection-status: \(snapshot.connectionStatus.rawValue)",
            "path-source: \(snapshot.executableSource?.rawValue ?? "unavailable")",
            "path-category: \(snapshot.path?.category.rawValue ?? "unavailable")",
            "cli-version: \(snapshot.cliVersion?.value ?? "unavailable")",
            "cli-version-issue: \(snapshot.cliVersionIssue?.rawValue ?? "none")"
        ].joined(separator: "\n")
    }
}

public typealias SettingsConnectionDiagnosticsProvider = @Sendable (
    _ selectedExecutableURL: URL?,
    _ connectionStatus: CodexConnectionStatus
) async -> ConnectionDiagnosticsSnapshot
