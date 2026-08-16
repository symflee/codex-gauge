import CodexGaugeCore
import CodexGaugeRefresh

public enum SettingsFormEvent: Equatable, Sendable {
    case productModeChanged(DisplayProductMode)
    case quotaSelectionModeChanged(SettingsQuotaSelectionMode)
    case quotaSelectionChanged(QuotaSelectionID, isSelected: Bool)
    case refreshProfileChanged(RefreshProfile)
    case launchAtLoginIntentChanged(Bool)
}

public struct SettingsFormReducer: Sendable {
    public init() {}

    public func reduce(
        state: SettingsFormState,
        event: SettingsFormEvent
    ) -> SettingsFormState {
        switch event {
        case .productModeChanged(let productMode):
            replacing(state, productMode: productMode)
        case .quotaSelectionModeChanged(let selectionMode):
            replacing(state, quotaSelectionMode: selectionMode)
        case .quotaSelectionChanged(let identifier, let isSelected):
            changingSelection(state, identifier: identifier, isSelected: isSelected)
        case .refreshProfileChanged(let profile):
            replacing(state, refreshProfile: profile)
        case .launchAtLoginIntentChanged(let enabled):
            replacing(state, launchAtLoginIntent: enabled)
        }
    }

    private func changingSelection(
        _ state: SettingsFormState,
        identifier: QuotaSelectionID,
        isSelected: Bool
    ) -> SettingsFormState {
        guard state.quotaSelectionMode == .manual else {
            return state
        }
        guard state.quotaOptions.contains(where: { $0.identifier == identifier }) else {
            return state
        }
        var selection = state.rememberedQuotaIDs
        if isSelected {
            selection.insert(identifier)
        } else {
            selection.remove(identifier)
        }
        return replacing(state, rememberedQuotaIDs: selection)
    }

    private func replacing(
        _ state: SettingsFormState,
        productMode: DisplayProductMode? = nil,
        quotaSelectionMode: SettingsQuotaSelectionMode? = nil,
        rememberedQuotaIDs: Set<QuotaSelectionID>? = nil,
        refreshProfile: RefreshProfile? = nil,
        launchAtLoginIntent: Bool? = nil
    ) -> SettingsFormState {
        SettingsFormState(
            productMode: productMode ?? state.productMode,
            quotaSelectionMode: quotaSelectionMode ?? state.quotaSelectionMode,
            rememberedQuotaIDs: rememberedQuotaIDs ?? state.rememberedQuotaIDs,
            refreshProfile: refreshProfile ?? state.refreshProfile,
            launchAtLoginIntent: launchAtLoginIntent ?? state.launchAtLoginIntent,
            discoveredQuotaIDs: state.discoveredQuotaIDs
        )
    }
}
