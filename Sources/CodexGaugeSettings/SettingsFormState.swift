import CodexGaugeCore
import CodexGaugeRefresh

public enum SettingsQuotaSelectionMode: Equatable, Sendable {
    case automatic
    case manual
}

public enum SettingsQuotaAvailability: Equatable, Sendable {
    case discovered
    case currentlyUnavailable
}

public struct SettingsQuotaOption: Equatable, Sendable {
    public let identifier: QuotaSelectionID
    public let isSelected: Bool
    public let availability: SettingsQuotaAvailability

    public init(
        identifier: QuotaSelectionID,
        isSelected: Bool,
        availability: SettingsQuotaAvailability
    ) {
        self.identifier = identifier
        self.isSelected = isSelected
        self.availability = availability
    }
}

public struct SettingsFormValues: Equatable, Sendable {
    public let displayPreference: DisplayPreference
    public let refreshProfile: RefreshProfile
    public let launchAtLoginIntent: Bool
    public let language: AppLanguage

    public init(preferences: AppPreferences) {
        displayPreference = preferences.displayPreference
        refreshProfile = preferences.refreshProfile
        launchAtLoginIntent = preferences.launchAtLoginIntent
        language = preferences.language
    }

    public init(
        displayPreference: DisplayPreference,
        refreshProfile: RefreshProfile,
        launchAtLoginIntent: Bool,
        language: AppLanguage = .english
    ) {
        let normalized = AppPreferences(
            displayPreference: displayPreference,
            refreshProfile: refreshProfile,
            launchAtLoginIntent: launchAtLoginIntent,
            language: language
        )
        self.init(preferences: normalized)
    }
}

public struct SettingsFormState: Equatable, Sendable {
    public let productMode: DisplayProductMode
    public let quotaSelectionMode: SettingsQuotaSelectionMode
    public let refreshProfile: RefreshProfile
    public let launchAtLoginIntent: Bool
    public let language: AppLanguage

    let discoveredQuotaIDs: Set<QuotaSelectionID>
    let rememberedQuotaIDs: Set<QuotaSelectionID>

    public init(
        preferences: AppPreferences,
        discoveredQuotaIDs: Set<QuotaSelectionID>
    ) {
        productMode = preferences.displayPreference.productMode
        refreshProfile = preferences.refreshProfile
        launchAtLoginIntent = preferences.launchAtLoginIntent
        language = preferences.language
        self.discoveredQuotaIDs = discoveredQuotaIDs

        switch preferences.displayPreference.quotaSelection {
        case .automatic:
            quotaSelectionMode = .automatic
            rememberedQuotaIDs = []
        case .manual(let identifiers):
            quotaSelectionMode = .manual
            rememberedQuotaIDs = identifiers
        }
    }

    public var selectedQuotaIDs: Set<QuotaSelectionID> {
        let products = Set(productMode.products)
        return Set(rememberedQuotaIDs.filter { identifier in
            products.contains(identifier.product)
        })
    }

    public var quotaOptions: [SettingsQuotaOption] {
        visibleQuotaIDs.map(makeOption)
    }

    public var formValues: SettingsFormValues {
        SettingsFormValues(
            displayPreference: DisplayPreference(
                productMode: productMode,
                quotaSelection: persistedQuotaSelection
            ),
            refreshProfile: refreshProfile,
            launchAtLoginIntent: launchAtLoginIntent,
            language: language
        )
    }

    init(
        productMode: DisplayProductMode,
        quotaSelectionMode: SettingsQuotaSelectionMode,
        rememberedQuotaIDs: Set<QuotaSelectionID>,
        refreshProfile: RefreshProfile,
        launchAtLoginIntent: Bool,
        language: AppLanguage,
        discoveredQuotaIDs: Set<QuotaSelectionID>
    ) {
        self.productMode = productMode
        self.quotaSelectionMode = quotaSelectionMode
        self.rememberedQuotaIDs = rememberedQuotaIDs
        self.refreshProfile = refreshProfile
        self.launchAtLoginIntent = launchAtLoginIntent
        self.language = language
        self.discoveredQuotaIDs = discoveredQuotaIDs
    }

    private var visibleQuotaIDs: [QuotaSelectionID] {
        let visibleProducts = Set(productMode.products)
        let discovered = discoveredQuotaIDs.filter { identifier in
            visibleProducts.contains(identifier.product)
        }
        return Array(Set(discovered).union(selectedQuotaIDs)).sorted(by: quotaIDAscending)
    }

    private var persistedQuotaSelection: DisplayQuotaSelection {
        guard quotaSelectionMode == .manual else {
            return .automatic
        }
        return .manual(selectedQuotaIDs)
    }

    private func makeOption(_ identifier: QuotaSelectionID) -> SettingsQuotaOption {
        SettingsQuotaOption(
            identifier: identifier,
            isSelected: selectedQuotaIDs.contains(identifier),
            availability: availability(of: identifier)
        )
    }

    private func availability(
        of identifier: QuotaSelectionID
    ) -> SettingsQuotaAvailability {
        guard discoveredQuotaIDs.contains(identifier) else {
            return .currentlyUnavailable
        }
        return .discovered
    }

    private func quotaIDAscending(
        _ left: QuotaSelectionID,
        _ right: QuotaSelectionID
    ) -> Bool {
        guard left.product == right.product else {
            return productRank(left.product) < productRank(right.product)
        }
        return durationAscending(
            left.rawDurationMinutes,
            right.rawDurationMinutes
        )
    }

    private func productRank(_ product: UsageProduct) -> Int {
        product == .codex ? 0 : 1
    }

    private func durationAscending(_ left: Int?, _ right: Int?) -> Bool {
        guard let left else {
            return false
        }
        guard let right else {
            return true
        }
        return left < right
    }
}
