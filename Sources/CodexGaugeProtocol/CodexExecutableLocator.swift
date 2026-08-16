import Foundation

public enum CodexLocationError: Error, Equatable, Sendable {
    case notFound
    case invalidSelection
}

public protocol CodexLocating: Sendable {
    func locate() throws(CodexLocationError) -> URL
}

public struct CodexExecutableLocator: CodexLocating, Sendable {
    private let selectedExecutableURL: URL?
    private let bundleApplicationURL: URL?
    private let homeDirectoryURL: URL
    private let systemRootURL: URL

    public init(
        selectedExecutableURL: URL? = nil,
        bundleApplicationURL: URL? = nil,
        homeDirectoryURL: URL,
        systemRootURL: URL = URL(fileURLWithPath: "/", isDirectory: true)
    ) {
        self.selectedExecutableURL = selectedExecutableURL
        self.bundleApplicationURL = bundleApplicationURL
        self.homeDirectoryURL = homeDirectoryURL
        self.systemRootURL = systemRootURL
    }

    public func locate() throws(CodexLocationError) -> URL {
        if let selectedExecutableURL {
            return try locateSelected(selectedExecutableURL)
        }
        for candidate in automaticCandidateURLs() {
            if let executable = validatedExecutable(at: candidate) {
                return executable
            }
        }
        throw .notFound
    }

    private func locateSelected(_ candidate: URL) throws(CodexLocationError) -> URL {
        guard let executable = validatedExecutable(at: candidate) else {
            throw .invalidSelection
        }
        return executable
    }

    private func automaticCandidateURLs() -> [URL] {
        injectedBundleExecutableURLs()
            + knownApplicationExecutableURLs()
            + knownCommandLineExecutableURLs()
    }

    private func injectedBundleExecutableURLs() -> [URL] {
        guard let bundleApplicationURL else {
            return []
        }
        return [executableURL(in: bundleApplicationURL)]
    }

    private func knownApplicationExecutableURLs() -> [URL] {
        let systemApplications = systemRootURL
            .appendingPathComponent("Applications", isDirectory: true)
        let homeApplications = homeDirectoryURL
            .appendingPathComponent("Applications", isDirectory: true)
        return [systemApplications, homeApplications].flatMap(applicationExecutables(in:))
    }

    private func applicationExecutables(in directory: URL) -> [URL] {
        ["Codex.app", "ChatGPT.app"].map { applicationName in
            executableURL(in: directory.appendingPathComponent(applicationName, isDirectory: true))
        }
    }

    private func executableURL(in applicationURL: URL) -> URL {
        applicationURL.appendingPathComponent("Contents/Resources/codex")
    }

    private func knownCommandLineExecutableURLs() -> [URL] {
        [
            systemRootURL.appendingPathComponent("opt/homebrew/bin/codex"),
            systemRootURL.appendingPathComponent("usr/local/bin/codex"),
            homeDirectoryURL.appendingPathComponent(".local/bin/codex")
        ]
    }

    private func validatedExecutable(at candidate: URL) -> URL? {
        guard candidate.isFileURL else {
            return nil
        }
        guard let resolved = resolveSymlinkChain(candidate.standardizedFileURL) else {
            return nil
        }
        guard isRegularFile(resolved) else {
            return nil
        }
        guard FileManager.default.isExecutableFile(atPath: resolved.path) else {
            return nil
        }
        return resolved
    }

    private func resolveSymlinkChain(_ candidate: URL) -> URL? {
        var current = candidate
        var visitedPaths = Set<String>()
        for _ in 0..<64 {
            guard visitedPaths.insert(current.path).inserted else {
                return nil
            }
            guard let destination = symlinkDestination(at: current) else {
                return existingURL(current)
            }
            current = resolvedDestination(destination, relativeTo: current)
        }
        return nil
    }

    private func symlinkDestination(at candidate: URL) -> String? {
        try? FileManager.default.destinationOfSymbolicLink(atPath: candidate.path)
    }

    private func resolvedDestination(_ destination: String, relativeTo link: URL) -> URL {
        if destination.hasPrefix("/") {
            return URL(fileURLWithPath: destination).standardizedFileURL
        }
        return link.deletingLastPathComponent()
            .appendingPathComponent(destination)
            .standardizedFileURL
    }

    private func existingURL(_ candidate: URL) -> URL? {
        FileManager.default.fileExists(atPath: candidate.path) ? candidate : nil
    }

    private func isRegularFile(_ candidate: URL) -> Bool {
        let keys: Set<URLResourceKey> = [.isRegularFileKey, .isDirectoryKey]
        guard let values = try? candidate.resourceValues(forKeys: keys) else {
            return false
        }
        return values.isRegularFile == true && values.isDirectory != true
    }
}
