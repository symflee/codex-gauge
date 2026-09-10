import CodexGaugeCore
import Foundation

public protocol AppServerSmokeSession: Sendable {
    func start() async throws
    func readRateLimits(capturedAt: Date) async throws -> RateLimitReadResult
    @discardableResult
    func stop() async -> UsageSessionStopResult
}

extension UsageSession: AppServerSmokeSession {}

public protocol AppServerSmokeSessionProviding: Sendable {
    func makeSmokeSession() throws -> any AppServerSmokeSession
}

public struct ProductionAppServerSmokeSessionProvider: AppServerSmokeSessionProviding {
    private let usageProvider: CodexUsageProvider

    public init(
        locator: any CodexLocating,
        configuration: UsageSessionConfiguration = .production
    ) {
        usageProvider = CodexUsageProvider(
            locator: locator,
            configuration: configuration
        )
    }

    public func makeSmokeSession() throws -> any AppServerSmokeSession {
        try usageProvider.makeSession()
    }
}

public enum AppServerSmokeProductState: Equatable, Sendable {
    case available
    case partial
    case unavailable
    case malformed
}

public enum AppServerSmokeFailure: Equatable, Sendable {
    case executableNotFound
    case invalidSelection
    case signedOut
    case unsupportedAuthentication
    case unsupportedVersion
    case incompatibleProtocol
    case timeout
    case processFailure
    case cleanupUnconfirmed
    case protocolFailure
    case cancelled
    case internalFailure
}

public enum AppServerSmokeResult: Equatable, Sendable {
    case success(
        codex: AppServerSmokeProductState,
        spark: AppServerSmokeProductState
    )
    case failure(AppServerSmokeFailure)

    public var exitCode: Int32 {
        switch self {
        case .success:
            0
        case let .failure(failure):
            failure.exitCode
        }
    }
}

public struct AppServerSmokeOutputFormatter: Sendable {
    public init() {}

    public func line(for result: AppServerSmokeResult) -> String {
        switch result {
        case let .success(codex, spark):
            successLine(codex: codex, spark: spark)
        case let .failure(failure):
            "codex-gauge-smoke: failed reason=\(failure.label)"
        }
    }

    private func successLine(
        codex: AppServerSmokeProductState,
        spark: AppServerSmokeProductState
    ) -> String {
        "codex-gauge-smoke: ok codex=\(codex.label) spark=\(spark.label)"
    }
}

public struct AppServerSmokeRunner: Sendable {
    private let sessionProvider: any AppServerSmokeSessionProviding

    public init(sessionProvider: any AppServerSmokeSessionProviding) {
        self.sessionProvider = sessionProvider
    }

    public func run() async -> AppServerSmokeResult {
        guard Task.isCancelled == false else {
            return .failure(.cancelled)
        }
        let session: any AppServerSmokeSession
        do {
            session = try sessionProvider.makeSmokeSession()
        } catch {
            return .failure(map(error))
        }
        return await run(session: session)
    }

    private func run(
        session: any AppServerSmokeSession
    ) async -> AppServerSmokeResult {
        let stopper = AppServerSmokeStopper()
        return await withTaskCancellationHandler {
            let result = await execute(session: session)
            let stopResult = await stopper.stop(session)
            guard stopResult == .exited else {
                return .failure(.cleanupUnconfirmed)
            }
            guard Task.isCancelled == false else {
                return .failure(.cancelled)
            }
            return result
        } onCancel: {
            Task {
                _ = await stopper.stop(session)
            }
        }
    }

    private func execute(
        session: any AppServerSmokeSession
    ) async -> AppServerSmokeResult {
        do {
            try await session.start()
            let result = try await session.readRateLimits(capturedAt: Date())
            return classify(result)
        } catch {
            guard Task.isCancelled == false else {
                return .failure(.cancelled)
            }
            return .failure(map(error))
        }
    }

    private func classify(
        _ result: RateLimitReadResult
    ) -> AppServerSmokeResult {
        guard result.responseStatus == .accepted else {
            return .failure(.incompatibleProtocol)
        }
        return .success(
            codex: map(result.rateLimits(for: .codex).state),
            spark: map(result.rateLimits(for: .spark).state)
        )
    }

    private func map(
        _ state: ProductRateLimitState
    ) -> AppServerSmokeProductState {
        switch state {
        case .available:
            .available
        case .partial:
            .partial
        case .unavailable:
            .unavailable
        case .malformed:
            .malformed
        }
    }

    private func map(_ error: any Error) -> AppServerSmokeFailure {
        if let locationError = error as? CodexLocationError {
            return map(locationError)
        }
        if let sessionError = error as? UsageSessionError {
            return map(sessionError)
        }
        return .internalFailure
    }

    private func map(_ error: CodexLocationError) -> AppServerSmokeFailure {
        switch error {
        case .notFound:
            .executableNotFound
        case .invalidSelection:
            .invalidSelection
        }
    }

    private func map(_ error: UsageSessionError) -> AppServerSmokeFailure {
        switch error {
        case .signedOut:
            .signedOut
        case .unsupportedAuth:
            .unsupportedAuthentication
        case .unsupportedVersion:
            .unsupportedVersion
        case .protocolIncompatible:
            .incompatibleProtocol
        case .timeout:
            .timeout
        case .launchFailed, .processFailed, .endOfFile:
            .processFailure
        case .malformedResponse, .responseTooLarge, .rpcFailure:
            .protocolFailure
        case .cancelled:
            .cancelled
        case .notStarted,
             .requestInProgress,
             .requestIdentifierExhausted,
             .stopped:
            .internalFailure
        }
    }
}

private actor AppServerSmokeStopper {
    private var stopTask: Task<UsageSessionStopResult, Never>?

    func stop(_ session: any AppServerSmokeSession) async -> UsageSessionStopResult {
        if let stopTask {
            return await stopTask.value
        }
        let task = Task {
            await session.stop()
        }
        stopTask = task
        return await task.value
    }
}

private extension AppServerSmokeProductState {
    var label: String {
        switch self {
        case .available:
            "available"
        case .partial:
            "partial"
        case .unavailable:
            "unavailable"
        case .malformed:
            "malformed"
        }
    }
}

private extension AppServerSmokeFailure {
    var label: String {
        switch self {
        case .executableNotFound:
            "executable_not_found"
        case .invalidSelection:
            "invalid_selection"
        case .signedOut:
            "signed_out"
        case .unsupportedAuthentication:
            "unsupported_authentication"
        case .unsupportedVersion:
            "unsupported_version"
        case .incompatibleProtocol:
            "incompatible_protocol"
        case .timeout:
            "timeout"
        case .processFailure:
            "process_failure"
        case .cleanupUnconfirmed:
            "cleanup_unconfirmed"
        case .protocolFailure:
            "protocol_failure"
        case .cancelled:
            "cancelled"
        case .internalFailure:
            "internal_failure"
        }
    }

    var exitCode: Int32 {
        switch self {
        case .executableNotFound, .invalidSelection:
            2
        case .signedOut, .unsupportedAuthentication:
            3
        case .unsupportedVersion, .incompatibleProtocol, .protocolFailure:
            4
        case .timeout, .processFailure, .cleanupUnconfirmed:
            5
        case .cancelled, .internalFailure:
            6
        }
    }
}
