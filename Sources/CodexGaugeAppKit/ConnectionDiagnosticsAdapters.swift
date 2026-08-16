import AppKit
import CodexGaugeProtocol
import CodexGaugeSettings
import Foundation

@MainActor
public protocol CodexExecutableSelecting: AnyObject {
    func selectExecutable(attachedTo window: NSWindow?) async -> URL?
}

@MainActor
public protocol CodexExecutablePanelPresenting: AnyObject {
    var selectedURL: URL? { get }

    func present(
        attachedTo window: NSWindow?,
        completion: @escaping @MainActor (NSApplication.ModalResponse) -> Void
    )

    func dismiss()
}

public typealias CodexExecutablePanelFactory = @MainActor () ->
    any CodexExecutablePanelPresenting

@MainActor
public final class NSOpenPanelCodexExecutableSelector: CodexExecutableSelecting {
    private let panelFactory: CodexExecutablePanelFactory

    public init() {
        panelFactory = { SystemCodexExecutablePanel() }
    }

    public init(panelFactory: @escaping CodexExecutablePanelFactory) {
        self.panelFactory = panelFactory
    }

    public func selectExecutable(attachedTo window: NSWindow?) async -> URL? {
        let panel = panelFactory()
        let session = CodexExecutablePanelSession(panel: panel)
        let response = await withTaskCancellationHandler {
            await session.response(attachedTo: window)
        } onCancel: {
            Task { @MainActor in
                session.cancel()
            }
        }
        guard !Task.isCancelled, response == .OK else {
            return nil
        }
        return panel.selectedURL
    }
}

@MainActor
private final class CodexExecutablePanelSession {
    private let panel: any CodexExecutablePanelPresenting
    private var continuation: CheckedContinuation<NSApplication.ModalResponse, Never>?
    private var isPresented = false
    private var isFinished = false

    init(panel: any CodexExecutablePanelPresenting) {
        self.panel = panel
    }

    func response(
        attachedTo window: NSWindow?
    ) async -> NSApplication.ModalResponse {
        guard !Task.isCancelled else {
            cancel()
            return .cancel
        }
        return await withCheckedContinuation { continuation in
            guard !isFinished else {
                continuation.resume(returning: .cancel)
                return
            }
            self.continuation = continuation
            isPresented = true
            panel.present(attachedTo: window) { [weak self] response in
                self?.finish(response)
            }
            if Task.isCancelled {
                cancel()
            }
        }
    }

    func cancel() {
        guard !isFinished else {
            return
        }
        if isPresented {
            panel.dismiss()
        }
        finish(.cancel)
    }

    private func finish(_ response: NSApplication.ModalResponse) {
        guard !isFinished else {
            return
        }
        isFinished = true
        let continuation = continuation
        self.continuation = nil
        continuation?.resume(returning: response)
    }
}

@MainActor
private final class SystemCodexExecutablePanel: CodexExecutablePanelPresenting {
    private let panel: NSOpenPanel

    var selectedURL: URL? {
        panel.url
    }

    init() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.canCreateDirectories = false
        panel.resolvesAliases = true
        panel.prompt = SettingsStrings.selectCodexAction
        self.panel = panel
    }

    func present(
        attachedTo window: NSWindow?,
        completion: @escaping @MainActor (NSApplication.ModalResponse) -> Void
    ) {
        guard let window else {
            panel.begin(completionHandler: completion)
            return
        }
        panel.beginSheetModal(for: window, completionHandler: completion)
    }

    func dismiss() {
        guard let parent = panel.sheetParent else {
            panel.cancel(nil)
            return
        }
        parent.endSheet(panel, returnCode: .cancel)
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
