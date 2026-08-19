import AppKit
import CodexGaugeSettings

@MainActor
public final class SettingsWindowController: NSWindowController, NSWindowDelegate {
    public let settingsViewController: SettingsFormViewController

    private var onClose: ((SettingsWindowController) -> Void)?

    public init(
        formState: SettingsFormState,
        connectionDiagnostics: ConnectionDiagnosticsSnapshot = .checking,
        launchAtLoginState: LaunchAtLoginSettingsState = LaunchAtLoginSettingsState(
            status: .disabled
        ),
        onSelectCodex: @escaping () -> Void = {},
        onCopyDiagnostics: @escaping () -> Void = {},
        onOpenLaunchAtLoginSystemSettings: @escaping () -> Void = {},
        onLaunchAtLoginIntentRequested: @escaping (Bool) -> Void = { _ in },
        onFormValuesChanged: @escaping (SettingsFormValues) -> Void,
        onClose: @escaping (SettingsWindowController) -> Void
    ) {
        settingsViewController = SettingsFormViewController(
            formState: formState,
            connectionDiagnostics: connectionDiagnostics,
            launchAtLoginState: launchAtLoginState,
            onSelectCodex: onSelectCodex,
            onCopyDiagnostics: onCopyDiagnostics,
            onOpenLaunchAtLoginSystemSettings: onOpenLaunchAtLoginSystemSettings,
            onLaunchAtLoginIntentRequested: onLaunchAtLoginIntentRequested,
            onFormValuesChanged: onFormValuesChanged
        )
        self.onClose = onClose
        let window = Self.makeWindow(
            contentViewController: settingsViewController,
            language: formState.language
        )
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

    public func updateLanguage(_ language: AppLanguage) {
        settingsViewController.updateLanguage(language)
        window?.title = SettingsStrings(language: language).windowTitle
    }

    private func releaseWindowGraph(_ closingWindow: NSWindow?) {
        closingWindow?.delegate = nil
        closingWindow?.contentViewController = nil
        closingWindow?.contentView = nil
        window = nil
    }

    private static func makeWindow(
        contentViewController: NSViewController,
        language: AppLanguage
    ) -> NSWindow {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 440, height: 720),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = SettingsStrings(language: language).windowTitle
        window.setAccessibilityIdentifier(
            CodexGaugeAccessibilityIdentifier.settingsWindow
        )
        window.standardWindowButton(.closeButton)?.setAccessibilityIdentifier(
            CodexGaugeAccessibilityIdentifier.settingsCloseButton
        )
        window.contentViewController = contentViewController
        window.contentMinSize = NSSize(width: 440, height: 720)
        window.contentMaxSize = NSSize(width: 440, height: 720)
        window.isReleasedWhenClosed = false
        window.isRestorable = false
        window.tabbingMode = .disallowed
        window.center()
        return window
    }
}
