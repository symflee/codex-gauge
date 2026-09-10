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
    private static let commandPrefixes = ["codex-cli ", "codex "]

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
        guard let line = singleOutputLine(output) else {
            throw .invalidOutput
        }
        guard let token = versionToken(in: line), isSemverLike(token) else {
            throw .invalidOutput
        }
        return CodexCLIVersion(value: token)
    }

    private func singleOutputLine(_ output: String) -> String? {
        var line = output
        if line.hasSuffix("\r\n") || line.hasSuffix("\n") {
            line.removeLast()
        }
        guard line.isEmpty == false else {
            return nil
        }
        guard line.unicodeScalars.contains(where: isLineEnding) == false else {
            return nil
        }
        return line
    }

    private func isLineEnding(_ scalar: Unicode.Scalar) -> Bool {
        scalar.value == 10 || scalar.value == 13
    }

    private func versionToken(in line: String) -> String? {
        for prefix in Self.commandPrefixes where line.hasPrefix(prefix) {
            let token = line.dropFirst(prefix.count)
            guard token.isEmpty == false else {
                return nil
            }
            return String(token)
        }
        return nil
    }

    private func isSemverLike(_ token: String) -> Bool {
        guard token.count <= 64 else {
            return false
        }
        let buildParts = token.split(
            separator: "+",
            omittingEmptySubsequences: false
        )
        guard buildParts.count <= 2 else {
            return false
        }
        guard buildParts.allSatisfy({ $0.isEmpty == false }) else {
            return false
        }
        guard validCoreAndPrerelease(buildParts[0]) else {
            return false
        }
        guard buildParts.count == 2 else {
            return true
        }
        return validIdentifiers(buildParts[1])
    }

    private func validCoreAndPrerelease(_ value: Substring) -> Bool {
        let parts = value.split(
            separator: "-",
            maxSplits: 1,
            omittingEmptySubsequences: false
        )
        guard validCore(parts[0]) else {
            return false
        }
        guard parts.count == 2 else {
            return true
        }
        return validIdentifiers(parts[1])
    }

    private func validCore(_ value: Substring) -> Bool {
        let components = value.split(
            separator: ".",
            omittingEmptySubsequences: false
        )
        guard components.count == 3 else {
            return false
        }
        return components.allSatisfy(validNumericIdentifier)
    }

    private func validNumericIdentifier(_ value: Substring) -> Bool {
        value.isEmpty == false && value.allSatisfy {
            $0.isASCII && $0.isNumber
        }
    }

    private func validIdentifiers(_ value: Substring) -> Bool {
        let identifiers = value.split(
            separator: ".",
            omittingEmptySubsequences: false
        )
        return identifiers.allSatisfy(validIdentifier)
    }

    private func validIdentifier(_ value: Substring) -> Bool {
        value.isEmpty == false && value.allSatisfy {
            $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-")
        }
    }
}

public struct CodexCLIVersionProbeConfiguration: Equatable, Sendable {
    public static var production: CodexCLIVersionProbeConfiguration {
        production(inheriting: ProcessInfo.processInfo.environment)
    }

    package static func production(
        inheriting environment: [String: String]
    ) -> CodexCLIVersionProbeConfiguration {
        production(
            inheriting: environment,
            safeSearchPath: CodexProcessEnvironment.safeSearchPath
        )
    }

    package static func production(
        inheriting environment: [String: String],
        safeSearchPath: String
    ) -> CodexCLIVersionProbeConfiguration {
        CodexCLIVersionProbeConfiguration(
            timeout: .seconds(2),
            stopGracePeriod: .milliseconds(250),
            maximumOutputBytes: CodexCLIVersionParser.maximumInputBytes,
            environment: CodexProcessEnvironment.versionProbe(
                inheriting: environment,
                safeSearchPath: safeSearchPath
            )
        )
    }

    public let timeout: Duration
    public let stopGracePeriod: Duration
    public let maximumOutputBytes: Int
    public let environment: [String: String]

    public init(
        timeout: Duration,
        stopGracePeriod: Duration,
        maximumOutputBytes: Int,
        environment: [String: String] = [:]
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
    private let terminationSignal: ProcessLifecycle.Signal
    private let parser = CodexCLIVersionParser()
    private let clock = ContinuousClock()

    private var process: Process?
    private var processLifecycle: ProcessLifecycle?
    private var isProbing = false
    private var isCleaningUp = false
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
        terminationSignal = ProcessLifecycle.sendSignal
    }

    package init(
        configuration: CodexCLIVersionProbeConfiguration,
        terminationSignal: @escaping ProcessLifecycle.Signal
    ) {
        self.configuration = configuration
        self.terminationSignal = terminationSignal
    }

    public func version(
        of executableURL: URL
    ) async throws(CodexCLIVersionProbeError) -> CodexCLIVersion {
        guard isProbing == false, process == nil, pendingProbe == nil else {
            throw .processFailed
        }
        isProbing = true
        defer { isProbing = false }
        nextGeneration &+= 1
        let generation = nextGeneration
        do {
            try launch(executableURL: executableURL, generation: generation)
            let data = try await waitForOutput(generation: generation)
            await cleanUpProcess(generation: generation)
            return try parser.parse(data)
        } catch let error as CodexCLIVersionProbeError {
            await cleanUpProcess(generation: generation)
            throw error
        } catch {
            await cleanUpProcess(generation: generation)
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
            processLifecycle = nil
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
        child.standardInput = FileHandle.nullDevice
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
        processLifecycle = ProcessLifecycle.observe(child, signal: terminationSignal) { status in
            await self.receiveTermination(status, generation: generation)
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
        guard generation == nextGeneration, process != nil else {
            return
        }
        recordedExitStatus = status
        if isCleaningUp {
            finishConfirmedCleanup(generation: generation)
            return
        }
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

    private func cleanUpProcess(generation: UInt64) async {
        guard generation == nextGeneration, let processLifecycle else {
            return
        }
        isCleaningUp = true
        pendingProbe?.timeoutTask.cancel()
        pendingProbe = nil
        outputReader?.readabilityHandler = nil
        let result = await processLifecycle.stop(gracePeriod: configuration.stopGracePeriod)
        if result == .exited {
            finishConfirmedCleanup(generation: generation)
        }
        // If unconfirmed, keep the process, lifecycle and termination observer.
        // A late event completes cleanup and only then permits another probe.
    }

    private func finishConfirmedCleanup(generation: UInt64) {
        guard generation == nextGeneration else {
            return
        }
        try? outputReader?.close()
        process = nil
        processLifecycle = nil
        outputReader = nil
        output = Data()
        reachedEndOfOutput = false
        recordedExitStatus = nil
        isCleaningUp = false
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
