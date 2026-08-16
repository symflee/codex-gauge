import AppKit
import CodexGaugeCore

@MainActor
public final class CodexGaugeApplicationDelegate: NSObject, NSApplicationDelegate {
    private var statusItemController: StatusItemController?

    public override init() {
        super.init()
    }

    public func applicationDidFinishLaunching(_ notification: Notification) {
        _ = notification
        let presenter = SystemStatusItemPresenter()
        let controller = StatusItemController(presenter: presenter)
        controller.setFrames([initialFrame])
        statusItemController = controller
    }

    private var initialFrame: DisplayFrame {
        .single(DisplayQuota(identifier: unknownCodexQuota, value: .loading))
    }

    private var unknownCodexQuota: QuotaSelectionID {
        QuotaSelectionID(product: .codex, rawDurationMinutes: nil)
    }
}
