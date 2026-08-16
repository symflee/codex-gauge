import CodexGaugeCore
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

public enum QuotaMenuAction: String, CaseIterable, Equatable, Sendable {
    case refresh
    case openCodex
    case selectCodex
    case settings
    case quit
}

public struct QuotaDetailsMenuInput: Equatable, Sendable {
    public let productStates: [UsageProduct: ProductUsageState]
    public let issuesByProduct: [UsageProduct: QuotaMenuIssue]
    public let lastSuccessfulRefreshByProduct: [UsageProduct: Date]
    public let codexAvailability: CodexMenuAvailability

    public init(
        productStates: [UsageProduct: ProductUsageState],
        issuesByProduct: [UsageProduct: QuotaMenuIssue] = [:],
        lastSuccessfulRefreshByProduct: [UsageProduct: Date] = [:],
        codexAvailability: CodexMenuAvailability
    ) {
        self.productStates = productStates
        self.issuesByProduct = issuesByProduct
        self.lastSuccessfulRefreshByProduct = lastSuccessfulRefreshByProduct
        self.codexAvailability = codexAvailability
    }
}

public struct QuotaMenuProductSection: Equatable, Sendable {
    public let product: UsageProduct
    public let title: String
    public let quotaRows: [String]
    public let statusRows: [String]

    public init(
        product: UsageProduct,
        title: String,
        quotaRows: [String],
        statusRows: [String]
    ) {
        self.product = product
        self.title = title
        self.quotaRows = quotaRows
        self.statusRows = statusRows
    }
}

public struct QuotaMenuActionItem: Equatable, Sendable {
    public let action: QuotaMenuAction
    public let title: String

    public init(action: QuotaMenuAction, title: String) {
        self.action = action
        self.title = title
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

    public func string(from date: Date) -> String {
        format(date)
    }
}

public struct QuotaDetailsMenuModelBuilder {
    private let localization: QuotaMenuLocalization
    private let dateFormatter: QuotaMenuDateFormatter

    public init(
        localization: QuotaMenuLocalization = .bundled(),
        dateFormatter: QuotaMenuDateFormatter = .localized
    ) {
        self.localization = localization
        self.dateFormatter = dateFormatter
    }

    public func build(_ input: QuotaDetailsMenuInput) -> QuotaDetailsMenuModel {
        QuotaDetailsMenuModel(
            productSections: UsageProduct.allCases.map {
                productSection(for: $0, input: input)
            },
            actionGroups: actionGroups(for: input.codexAvailability)
        )
    }

    private func productSection(
        for product: UsageProduct,
        input: QuotaDetailsMenuInput
    ) -> QuotaMenuProductSection {
        let state = input.productStates[product] ?? .unavailable
        let explicitSuccess = input.lastSuccessfulRefreshByProduct[product]
        let issue = input.issuesByProduct[product]
        return section(
            product: product,
            state: state,
            explicitSuccess: explicitSuccess,
            issue: issue
        )
    }

    private func section(
        product: UsageProduct,
        state: ProductUsageState,
        explicitSuccess: Date?,
        issue: QuotaMenuIssue?
    ) -> QuotaMenuProductSection {
        switch state {
        case .loading:
            return makeSection(product: product, statusRows: [text(.statusLoading)])
        case .unavailable:
            let status = successRows(explicitSuccess) + [issueText(issue)]
            return makeSection(product: product, statusRows: status)
        case .value(let value, let freshness):
            return valueSection(
                product: product,
                value: value,
                freshness: freshness,
                explicitSuccess: explicitSuccess,
                issue: issue
            )
        }
    }

    private func valueSection(
        product: UsageProduct,
        value: ProductQuotaValue,
        freshness: ProductValueFreshness,
        explicitSuccess: Date?,
        issue: QuotaMenuIssue?
    ) -> QuotaMenuProductSection {
        let success = explicitSuccess ?? value.capturedAt
        let rows = value.quotaWindows.sorted(by: quotaAscending).map(quotaRow)
        let status = successRows(success) + freshnessRows(freshness, issue: issue)
        return makeSection(product: product, quotaRows: rows, statusRows: status)
    }

    private func makeSection(
        product: UsageProduct,
        quotaRows: [String] = [],
        statusRows: [String]
    ) -> QuotaMenuProductSection {
        QuotaMenuProductSection(
            product: product,
            title: productTitle(product),
            quotaRows: quotaRows,
            statusRows: statusRows
        )
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

    private func quotaRow(_ quota: QuotaWindow) -> String {
        let values = [
            "duration": quota.durationBadge.label,
            "remaining": String(quota.remainingPercent)
        ]
        guard let reset = quota.resetsAt else {
            return template(.quotaWithoutReset, values: values)
        }
        return template(
            .quotaWithReset,
            values: values.merging(["reset": dateFormatter.string(from: reset)]) { _, new in new }
        )
    }

    private func successRows(_ date: Date?) -> [String] {
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

    private func productTitle(_ product: UsageProduct) -> String {
        switch product {
        case .codex:
            text(.productCodex)
        case .spark:
            text(.productSpark)
        }
    }

    private func actionGroups(
        for availability: CodexMenuAvailability
    ) -> [[QuotaMenuActionItem]] {
        let connectionAction: QuotaMenuAction
        switch availability {
        case .available:
            connectionAction = .openCodex
        case .needsSelection:
            connectionAction = .selectCodex
        }
        return [
            [.refresh, connectionAction, .settings].map(actionItem),
            [.quit].map(actionItem)
        ]
    }

    private func actionItem(_ action: QuotaMenuAction) -> QuotaMenuActionItem {
        QuotaMenuActionItem(action: action, title: text(action.textKey))
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

private enum QuotaMenuTextKey: String, CaseIterable {
    case productCodex = "menu.product.codex"
    case productSpark = "menu.product.spark"
    case quotaWithReset = "menu.quota.with_reset"
    case quotaWithoutReset = "menu.quota.without_reset"
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
        case .settings:
            .actionSettings
        case .quit:
            .actionQuit
        }
    }
}
