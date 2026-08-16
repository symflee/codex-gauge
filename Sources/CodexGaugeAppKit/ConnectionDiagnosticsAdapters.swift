import AppKit
import CodexGaugeProtocol
import CodexGaugeSettings
import Foundation

@MainActor
public protocol CodexExecutableSelecting: AnyObject {
    func selectExecutable(attachedTo window: NSWindow?) async -> URL?
}

@MainActor
public final class NSOpenPanelCodexExecutableSelector: CodexExecutableSelecting {
    public init() {}

    public func selectExecutable(attachedTo window: NSWindow?) async -> URL? {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.canCreateDirectories = false
        panel.resolvesAliases = true
        panel.prompt = SettingsStrings.selectCodexAction
        let response = await response(for: panel, attachedTo: window)
        guard response == .OK else {
            return nil
        }
        return panel.url
    }

    private func response(
        for panel: NSOpenPanel,
        attachedTo window: NSWindow?
    ) async -> NSApplication.ModalResponse {
        await withCheckedContinuation { continuation in
            guard let window else {
                panel.begin { response in
                    continuation.resume(returning: response)
                }
                return
            }
            panel.beginSheetModal(for: window) { response in
                continuation.resume(returning: response)
            }
        }
    }
}

@MainActor
public protocol DiagnosticClipboardWriting: AnyObject {
    func writeDiagnosticText(_ text: String)
}

@MainActor
public final class SystemDiagnosticClipboardWriter: DiagnosticClipboardWriting {
    private let pasteboard: NSPasteboard

    public init(pasteboard: NSPasteboard = .general) {
        self.pasteboard = pasteboard
    }

    public func writeDiagnosticText(_ text: String) {
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
    }
}

public struct SystemConnectionDiagnosticsProvider: Sendable {
    private let inspector: any ConnectionDiagnosticsInspecting
    private let bundleApplicationURL: URL?
    private let homeDirectoryURL: URL
    private let systemRootURL: URL

    @MainActor
    public init(
        inspector: any ConnectionDiagnosticsInspecting = ConnectionDiagnosticsInspector(
            versionProbe: CodexCLIVersionProbe()
        )
    ) {
        self.init(
            inspector: inspector,
            bundleApplicationURL: NSWorkspace.shared.urlForApplication(
                withBundleIdentifier: "com.openai.codex"
            ),
            homeDirectoryURL: FileManager.default.homeDirectoryForCurrentUser
        )
    }

    public init(
        inspector: any ConnectionDiagnosticsInspecting,
        bundleApplicationURL: URL?,
        homeDirectoryURL: URL,
        systemRootURL: URL = URL(fileURLWithPath: "/", isDirectory: true)
    ) {
        self.inspector = inspector
        self.bundleApplicationURL = bundleApplicationURL
        self.homeDirectoryURL = homeDirectoryURL
        self.systemRootURL = systemRootURL
    }

    public func inspect(
        selectedExecutableURL: URL?,
        connectionStatus: CodexConnectionStatus
    ) async -> ConnectionDiagnosticsSnapshot {
        let locator = CodexExecutableLocator(
            selectedExecutableURL: selectedExecutableURL,
            bundleApplicationURL: bundleApplicationURL,
            homeDirectoryURL: homeDirectoryURL,
            systemRootURL: systemRootURL
        )
        let source: CodexExecutableSource = selectedExecutableURL == nil
            ? .automatic
            : .userSelected
        return await inspector.inspect(
            locator: locator,
            source: source,
            connectionStatus: connectionStatus
        )
    }

    public var provider: SettingsConnectionDiagnosticsProvider {
        { selectedExecutableURL, connectionStatus in
            await inspect(
                selectedExecutableURL: selectedExecutableURL,
                connectionStatus: connectionStatus
            )
        }
    }
}
