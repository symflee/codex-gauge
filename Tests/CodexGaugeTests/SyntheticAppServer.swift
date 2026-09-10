import CodexGaugeProtocol
import Darwin
import Foundation

enum SyntheticAppServerMode: String {
    case happy
    case unrelatedMessages
    case unknownProvider
    case signedOut
    case unsupportedAuth
    case methodNotFound
    case parseError
    case invalidRequest
    case invalidParameters
    case internalError
    case serverError
    case positiveError
    case handshakeMismatch
    case malformed
    case oversized
    case stdoutFlood
    case finalLineWithoutNewline
    case endOfFile
    case nonzeroExit
    case timeout
    case stderrFlood
    case stopDuringRequest
    case waitForStop
    case ignoreTermination
    case environmentBoundary
    case safeSearchPath
}

enum SyntheticAppServer {
    static let modeEnvironmentKey = "CODEX_GAUGE_SYNTHETIC_APP_SERVER_MODE"
    static let pidFileEnvironmentKey = "CODEX_GAUGE_SYNTHETIC_PID_FILE"
    static let secretEnvironmentKey = "CODEX_GAUGE_SYNTHETIC_PARENT_SECRET"
    static let expectedHomeDirectory = "/synthetic/authentication-home"
    static let expectedSecretValue = "synthetic-sensitive-value"
    static let productionSafeSearchPath =
        "/usr/bin:/bin:/usr/sbin:/sbin:/opt/homebrew/bin:/usr/local/bin"

    static func runIfRequested() -> Bool {
        let mode = configuredMode()
        guard hasAppServerArgument(mode: mode) else {
            return false
        }
        guard isAppServerInvocation(mode: mode) else {
            Darwin.exit(64)
        }
        guard let mode else {
            Darwin.exit(65)
        }
        if mode == .ignoreTermination {
            Darwin.signal(SIGTERM, SIG_IGN)
        }
        recordProcessIdentifier()
        run(mode)
        return true
    }

    private static func hasAppServerArgument(
        mode: SyntheticAppServerMode?
    ) -> Bool {
        if CommandLine.arguments.dropFirst().first == "app-server" {
            return true
        }
        return mode == .safeSearchPath
            && CommandLine.arguments.last == "app-server"
    }

    private static func isAppServerInvocation(
        mode: SyntheticAppServerMode?
    ) -> Bool {
        guard mode == .safeSearchPath else {
            return CommandLine.arguments.count == 2
                && CommandLine.arguments.dropFirst().first == "app-server"
        }
        return CommandLine.arguments.count >= 2
            && CommandLine.arguments.last == "app-server"
    }

    private static func configuredMode() -> SyntheticAppServerMode? {
        let value = ProcessInfo.processInfo.environment[modeEnvironmentKey]
        return value.flatMap(SyntheticAppServerMode.init(rawValue:))
    }

    private static func recordProcessIdentifier() {
        guard let path = ProcessInfo.processInfo.environment[pidFileEnvironmentKey] else {
            return
        }
        let data = Data(String(Darwin.getpid()).utf8)
        try? data.write(to: URL(fileURLWithPath: path), options: .atomic)
    }

    private static func run(_ mode: SyntheticAppServerMode) {
        verifyEnvironmentBoundaryIfNeeded(mode)
        guard let initialize = readRequest(method: "initialize", identifier: 1) else {
            Darwin.exit(65)
        }
        guard initialize.params == expectedInitializeParameters else {
            Darwin.exit(66)
        }
        guard handleEarlyInitializeMode(mode) == false else {
            return
        }
        emitNoiseIfNeeded(mode)
        writeLine("{\"id\":1,\"result\":{\"synthetic\":true}}")
        guard readNotification(method: "initialized") else {
            Darwin.exit(67)
        }
        if mode == .ignoreTermination {
            sleepUntilTerminated()
            return
        }
        guard mode != .waitForStop else {
            waitForInputEnd()
            return
        }
        runReadLoop(mode)
    }

    private static func verifyEnvironmentBoundaryIfNeeded(
        _ mode: SyntheticAppServerMode
    ) {
        guard mode == .environmentBoundary else {
            return
        }
        let environment = ProcessInfo.processInfo.environment
        guard environment["PATH"] == productionSafeSearchPath else {
            Darwin.exit(71)
        }
        guard environment["HOME"] == expectedHomeDirectory else {
            Darwin.exit(72)
        }
        guard environment[secretEnvironmentKey] == expectedSecretValue else {
            Darwin.exit(73)
        }
    }

    private static var expectedInitializeParameters: JSONValue {
        .object([
            "clientInfo": .object([
                "name": .string("codex-gauge"),
                "title": .string("Codex Gauge"),
                "version": .string("0.1.0")
            ])
        ])
    }

    private static func handleEarlyInitializeMode(
        _ mode: SyntheticAppServerMode
    ) -> Bool {
        if mode == .timeout {
            sleepUntilTerminated()
            return true
        }
        if mode == .endOfFile {
            return true
        }
        if mode == .nonzeroExit {
            Darwin.exit(17)
        }
        if mode == .handshakeMismatch {
            writeLine("{\"id\":1,\"result\":[]}")
            return true
        }
        if mode == .stderrFlood {
            writeStderrFlood()
        }
        return false
    }

    private static func runReadLoop(_ mode: SyntheticAppServerMode) {
        guard let account = readRequest(method: "account/read", identifier: 2) else {
            Darwin.exit(68)
        }
        guard account.params == .object(["refreshToken": .boolean(false)]) else {
            Darwin.exit(69)
        }
        guard handleAccount(mode, identifier: 2) else {
            return
        }
        var rateIdentifier: Int64 = 3
        while readRequest(
            method: "account/rateLimits/read",
            identifier: rateIdentifier
        ) != nil {
            guard handleRateLimits(mode, identifier: rateIdentifier) else {
                return
            }
            rateIdentifier += 1
        }
    }

    private static func handleAccount(
        _ mode: SyntheticAppServerMode,
        identifier: Int64
    ) -> Bool {
        if mode == .stopDuringRequest {
            waitForInputEnd()
            return false
        }
        emitNoiseIfNeeded(mode)
        if mode == .signedOut {
            writeLine("{\"id\":\(identifier),\"result\":{\"account\":null,\"requiresOpenaiAuth\":true}}")
            return false
        }
        if mode == .unsupportedAuth {
            writeLine("{\"id\":\(identifier),\"result\":{\"account\":{\"type\":\"apiKey\"},\"requiresOpenaiAuth\":true}}")
            return false
        }
        let provider = mode == .unknownProvider ? "futureProvider" : "chatgpt"
        writeLine("{\"id\":\(identifier),\"result\":{\"account\":{\"type\":\"\(provider)\"},\"requiresOpenaiAuth\":true}}")
        return true
    }

    private static func handleRateLimits(
        _ mode: SyntheticAppServerMode,
        identifier: Int64
    ) -> Bool {
        emitNoiseIfNeeded(mode)
        if let errorCode = rateLimitFailureCode(for: mode) {
            writeLine("{\"id\":\(identifier),\"error\":{\"code\":\(errorCode),\"message\":\"synthetic\"}}")
            return false
        }
        if mode == .malformed {
            writeLine("not-json")
            return false
        }
        if mode == .oversized {
            writeOversizedLine()
            return false
        }
        if mode == .stdoutFlood {
            writeStdoutFlood()
            writeLine(rateLimitResponse(identifier: identifier))
            return true
        }
        let response = rateLimitResponse(identifier: identifier)
        if mode == .finalLineWithoutNewline {
            write(response)
            return false
        }
        writeLine(response)
        return true
    }

    private static func rateLimitFailureCode(
        for mode: SyntheticAppServerMode
    ) -> Int? {
        switch mode {
        case .methodNotFound:
            -32_601
        case .parseError:
            -32_700
        case .invalidRequest:
            -32_600
        case .invalidParameters:
            -32_602
        case .internalError:
            -32_603
        case .serverError:
            -32_001
        case .positiveError:
            42
        default:
            nil
        }
    }

    private static func emitNoiseIfNeeded(_ mode: SyntheticAppServerMode) {
        guard mode == .unrelatedMessages else {
            return
        }
        writeLine("{\"method\":\"future/notification\",\"params\":{}}")
        writeLine("{\"id\":\"server-request\",\"method\":\"future/request\",\"params\":{}}")
        writeLine("{\"id\":999,\"result\":{}}")
    }

    private static func rateLimitResponse(identifier: Int64) -> String {
        "{\"id\":\(identifier),\"result\":{\"rateLimitsByLimitId\":{\"codex\":{\"primary\":{\"usedPercent\":17,\"windowDurationMins\":300,\"resetsAt\":1900000000}},\"codex_bengalfox\":{\"primary\":{\"usedPercent\":9,\"windowDurationMins\":300,\"resetsAt\":1900000000}}}}}"
    }

    private static func readRequest(
        method: String,
        identifier: Int64
    ) -> JSONRPCRequest? {
        guard let message = readMessage() else {
            return nil
        }
        guard case let .request(request) = message else {
            return nil
        }
        guard request.id == .integer(identifier), request.method == method else {
            return nil
        }
        return request
    }

    private static func readNotification(method: String) -> Bool {
        guard let message = readMessage() else {
            return false
        }
        guard case let .notification(notification) = message else {
            return false
        }
        return notification.method == method
    }

    private static func readMessage() -> JSONRPCMessage? {
        guard let line = readLine(strippingNewline: true) else {
            return nil
        }
        return try? JSONRPCMessageDecoder().decode(Data(line.utf8))
    }

    private static func writeLine(_ value: String) {
        write(value + "\n")
    }

    private static func write(_ value: String) {
        FileHandle.standardOutput.write(Data(value.utf8))
    }

    private static func writeStderrFlood() {
        let data = Data(repeating: 0x78, count: 2_097_152)
        FileHandle.standardError.write(data)
    }

    private static func writeOversizedLine() {
        var data = Data(repeating: 0x78, count: JSONLFramer.maximumLineBytes + 1)
        data.append(0x0A)
        FileHandle.standardOutput.write(data)
    }

    private static func writeStdoutFlood() {
        let line = Data("{\"method\":\"future/notification\"}\n".utf8)
        var flood = Data()
        for _ in 0..<8_192 {
            flood.append(line)
        }
        FileHandle.standardOutput.write(flood)
    }

    private static func waitForInputEnd() {
        while readLine(strippingNewline: true) != nil {}
    }

    private static func sleepUntilTerminated() {
        while true {
            Darwin.sleep(30)
        }
    }
}
