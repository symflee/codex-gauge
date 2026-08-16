import CodexGaugeProtocol
import Darwin
import Foundation

@main
struct CodexGaugeSmokeCommand {
    static func main() async {
        guard CommandLine.arguments.dropFirst().isEmpty else {
            write("codex-gauge-smoke: failed reason=invalid_arguments")
            exit(64)
        }

        let locator = CodexExecutableLocator(
            homeDirectoryURL: FileManager.default.homeDirectoryForCurrentUser
        )
        let provider = ProductionAppServerSmokeSessionProvider(locator: locator)
        let result = await AppServerSmokeRunner(sessionProvider: provider).run()
        write(AppServerSmokeOutputFormatter().line(for: result))
        exit(result.exitCode)
    }

    private static func write(_ line: String) {
        let data = Data((line + "\n").utf8)
        try? FileHandle.standardOutput.write(contentsOf: data)
    }
}
