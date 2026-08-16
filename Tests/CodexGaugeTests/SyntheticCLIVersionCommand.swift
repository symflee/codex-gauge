import Darwin
import Foundation

enum SyntheticCLIVersionMode: String {
    case valid
    case malformed
    case oversized
    case nonzeroExit
    case timeout
    case stderrFlood
}

enum SyntheticCLIVersionCommand {
    static let modeEnvironmentKey = "CODEX_GAUGE_SYNTHETIC_VERSION_MODE"
    static let pidFileEnvironmentKey = "CODEX_GAUGE_SYNTHETIC_VERSION_PID_FILE"

    static func runIfRequested() -> Bool {
        guard CommandLine.arguments.dropFirst().first == "--version" else {
            return false
        }
        guard CommandLine.arguments.count == 2 else {
            Darwin.exit(64)
        }
        guard let mode = configuredMode() else {
            Darwin.exit(65)
        }
        recordProcessIdentifier()
        run(mode)
        return true
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
            writeStdout("codex-cli 1.2.3\n")
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
        }
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
