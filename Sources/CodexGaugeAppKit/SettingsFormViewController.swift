import AppKit
import CodexGaugeCore
import CodexGaugeRefresh
import CodexGaugeSettings

@MainActor
public final class SettingsFormViewController: NSViewController {
    public private(set) var formState: SettingsFormState
    public private(set) var connectionDiagnostics: ConnectionDiagnosticsSnapshot
    public private(set) var launchAtLoginState: LaunchAtLoginSettingsState

    public var renderedQuotaOptionTitles: [String] {
        quotaButtons.map(\.title)
    }

    public var renderedConnectionDetailTexts: [String] {
        [connectionPathLabel, connectionVersionLabel, connectionStatusLabel].map(\.stringValue)
    }

    public var renderedConnectionActionTitles: [String] {
        [selectCodexButton.title, copyDiagnosticsButton.title]
    }

    public var renderedProjectNoticeText: String {
        projectNoticeLabel.stringValue
    }

    public var renderedLaunchAtLoginToggleValue: LaunchAtLoginToggleValue {
        switch launchAtLoginButton.state {
        case .on:
            .on
        case .mixed:
            .mixed
        default:
            .off
        }
    }

    public var isLaunchAtLoginToggleEnabled: Bool {
        launchAtLoginButton.isEnabled
    }

    public var renderedLaunchAtLoginDetailText: String {
        launchAtLoginDetailLabel.stringValue
    }

    public var renderedLaunchAtLoginRecoveryActionTitle: String? {
        launchAtLoginRecoveryButton.isHidden
            ? nil
            : launchAtLoginRecoveryButton.title
    }

    private let reducer = SettingsFormReducer()
    private let presenter = SettingsFormPresenter()
    private let onFormValuesChanged: (SettingsFormValues) -> Void
    private let onSelectCodex: () -> Void
    private let onCopyDiagnostics: () -> Void
    private let onOpenLaunchAtLoginSystemSettings: () -> Void
    private let onLaunchAtLoginIntentRequested: (Bool) -> Void
    private let productModes = DisplayProductMode.allCases
    private let selectionModes: [SettingsQuotaSelectionMode] = [.automatic, .manual]
    private let refreshProfiles = RefreshProfile.allCases
    private var quotaButtons: [NSButton] = []

    private lazy var productControl = makeProductControl()
    private lazy var selectionControl = makeSelectionControl()
    private lazy var quotaStack = makeQuotaStack()
    private lazy var refreshControl = makeRefreshControl()
    private lazy var launchAtLoginButton = makeLaunchAtLoginButton()
    private lazy var launchAtLoginDetailLabel = makeLaunchAtLoginDetailLabel()
    private lazy var launchAtLoginRecoveryButton = makeConnectionActionButton(
        title: SettingsStrings.openLaunchAtLoginSystemSettings,
        action: #selector(openLaunchAtLoginSystemSettings(_:))
    )
    private lazy var launchAtLoginStack = makeLaunchAtLoginStack()
    private lazy var connectionPathLabel = makeConnectionDetailLabel()
    private lazy var connectionVersionLabel = makeConnectionDetailLabel()
    private lazy var connectionStatusLabel = makeConnectionDetailLabel()
    private lazy var selectCodexButton = makeConnectionActionButton(
        title: SettingsStrings.selectCodexAction,
        action: #selector(selectCodex(_:))
    )
    private lazy var copyDiagnosticsButton = makeConnectionActionButton(
        title: SettingsStrings.copyDiagnosticsAction,
        action: #selector(copyDiagnostics(_:))
    )
    private lazy var projectNoticeLabel = makeProjectNoticeLabel()

    public init(
        formState: SettingsFormState,
        connectionDiagnostics: ConnectionDiagnosticsSnapshot = .checking,
        launchAtLoginState: LaunchAtLoginSettingsState = LaunchAtLoginSettingsState(
            status: .disabled
        ),
        onSelectCodex: @escaping () -> Void = {},
        onCopyDiagnostics: @escaping () -> Void = {},
        onOpenLaunchAtLoginSystemSettings: @escaping () -> Void = {},
        onLaunchAtLoginIntentRequested: @escaping (Bool) -> Void = { _ in },
        onFormValuesChanged: @escaping (SettingsFormValues) -> Void
    ) {
        self.formState = formState
        self.connectionDiagnostics = connectionDiagnostics
        self.launchAtLoginState = launchAtLoginState
        self.onSelectCodex = onSelectCodex
        self.onCopyDiagnostics = onCopyDiagnostics
        self.onOpenLaunchAtLoginSystemSettings = onOpenLaunchAtLoginSystemSettings
        self.onLaunchAtLoginIntentRequested = onLaunchAtLoginIntentRequested
        self.onFormValuesChanged = onFormValuesChanged
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    public required init?(coder: NSCoder) {
        nil
    }

    public override func loadView() {
        let rootView = NSView(frame: NSRect(x: 0, y: 0, width: 440, height: 720))
        let contentStack = makeContentStack()
        rootView.addSubview(contentStack)
        NSLayoutConstraint.activate([
            contentStack.leadingAnchor.constraint(equalTo: rootView.leadingAnchor, constant: 24),
            contentStack.trailingAnchor.constraint(equalTo: rootView.trailingAnchor, constant: -24),
            contentStack.topAnchor.constraint(equalTo: rootView.topAnchor, constant: 24),
            contentStack.bottomAnchor.constraint(lessThanOrEqualTo: rootView.bottomAnchor, constant: -24)
        ])
        view = rootView
        render()
    }

    public func apply(_ event: SettingsFormEvent) {
        formState = reducer.reduce(state: formState, event: event)
        if isViewLoaded {
            render()
        }
        onFormValuesChanged(formState.formValues)
        forwardLaunchAtLoginRequest(event)
    }

    public func applyConnectionDiagnostics(
        _ diagnostics: ConnectionDiagnosticsSnapshot
    ) {
        connectionDiagnostics = diagnostics
        guard isViewLoaded else {
            return
        }
        renderConnectionDiagnostics()
    }

    public func applyLaunchAtLoginState(
        _ state: LaunchAtLoginSettingsState
    ) {
        launchAtLoginState = state
        guard isViewLoaded else {
            return
        }
        renderLaunchAtLogin()
    }

    public func updateDiscoveredQuotaIDs(_ identifiers: Set<QuotaSelectionID>) {
        formState = reducer.reduce(
            state: formState,
            event: .discoveredQuotaIDsChanged(identifiers)
        )
        guard isViewLoaded else {
            return
        }
        renderQuotaRows(presenter.present(formState))
    }

    public func performConnectionAction(_ action: SettingsConnectionAction) {
        switch action {
        case .selectCodex:
            onSelectCodex()
        case .copyDiagnostics:
            onCopyDiagnostics()
        }
    }

    public func performLaunchAtLoginRecoveryAction() {
        guard launchAtLoginState.showsSystemSettingsRecovery else {
            return
        }
        onOpenLaunchAtLoginSystemSettings()
    }

    public func performLaunchAtLoginToggleClick() {
        launchAtLoginButton.performClick(nil)
    }

    private func forwardLaunchAtLoginRequest(_ event: SettingsFormEvent) {
        guard case .launchAtLoginIntentChanged(let enabled) = event else {
            return
        }
        onLaunchAtLoginIntentRequested(enabled)
    }

    private func makeContentStack() -> NSStackView {
        let stack = NSStackView(views: [
            makeSectionTitle(SettingsStrings.displaySection),
            productControl,
            selectionControl,
            makeSectionTitle(SettingsStrings.quotaSection),
            makeQuotaScrollView(),
            makeSectionTitle(SettingsStrings.refreshSection),
            refreshControl,
            launchAtLoginStack,
            makeSectionTitle(SettingsStrings.connectionSection),
            connectionPathLabel,
            connectionVersionLabel,
            connectionStatusLabel,
            makeConnectionActionStack(),
            projectNoticeLabel
        ])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 12
        stack.translatesAutoresizingMaskIntoConstraints = false
        productControl.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        selectionControl.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        refreshControl.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        launchAtLoginStack.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        projectNoticeLabel.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        return stack
    }

    private func makeProductControl() -> NSSegmentedControl {
        let labels = productModes.map(SettingsStrings.productName)
        let control = NSSegmentedControl(
            labels: labels,
            trackingMode: .selectOne,
            target: self,
            action: #selector(productModeChanged(_:))
        )
        control.setAccessibilityLabel(SettingsStrings.productAccessibilityLabel)
        return control
    }

    private func makeSelectionControl() -> NSSegmentedControl {
        let labels = selectionModes.map(SettingsStrings.selectionModeName)
        let control = NSSegmentedControl(
            labels: labels,
            trackingMode: .selectOne,
            target: self,
            action: #selector(selectionModeChanged(_:))
        )
        control.setAccessibilityLabel(SettingsStrings.selectionAccessibilityLabel)
        return control
    }

    private func makeQuotaStack() -> NSStackView {
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 6
        stack.translatesAutoresizingMaskIntoConstraints = false
        return stack
    }

    private func makeQuotaScrollView() -> NSScrollView {
        let documentView = NSView()
        documentView.translatesAutoresizingMaskIntoConstraints = false
        documentView.addSubview(quotaStack)
        NSLayoutConstraint.activate([
            quotaStack.leadingAnchor.constraint(equalTo: documentView.leadingAnchor, constant: 8),
            quotaStack.trailingAnchor.constraint(equalTo: documentView.trailingAnchor, constant: -8),
            quotaStack.topAnchor.constraint(equalTo: documentView.topAnchor, constant: 8),
            quotaStack.bottomAnchor.constraint(lessThanOrEqualTo: documentView.bottomAnchor, constant: -8),
            documentView.widthAnchor.constraint(equalToConstant: 372)
        ])

        let scrollView = NSScrollView()
        scrollView.documentView = documentView
        scrollView.hasVerticalScroller = true
        scrollView.borderType = .bezelBorder
        scrollView.drawsBackground = false
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.widthAnchor.constraint(equalToConstant: 392).isActive = true
        scrollView.heightAnchor.constraint(equalToConstant: 150).isActive = true
        return scrollView
    }

    private func makeRefreshControl() -> NSPopUpButton {
        let control = NSPopUpButton()
        control.addItems(withTitles: refreshProfiles.map(SettingsStrings.refreshProfileName))
        control.target = self
        control.action = #selector(refreshProfileChanged(_:))
        control.setAccessibilityLabel(SettingsStrings.refreshAccessibilityLabel)
        return control
    }

    private func makeLaunchAtLoginButton() -> NSButton {
        let button = NSButton(
            checkboxWithTitle: SettingsStrings.launchAtLogin,
            target: self,
            action: #selector(launchAtLoginChanged(_:))
        )
        button.allowsMixedState = true
        return button
    }

    private func makeLaunchAtLoginStack() -> NSStackView {
        let stack = NSStackView(views: [
            launchAtLoginButton,
            launchAtLoginDetailLabel,
            launchAtLoginRecoveryButton
        ])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 4
        return stack
    }

    private func makeLaunchAtLoginDetailLabel() -> NSTextField {
        let label = NSTextField(wrappingLabelWithString: "")
        label.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        label.textColor = .secondaryLabelColor
        label.maximumNumberOfLines = 2
        return label
    }

    private func makeConnectionDetailLabel() -> NSTextField {
        let label = NSTextField(wrappingLabelWithString: "")
        label.maximumNumberOfLines = 2
        return label
    }

    private func makeConnectionActionButton(
        title: String,
        action: Selector
    ) -> NSButton {
        NSButton(title: title, target: self, action: action)
    }

    private func makeConnectionActionStack() -> NSStackView {
        let stack = NSStackView(views: [selectCodexButton, copyDiagnosticsButton])
        stack.orientation = .horizontal
        stack.spacing = 8
        return stack
    }

    private func makeProjectNoticeLabel() -> NSTextField {
        let label = NSTextField(wrappingLabelWithString: SettingsStrings.projectNotice)
        label.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        label.textColor = .secondaryLabelColor
        label.maximumNumberOfLines = 0
        return label
    }

    private func makeSectionTitle(_ title: String) -> NSTextField {
        let label = NSTextField(labelWithString: title)
        label.font = .systemFont(ofSize: NSFont.systemFontSize, weight: .semibold)
        return label
    }

    private func render() {
        productControl.selectedSegment = productModes.firstIndex(of: formState.productMode) ?? 0
        selectionControl.selectedSegment = selectionModes.firstIndex(
            of: formState.quotaSelectionMode
        ) ?? 0
        refreshControl.selectItem(
            at: refreshProfiles.firstIndex(of: formState.refreshProfile) ?? 0
        )
        renderLaunchAtLogin()
        renderQuotaRows(presenter.present(formState))
        renderConnectionDiagnostics()
    }

    private func renderLaunchAtLogin() {
        launchAtLoginButton.state = launchAtLoginButtonState
        launchAtLoginButton.isEnabled = launchAtLoginState.allowsChanges
        launchAtLoginDetailLabel.stringValue = SettingsStrings.launchAtLoginDetail(
            launchAtLoginState
        )
        launchAtLoginRecoveryButton.isHidden = !launchAtLoginState
            .showsSystemSettingsRecovery
    }

    private var launchAtLoginButtonState: NSControl.StateValue {
        switch launchAtLoginState.toggleValue {
        case .off:
            .off
        case .on:
            .on
        case .mixed:
            .mixed
        }
    }

    private func renderConnectionDiagnostics() {
        connectionPathLabel.stringValue = SettingsStrings.connectionPath(connectionDiagnostics)
        connectionVersionLabel.stringValue = SettingsStrings.connectionVersion(
            connectionDiagnostics.cliVersion?.value
        )
        connectionStatusLabel.stringValue = SettingsStrings.connectionStatus(
            connectionDiagnostics.connectionStatus
        )
    }

    private func renderQuotaRows(_ presentation: SettingsFormPresentation) {
        removeQuotaRows()
        guard !presentation.showsEmptyQuotaMessage else {
            quotaStack.addArrangedSubview(makeEmptyQuotaLabel())
            return
        }
        quotaButtons = presentation.quotaRows.enumerated().map { index, option in
            makeQuotaButton(option: option, index: index, enabled: presentation.quotaChoicesEnabled)
        }
        quotaButtons.forEach(quotaStack.addArrangedSubview)
    }

    private func removeQuotaRows() {
        quotaStack.arrangedSubviews.forEach { subview in
            quotaStack.removeArrangedSubview(subview)
            subview.removeFromSuperview()
        }
        quotaButtons = []
    }

    private func makeQuotaButton(
        option: SettingsQuotaOption,
        index: Int,
        enabled: Bool
    ) -> NSButton {
        let button = NSButton(
            checkboxWithTitle: SettingsStrings.quotaTitle(option),
            target: self,
            action: #selector(quotaSelectionChanged(_:))
        )
        button.tag = index
        button.state = option.isSelected ? .on : .off
        button.isEnabled = enabled
        button.setAccessibilityLabel(SettingsStrings.quotaAccessibilityLabel(option))
        return button
    }

    private func makeEmptyQuotaLabel() -> NSTextField {
        let label = NSTextField(wrappingLabelWithString: SettingsStrings.noQuotas)
        label.textColor = .secondaryLabelColor
        return label
    }

    @objc private func productModeChanged(_ sender: NSSegmentedControl) {
        guard productModes.indices.contains(sender.selectedSegment) else {
            return
        }
        apply(.productModeChanged(productModes[sender.selectedSegment]))
    }

    @objc private func selectionModeChanged(_ sender: NSSegmentedControl) {
        guard selectionModes.indices.contains(sender.selectedSegment) else {
            return
        }
        apply(.quotaSelectionModeChanged(selectionModes[sender.selectedSegment]))
    }

    @objc private func quotaSelectionChanged(_ sender: NSButton) {
        let options = formState.quotaOptions
        guard options.indices.contains(sender.tag) else {
            return
        }
        apply(
            .quotaSelectionChanged(
                options[sender.tag].identifier,
                isSelected: sender.state == .on
            )
        )
    }

    @objc private func refreshProfileChanged(_ sender: NSPopUpButton) {
        guard refreshProfiles.indices.contains(sender.indexOfSelectedItem) else {
            return
        }
        apply(.refreshProfileChanged(refreshProfiles[sender.indexOfSelectedItem]))
    }

    @objc private func launchAtLoginChanged(_ sender: NSButton) {
        _ = sender
        apply(.launchAtLoginIntentChanged(requestedLaunchAtLoginValue))
    }

    private var requestedLaunchAtLoginValue: Bool {
        launchAtLoginState.toggleValue == .off
    }

    @objc private func openLaunchAtLoginSystemSettings(_ sender: NSButton) {
        _ = sender
        performLaunchAtLoginRecoveryAction()
    }

    @objc private func selectCodex(_ sender: NSButton) {
        _ = sender
        performConnectionAction(.selectCodex)
    }

    @objc private func copyDiagnostics(_ sender: NSButton) {
        _ = sender
        performConnectionAction(.copyDiagnostics)
    }
}

public enum SettingsConnectionAction: Equatable, Sendable {
    case selectCodex
    case copyDiagnostics
}

enum SettingsStrings {
    static let windowTitle = localized("settings.window.title")
    static let displaySection = localized("settings.section.display")
    static let quotaSection = localized("settings.section.quotas")
    static let refreshSection = localized("settings.section.refresh")
    static let launchAtLogin = localized("settings.launch-at-login")
    static let openLaunchAtLoginSystemSettings = localized(
        "settings.launch-at-login.open-system-settings"
    )
    static let noQuotas = localized("settings.quota.empty")
    static let productAccessibilityLabel = localized("settings.product.accessibility")
    static let selectionAccessibilityLabel = localized("settings.selection.accessibility")
    static let refreshAccessibilityLabel = localized("settings.refresh.accessibility")
    static let connectionSection = localized("settings.section.connection")
    static let selectCodexAction = localized("settings.connection.select")
    static let copyDiagnosticsAction = localized("settings.connection.copy-diagnostics")
    static let projectNotice = localized("settings.project-notice")

    private static let durationFormatter = SettingsDurationAccessibilityFormatter(
        vocabulary: SettingsDurationAccessibilityVocabulary(
            unknown: localized("settings.duration.unknown"),
            oneHour: localized("settings.duration.one-hour"),
            hours: localized("settings.duration.hours"),
            oneDay: localized("settings.duration.one-day"),
            days: localized("settings.duration.days"),
            oneWeek: localized("settings.duration.one-week"),
            weeks: localized("settings.duration.weeks")
        )
    )

    static func productName(_ mode: DisplayProductMode) -> String {
        localized("settings.product.\(mode.rawValue)")
    }

    static func connectionPath(
        _ diagnostics: ConnectionDiagnosticsSnapshot
    ) -> String {
        guard let sourceValue = diagnostics.executableSource else {
            return String(
                format: localized("settings.connection.path.format"),
                localized("settings.connection.unavailable")
            )
        }
        let source = localized("settings.connection.source.\(sourceValue.rawValue)")
        let location = connectionLocation(diagnostics.path)
        let value = String(
            format: localized("settings.connection.path.value.format"),
            source,
            location
        )
        return String(format: localized("settings.connection.path.format"), value)
    }

    private static func connectionLocation(_ path: CodexPathSummary?) -> String {
        guard let path else {
            return localized("settings.connection.unavailable")
        }
        return path.basename ?? localized(
            "settings.connection.category.\(path.category.rawValue)"
        )
    }

    static func connectionVersion(_ version: String?) -> String {
        String(
            format: localized("settings.connection.version.format"),
            version ?? localized("settings.connection.unavailable")
        )
    }

    static func connectionStatus(_ status: CodexConnectionStatus) -> String {
        let value = localized("settings.connection.status.\(status.rawValue)")
        return String(format: localized("settings.connection.status.format"), value)
    }

    static func selectionModeName(_ mode: SettingsQuotaSelectionMode) -> String {
        switch mode {
        case .automatic:
            localized("settings.selection.automatic")
        case .manual:
            localized("settings.selection.manual")
        }
    }

    static func refreshProfileName(_ profile: RefreshProfile) -> String {
        localized("settings.refresh.\(profile.rawValue)")
    }

    static func launchAtLoginDetail(
        _ state: LaunchAtLoginSettingsState
    ) -> String {
        if let failure = state.failure {
            return launchAtLoginFailure(failure)
        }
        return localized("settings.launch-at-login.status.\(state.status.localizationKey)")
    }

    private static func launchAtLoginFailure(
        _ failure: LaunchAtLoginError
    ) -> String {
        switch failure {
        case .serviceUnavailable:
            localized("settings.launch-at-login.status.unavailable")
        case .registrationFailed:
            localized("settings.launch-at-login.failure.registration")
        case .unregistrationFailed:
            localized("settings.launch-at-login.failure.unregistration")
        }
    }

    static func quotaTitle(_ option: SettingsQuotaOption) -> String {
        let base = String(
            format: localized("settings.quota.format"),
            productName(option.identifier.product),
            DurationBadge(windowDurationMinutes: option.identifier.rawDurationMinutes).label
        )
        guard option.availability == .currentlyUnavailable else {
            return base
        }
        return String(format: localized("settings.quota.unavailable.format"), base)
    }

    static func quotaAccessibilityLabel(_ option: SettingsQuotaOption) -> String {
        let base = String(
            format: localized("settings.quota.accessibility.format"),
            productName(option.identifier.product),
            durationFormatter.format(option.identifier.rawDurationMinutes)
        )
        guard option.availability == .currentlyUnavailable else {
            return base
        }
        return String(
            format: localized("settings.quota.accessibility.unavailable.format"),
            base
        )
    }

    static func productName(_ product: UsageProduct) -> String {
        localized("settings.product.\(product.rawValue)")
    }

    private static func localized(_ key: String) -> String {
        NSLocalizedString(key, bundle: .module, comment: "")
    }
}

private extension LaunchAtLoginStatus {
    var localizationKey: String {
        switch self {
        case .disabled:
            "disabled"
        case .enabled:
            "enabled"
        case .requiresApproval:
            "requires-approval"
        case .unavailable:
            "unavailable"
        }
    }
}
