import Foundation

package enum CodexProcessEnvironment {
    package static let safeSearchPath =
        "/usr/bin:/bin:/usr/sbin:/sbin:/opt/homebrew/bin:/usr/local/bin"

    package static func appServer(
        inheriting environment: [String: String],
        safeSearchPath: String = CodexProcessEnvironment.safeSearchPath
    ) -> [String: String] {
        var childEnvironment = environment
        childEnvironment["PATH"] = safeSearchPath
        return childEnvironment
    }

    package static func versionProbe(
        inheriting environment: [String: String],
        safeSearchPath: String = CodexProcessEnvironment.safeSearchPath
    ) -> [String: String] {
        var childEnvironment = ["PATH": safeSearchPath]
        for key in localeEnvironmentKeys {
            childEnvironment[key] = environment[key]
        }
        return childEnvironment
    }

    private static let localeEnvironmentKeys = [
        "LANG",
        "LC_ALL",
        "LC_CTYPE"
    ]
}
