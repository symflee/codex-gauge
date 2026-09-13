import CodexGaugeCore
import CodexGaugeSettings
import Foundation

public enum QuotaMenuIssue: Equatable, Sendable {
    case partialData
    case refreshFailed
    case timeout
    case signedOut
    case codexNotFound
    case incompatibleProtocol
    case unsupportedAccount
}

public enum CodexMenuAvailability: Equatable, Sendable {
    case available
    case needsSelection
}

public enum QuotaMenuSpendControl: Equatable, Sendable {
    case reached
    case remaining(percent: Int)
    case notReachedWithoutRemainingPercent
}

public enum QuotaMenuAction: String, CaseIterable, Equatable, Sendable {
    case refresh
    case openCodex
    case selectCodex
    case checkForUpdates
    case settings
    case quit
}

public struct QuotaDetailsMenuInput: Equatable, Sendable {
    public let productStates: [UsageProduct: ProductUsageState]
    public let spendControlsByProduct: [UsageProduct: QuotaMenuSpendControl]
    public let issuesByProduct: [UsageProduct: QuotaMenuIssue]
    public let lastSuccessfulRefreshByProduct: [UsageProduct: Date]
    public let codexAvailability: CodexMenuAvailability
    public let currentDate: Date

    public init(
        productStates: [UsageProduct: ProductUsageState],
        spendControlsByProduct: [UsageProduct: QuotaMenuSpendControl] = [:],
        issuesByProduct: [UsageProduct: QuotaMenuIssue] = [:],
        lastSuccessfulRefreshByProduct: [UsageProduct: Date] = [:],
        codexAvailability: CodexMenuAvailability,
        currentDate: Date
    ) {
        self.productStates = productStates
        self.spendControlsByProduct = spendControlsByProduct
        self.issuesByProduct = issuesByProduct
        self.lastSuccessfulRefreshByProduct = lastSuccessfulRefreshByProduct
        self.codexAvailability = codexAvailability
        self.currentDate = currentDate
    }

    /// Reevaluate validity when deferred content is requested, without fetching a
    /// new snapshot. The payload remains the most recent in-memory publication.
    public func replacingCurrentDate(_ date: Date) -> Self {
        Self(
            productStates: productStates,
            spendControlsByProduct: spendControlsByProduct,
            issuesByProduct: issuesByProduct,
            lastSuccessfulRefreshByProduct: lastSuccessfulRefreshByProduct,
            codexAvailability: codexAvailability,
            currentDate: date
        )
    }
}

public struct QuotaMenuProductSection: Equatable, Sendable {
    public let product: UsageProduct
    public let title: String
    public let quotaRows: [String]
    public let spendControlRows: [String]
    public let statusRows: [String]
    public let quotaRowIDs: [String]
    public let statusRowIDs: [String]

    public init(
        product: UsageProduct,
        title: String,
        quotaRows: [String],
        spendControlRows: [String],
        statusRows: [String],
        quotaRowIDs: [String]? = nil,
        statusRowIDs: [String]? = nil
    ) {
        self.product = product
        self.title = title
        self.quotaRows = quotaRows
        self.spendControlRows = spendControlRows
        self.statusRows = statusRows
        self.quotaRowIDs = quotaRowIDs ?? quotaRows.indices.map { "quota-\($0)" }
        self.statusRowIDs = statusRowIDs ?? statusRows.indices.map { "status-\($0)" }
    }
}

public struct QuotaMenuActionItem: Equatable, Sendable {
    public let action: QuotaMenuAction
    public let title: String
    public let isEnabled: Bool

    public init(
        action: QuotaMenuAction,
        title: String,
        isEnabled: Bool = true
    ) {
        self.action = action
        self.title = title
        self.isEnabled = isEnabled
    }
}

public struct QuotaDetailsMenuModel: Equatable, Sendable {
    public let productSections: [QuotaMenuProductSection]
    public let actionGroups: [[QuotaMenuActionItem]]

    public init(
        productSections: [QuotaMenuProductSection],
        actionGroups: [[QuotaMenuActionItem]]
    ) {
        self.productSections = productSections
        self.actionGroups = actionGroups
    }
}

public struct QuotaMenuLocalization: Sendable {
    private let values: [String: String]

    public init(resolve: (String) -> String) {
        values = Dictionary(uniqueKeysWithValues: QuotaMenuTextKey.allCases.map { key in
            (key.rawValue, resolve(key.rawValue))
        })
    }

    public static func bundled() -> QuotaMenuLocalization {
        QuotaMenuLocalization { key in
            Bundle.module.localizedString(forKey: key, value: key, table: nil)
        }
    }

    public static func bundled(
        language: AppLanguage
    ) -> QuotaMenuLocalization {
        let localization = AppLocalization(language: language)
        return QuotaMenuLocalization(resolve: localization.string)
    }

    fileprivate func string(_ key: QuotaMenuTextKey) -> String {
        values[key.rawValue] ?? key.rawValue
    }
}

public struct QuotaMenuDateFormatter {
    private let format: (Date) -> String

    public init(format: @escaping (Date) -> String) {
        self.format = format
    }

    public static var localized: QuotaMenuDateFormatter {
        QuotaMenuDateFormatter { date in
            date.formatted(date: .abbreviated, time: .shortened)
        }
    }

    public static func localized(
        language: AppLanguage,
        timeZone: TimeZone = .autoupdatingCurrent
    ) -> QuotaMenuDateFormatter {
        let localization = AppLocalization(language: language)
        let style = Date.FormatStyle(
            date: .abbreviated,
            time: .shortened,
            locale: localization.locale,
            timeZone: timeZone
        )
        return QuotaMenuDateFormatter { date in
            date.formatted(style)
        }
    }

    public func string(from date: Date) -> String {
        format(date)
    }
}

public struct QuotaDetailsMenuModelBuilder {
    fileprivate let cacheIdentity = UUID()
    private let localization: QuotaMenuLocalization
    private let dateFormatter: QuotaMenuDateFormatter
    private let validityPolicy = QuotaValueValidityPolicy()

    public init(
        localization: QuotaMenuLocalization = .bundled(),
        dateFormatter: QuotaMenuDateFormatter = .localized
    ) {
        self.localization = localization
        self.dateFormatter = dateFormatter
    }

    public static func bundled(
        language: AppLanguage
    ) -> QuotaDetailsMenuModelBuilder {
        QuotaDetailsMenuModelBuilder(
            localization: .bundled(language: language),
            dateFormatter: .localized(language: language)
        )
    }

    public func build(
        _ input: QuotaDetailsMenuInput,
        applicationUpdateState: ApplicationUpdateState = .unavailable
    ) -> QuotaDetailsMenuModel {
        var cache = QuotaDetailsMenuModelCache()
        return cache.build(input, using: self, applicationUpdateState: applicationUpdateState)
    }

    fileprivate func sectionInput(
        for product: UsageProduct,
        input: QuotaDetailsMenuInput
    ) -> QuotaMenuSectionInput {
        let state = input.productStates[product] ?? .unavailable
        let issue = input.issuesByProduct[product]
        var result = QuotaMenuSectionInput(
            spendControl: input.spendControlsByProduct[product]
        )
        switch state {
        case .loading:
            result.status = .loading
        case .unavailable:
            result.success = input.lastSuccessfulRefreshByProduct[product]
            result.status = .unavailable(issue)
        case .value(let value, let freshness):
            result.success = input.lastSuccessfulRefreshByProduct[product] ?? value.capturedAt
            result.status = .value(freshness, issue)
            result.windows = value.quotaWindows.sorted(by: quotaAscending).map { quota in
                QuotaMenuWindowInput(
                    slot: quota.slot,
                    durationMinutes: quota.windowDurationMinutes,
                    remainingPercent: validityPolicy.isValid(
                        quota, capturedAt: value.capturedAt, now: input.currentDate
                    ) ? quota.remainingPercent : nil,
                    resetsAt: quota.resetsAt
                )
            }
        }
        return result
    }

    fileprivate func statusRows(_ status: QuotaMenuSectionInput.Status) -> [String] {
        switch status {
        case .loading:
            [text(.statusLoading)]
        case .unavailable(let issue):
            [issueText(issue)]
        case .value(let freshness, let issue):
            freshnessRows(freshness, issue: issue)
        }
    }

    private func quotaAscending(_ left: QuotaWindow, _ right: QuotaWindow) -> Bool {
        let leftDuration = left.windowDurationMinutes ?? Int.max
        let rightDuration = right.windowDurationMinutes ?? Int.max
        guard leftDuration == rightDuration else {
            return leftDuration < rightDuration
        }
        return slotRank(left.slot) < slotRank(right.slot)
    }

    private func slotRank(_ slot: QuotaSlot) -> Int {
        switch slot {
        case .primary:
            0
        case .secondary:
            1
        }
    }

    fileprivate func quotaRow(_ quota: QuotaMenuWindowInput) -> String {
        var values = ["duration": DurationBadge(windowDurationMinutes: quota.durationMinutes).label]
        if let remaining = quota.remainingPercent {
            values["remaining"] = String(remaining)
        }
        let valid = quota.remainingPercent != nil
        guard let reset = quota.resetsAt else {
            return template(valid ? .quotaWithoutReset : .quotaExpiredWithoutReset, values: values)
        }
        values["reset"] = dateFormatter.string(from: reset)
        return template(valid ? .quotaWithReset : .quotaExpiredWithReset, values: values)
    }

    fileprivate func spendControlRow(_ spendControl: QuotaMenuSpendControl) -> String {
        switch spendControl {
        case .reached:
            text(.spendControlReached)
        case .remaining(let percent):
            template(
                .spendControlRemaining,
                values: ["remaining": String(percent)]
            )
        case .notReachedWithoutRemainingPercent:
            text(.spendControlNotReachedWithoutRemaining)
        }
    }

    fileprivate func successRows(_ date: Date?) -> [String] {
        guard let date else {
            return []
        }
        return [template(
            .lastSuccess,
            values: ["date": dateFormatter.string(from: date)]
        )]
    }

    private func freshnessRows(
        _ freshness: ProductValueFreshness,
        issue: QuotaMenuIssue?
    ) -> [String] {
        guard freshness == .stale else {
            return issue.map { [issueText($0)] } ?? []
        }
        let reason = issueText(issue ?? .refreshFailed)
        return [template(.statusStale, values: ["reason": reason])]
    }

    private func issueText(_ issue: QuotaMenuIssue?) -> String {
        guard let issue else {
            return text(.statusUnavailable)
        }
        return text(issue.textKey)
    }

    fileprivate func productTitle(_ product: UsageProduct) -> String {
        switch product {
        case .codex:
            text(.productCodex)
        }
    }

    fileprivate func actionGroups(
        for availability: CodexMenuAvailability,
        applicationUpdateState: ApplicationUpdateState
    ) -> [[QuotaMenuActionItem]] {
        let connectionAction: QuotaMenuAction
        switch availability {
        case .available:
            connectionAction = .openCodex
        case .needsSelection:
            connectionAction = .selectCodex
        }
        return [
            [.refresh, connectionAction].map { actionItem($0) },
            [
                updateActionItem(applicationUpdateState),
                actionItem(.settings)
            ],
            [.quit].map { actionItem($0) }
        ]
    }

    private func actionItem(
        _ action: QuotaMenuAction,
        isEnabled: Bool = true
    ) -> QuotaMenuActionItem {
        QuotaMenuActionItem(
            action: action,
            title: text(action.textKey),
            isEnabled: isEnabled
        )
    }

    private func updateActionItem(
        _ state: ApplicationUpdateState
    ) -> QuotaMenuActionItem {
        QuotaMenuActionItem(
            action: .checkForUpdates,
            title: updateTitle(state),
            isEnabled: state.status.isUpdateAvailable
        )
    }

    private func updateTitle(_ state: ApplicationUpdateState) -> String {
        let values = ["current": state.currentVersion]
        switch state.status {
        case .unavailable:
            return template(.updateUnavailable, values: values)
        case .checking:
            return template(.updateChecking, values: values)
        case .current(let latestVersion), .updateAvailable(let latestVersion):
            return template(
                .updateVersions,
                values: values.merging(["latest": latestVersion]) { _, new in new }
            )
        case .failed:
            return template(.updateFailed, values: values)
        }
    }

    private func text(_ key: QuotaMenuTextKey) -> String {
        localization.string(key)
    }

    private func template(
        _ key: QuotaMenuTextKey,
        values: [String: String]
    ) -> String {
        values.reduce(text(key)) { result, value in
            result.replacingOccurrences(of: "{\(value.key)}", with: value.value)
        }
    }
}

/// Stores only the current rows. A new success timestamp does not reformat quota dates.
public struct QuotaDetailsMenuModelCache {
    private var sections: [UsageProduct: CachedSection] = [:]
    private var builderIdentity: UUID?
    private var actionInput: ActionInput?
    private var actions: [[QuotaMenuActionItem]] = []

    public init() {}

    public mutating func build(
        _ input: QuotaDetailsMenuInput,
        using builder: QuotaDetailsMenuModelBuilder,
        applicationUpdateState: ApplicationUpdateState = .unavailable
    ) -> QuotaDetailsMenuModel {
        if builderIdentity != builder.cacheIdentity {
            self = Self()
            builderIdentity = builder.cacheIdentity
        }
        let productSections = UsageProduct.allCases.map { product in
            let semantic = builder.sectionInput(for: product, input: input)
            let previous = sections[product]
            if previous?.input == semantic, let previous { return previous.section }
            let windows = semantic.windows.map { window in
                if let oldIndex = previous?.input.windows.firstIndex(of: window),
                   let previous {
                    return previous.section.quotaRows[oldIndex]
                }
                return builder.quotaRow(window)
            }
            let success: [String]
            if previous?.input.success == semantic.success, let previous {
                success = previous.successRows
            } else {
                success = builder.successRows(semantic.success)
            }
            let status: [String]
            if previous?.input.status == semantic.status, let previous {
                status = previous.statusRows
            } else {
                status = builder.statusRows(semantic.status)
            }
            let spend: [String]
            if previous?.input.spendControl == semantic.spendControl, let previous {
                spend = previous.section.spendControlRows
            } else {
                spend = semantic.spendControl.map { [builder.spendControlRow($0)] } ?? []
            }
            let section = QuotaMenuProductSection(
                product: product,
                title: previous?.section.title ?? builder.productTitle(product),
                quotaRows: windows,
                spendControlRows: spend,
                statusRows: success + status,
                quotaRowIDs: semantic.windows.map { $0.slot.rawValue },
                statusRowIDs: success.map { _ in "last-success" } + status.map { _ in "condition" }
            )
            sections[product] = CachedSection(
                input: semantic, section: section, successRows: success, statusRows: status
            )
            return section
        }
        let nextActionInput = ActionInput(
            availability: input.codexAvailability, update: applicationUpdateState
        )
        if nextActionInput != actionInput {
            actions = builder.actionGroups(
                for: input.codexAvailability, applicationUpdateState: applicationUpdateState
            )
            actionInput = nextActionInput
        }
        return QuotaDetailsMenuModel(productSections: productSections, actionGroups: actions)
    }

    private struct CachedSection {
        let input: QuotaMenuSectionInput
        let section: QuotaMenuProductSection
        let successRows: [String]
        let statusRows: [String]
    }

    private struct ActionInput: Equatable {
        let availability: CodexMenuAvailability
        let update: ApplicationUpdateState
    }
}

fileprivate struct QuotaMenuSectionInput: Equatable {
    enum Status: Equatable {
        case loading
        case unavailable(QuotaMenuIssue?)
        case value(ProductValueFreshness, QuotaMenuIssue?)
    }

    var windows: [QuotaMenuWindowInput] = []
    var success: Date?
    var status: Status = .loading
    let spendControl: QuotaMenuSpendControl?
}

fileprivate struct QuotaMenuWindowInput: Equatable {
    let slot: QuotaSlot
    let durationMinutes: Int?
    let remainingPercent: Int?
    let resetsAt: Date?
}

private enum QuotaMenuTextKey: String, CaseIterable {
    case productCodex = "menu.product.codex"
    case quotaWithReset = "menu.quota.with_reset"
    case quotaWithoutReset = "menu.quota.without_reset"
    case quotaExpiredWithReset = "menu.quota.expired_with_reset"
    case quotaExpiredWithoutReset = "menu.quota.expired_without_reset"
    case spendControlReached = "menu.spend_control.reached"
    case spendControlRemaining = "menu.spend_control.remaining"
    case spendControlNotReachedWithoutRemaining =
        "menu.spend_control.not_reached_without_remaining"
    case lastSuccess = "menu.last_success"
    case statusLoading = "menu.status.loading"
    case statusUnavailable = "menu.status.unavailable"
    case statusPartial = "menu.status.partial"
    case statusRefreshFailed = "menu.status.refresh_failed"
    case statusTimeout = "menu.status.timeout"
    case statusSignedOut = "menu.status.signed_out"
    case statusCodexNotFound = "menu.status.codex_not_found"
    case statusIncompatibleProtocol = "menu.status.incompatible_protocol"
    case statusUnsupportedAccount = "menu.status.unsupported_account"
    case statusStale = "menu.status.stale"
    case actionRefresh = "menu.action.refresh"
    case actionOpenCodex = "menu.action.open_codex"
    case actionSelectCodex = "menu.action.select_codex"
    case updateChecking = "menu.update.checking"
    case updateVersions = "menu.update.versions"
    case updateFailed = "menu.update.failed"
    case updateUnavailable = "menu.update.unavailable"
    case actionSettings = "menu.action.settings"
    case actionQuit = "menu.quit"
}

private extension QuotaMenuIssue {
    var textKey: QuotaMenuTextKey {
        switch self {
        case .partialData:
            .statusPartial
        case .refreshFailed:
            .statusRefreshFailed
        case .timeout:
            .statusTimeout
        case .signedOut:
            .statusSignedOut
        case .codexNotFound:
            .statusCodexNotFound
        case .incompatibleProtocol:
            .statusIncompatibleProtocol
        case .unsupportedAccount:
            .statusUnsupportedAccount
        }
    }
}

private extension QuotaMenuAction {
    var textKey: QuotaMenuTextKey {
        switch self {
        case .refresh:
            .actionRefresh
        case .openCodex:
            .actionOpenCodex
        case .selectCodex:
            .actionSelectCodex
        case .checkForUpdates:
            .updateUnavailable
        case .settings:
            .actionSettings
        case .quit:
            .actionQuit
        }
    }
}
