public struct SettingsFormPresentation: Equatable, Sendable {
    public let quotaChoicesEnabled: Bool
    public let showsEmptyQuotaMessage: Bool
    public let quotaRows: [SettingsQuotaOption]

    public init(
        quotaChoicesEnabled: Bool,
        showsEmptyQuotaMessage: Bool,
        quotaRows: [SettingsQuotaOption]
    ) {
        self.quotaChoicesEnabled = quotaChoicesEnabled
        self.showsEmptyQuotaMessage = showsEmptyQuotaMessage
        self.quotaRows = quotaRows
    }
}

public struct SettingsFormPresenter: Sendable {
    public init() {}

    public func present(_ state: SettingsFormState) -> SettingsFormPresentation {
        let rows = state.quotaOptions
        return SettingsFormPresentation(
            quotaChoicesEnabled: state.quotaSelectionMode == .manual,
            showsEmptyQuotaMessage: rows.isEmpty,
            quotaRows: rows
        )
    }
}
