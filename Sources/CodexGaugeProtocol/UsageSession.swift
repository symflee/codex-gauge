import Darwin
import Foundation

public protocol CodexUsageProviding: Sendable {
    func makeSession() throws(CodexLocationError) -> UsageSession
}

public struct CodexUsageProvider: CodexUsageProviding, Sendable {
    private let locator: any CodexLocating
    private let configuration: UsageSessionConfiguration

    public init(
        locator: any CodexLocating,
        configuration: UsageSessionConfiguration = .production
    ) {
        self.locator = locator
        self.configuration = configuration
    }

    public func makeSession() throws(CodexLocationError) -> UsageSession {
        let executableURL = try locator.locate()
        return UsageSession(
            executableURL: executableURL,
            configuration: configuration
        )
    }
}

public struct UsageSessionConfiguration: Equatable, Sendable {
    public static var production: UsageSessionConfiguration {
        production(inheriting: ProcessInfo.processInfo.environment)
    }

    package static func production(
        inheriting environment: [String: String],
        safeSearchPath: String = CodexProcessEnvironment.safeSearchPath
    ) -> UsageSessionConfiguration {
        UsageSessionConfiguration(
            initializeTimeout: .seconds(5),
            requestTimeout: .seconds(15),
            stopGracePeriod: .milliseconds(500),
            environment: CodexProcessEnvironment.appServer(
                inheriting: environment,
                safeSearchPath: safeSearchPath
            )
        )
    }

    public let initializeTimeout: Duration
    public let requestTimeout: Duration
    public let stopGracePeriod: Duration
    package let environment: [String: String]?

    public init(
        initializeTimeout: Duration,
        requestTimeout: Duration,
        stopGracePeriod: Duration
    ) {
        self.initializeTimeout = initializeTimeout
        self.requestTimeout = requestTimeout
        self.stopGracePeriod = stopGracePeriod
        environment = nil
    }

    private init(
        initializeTimeout: Duration,
        requestTimeout: Duration,
        stopGracePeriod: Duration,
        environment: [String: String]
    ) {
        self.initializeTimeout = initializeTimeout
        self.requestTimeout = requestTimeout
        self.stopGracePeriod = stopGracePeriod
        self.environment = environment
    }
}

public enum UsageSessionOperation: Equatable, Sendable {
    case initialize
    case account
    case rateLimits
}

public enum UsageSessionError: Error, Equatable, Sendable {
    case notStarted
    case requestInProgress
    case requestIdentifierExhausted
    case launchFailed
    case processFailed(exitStatus: Int32?)
    case endOfFile
    case timeout(UsageSessionOperation)
    case malformedResponse
    case responseTooLarge
    case unsupportedVersion
    case protocolIncompatible
    case signedOut
    case unsupportedAuth
    case rpcFailure(code: Int)
    case stopped
    case cancelled
}

public enum UsageSessionState: Equatable, Sendable {
    case idle
    case starting
    case ready
    case stopping
    case stopped
    case failed(UsageSessionError)
}

public actor UsageSession {
    public private(set) var state = UsageSessionState.idle

    private let executableURL: URL
    private let configuration: UsageSessionConfiguration
    private let clock = ContinuousClock()
    private let interpreter = AppServerResponseInterpreter()
    private let messageDecoder = JSONRPCMessageDecoder()

    private var process: Process?
    private var inputWriter: FileHandle?
    private var outputReader: FileHandle?
    private var framer = JSONLFramer()
    private var nextRequestIdentifier: Int64 = 1
    private var pendingResponse: PendingResponse?
    private var transportEndTask: Task<Void, Never>?
    private var failureCleanupTask: Task<Void, Never>?
    private var recordedExitStatus: Int32?
    private var readingRateLimits = false
    private var accountValidated = false
    private var transportGeneration: UInt64 = 0

    public init(
        executableURL: URL,
        configuration: UsageSessionConfiguration = .production
    ) {
        self.executableURL = executableURL
        self.configuration = configuration
    }

    public func start() async throws {
        guard state == .idle else {
            throw errorForStartState()
        }
        state = .starting
        do {
            try launchProcess()
            try await performHandshake()
            state = .ready
        } catch {
            let sessionError = mapUnknownError(error)
            failSession(with: sessionError)
            throw sessionError
        }
    }

    public func readRateLimits(
        capturedAt: Date = Date()
    ) async throws -> RateLimitReadResult {
        try ensureReadyForRead()
        readingRateLimits = true
        defer { readingRateLimits = false }

        do {
            try await validateAccountIfNeeded()
            return try await requestRateLimits(capturedAt: capturedAt)
        } catch {
            let sessionError = mapUnknownError(error)
            failSession(with: sessionError)
            throw sessionError
        }
    }

    public func stop() async {
        guard state != .stopped else {
            return
        }
        state = .stopping
        completePendingResponse(throwing: .stopped)
        transportEndTask?.cancel()
        transportEndTask = nil
        closeInput()
        stopReadingOutput()
        await terminateProcessIfNeeded()
        closeTransportHandles()
        state = .stopped
    }

    private func errorForStartState() -> UsageSessionError {
        switch state {
        case .stopped, .stopping:
            .stopped
        case let .failed(error):
            error
        default:
            .requestInProgress
        }
    }

    private func launchProcess() throws {
        let child = Process()
        let input = Pipe()
        let output = Pipe()
        configure(child: child, input: input, output: output)
        installCallbacks(child: child, output: output.fileHandleForReading)
        do {
            try child.run()
        } catch {
            removeCallbacks(child: child, output: output.fileHandleForReading)
            closePipeHandles(input: input, output: output)
            throw UsageSessionError.launchFailed
        }
        process = child
        inputWriter = input.fileHandleForWriting
        outputReader = output.fileHandleForReading
        closeChildFacingParentHandles(input: input, output: output)
    }

    private func configure(child: Process, input: Pipe, output: Pipe) {
        child.executableURL = executableURL
        child.arguments = ["app-server"]
        child.standardInput = input
        child.standardOutput = output
        child.standardError = FileHandle.nullDevice
        if let environment = configuration.environment {
            child.environment = environment
        }
    }

    private func installCallbacks(
        child: Process,
        output: FileHandle
    ) {
        installOutputHandler(on: output)
        installTerminationHandler(on: child)
    }

    private func installOutputHandler(on output: FileHandle) {
        output.readabilityHandler = { [weak self] readableHandle in
            readableHandle.readabilityHandler = nil
            let data = readableHandle.availableData
            Task { [weak self, data] in
                await self?.receiveOutputChunk(data)
            }
        }
    }

    private func installTerminationHandler(on child: Process) {
        child.terminationHandler = { [weak self] terminatedChild in
            let status = terminatedChild.terminationStatus
            Task { [weak self, status] in
                await self?.receiveProcessTermination(status: status)
            }
        }
    }

    private func removeCallbacks(child: Process, output: FileHandle) {
        output.readabilityHandler = nil
        child.terminationHandler = nil
    }

    private func closePipeHandles(input: Pipe, output: Pipe) {
        try? input.fileHandleForWriting.close()
        try? input.fileHandleForReading.close()
        try? output.fileHandleForWriting.close()
        try? output.fileHandleForReading.close()
    }

    private func closeChildFacingParentHandles(input: Pipe, output: Pipe) {
        try? input.fileHandleForReading.close()
        try? output.fileHandleForWriting.close()
    }

    private func performHandshake() async throws {
        let response = try await request(
            method: "initialize",
            params: initializeParameters,
            operation: .initialize,
            timeout: configuration.initializeTimeout
        )
        do {
            _ = try interpreter.initialize(from: response)
        } catch {
            throw mapInterpretationError(error, handshake: true)
        }
        try writeNotification(method: "initialized", params: .object([:]))
    }

    private var initializeParameters: JSONValue {
        .object([
            "clientInfo": .object([
                "name": .string("codex-gauge"),
                "title": .string("Codex Gauge"),
                "version": .string("0.1.0")
            ])
        ])
    }

    private func readAccountStatus() async throws -> AccountStatus {
        let response = try await request(
            method: "account/read",
            params: .object(["refreshToken": .boolean(false)]),
            operation: .account,
            timeout: configuration.requestTimeout
        )
        do {
            return try interpreter.account(from: response)
        } catch {
            throw mapInterpretationError(error, handshake: false)
        }
    }

    private func validateAccountIfNeeded() async throws {
        guard accountValidated == false else {
            return
        }
        let account = try await readAccountStatus()
        try validate(account: account)
        accountValidated = true
    }

    private func validate(account: AccountStatus) throws {
        switch account {
        case .signedOut:
            throw UsageSessionError.signedOut
        case .unsupportedProvider:
            throw UsageSessionError.unsupportedAuth
        case .rateLimitsAvailable, .unknownProvider:
            return
        }
    }

    private func requestRateLimits(
        capturedAt: Date
    ) async throws -> RateLimitReadResult {
        let response = try await request(
            method: "account/rateLimits/read",
            params: .object([:]),
            operation: .rateLimits,
            timeout: configuration.requestTimeout
        )
        do {
            return try interpreter.rateLimits(
                from: response,
                capturedAt: capturedAt
            )
        } catch {
            throw mapInterpretationError(error, handshake: false)
        }
    }

    private func ensureReadyForRead() throws {
        guard state == .ready else {
            throw errorForReadState()
        }
        guard readingRateLimits == false, pendingResponse == nil else {
            throw UsageSessionError.requestInProgress
        }
    }

    private func errorForReadState() -> UsageSessionError {
        switch state {
        case .stopped, .stopping:
            .stopped
        case let .failed(error):
            error
        default:
            .notStarted
        }
    }

    private func request(
        method: String,
        params: JSONValue,
        operation: UsageSessionOperation,
        timeout: Duration
    ) async throws -> JSONRPCResponse {
        guard pendingResponse == nil else {
            throw UsageSessionError.requestInProgress
        }
        let identifier = try takeNextRequestIdentifier()
        let response = try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                installPendingResponse(
                    identifier: identifier,
                    operation: operation,
                    timeout: timeout,
                    continuation: continuation
                )
                sendRequest(
                    identifier: identifier,
                    method: method,
                    params: params
                )
            }
        } onCancel: {
            Task { [weak self] in
                await self?.cancelPendingResponse(identifier: identifier)
            }
        }
        guard Task.isCancelled == false else {
            throw UsageSessionError.cancelled
        }
        return response
    }

    private func takeNextRequestIdentifier() throws -> Int64 {
        guard nextRequestIdentifier < Int64.max else {
            throw UsageSessionError.requestIdentifierExhausted
        }
        let identifier = nextRequestIdentifier
        nextRequestIdentifier += 1
        return identifier
    }

    private func installPendingResponse(
        identifier: Int64,
        operation: UsageSessionOperation,
        timeout: Duration,
        continuation: CheckedContinuation<JSONRPCResponse, any Error>
    ) {
        let timeoutTask = makeTimeoutTask(
            identifier: identifier,
            operation: operation,
            timeout: timeout
        )
        pendingResponse = PendingResponse(
            identifier: .integer(identifier),
            continuation: continuation,
            timeoutTask: timeoutTask
        )
    }

    private func makeTimeoutTask(
        identifier: Int64,
        operation: UsageSessionOperation,
        timeout: Duration
    ) -> Task<Void, Never> {
        Task { [weak self, clock] in
            do {
                try await clock.sleep(for: timeout)
            } catch {
                return
            }
            await self?.timeOutPendingResponse(
                identifier: identifier,
                operation: operation
            )
        }
    }

    private func sendRequest(
        identifier: Int64,
        method: String,
        params: JSONValue
    ) {
        let message = JSONValue.object([
            "id": .integer(identifier),
            "method": .string(method),
            "params": params
        ])
        do {
            try write(message)
        } catch {
            completePendingResponse(
                identifier: identifier,
                throwing: .processFailed(exitStatus: currentExitStatus())
            )
        }
    }

    private func writeNotification(
        method: String,
        params: JSONValue
    ) throws {
        try write(.object([
            "method": .string(method),
            "params": params
        ]))
    }

    private func write(_ message: JSONValue) throws {
        guard let inputWriter else {
            throw UsageSessionError.processFailed(exitStatus: currentExitStatus())
        }
        var data = try JSONEncoder().encode(message)
        data.append(0x0A)
        do {
            try inputWriter.write(contentsOf: data)
        } catch {
            throw UsageSessionError.processFailed(exitStatus: currentExitStatus())
        }
    }

    private func receiveOutput(_ data: Data) {
        guard ignoresTransportEvents == false else {
            return
        }
        guard data.isEmpty == false else {
            receiveEndOfFile()
            return
        }
        do {
            let lines = try framer.append(data)
            try lines.forEach(receiveLine)
        } catch let error as JSONLFramingError {
            failSession(with: mapFramingError(error))
        } catch {
            failSession(with: .malformedResponse)
        }
    }

    private func receiveOutputChunk(_ data: Data) {
        receiveOutput(data)
        guard data.isEmpty == false, ignoresTransportEvents == false else {
            return
        }
        armOutputReader()
    }

    private func armOutputReader() {
        guard let outputReader else {
            return
        }
        installOutputHandler(on: outputReader)
    }

    private func receiveLine(_ line: Data) throws {
        let message: JSONRPCMessage
        do {
            message = try messageDecoder.decode(line)
        } catch {
            throw UsageSessionError.malformedResponse
        }
        guard case let .response(response) = message else {
            return
        }
        completePendingResponse(with: response)
    }

    private func receiveEndOfFile() {
        do {
            try framer.finish().forEach(receiveLine)
        } catch let error as JSONLFramingError {
            failSession(with: mapFramingError(error))
            return
        } catch {
            failSession(with: .malformedResponse)
            return
        }
        scheduleTransportEndClassification(after: .milliseconds(20))
    }

    private func receiveProcessTermination(status: Int32) {
        guard state != .stopped else {
            return
        }
        recordedExitStatus = status
    }

    private func scheduleTransportEndClassification(after delay: Duration) {
        transportEndTask?.cancel()
        transportGeneration &+= 1
        let generation = transportGeneration
        transportEndTask = Task { [weak self, clock, delay] in
            do {
                try await clock.sleep(for: delay)
            } catch {
                return
            }
            await self?.classifyTransportEnd(generation: generation)
        }
    }

    private func classifyTransportEnd(generation: UInt64) {
        guard generation == transportGeneration else {
            return
        }
        guard ignoresTransportEvents == false else {
            return
        }
        let status = recordedExitStatus ?? currentExitStatus()
        guard let status, status != 0 else {
            failSession(with: .endOfFile)
            return
        }
        failSession(with: .processFailed(exitStatus: status))
    }

    private var ignoresTransportEvents: Bool {
        switch state {
        case .stopping, .stopped, .failed:
            true
        default:
            false
        }
    }

    private func completePendingResponse(with response: JSONRPCResponse) {
        guard pendingResponse?.identifier == response.id else {
            return
        }
        guard let pending = removePendingResponse() else {
            return
        }
        pending.continuation.resume(returning: response)
    }

    private func completePendingResponse(
        identifier: Int64? = nil,
        throwing error: UsageSessionError
    ) {
        if let identifier {
            guard pendingResponse?.identifier == .integer(identifier) else {
                return
            }
        }
        guard let pending = removePendingResponse() else {
            return
        }
        pending.continuation.resume(throwing: error)
    }

    private func removePendingResponse() -> PendingResponse? {
        guard let pendingResponse else {
            return nil
        }
        self.pendingResponse = nil
        pendingResponse.timeoutTask.cancel()
        return pendingResponse
    }

    private func timeOutPendingResponse(
        identifier: Int64,
        operation: UsageSessionOperation
    ) {
        guard pendingResponse?.identifier == .integer(identifier) else {
            return
        }
        let error = timeoutError(operation: operation)
        completePendingResponse(identifier: identifier, throwing: error)
        guard pendingResponse == nil else {
            return
        }
        failSession(with: error)
    }

    private func timeoutError(
        operation: UsageSessionOperation
    ) -> UsageSessionError {
        guard let status = currentExitStatus() else {
            return .timeout(operation)
        }
        guard status == 0 else {
            return .processFailed(exitStatus: status)
        }
        return .endOfFile
    }

    private func cancelPendingResponse(identifier: Int64) {
        guard pendingResponse?.identifier == .integer(identifier) else {
            return
        }
        completePendingResponse(identifier: identifier, throwing: .cancelled)
        guard pendingResponse == nil else {
            return
        }
        failSession(with: .cancelled)
    }

    private func failSession(with error: UsageSessionError) {
        guard ignoresTransportEvents == false else {
            return
        }
        state = .failed(error)
        completePendingResponse(throwing: error)
        transportEndTask?.cancel()
        transportEndTask = nil
        closeInput()
        stopReadingOutput()
        terminateImmediately()
        scheduleFailureCleanup()
    }

    private func scheduleFailureCleanup() {
        guard failureCleanupTask == nil else {
            return
        }
        failureCleanupTask = Task {
            await completeFailureCleanup()
        }
    }

    private func completeFailureCleanup() async {
        await terminateProcessIfNeeded()
        guard case .failed = state else {
            failureCleanupTask = nil
            return
        }
        closeTransportHandles()
        failureCleanupTask = nil
    }

    private func mapInterpretationError(
        _ error: any Error,
        handshake: Bool
    ) -> UsageSessionError {
        guard let error = error as? AppServerInterpretationError else {
            return .malformedResponse
        }
        switch error {
        case let .rpcFailure(code):
            return mapRPCFailure(code)
        case .invalidInitializeResult:
            return handshake ? .unsupportedVersion : .malformedResponse
        case .invalidAccountResult, .invalidRateLimitsResult:
            return .malformedResponse
        }
    }

    private func mapRPCFailure(_ code: Int) -> UsageSessionError {
        switch code {
        case -32_601:
            .unsupportedVersion
        case -32_700, -32_600, -32_602:
            .protocolIncompatible
        default:
            .rpcFailure(code: code)
        }
    }

    private func mapUnknownError(_ error: any Error) -> UsageSessionError {
        if let error = error as? UsageSessionError {
            return error
        }
        if Task.isCancelled {
            return .cancelled
        }
        return .malformedResponse
    }

    private func mapFramingError(
        _ error: JSONLFramingError
    ) -> UsageSessionError {
        switch error {
        case .lineTooLong:
            .responseTooLarge
        }
    }

    private func currentExitStatus() -> Int32? {
        guard let process, process.isRunning == false else {
            return recordedExitStatus
        }
        return process.terminationStatus
    }

    private func closeInput() {
        guard let inputWriter else {
            return
        }
        try? inputWriter.close()
        self.inputWriter = nil
    }

    private func stopReadingOutput() {
        outputReader?.readabilityHandler = nil
    }

    private func terminateImmediately() {
        guard let process, process.isRunning else {
            return
        }
        process.terminate()
    }

    private func terminateProcessIfNeeded() async {
        guard let process, process.isRunning else {
            return
        }
        process.terminate()
        await waitForProcessExit(for: configuration.stopGracePeriod)
        guard process.isRunning else {
            return
        }
        Darwin.kill(process.processIdentifier, SIGKILL)
        await waitForProcessExit(for: configuration.stopGracePeriod)
    }

    private func waitForProcessExit(for duration: Duration) async {
        let deadline = clock.now.advanced(by: duration)
        while process?.isRunning == true, clock.now < deadline {
            await cancellationIndependentPause()
        }
    }

    private func cancellationIndependentPause() async {
        let pause = Task.detached {
            try? await ContinuousClock().sleep(for: .milliseconds(5))
        }
        await pause.value
    }

    private func closeTransportHandles() {
        if let process, let outputReader {
            removeCallbacks(child: process, output: outputReader)
        }
        try? outputReader?.close()
        process = nil
        outputReader = nil
        recordedExitStatus = nil
    }
}

private struct PendingResponse {
    let identifier: JSONRPCIdentifier
    let continuation: CheckedContinuation<JSONRPCResponse, any Error>
    let timeoutTask: Task<Void, Never>
}
