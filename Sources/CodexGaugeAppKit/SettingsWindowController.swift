import AppKit
import CodexGaugeSettings

@MainActor
public final class SettingsWindowController: NSWindowController, NSWindowDelegate {
    public let settingsViewController: SettingsFormViewController

    private var onClose: ((SettingsWindowController) -> Void)?

    public init(
        formState: SettingsFormState,
        connectionDiagnostics: ConnectionDiagnosticsSnapshot = .checking,
        onSelectCodex: @escaping () -> Void = {},
        onCopyDiagnostics: @escaping () -> Void = {},
        onFormValuesChanged: @escaping (SettingsFormValues) -> Void,
        onClose: @escaping (SettingsWindowController) -> Void
    ) {
        settingsViewController = SettingsFormViewController(
            formState: formState,
            connectionDiagnostics: connectionDiagnostics,
            onSelectCodex: onSelectCodex,
            onCopyDiagnostics: onCopyDiagnostics,
            onFormValuesChanged: onFormValuesChanged
        )
        self.onClose = onClose
        let window = Self.makeWindow(contentViewController: settingsViewController)
        super.init(window: window)
        window.delegate = self
    }

    @available(*, unavailable)
    public required init?(coder: NSCoder) {
        nil
    }

    public func windowWillClose(_ notification: Notification) {
        releaseWindowGraph(notification.object as? NSWindow)
        let closure = onClose
        onClose = nil
        closure?(self)
    }

    private func releaseWindowGraph(_ closingWindow: NSWindow?) {
        closingWindow?.delegate = nil
        closingWindow?.contentViewController = nil
        closingWindow?.contentView = nil
        window = nil
    }

    private static func makeWindow(
        contentViewController: NSViewController
    ) -> NSWindow {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 440, height: 680),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = SettingsStrings.windowTitle
        window.contentViewController = contentViewController
        window.contentMinSize = NSSize(width: 440, height: 680)
        window.contentMaxSize = NSSize(width: 440, height: 680)
        window.isReleasedWhenClosed = false
        window.isRestorable = false
        window.tabbingMode = .disallowed
        window.center()
        return window
    }
}
