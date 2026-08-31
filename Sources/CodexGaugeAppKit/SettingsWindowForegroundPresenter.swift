import AppKit

@MainActor
public protocol SettingsWindowApplicationActivating: AnyObject {
    func activate(ignoringOtherApps: Bool)
}

@MainActor
public final class NSApplicationSettingsWindowActivator:
    SettingsWindowApplicationActivating {
    private let application: NSApplication

    public init(application: NSApplication = .shared) {
        self.application = application
    }

    public func activate(ignoringOtherApps: Bool) {
        application.activate(ignoringOtherApps: ignoringOtherApps)
    }
}

@MainActor
public protocol SettingsWindowFronting: AnyObject {
    var hasSettingsWindow: Bool { get }
    var isSettingsWindowVisible: Bool { get }

    func showSettingsWindow()
    func makeSettingsWindowKeyAndOrderFront()
}

@MainActor
extension SettingsWindowController: SettingsWindowFronting {
    public var hasSettingsWindow: Bool {
        window != nil
    }

    public var isSettingsWindowVisible: Bool {
        window?.isVisible == true
    }

    public func showSettingsWindow() {
        showWindow(nil)
    }

    public func makeSettingsWindowKeyAndOrderFront() {
        window?.makeKeyAndOrderFront(nil)
    }
}

@MainActor
public protocol SettingsWindowForegroundPresenting: AnyObject {
    @discardableResult
    func present(_ window: any SettingsWindowFronting) -> Bool
}

@MainActor
public final class SettingsWindowForegroundPresenter:
    SettingsWindowForegroundPresenting {
    private let applicationActivator: any SettingsWindowApplicationActivating
    private let presentationAllowed: @MainActor () -> Bool

    public init(
        applicationActivator: any SettingsWindowApplicationActivating =
            NSApplicationSettingsWindowActivator(),
        presentationAllowed: @escaping @MainActor () -> Bool = {
            let policy = NSApplication.shared.activationPolicy()
            return policy == .regular || policy == .accessory
        }
    ) {
        self.applicationActivator = applicationActivator
        self.presentationAllowed = presentationAllowed
    }

    @discardableResult
    public func present(_ window: any SettingsWindowFronting) -> Bool {
        guard window.hasSettingsWindow else {
            return false
        }
        guard presentationAllowed() else {
            return true
        }
        applicationActivator.activate(ignoringOtherApps: true)
        window.showSettingsWindow()
        guard window.hasSettingsWindow else {
            return false
        }
        window.makeSettingsWindowKeyAndOrderFront()
        return window.isSettingsWindowVisible
    }
}
