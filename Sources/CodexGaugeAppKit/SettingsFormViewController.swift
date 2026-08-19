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

    public var renderedQuotaAccessibilityLabels: [String] {
        quotaAccessibilityLabels
    }

    public var renderedSectionTitles: [String] {
        sectionLabels.map(\.stringValue)
    }

    public var renderedLanguageOptionTitles: [String] {
        languageControl.itemTitles
    }

    public var renderedProductOptionTitles: [String] {
        segmentTitles(productControl)
    }

    public var renderedSelectionOptionTitles: [String] {
        segmentTitles(selectionControl)
    }

    public var renderedRefreshOptionTitles: [String] {
        refreshControl.itemTitles
    }

    public var renderedLaunchAtLoginTitle: String {
        launchAtLoginButton.title
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
    private let languages = AppLanguage.allCases
    private var strings: SettingsStrings
    private var quotaButtons: [NSButton] = []
    private var quotaAccessibilityLabels: [String] = []

    private lazy var languageSectionLabel = makeSectionTitle(strings.languageSection)
    private lazy var displaySectionLabel = makeSectionTitle(strings.displaySection)
    private lazy var quotaSectionLabel = makeSectionTitle(strings.quotaSection)
    private lazy var refreshSectionLabel = makeSectionTitle(strings.refreshSection)
    private lazy var connectionSectionLabel = makeSectionTitle(strings.connectionSection)
    private lazy var languageControl = makeLanguageControl()
    private lazy var productControl = makeProductControl()
    private lazy var selectionControl = makeSelectionControl()
    private lazy var quotaStack = makeQuotaStack()
    private lazy var refreshControl = makeRefreshControl()
    private lazy var launchAtLoginButton = makeLaunchAtLoginButton()
    private lazy var launchAtLoginDetailLabel = makeLaunchAtLoginDetailLabel()
    private lazy var launchAtLoginRecoveryButton = makeConnectionActionButton(
        title: strings.openLaunchAtLoginSystemSettings,
        action: #selector(openLaunchAtLoginSystemSettings(_:))
    )
    private lazy var launchAtLoginStack = makeLaunchAtLoginStack()
    private lazy var connectionPathLabel = makeConnectionDetailLabel()
    private lazy var connectionVersionLabel = makeConnectionDetailLabel()
    private lazy var connectionStatusLabel = makeConnectionDetailLabel()
    private lazy var selectCodexButton = makeConnectionActionButton(
        title: strings.selectCodexAction,
        action: #selector(selectCodex(_:))
    )
    private lazy var copyDiagnosticsButton = makeConnectionActionButton(
        title: strings.copyDiagnosticsAction,
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
        strings = SettingsStrings(language: formState.language)
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
        let nextState = reducer.reduce(state: formState, event: event)
        replaceFormState(nextState)
        if isViewLoaded {
            render()
        }
        onFormValuesChanged(formState.formValues)
        forwardLaunchAtLoginRequest(event)
    }

    public func updateLanguage(_ language: AppLanguage) {
        guard formState.language != language else {
            return
        }
        let nextState = reducer.reduce(state: formState, event: .languageChanged(language))
        replaceFormState(nextState)
        guard isViewLoaded else {
            return
        }
        render()
    }

    private func replaceFormState(_ state: SettingsFormState) {
        if state.language != formState.language {
            strings = SettingsStrings(language: state.language)
        }
        formState = state
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
            languageSectionLabel,
            languageControl,
            displaySectionLabel,
            productControl,
            selectionControl,
            quotaSectionLabel,
            makeQuotaScrollView(),
            refreshSectionLabel,
            refreshControl,
            launchAtLoginStack,
            connectionSectionLabel,
            connectionPathLabel,
            connectionVersionLabel,
            connectionStatusLabel,
            makeConnectionActionStack(),
            projectNoticeLabel
        ])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        stack.translatesAutoresizingMaskIntoConstraints = false
        languageControl.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        productControl.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        selectionControl.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        refreshControl.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        launchAtLoginStack.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        projectNoticeLabel.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        return stack
    }

    private var sectionLabels: [NSTextField] {
        [
            languageSectionLabel,
            displaySectionLabel,
            quotaSectionLabel,
            refreshSectionLabel,
            connectionSectionLabel
        ]
    }

    private func makeLanguageControl() -> NSPopUpButton {
        let control = NSPopUpButton()
        control.addItems(withTitles: languages.map(strings.languageName))
        control.target = self
        control.action = #selector(languageChanged(_:))
        control.setAccessibilityIdentifier(
            CodexGaugeAccessibilityIdentifier.settingsLanguage
        )
        control.setAccessibilityLabel(strings.languageAccessibilityLabel)
        return control
    }

    private func makeProductControl() -> NSSegmentedControl {
        let labels = productModes.map(strings.productName)
        let control = NSSegmentedControl(
            labels: labels,
            trackingMode: .selectOne,
            target: self,
            action: #selector(productModeChanged(_:))
        )
        control.setAccessibilityLabel(strings.productAccessibilityLabel)
        return control
    }

    private func makeSelectionControl() -> NSSegmentedControl {
        let labels = selectionModes.map(strings.selectionModeName)
        let control = NSSegmentedControl(
            labels: labels,
            trackingMode: .selectOne,
            target: self,
            action: #selector(selectionModeChanged(_:))
        )
        control.setAccessibilityLabel(strings.selectionAccessibilityLabel)
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
        control.addItems(withTitles: refreshProfiles.map(strings.refreshProfileName))
        control.target = self
        control.action = #selector(refreshProfileChanged(_:))
        control.setAccessibilityLabel(strings.refreshAccessibilityLabel)
        return control
    }

    private func makeLaunchAtLoginButton() -> NSButton {
        let button = NSButton(
            checkboxWithTitle: strings.launchAtLogin,
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
        let label = NSTextField(wrappingLabelWithString: strings.projectNotice)
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
        renderLocalizedStrings()
        languageControl.selectItem(
            at: languages.firstIndex(of: formState.language) ?? 0
        )
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

    private func renderLocalizedStrings() {
        renderSectionTitles()
        renderLanguageControl()
        renderSegmentTitles(productControl, titles: productModes.map(strings.productName))
        renderSegmentTitles(selectionControl, titles: selectionModes.map(strings.selectionModeName))
        renderRefreshControl()
        renderActionTitles()
        renderAccessibilityLabels()
    }

    private func renderSectionTitles() {
        let titles = [
            strings.languageSection,
            strings.displaySection,
            strings.quotaSection,
            strings.refreshSection,
            strings.connectionSection
        ]
        zip(sectionLabels, titles).forEach { label, title in
            label.stringValue = title
        }
    }

    private func renderLanguageControl() {
        replaceItems(in: languageControl, with: languages.map(strings.languageName))
    }

    private func renderRefreshControl() {
        replaceItems(in: refreshControl, with: refreshProfiles.map(strings.refreshProfileName))
    }

    private func replaceItems(
        in control: NSPopUpButton,
        with titles: [String]
    ) {
        control.removeAllItems()
        control.addItems(withTitles: titles)
    }

    private func renderActionTitles() {
        launchAtLoginButton.title = strings.launchAtLogin
        launchAtLoginRecoveryButton.title = strings.openLaunchAtLoginSystemSettings
        selectCodexButton.title = strings.selectCodexAction
        copyDiagnosticsButton.title = strings.copyDiagnosticsAction
        projectNoticeLabel.stringValue = strings.projectNotice
    }

    private func renderAccessibilityLabels() {
        languageControl.setAccessibilityLabel(strings.languageAccessibilityLabel)
        productControl.setAccessibilityLabel(strings.productAccessibilityLabel)
        selectionControl.setAccessibilityLabel(strings.selectionAccessibilityLabel)
        refreshControl.setAccessibilityLabel(strings.refreshAccessibilityLabel)
    }

    private func renderSegmentTitles(
        _ control: NSSegmentedControl,
        titles: [String]
    ) {
        titles.enumerated().forEach { index, title in
            control.setLabel(title, forSegment: index)
        }
    }

    private func segmentTitles(_ control: NSSegmentedControl) -> [String] {
        (0..<control.segmentCount).map { control.label(forSegment: $0) ?? "" }
    }

    private func renderLaunchAtLogin() {
        launchAtLoginButton.state = launchAtLoginButtonState
        launchAtLoginButton.isEnabled = launchAtLoginState.allowsChanges
        launchAtLoginDetailLabel.stringValue = strings.launchAtLoginDetail(
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
        connectionPathLabel.stringValue = strings.connectionPath(connectionDiagnostics)
        connectionVersionLabel.stringValue = strings.connectionVersion(
            connectionDiagnostics.cliVersion?.value
        )
        connectionStatusLabel.stringValue = strings.connectionStatus(
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
        quotaAccessibilityLabels = presentation.quotaRows.map(
            strings.quotaAccessibilityLabel
        )
        quotaButtons.forEach(quotaStack.addArrangedSubview)
    }

    private func removeQuotaRows() {
        quotaStack.arrangedSubviews.forEach { subview in
            quotaStack.removeArrangedSubview(subview)
            subview.removeFromSuperview()
        }
        quotaButtons = []
        quotaAccessibilityLabels = []
    }

    private func makeQuotaButton(
        option: SettingsQuotaOption,
        index: Int,
        enabled: Bool
    ) -> NSButton {
        let button = NSButton(
            checkboxWithTitle: strings.quotaTitle(option),
            target: self,
            action: #selector(quotaSelectionChanged(_:))
        )
        button.tag = index
        button.state = option.isSelected ? .on : .off
        button.isEnabled = enabled
        button.setAccessibilityLabel(strings.quotaAccessibilityLabel(option))
        return button
    }

    private func makeEmptyQuotaLabel() -> NSTextField {
        let label = NSTextField(wrappingLabelWithString: strings.noQuotas)
        label.textColor = .secondaryLabelColor
        return label
    }

    @objc private func productModeChanged(_ sender: NSSegmentedControl) {
        guard productModes.indices.contains(sender.selectedSegment) else {
            return
        }
        apply(.productModeChanged(productModes[sender.selectedSegment]))
    }

    @objc private func languageChanged(_ sender: NSPopUpButton) {
        guard languages.indices.contains(sender.indexOfSelectedItem) else {
            return
        }
        apply(.languageChanged(languages[sender.indexOfSelectedItem]))
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

struct SettingsStrings {
    let localization: AppLocalization

    private let durationFormatter: SettingsDurationAccessibilityFormatter

    init(language: AppLanguage) {
        let localization = AppLocalization(language: language)
        self.localization = localization
        durationFormatter = SettingsDurationAccessibilityFormatter(
            vocabulary: SettingsDurationAccessibilityVocabulary(
                unknown: localization.string("settings.duration.unknown"),
                oneHour: localization.string("settings.duration.one-hour"),
                hours: localization.string("settings.duration.hours"),
                oneDay: localization.string("settings.duration.one-day"),
                days: localization.string("settings.duration.days"),
                oneWeek: localization.string("settings.duration.one-week"),
                weeks: localization.string("settings.duration.weeks")
            )
        )
    }

    var windowTitle: String { localized("settings.window.title") }
    var languageSection: String { localized("settings.section.language") }
    var displaySection: String { localized("settings.section.display") }
    var quotaSection: String { localized("settings.section.quotas") }
    var refreshSection: String { localized("settings.section.refresh") }
    var launchAtLogin: String { localized("settings.launch-at-login") }
    var openLaunchAtLoginSystemSettings: String {
        localized("settings.launch-at-login.open-system-settings")
    }
    var noQuotas: String { localized("settings.quota.empty") }
    var languageAccessibilityLabel: String {
        localized("settings.language.accessibility")
    }
    var productAccessibilityLabel: String {
        localized("settings.product.accessibility")
    }
    var selectionAccessibilityLabel: String {
        localized("settings.selection.accessibility")
    }
    var refreshAccessibilityLabel: String {
        localized("settings.refresh.accessibility")
    }
    var connectionSection: String { localized("settings.section.connection") }
    var selectCodexAction: String { localized("settings.connection.select") }
    var copyDiagnosticsAction: String {
        localized("settings.connection.copy-diagnostics")
    }
    var projectNotice: String { localized("settings.project-notice") }

    func languageName(_ language: AppLanguage) -> String {
        switch language {
        case .korean:
            localized("settings.language.korean")
        case .english:
            localized("settings.language.english")
        }
    }

    func productName(_ mode: DisplayProductMode) -> String {
        localized("settings.product.\(mode.rawValue)")
    }

    func connectionPath(
        _ diagnostics: ConnectionDiagnosticsSnapshot
    ) -> String {
        guard let sourceValue = diagnostics.executableSource else {
            return formatted(
                "settings.connection.path.format",
                localized("settings.connection.unavailable")
            )
        }
        let source = localized("settings.connection.source.\(sourceValue.rawValue)")
        let location = connectionLocation(diagnostics.path)
        let value = formatted(
            "settings.connection.path.value.format",
            source,
            location
        )
        return formatted("settings.connection.path.format", value)
    }

    private func connectionLocation(_ path: CodexPathSummary?) -> String {
        guard let path else {
            return localized("settings.connection.unavailable")
        }
        return path.basename ?? localized(
            "settings.connection.category.\(path.category.rawValue)"
        )
    }

    func connectionVersion(_ version: String?) -> String {
        formatted(
            "settings.connection.version.format",
            version ?? localized("settings.connection.unavailable")
        )
    }

    func connectionStatus(_ status: CodexConnectionStatus) -> String {
        let value = localized("settings.connection.status.\(status.rawValue)")
        return formatted("settings.connection.status.format", value)
    }

    func selectionModeName(_ mode: SettingsQuotaSelectionMode) -> String {
        switch mode {
        case .automatic:
            localized("settings.selection.automatic")
        case .manual:
            localized("settings.selection.manual")
        }
    }

    func refreshProfileName(_ profile: RefreshProfile) -> String {
        localized("settings.refresh.\(profile.rawValue)")
    }

    func launchAtLoginDetail(
        _ state: LaunchAtLoginSettingsState
    ) -> String {
        if let failure = state.failure {
            return launchAtLoginFailure(failure)
        }
        return localized("settings.launch-at-login.status.\(state.status.localizationKey)")
    }

    private func launchAtLoginFailure(
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

    func quotaTitle(_ option: SettingsQuotaOption) -> String {
        let base = formatted(
            "settings.quota.format",
            productName(option.identifier.product),
            DurationBadge(windowDurationMinutes: option.identifier.rawDurationMinutes).label
        )
        guard option.availability == .currentlyUnavailable else {
            return base
        }
        return formatted("settings.quota.unavailable.format", base)
    }

    func quotaAccessibilityLabel(_ option: SettingsQuotaOption) -> String {
        let base = formatted(
            "settings.quota.accessibility.format",
            productName(option.identifier.product),
            durationFormatter.format(option.identifier.rawDurationMinutes)
        )
        guard option.availability == .currentlyUnavailable else {
            return base
        }
        return formatted(
            "settings.quota.accessibility.unavailable.format",
            base
        )
    }

    func productName(_ product: UsageProduct) -> String {
        localized("settings.product.\(product.rawValue)")
    }

    private func formatted(_ key: String, _ arguments: CVarArg...) -> String {
        String(
            format: localized(key),
            locale: localization.locale,
            arguments: arguments
        )
    }

    private func localized(_ key: String) -> String {
        localization.string(key)
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
