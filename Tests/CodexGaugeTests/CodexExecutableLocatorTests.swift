import CodexGaugeProtocol
import Foundation

func codexExecutableLocatorTests() -> [TestCase] {
    [
        selectedExecutableTest(),
        selectedNonExecutableTest(),
        selectedDirectoryTest(),
        selectedNonFileURLTest(),
        selectedSymlinkTest(),
        selectedDirectorySymlinkTest(),
        selectedSymlinkCycleTest(),
        selectedCandidatePriorityTest(),
        brokenSelectionDoesNotFallBackTest(),
        bundleCandidatePriorityTest(),
        invalidBundleFallsBackTest(),
        knownApplicationTest(),
        knownHomebrewExecutableTest(),
        homeLocalSymlinkTest(),
        noCandidateTest(),
        locatorValuesAreSendableTest()
    ]
}

private func selectedExecutableTest() -> TestCase {
    TestCase(name: "locator accepts a selected regular executable") {
        try withSyntheticFileSystem { fileSystem in
            let executable = try fileSystem.makeExecutable("selected/codex")
            let locator = fileSystem.locator(selected: executable)
            let located = try locator.locate()

            try expect(located == executable, "Expected selected executable")
        }
    }
}

private func selectedNonExecutableTest() -> TestCase {
    TestCase(name: "locator rejects a selected non-executable file") {
        try withSyntheticFileSystem { fileSystem in
            let file = try fileSystem.makeFile("selected/codex")
            let locator = fileSystem.locator(selected: file)

            try expectLocationError(.invalidSelection, from: locator)
        }
    }
}

private func selectedDirectoryTest() -> TestCase {
    TestCase(name: "locator rejects a selected directory") {
        try withSyntheticFileSystem { fileSystem in
            let directory = try fileSystem.makeDirectory("selected/codex")
            let locator = fileSystem.locator(selected: directory)

            try expectLocationError(.invalidSelection, from: locator)
        }
    }
}

private func selectedNonFileURLTest() -> TestCase {
    TestCase(name: "locator rejects a selected non-file URL") {
        try withSyntheticFileSystem { fileSystem in
            guard let remote = URL(string: "https://invalid.example/codex") else {
                throw TestFailure(description: "Expected synthetic remote URL")
            }
            let locator = fileSystem.locator(selected: remote)

            try expectLocationError(.invalidSelection, from: locator)
        }
    }
}

private func selectedSymlinkTest() -> TestCase {
    TestCase(name: "locator resolves a selected executable symlink") {
        try withSyntheticFileSystem { fileSystem in
            let target = try fileSystem.makeExecutable("cellar/codex")
            let link = try fileSystem.makeSymlink("bin/codex", destination: target)
            let locator = fileSystem.locator(selected: link)
            let located = try locator.locate()

            try expect(located == target, "Expected resolved executable target")
        }
    }
}

private func selectedDirectorySymlinkTest() -> TestCase {
    TestCase(name: "locator rejects a symlink resolving to a directory") {
        try withSyntheticFileSystem { fileSystem in
            let target = try fileSystem.makeDirectory("payload")
            let link = try fileSystem.makeSymlink("bin/codex", destination: target)
            let locator = fileSystem.locator(selected: link)

            try expectLocationError(.invalidSelection, from: locator)
        }
    }
}

private func selectedSymlinkCycleTest() -> TestCase {
    TestCase(name: "locator rejects a selected symlink cycle") {
        try withSyntheticFileSystem { fileSystem in
            let first = fileSystem.url("cycle/first")
            let second = fileSystem.url("cycle/second")
            try fileSystem.makeSymlink(first, destination: second)
            try fileSystem.makeSymlink(second, destination: first)
            let locator = fileSystem.locator(selected: first)

            try expectLocationError(.invalidSelection, from: locator)
        }
    }
}

private func brokenSelectionDoesNotFallBackTest() -> TestCase {
    TestCase(name: "locator never falls back from a broken selection") {
        try withSyntheticFileSystem { fileSystem in
            let missingTarget = fileSystem.url("selected/missing-codex")
            let brokenLink = try fileSystem.makeSymlink(
                "selected/codex",
                destination: missingTarget
            )
            let bundle = try fileSystem.makeBundleExecutable("OpenAI.app")
            let automatic = try fileSystem.makeHomeLocalExecutable()
            let locator = fileSystem.locator(selected: brokenLink, bundle: bundle)

            try expectLocationError(.invalidSelection, from: locator)
            try expect(FileManager.default.fileExists(atPath: automatic.path), "Expected fallback fixture")
        }
    }
}

private func selectedCandidatePriorityTest() -> TestCase {
    TestCase(name: "locator prefers a valid selection over automatic candidates") {
        try withSyntheticFileSystem { fileSystem in
            let selected = try fileSystem.makeExecutable("selected/codex")
            let bundle = try fileSystem.makeBundleExecutable("OpenAI.app")
            _ = try fileSystem.makeHomeLocalExecutable()
            let locator = fileSystem.locator(selected: selected, bundle: bundle)
            let located = try locator.locate()

            try expect(located == selected, "Expected authoritative user selection")
        }
    }
}

private func knownApplicationTest() -> TestCase {
    TestCase(name: "locator finds a known macOS application executable") {
        try withSyntheticFileSystem { fileSystem in
            let bundle = try fileSystem.makeSystemBundleExecutable("Codex.app")
            let expected = fileSystem.bundleExecutable(bundle)
            let locator = fileSystem.locator()
            let located = try locator.locate()

            try expect(located == expected, "Expected known app executable")
        }
    }
}

private func knownHomebrewExecutableTest() -> TestCase {
    TestCase(name: "locator finds a known Homebrew CLI executable") {
        try withSyntheticFileSystem { fileSystem in
            let executable = try fileSystem.makeSystemExecutable("opt/homebrew/bin/codex")
            let locator = fileSystem.locator()
            let located = try locator.locate()

            try expect(located == executable, "Expected Homebrew executable")
        }
    }
}

private func bundleCandidatePriorityTest() -> TestCase {
    TestCase(name: "locator prefers an injected bundle candidate") {
        try withSyntheticFileSystem { fileSystem in
            let bundle = try fileSystem.makeBundleExecutable("OpenAI.app")
            let bundleExecutable = fileSystem.bundleExecutable(bundle)
            _ = try fileSystem.makeHomeLocalExecutable()
            let locator = fileSystem.locator(bundle: bundle)
            let located = try locator.locate()

            try expect(located == bundleExecutable, "Expected bundle candidate first")
        }
    }
}

private func invalidBundleFallsBackTest() -> TestCase {
    TestCase(name: "locator skips an invalid automatic bundle candidate") {
        try withSyntheticFileSystem { fileSystem in
            let invalidBundle = try fileSystem.makeDirectory("Broken.app")
            let fallback = try fileSystem.makeHomeLocalExecutable()
            let locator = fileSystem.locator(bundle: invalidBundle)
            let located = try locator.locate()

            try expect(located == fallback, "Expected known automatic fallback")
        }
    }
}

private func homeLocalSymlinkTest() -> TestCase {
    TestCase(name: "locator accepts a Homebrew-style automatic symlink") {
        try withSyntheticFileSystem { fileSystem in
            let target = try fileSystem.makeExecutable("cellar/codex/bin/codex")
            let link = fileSystem.homeURL.appendingPathComponent(".local/bin/codex")
            try fileSystem.makeRelativeSymlink(
                link,
                destination: "../../../cellar/codex/bin/codex"
            )
            let locator = fileSystem.locator()
            let located = try locator.locate()

            try expect(located == target, "Expected resolved local CLI target")
        }
    }
}

private func noCandidateTest() -> TestCase {
    TestCase(name: "locator reports not found without valid candidates") {
        try withSyntheticFileSystem { fileSystem in
            let locator = fileSystem.locator()

            try expectLocationError(.notFound, from: locator)
        }
    }
}

private func locatorValuesAreSendableTest() -> TestCase {
    TestCase(name: "locator contract and errors are sendable values") {
        try withSyntheticFileSystem { fileSystem in
            let locator = fileSystem.locator()

            requireLocatorSendable(locator)
            requireLocatorSendable(CodexLocationError.notFound)
        }
    }
}

private func expectLocationError(
    _ expected: CodexLocationError,
    from locator: some CodexLocating
) throws {
    do {
        _ = try locator.locate()
        throw TestFailure(description: "Expected locator failure")
    } catch let error as CodexLocationError {
        try expect(error == expected, "Unexpected locator error")
    }
}

private func withSyntheticFileSystem(
    _ body: (SyntheticFileSystem) throws -> Void
) throws {
    let fileSystem = try SyntheticFileSystem()
    defer { fileSystem.remove() }
    try body(fileSystem)
}

private func requireLocatorSendable<Value: Sendable>(_ value: Value) {
    _ = value
}

private struct SyntheticFileSystem {
    let rootURL: URL
    let homeURL: URL
    let systemRootURL: URL

    init() throws {
        rootURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("codex-gauge-locator-\(UUID().uuidString)", isDirectory: true)
        homeURL = rootURL.appendingPathComponent("home", isDirectory: true)
        systemRootURL = rootURL.appendingPathComponent("system", isDirectory: true)
        try FileManager.default.createDirectory(at: homeURL, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(
            at: systemRootURL,
            withIntermediateDirectories: true
        )
    }

    func locator(
        selected: URL? = nil,
        bundle: URL? = nil
    ) -> CodexExecutableLocator {
        CodexExecutableLocator(
            selectedExecutableURL: selected,
            bundleApplicationURL: bundle,
            homeDirectoryURL: homeURL,
            systemRootURL: systemRootURL
        )
    }

    func url(_ relativePath: String) -> URL {
        rootURL.appendingPathComponent(relativePath)
    }

    func makeDirectory(_ relativePath: String) throws -> URL {
        let directory = url(relativePath)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    func makeFile(_ relativePath: String) throws -> URL {
        let file = url(relativePath)
        try makeParentDirectory(for: file)
        try Data().write(to: file)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o644],
            ofItemAtPath: file.path
        )
        return file
    }

    func makeExecutable(_ relativePath: String) throws -> URL {
        let file = try makeFile(relativePath)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: file.path
        )
        return file
    }

    func makeBundleExecutable(_ relativePath: String) throws -> URL {
        try makeBundleExecutable(at: url(relativePath))
    }

    func makeHomeLocalExecutable() throws -> URL {
        let executable = homeURL.appendingPathComponent(".local/bin/codex")
        return try makeExecutable(at: executable)
    }

    func makeSystemBundleExecutable(_ applicationName: String) throws -> URL {
        let bundle = systemRootURL
            .appendingPathComponent("Applications", isDirectory: true)
            .appendingPathComponent(applicationName, isDirectory: true)
        return try makeBundleExecutable(at: bundle)
    }

    func makeSystemExecutable(_ relativePath: String) throws -> URL {
        let executable = systemRootURL.appendingPathComponent(relativePath)
        return try makeExecutable(at: executable)
    }

    func bundleExecutable(_ bundle: URL) -> URL {
        bundle.appendingPathComponent("Contents/Resources/codex")
    }

    func makeSymlink(_ relativePath: String, destination: URL) throws -> URL {
        let link = url(relativePath)
        try makeSymlink(link, destination: destination)
        return link
    }

    func makeSymlink(_ link: URL, destination: URL) throws {
        try makeParentDirectory(for: link)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: destination)
    }

    func makeRelativeSymlink(_ link: URL, destination: String) throws {
        try makeParentDirectory(for: link)
        try FileManager.default.createSymbolicLink(
            atPath: link.path,
            withDestinationPath: destination
        )
    }

    func remove() {
        try? FileManager.default.removeItem(at: rootURL)
    }

    private func makeParentDirectory(for file: URL) throws {
        try FileManager.default.createDirectory(
            at: file.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
    }

    private func makeBundleExecutable(at bundle: URL) throws -> URL {
        try FileManager.default.createDirectory(at: bundle, withIntermediateDirectories: true)
        let executable = bundleExecutable(bundle)
        _ = try makeExecutable(at: executable)
        return bundle
    }

    private func makeExecutable(at file: URL) throws -> URL {
        try makeParentDirectory(for: file)
        try Data().write(to: file)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: file.path
        )
        return file
    }
}
