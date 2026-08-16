import Darwin
import Foundation

public struct CodexCLIVersion: Equatable, Sendable, CustomStringConvertible {
    public let value: String

    init(value: String) {
        self.value = value
    }

    public var description: String {
        value
    }
}

public enum CodexCLIVersionProbeError: Error, Equatable, Sendable {
    case launchFailed
    case timeout
    case processFailed
    case outputTooLarge
    case invalidOutput
    case cancelled
}

public struct CodexCLIVersionParser: Sendable {
    public static let maximumInputBytes = 4_096

    public init() {}

    public func parse(
        _ data: Data
    ) throws(CodexCLIVersionProbeError) -> CodexCLIVersion {
        guard data.count <= Self.maximumInputBytes else {
            throw .outputTooLarge
        }
        guard let output = String(data: data, encoding: .utf8) else {
            throw .invalidOutput
        }
        guard let token = output.split(whereSeparator: \Character.isWhitespace)
            .compactMap(normalizedVersionToken)
            .first else {
            throw .invalidOutput
        }
        return CodexCLIVersion(value: token)
    }

    private func normalizedVersionToken(
        _ candidate: Substring
    ) -> String? {
        let token = candidate.first == "v" ? candidate.dropFirst() : candidate[...]
        guard token.count <= 64, token.count >= 3 else {
            return nil
        }
        guard token.first?.isNumber == true else {
            return nil
        }
        guard token.contains("."), token.allSatisfy(isVersionCharacter) else {
            return nil
        }
        return String(token)
    }

    private func isVersionCharacter(_ character: Character) -> Bool {
        character.isASCII && (
            character.isNumber
                || character.isLetter
                || character == "."
                || character == "-"
                || character == "+"
        )
    }
}

public struct CodexCLIVersionProbeConfiguration: Equatable, Sendable {
    public static let production = CodexCLIVersionProbeConfiguration(
        timeout: .seconds(2),
        stopGracePeriod: .milliseconds(250),
        maximumOutputBytes: CodexCLIVersionParser.maximumInputBytes
    )

    public let timeout: Duration
    public let stopGracePeriod: Duration
    public let maximumOutputBytes: Int
    public let environment: [String: String]?

    public init(
        timeout: Duration,
        stopGracePeriod: Duration,
        maximumOutputBytes: Int,
        environment: [String: String]? = nil
    ) {
        self.timeout = timeout
        self.stopGracePeriod = stopGracePeriod
        self.maximumOutputBytes = max(1, maximumOutputBytes)
        self.environment = environment
    }
}

public protocol CodexCLIVersionProbing: Sendable {
    func version(
        of executableURL: URL
    ) async throws(CodexCLIVersionProbeError) -> CodexCLIVersion
}

public actor CodexCLIVersionProbe: CodexCLIVersionProbing {
    private let configuration: CodexCLIVersionProbeConfiguration
    private let parser = CodexCLIVersionParser()
    private let clock = ContinuousClock()

    private var process: Process?
    private var outputReader: FileHandle?
    private var output = Data()
    private var reachedEndOfOutput = false
    private var recordedExitStatus: Int32?
    private var pendingProbe: PendingVersionProbe?
    private var nextGeneration: UInt64 = 0

    public init(
        configuration: CodexCLIVersionProbeConfiguration = .production
    ) {
        self.configuration = configuration
    }

    public func version(
        of executableURL: URL
    ) async throws(CodexCLIVersionProbeError) -> CodexCLIVersion {
        guard process == nil, pendingProbe == nil else {
            throw .processFailed
        }
        nextGeneration &+= 1
        let generation = nextGeneration
        do {
            try launch(executableURL: executableURL, generation: generation)
            let data = try await waitForOutput(generation: generation)
            await cleanUpProcess()
            return try parser.parse(data)
        } catch let error as CodexCLIVersionProbeError {
            await cleanUpProcess()
            throw error
        } catch {
            await cleanUpProcess()
            throw .processFailed
        }
    }

    private func launch(
        executableURL: URL,
        generation: UInt64
    ) throws(CodexCLIVersionProbeError) {
        let child = Process()
        let outputPipe = Pipe()
        configure(
            child,
            executableURL: executableURL,
            outputPipe: outputPipe
        )
        installCallbacks(
            child,
            reader: outputPipe.fileHandleForReading,
            generation: generation
        )
        do {
            try child.run()
        } catch {
            removeCallbacks(child, reader: outputPipe.fileHandleForReading)
            close(outputPipe)
            throw .launchFailed
        }
        process = child
        outputReader = outputPipe.fileHandleForReading
        try? outputPipe.fileHandleForWriting.close()
    }

    private func configure(
        _ child: Process,
        executableURL: URL,
        outputPipe: Pipe
    ) {
        child.executableURL = executableURL
        child.arguments = ["--version"]
        child.standardOutput = outputPipe
        child.standardError = FileHandle.nullDevice
        child.environment = configuration.environment
    }

    private func installCallbacks(
        _ child: Process,
        reader: FileHandle,
        generation: UInt64
    ) {
        installOutputHandler(reader, generation: generation)
        child.terminationHandler = { [weak self] terminatedChild in
            let status = terminatedChild.terminationStatus
            Task { [weak self, status] in
                await self?.receiveTermination(status, generation: generation)
            }
        }
    }

    private func installOutputHandler(
        _ reader: FileHandle,
        generation: UInt64
    ) {
        reader.readabilityHandler = { [weak self] readableHandle in
            readableHandle.readabilityHandler = nil
            let data = readableHandle.availableData
            Task { [weak self, data] in
                await self?.receiveOutput(data, generation: generation)
            }
        }
    }

    private func waitForOutput(
        generation: UInt64
    ) async throws -> Data {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                let timeoutTask = makeTimeoutTask(generation: generation)
                pendingProbe = PendingVersionProbe(
                    generation: generation,
                    continuation: continuation,
                    timeoutTask: timeoutTask
                )
            }
        } onCancel: {
            Task { [weak self] in
                await self?.cancel(generation: generation)
            }
        }
    }

    private func makeTimeoutTask(
        generation: UInt64
    ) -> Task<Void, Never> {
        Task { [weak self, clock, configuration] in
            do {
                try await clock.sleep(for: configuration.timeout)
            } catch {
                return
            }
            await self?.timeOut(generation: generation)
        }
    }

    private func receiveOutput(
        _ data: Data,
        generation: UInt64
    ) {
        guard generation == pendingProbe?.generation else {
            return
        }
        guard data.isEmpty == false else {
            reachedEndOfOutput = true
            completeIfReady(generation: generation)
            return
        }
        guard output.count <= configuration.maximumOutputBytes - data.count else {
            complete(generation: generation, throwing: .outputTooLarge)
            return
        }
        output.append(data)
        guard let outputReader else {
            complete(generation: generation, throwing: .processFailed)
            return
        }
        installOutputHandler(outputReader, generation: generation)
    }

    private func receiveTermination(
        _ status: Int32,
        generation: UInt64
    ) {
        guard generation == pendingProbe?.generation else {
            return
        }
        recordedExitStatus = status
        guard status == 0 else {
            complete(generation: generation, throwing: .processFailed)
            return
        }
        completeIfReady(generation: generation)
    }

    private func completeIfReady(generation: UInt64) {
        guard reachedEndOfOutput, recordedExitStatus == 0 else {
            return
        }
        complete(generation: generation, returning: output)
    }

    private func timeOut(generation: UInt64) {
        complete(generation: generation, throwing: .timeout)
    }

    private func cancel(generation: UInt64) {
        complete(generation: generation, throwing: .cancelled)
    }

    private func complete(
        generation: UInt64,
        returning data: Data
    ) {
        guard let pending = removePending(generation: generation) else {
            return
        }
        pending.continuation.resume(returning: data)
    }

    private func complete(
        generation: UInt64,
        throwing error: CodexCLIVersionProbeError
    ) {
        guard let pending = removePending(generation: generation) else {
            return
        }
        pending.continuation.resume(throwing: error)
    }

    private func removePending(
        generation: UInt64
    ) -> PendingVersionProbe? {
        guard pendingProbe?.generation == generation else {
            return nil
        }
        let pending = pendingProbe
        pendingProbe = nil
        pending?.timeoutTask.cancel()
        outputReader?.readabilityHandler = nil
        return pending
    }

    private func cleanUpProcess() async {
        pendingProbe?.timeoutTask.cancel()
        pendingProbe = nil
        outputReader?.readabilityHandler = nil
        process?.terminationHandler = nil
        await terminateProcessIfNeeded()
        try? outputReader?.close()
        process = nil
        outputReader = nil
        output = Data()
        reachedEndOfOutput = false
        recordedExitStatus = nil
    }

    private func terminateProcessIfNeeded() async {
        guard let process, process.isRunning else {
            return
        }
        process.terminate()
        await waitForExit(for: configuration.stopGracePeriod)
        guard process.isRunning else {
            return
        }
        Darwin.kill(process.processIdentifier, SIGKILL)
        await waitForExit(for: configuration.stopGracePeriod)
    }

    private func waitForExit(for duration: Duration) async {
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

    private func removeCallbacks(_ child: Process, reader: FileHandle) {
        child.terminationHandler = nil
        reader.readabilityHandler = nil
    }

    private func close(_ pipe: Pipe) {
        try? pipe.fileHandleForReading.close()
        try? pipe.fileHandleForWriting.close()
    }
}

private struct PendingVersionProbe {
    let generation: UInt64
    let continuation: CheckedContinuation<Data, any Error>
    let timeoutTask: Task<Void, Never>
}
