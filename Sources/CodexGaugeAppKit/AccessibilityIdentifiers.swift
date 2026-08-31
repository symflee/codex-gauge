enum CodexGaugeAccessibilityIdentifier {
    static let statusItem = "codex-gauge.status-item"
    static let settingsWindow = "codex-gauge.settings.window"
    static let settingsCloseButton = "codex-gauge.settings.close"
    static let settingsLanguage = "codex-gauge.settings.language"
    static let settingsGaugePreset = "codex-gauge.settings.gauge-preset"
    static let settingsGaugeBorder = "codex-gauge.settings.gauge-border"
    static let settingsGaugeFill = "codex-gauge.settings.gauge-fill"

    static func menuAction(_ rawValue: String) -> String {
        "codex-gauge.menu.action.\(rawValue)"
    }
}
