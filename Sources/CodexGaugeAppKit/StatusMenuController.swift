import AppKit

@MainActor
public protocol StatusMenuPresenting: AnyObject {
    func setMenu(_ menu: NSMenu)
}

@MainActor
public struct StatusMenuActions {
    private let refresh: @MainActor () -> Void
    private let openCodex: @MainActor () -> Void
    private let selectCodex: @MainActor () -> Void
    private let checkForUpdates: @MainActor () -> Void
    private let settings: @MainActor () -> Void
    private let quit: @MainActor () -> Void

    public init(
        refresh: @escaping @MainActor () -> Void,
        openCodex: @escaping @MainActor () -> Void,
        selectCodex: @escaping @MainActor () -> Void,
        checkForUpdates: @escaping @MainActor () -> Void,
        settings: @escaping @MainActor () -> Void,
        quit: @escaping @MainActor () -> Void
    ) {
        self.refresh = refresh
        self.openCodex = openCodex
        self.selectCodex = selectCodex
        self.checkForUpdates = checkForUpdates
        self.settings = settings
        self.quit = quit
    }

    public func perform(_ action: QuotaMenuAction) {
        switch action {
        case .refresh:
            refresh()
        case .openCodex:
            openCodex()
        case .selectCodex:
            selectCodex()
        case .checkForUpdates:
            checkForUpdates()
        case .settings:
            settings()
        case .quit:
            quit()
        }
    }
}

@MainActor
public final class StatusMenuController: NSObject, NSMenuDelegate {
    private let menu = NSMenu()
    private let statusItemController: StatusItemController
    private let actions: StatusMenuActions
    private var currentModel: QuotaDetailsMenuModel?
    private var rowsByID: [String: NSMenuItem] = [:]
    private var currentRows: [String: Row] = [:]
    private var pendingModelProvider: (@MainActor () -> QuotaDetailsMenuModel?)?
    private var isOpen = false

    public init(
        presenter: StatusMenuPresenting,
        statusItemController: StatusItemController,
        actions: StatusMenuActions
    ) {
        self.statusItemController = statusItemController
        self.actions = actions
        super.init()
        menu.autoenablesItems = false
        menu.delegate = self
        presenter.setMenu(menu)
    }

    public func update(_ model: QuotaDetailsMenuModel) {
        pendingModelProvider = nil
        guard model != currentModel else { return }
        let rows = flattenedRows(model)
        let identifiers = Set(rows.map(\.id))
        for identifier in Array(rowsByID.keys) where !identifiers.contains(identifier) {
            if let item = rowsByID.removeValue(forKey: identifier) {
                menu.removeItem(item)
            }
            currentRows.removeValue(forKey: identifier)
        }
        for (index, row) in rows.enumerated() {
            let item: NSMenuItem
            if let existing = rowsByID[row.id] {
                item = existing
                if currentRows[row.id] != row {
                    if item.title != row.title { item.title = row.title }
                    if item.isEnabled != row.isEnabled { item.isEnabled = row.isEnabled }
                    if item.indentationLevel != row.indentation {
                        item.indentationLevel = row.indentation
                    }
                }
            } else {
                item = makeItem(row)
                rowsByID[row.id] = item
            }
            if menu.index(of: item) != index {
                if item.menu === menu { menu.removeItem(item) }
                menu.insertItem(item, at: index)
            }
            currentRows[row.id] = row
        }
        currentModel = model
    }

    /// Retains at most one pending provider. It may only read already-held local
    /// state and format it; never fetch data or perform blocking I/O here.
    public func updateDeferred(
        _ modelProvider: @escaping @MainActor () -> QuotaDetailsMenuModel?
    ) {
        pendingModelProvider = modelProvider
        if isOpen { applyPendingModel() }
    }

    public func menuNeedsUpdate(_ menu: NSMenu) {
        guard menu === self.menu else { return }
        applyPendingModel()
    }

    private func applyPendingModel() {
        guard let provider = pendingModelProvider else { return }
        pendingModelProvider = nil
        if let model = provider() { update(model) }
    }

    public func menuWillOpen(_ menu: NSMenu) {
        _ = menu
        isOpen = true
        statusItemController.setPaused(true, for: .menuOpen)
    }

    public func menuDidClose(_ menu: NSMenu) {
        _ = menu
        isOpen = false
        statusItemController.setPaused(false, for: .menuOpen)
    }

    public func perform(_ action: QuotaMenuAction) {
        actions.perform(action)
    }

    private struct Row: Equatable {
        let id: String
        var title = ""
        var indentation = 0
        var isEnabled = false
        var action: QuotaMenuAction?
        var isSeparator = false
    }

    private func flattenedRows(_ model: QuotaDetailsMenuModel) -> [Row] {
        var rows: [Row] = []
        for section in model.productSections {
            let prefix = "product-\(section.product.rawValue)"
            if !rows.isEmpty { rows.append(Row(id: "before-\(prefix)", isSeparator: true)) }
            rows.append(Row(id: prefix, title: section.title))
            for (index, title) in section.quotaRows.enumerated() {
                let identifier = section.quotaRowIDs.indices.contains(index)
                    ? section.quotaRowIDs[index] : String(index)
                rows.append(Row(id: "\(prefix)-quota-\(identifier)", title: title, indentation: 1))
            }
            for (index, title) in section.spendControlRows.enumerated() {
                rows.append(Row(id: "\(prefix)-spend-\(index)", title: title, indentation: 1))
            }
            for (index, title) in section.statusRows.enumerated() {
                let identifier = section.statusRowIDs.indices.contains(index)
                    ? section.statusRowIDs[index] : String(index)
                rows.append(Row(id: "\(prefix)-status-\(identifier)", title: title, indentation: 1))
            }
        }
        for group in model.actionGroups where !group.isEmpty {
            if let first = group.first, !rows.isEmpty {
                rows.append(Row(id: "before-action-\(first.action.rawValue)", isSeparator: true))
            }
            rows += group.map { item in
                Row(id: "action-\(item.action.rawValue)", title: item.title,
                    isEnabled: item.isEnabled, action: item.action)
            }
        }
        return rows
    }

    private func makeItem(_ row: Row) -> NSMenuItem {
        if row.isSeparator { return .separator() }
        let item = NSMenuItem(title: row.title, action: nil, keyEquivalent: "")
        item.isEnabled = row.isEnabled
        item.indentationLevel = row.indentation
        if let action = row.action {
            item.action = #selector(actionSelected(_:))
            item.target = self
            item.representedObject = action.rawValue
            item.setAccessibilityIdentifier(
                CodexGaugeAccessibilityIdentifier.menuAction(action.rawValue)
            )
        }
        return item
    }

    @objc
    private func actionSelected(_ sender: NSMenuItem) {
        guard let rawValue = sender.representedObject as? String else {
            return
        }
        guard let action = QuotaMenuAction(rawValue: rawValue) else {
            return
        }
        perform(action)
    }
}
