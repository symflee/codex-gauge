import Darwin
import Foundation

enum SyntheticCLIVersionMode: String {
    case valid
    case malformed
    case oversized
    case nonzeroExit
    case timeout
    case stderrFlood
    case standardInputEndOfFile
    case environmentIsolation
    case safeSearchPath
}

enum SyntheticCLIVersionCommand {
    static let modeEnvironmentKey = "CODEX_GAUGE_SYNTHETIC_VERSION_MODE"
    static let pidFileEnvironmentKey = "CODEX_GAUGE_SYNTHETIC_VERSION_PID_FILE"
    static let secretEnvironmentKey = "CODEX_GAUGE_SYNTHETIC_PARENT_SECRET"
    static let productionSafeSearchPath =
        "/usr/bin:/bin:/usr/sbin:/sbin:/opt/homebrew/bin:/usr/local/bin"

    static func runIfRequested() -> Bool {
        guard let mode = configuredMode() else {
            return false
        }
        guard isVersionInvocation(mode: mode) else {
            Darwin.exit(64)
        }
        recordProcessIdentifier()
        run(mode)
        return true
    }

    private static func isVersionInvocation(mode: SyntheticCLIVersionMode) -> Bool {
        guard mode == .safeSearchPath else {
            return CommandLine.arguments.count == 2
                && CommandLine.arguments.dropFirst().first == "--version"
        }
        return CommandLine.arguments.count >= 2
            && CommandLine.arguments.last == "--version"
    }

    private static func configuredMode() -> SyntheticCLIVersionMode? {
        let value = ProcessInfo.processInfo.environment[modeEnvironmentKey]
        return value.flatMap(SyntheticCLIVersionMode.init(rawValue:))
    }

    private static func recordProcessIdentifier() {
        guard let path = ProcessInfo.processInfo.environment[pidFileEnvironmentKey] else {
            return
        }
        let data = Data(String(Darwin.getpid()).utf8)
        try? data.write(to: URL(fileURLWithPath: path), options: .atomic)
    }

    private static func run(_ mode: SyntheticCLIVersionMode) {
        switch mode {
        case .valid:
            writeStdout("codex-cli 0.148.0-alpha.9\n")
        case .malformed:
            writeStdout("synthetic-version-unavailable\n")
        case .oversized:
            FileHandle.standardOutput.write(Data(repeating: 0x78, count: 8_192))
        case .nonzeroExit:
            Darwin.exit(23)
        case .timeout:
            sleepUntilTerminated()
        case .stderrFlood:
            FileHandle.standardError.write(Data(repeating: 0x78, count: 2_097_152))
            writeStdout("codex-cli 2.3.4\n")
        case .standardInputEndOfFile:
            verifyStandardInputEndOfFile()
        case .environmentIsolation:
            verifyEnvironmentIsolation()
        case .safeSearchPath:
            writeStdout("codex-cli 5.6.7\n")
        }
    }

    private static func verifyStandardInputEndOfFile() {
        guard FileHandle.standardInput.readDataToEndOfFile().isEmpty else {
            Darwin.exit(66)
        }
        writeStdout("codex 3.4.5\n")
    }

    private static func verifyEnvironmentIsolation() {
        let environment = ProcessInfo.processInfo.environment
        guard environment[secretEnvironmentKey] == nil else {
            Darwin.exit(67)
        }
        guard environment["PATH"] == productionSafeSearchPath else {
            Darwin.exit(68)
        }
        guard environment["HOME"] == nil else {
            Darwin.exit(69)
        }
        guard environment["LANG"] == "C" else {
            Darwin.exit(70)
        }
        writeStdout("codex-cli 4.5.6\n")
    }

    private static func writeStdout(_ value: String) {
        FileHandle.standardOutput.write(Data(value.utf8))
    }

    private static func sleepUntilTerminated() {
        while true {
            Darwin.sleep(30)
        }
    }
}
