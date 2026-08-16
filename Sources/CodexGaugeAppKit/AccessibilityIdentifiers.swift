enum CodexGaugeAccessibilityIdentifier {
    static let statusItem = "codex-gauge.status-item"
    static let settingsWindow = "codex-gauge.settings.window"
    static let settingsCloseButton = "codex-gauge.settings.close"

    static func menuAction(_ rawValue: String) -> String {
        "codex-gauge.menu.action.\(rawValue)"
    }
}
