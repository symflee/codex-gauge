import AppKit

@MainActor
public final class CodexGaugeApplicationDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem?

    public override init() {
        super.init()
    }

    public func applicationDidFinishLaunching(_ notification: Notification) {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.title = "…"
        item.button?.setAccessibilityLabel("Codex 사용량 확인 중")
        statusItem = item
    }
}
