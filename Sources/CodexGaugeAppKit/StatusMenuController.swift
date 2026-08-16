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
    private let settings: @MainActor () -> Void
    private let quit: @MainActor () -> Void

    public init(
        refresh: @escaping @MainActor () -> Void,
        openCodex: @escaping @MainActor () -> Void,
        selectCodex: @escaping @MainActor () -> Void,
        settings: @escaping @MainActor () -> Void,
        quit: @escaping @MainActor () -> Void
    ) {
        self.refresh = refresh
        self.openCodex = openCodex
        self.selectCodex = selectCodex
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
        menu.removeAllItems()
        addProductSections(model.productSections)
        let actionGroups = model.actionGroups.filter { !$0.isEmpty }
        addSeparatorIfNeeded(hasFollowingItems: !actionGroups.isEmpty)
        addActionGroups(actionGroups)
    }

    public func menuWillOpen(_ menu: NSMenu) {
        _ = menu
        statusItemController.setPaused(true, for: .menuOpen)
    }

    public func menuDidClose(_ menu: NSMenu) {
        _ = menu
        statusItemController.setPaused(false, for: .menuOpen)
    }

    public func perform(_ action: QuotaMenuAction) {
        actions.perform(action)
    }

    private func addProductSections(_ sections: [QuotaMenuProductSection]) {
        for (index, section) in sections.enumerated() {
            guard index > 0 else {
                addProductSection(section)
                continue
            }
            menu.addItem(.separator())
            addProductSection(section)
        }
    }

    private func addProductSection(_ section: QuotaMenuProductSection) {
        menu.addItem(informationItem(title: section.title, indentation: 0))
        section.quotaRows.forEach { title in
            menu.addItem(informationItem(title: title, indentation: 1))
        }
        section.spendControlRows.forEach { title in
            menu.addItem(informationItem(title: title, indentation: 1))
        }
        section.statusRows.forEach { title in
            menu.addItem(informationItem(title: title, indentation: 1))
        }
    }

    private func informationItem(title: String, indentation: Int) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.isEnabled = false
        item.indentationLevel = indentation
        return item
    }

    private func addActionGroups(_ groups: [[QuotaMenuActionItem]]) {
        for (index, group) in groups.enumerated() {
            guard index > 0 else {
                addActions(group)
                continue
            }
            menu.addItem(.separator())
            addActions(group)
        }
    }

    private func addActions(_ actionItems: [QuotaMenuActionItem]) {
        actionItems.forEach { item in
            menu.addItem(actionItem(item))
        }
    }

    private func actionItem(_ model: QuotaMenuActionItem) -> NSMenuItem {
        let item = NSMenuItem(
            title: model.title,
            action: #selector(actionSelected(_:)),
            keyEquivalent: ""
        )
        item.target = self
        item.representedObject = model.action.rawValue
        item.isEnabled = true
        item.setAccessibilityIdentifier(
            CodexGaugeAccessibilityIdentifier.menuAction(model.action.rawValue)
        )
        return item
    }

    private func addSeparatorIfNeeded(hasFollowingItems: Bool) {
        guard !menu.items.isEmpty, hasFollowingItems else {
            return
        }
        menu.addItem(.separator())
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
