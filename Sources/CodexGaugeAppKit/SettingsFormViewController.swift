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

    public var renderedGaugePresetOptionTitles: [String] {
        gaugePresetControl.itemArray.compactMap { item in
            item.isSeparatorItem ? nil : item.title
        }
    }

    public var renderedGaugePresetSeparatorCount: Int {
        gaugePresetControl.itemArray.filter(\.isSeparatorItem).count
    }

    public var renderedGaugePresetSwatchCount: Int {
        gaugePresetControl.itemArray.filter { item in
            !item.isSeparatorItem && item.image != nil
        }.count
    }

    public var renderedGaugeColorHexValues: [String] {
        let appearance = formState.statusGaugeAppearance
        return [appearance.borderColor.hexString, appearance.fillColor.hexString]
    }

    public var renderedGaugeColorAccessibilityValues: [String] {
        [gaugeBorderColorWell, gaugeFillColorWell].compactMap { colorWell in
            colorWell.accessibilityValue() as? String
        }
    }

    public var renderedGaugeColorLabels: [String] {
        [gaugeBorderLabel.stringValue, gaugeFillLabel.stringValue]
    }

    public var usesExpandedNonContinuousGaugeColorWells: Bool {
        let wells = [gaugeBorderColorWell, gaugeFillColorWell]
        return wells.allSatisfy { well in
            well.colorWellStyle == .expanded && !well.isContinuous
        }
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
    private let gaugePresets = StatusGaugePreset.allCases
    private var strings: SettingsStrings
    private var quotaButtons: [NSButton] = []
    private var quotaAccessibilityLabels: [String] = []

    private lazy var languageSectionLabel = makeSectionTitle(strings.languageSection)
    private lazy var displaySectionLabel = makeSectionTitle(strings.displaySection)
    private lazy var gaugeSectionLabel = makeSectionTitle(strings.gaugeSection)
    private lazy var quotaSectionLabel = makeSectionTitle(strings.quotaSection)
    private lazy var refreshSectionLabel = makeSectionTitle(strings.refreshSection)
    private lazy var connectionSectionLabel = makeSectionTitle(strings.connectionSection)
    private lazy var languageControl = makeLanguageControl()
    private lazy var productControl = makeProductControl()
    private lazy var selectionControl = makeSelectionControl()
    private lazy var gaugePresetControl = makeGaugePresetControl()
    private lazy var gaugeBorderLabel = makeGaugeColorLabel(strings.gaugeBorderColor)
    private lazy var gaugeFillLabel = makeGaugeColorLabel(strings.gaugeFillColor)
    private lazy var gaugeBorderColorWell = makeGaugeColorWell(
        action: #selector(gaugeBorderColorChanged(_:)),
        identifier: CodexGaugeAccessibilityIdentifier.settingsGaugeBorder
    )
    private lazy var gaugeFillColorWell = makeGaugeColorWell(
        action: #selector(gaugeFillColorChanged(_:)),
        identifier: CodexGaugeAccessibilityIdentifier.settingsGaugeFill
    )
    private lazy var gaugeColorStack = makeGaugeColorStack()
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

    private var customGaugePresetIndex: Int {
        gaugePresets.count + 1
    }

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
        let scrollView = makeOuterScrollView()
        rootView.addSubview(scrollView)
        NSLayoutConstraint.activate([
            scrollView.leadingAnchor.constraint(equalTo: rootView.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: rootView.trailingAnchor),
            scrollView.topAnchor.constraint(equalTo: rootView.topAnchor),
            scrollView.bottomAnchor.constraint(equalTo: rootView.bottomAnchor)
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

    public func performGaugeBorderColorSelection(_ color: NSColor) {
        gaugeBorderColorWell.color = color
        gaugeBorderColorChanged(gaugeBorderColorWell)
    }

    public func performGaugeFillColorSelection(_ color: NSColor) {
        gaugeFillColorWell.color = color
        gaugeFillColorChanged(gaugeFillColorWell)
    }

    public func deactivateGaugeColorWells() {
        guard isViewLoaded else {
            return
        }
        gaugeBorderColorWell.deactivate()
        gaugeFillColorWell.deactivate()
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
            gaugeSectionLabel,
            gaugePresetControl,
            gaugeColorStack,
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
        gaugePresetControl.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        gaugeColorStack.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        refreshControl.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        launchAtLoginStack.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        projectNoticeLabel.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        return stack
    }

    private var sectionLabels: [NSTextField] {
        [
            languageSectionLabel,
            displaySectionLabel,
            gaugeSectionLabel,
            quotaSectionLabel,
            refreshSectionLabel,
            connectionSectionLabel
        ]
    }

    private func makeOuterScrollView() -> NSScrollView {
        let scrollView = NSScrollView()
        let documentView = SettingsFormDocumentView()
        let contentStack = makeContentStack()
        configureOuterScrollView(scrollView, documentView: documentView)
        documentView.addSubview(contentStack)
        NSLayoutConstraint.activate([
            documentView.widthAnchor.constraint(equalTo: scrollView.contentView.widthAnchor),
            contentStack.leadingAnchor.constraint(equalTo: documentView.leadingAnchor, constant: 24),
            contentStack.trailingAnchor.constraint(equalTo: documentView.trailingAnchor, constant: -24),
            contentStack.topAnchor.constraint(equalTo: documentView.topAnchor, constant: 24),
            contentStack.bottomAnchor.constraint(equalTo: documentView.bottomAnchor, constant: -24)
        ])
        return scrollView
    }

    private func configureOuterScrollView(
        _ scrollView: NSScrollView,
        documentView: NSView
    ) {
        documentView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.documentView = documentView
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.borderType = .noBorder
        scrollView.drawsBackground = false
        scrollView.translatesAutoresizingMaskIntoConstraints = false
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

    private func makeGaugePresetControl() -> NSPopUpButton {
        let control = NSPopUpButton()
        control.target = self
        control.action = #selector(gaugePresetChanged(_:))
        control.setAccessibilityIdentifier(
            CodexGaugeAccessibilityIdentifier.settingsGaugePreset
        )
        control.setAccessibilityLabel(strings.gaugePresetAccessibilityLabel)
        return control
    }

    private func makeGaugeColorLabel(_ title: String) -> NSTextField {
        let label = NSTextField(labelWithString: title)
        label.widthAnchor.constraint(equalToConstant: 104).isActive = true
        return label
    }

    private func makeGaugeColorWell(
        action: Selector,
        identifier: String
    ) -> NSColorWell {
        let colorWell = NSColorWell()
        colorWell.colorWellStyle = .expanded
        colorWell.isContinuous = false
        colorWell.target = self
        colorWell.action = action
        colorWell.setAccessibilityIdentifier(identifier)
        colorWell.setContentHuggingPriority(.defaultLow, for: .horizontal)
        return colorWell
    }

    private func makeGaugeColorStack() -> NSStackView {
        let stack = NSStackView(views: [
            makeGaugeColorRow(label: gaugeBorderLabel, colorWell: gaugeBorderColorWell),
            makeGaugeColorRow(label: gaugeFillLabel, colorWell: gaugeFillColorWell)
        ])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 6
        return stack
    }

    private func makeGaugeColorRow(
        label: NSTextField,
        colorWell: NSColorWell
    ) -> NSStackView {
        let row = NSStackView(views: [label, colorWell])
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 8
        row.distribution = .fill
        colorWell.widthAnchor.constraint(greaterThanOrEqualToConstant: 220).isActive = true
        return row
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
        renderGaugeAppearance()
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
        renderGaugeLocalizedStrings()
        renderRefreshControl()
        renderActionTitles()
        renderAccessibilityLabels()
    }

    private func renderSectionTitles() {
        let titles = [
            strings.languageSection,
            strings.displaySection,
            strings.gaugeSection,
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

    private func renderGaugeLocalizedStrings() {
        gaugeBorderLabel.stringValue = strings.gaugeBorderColor
        gaugeFillLabel.stringValue = strings.gaugeFillColor
        rebuildGaugePresetItems()
    }

    private func rebuildGaugePresetItems() {
        gaugePresetControl.removeAllItems()
        gaugePresets.forEach(addGaugePresetItem)
        gaugePresetControl.menu?.addItem(.separator())
        addGaugeCustomItem()
    }

    private func addGaugePresetItem(_ preset: StatusGaugePreset) {
        gaugePresetControl.addItem(withTitle: strings.gaugePresetName(preset))
        gaugePresetControl.lastItem?.image = makeGaugeSwatch(
            borderColor: preset.borderColor,
            fillColor: preset.fillColor
        )
    }

    private func addGaugeCustomItem() {
        let appearance = formState.statusGaugeAppearance
        gaugePresetControl.addItem(withTitle: strings.gaugeCustom)
        gaugePresetControl.lastItem?.image = makeGaugeSwatch(
            borderColor: appearance.borderColor,
            fillColor: appearance.fillColor
        )
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
        gaugePresetControl.setAccessibilityLabel(strings.gaugePresetAccessibilityLabel)
        gaugeBorderColorWell.setAccessibilityLabel(strings.gaugeBorderColor)
        gaugeFillColorWell.setAccessibilityLabel(strings.gaugeFillColor)
        refreshControl.setAccessibilityLabel(strings.refreshAccessibilityLabel)
    }

    private func renderGaugeAppearance() {
        let appearance = formState.statusGaugeAppearance
        selectGaugePreset(for: appearance)
        renderGaugeColorWell(gaugeBorderColorWell, color: appearance.borderColor)
        renderGaugeColorWell(gaugeFillColorWell, color: appearance.fillColor)
    }

    private func selectGaugePreset(for appearance: StatusGaugeAppearance) {
        switch appearance {
        case .preset(let preset):
            gaugePresetControl.selectItem(
                at: gaugePresets.firstIndex(of: preset) ?? 0
            )
        case .custom:
            gaugePresetControl.selectItem(at: customGaugePresetIndex)
        }
    }

    private func renderGaugeColorWell(
        _ colorWell: NSColorWell,
        color: StatusGaugeColor
    ) {
        colorWell.color = Self.appKitColor(color)
        colorWell.setAccessibilityValue(color.hexString)
    }

    private func makeGaugeSwatch(
        borderColor: StatusGaugeColor,
        fillColor: StatusGaugeColor
    ) -> NSImage {
        let size = NSSize(width: 20, height: 12)
        let border = Self.appKitColor(borderColor)
        let fill = Self.appKitColor(fillColor)
        let image = NSImage(size: size, flipped: false) { rect in
            Self.drawGaugeSwatch(rect, borderColor: border, fillColor: fill)
            return true
        }
        image.isTemplate = false
        return image
    }

    private static func drawGaugeSwatch(
        _ rect: NSRect,
        borderColor: NSColor,
        fillColor: NSColor
    ) {
        let swatchRect = rect.insetBy(dx: 1, dy: 1)
        let path = NSBezierPath(roundedRect: swatchRect, xRadius: 3, yRadius: 3)
        fillColor.setFill()
        path.fill()
        borderColor.setStroke()
        path.lineWidth = 2
        path.stroke()
    }

    private static func appKitColor(_ color: StatusGaugeColor) -> NSColor {
        NSColor(
            srgbRed: CGFloat(color.red) / 255,
            green: CGFloat(color.green) / 255,
            blue: CGFloat(color.blue) / 255,
            alpha: 1
        )
    }

    private func normalizedGaugeColor(_ color: NSColor) -> StatusGaugeColor? {
        guard let color = color.usingColorSpace(.sRGB),
              let red = normalizedColorByte(color.redComponent),
              let green = normalizedColorByte(color.greenComponent),
              let blue = normalizedColorByte(color.blueComponent) else {
            return nil
        }
        return StatusGaugeColor(red: red, green: green, blue: blue)
    }

    private func normalizedColorByte(_ component: CGFloat) -> UInt8? {
        guard component.isFinite else {
            return nil
        }
        let clamped = min(max(component, 0), 1)
        return UInt8((clamped * 255).rounded())
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

    @objc private func gaugePresetChanged(_ sender: NSPopUpButton) {
        let index = sender.indexOfSelectedItem
        if gaugePresets.indices.contains(index) {
            apply(.statusGaugePresetChanged(gaugePresets[index]))
            return
        }
        guard index == customGaugePresetIndex else {
            renderGaugeAppearance()
            return
        }
        apply(.statusGaugeCustomSelected)
    }

    @objc private func gaugeBorderColorChanged(_ sender: NSColorWell) {
        guard let color = normalizedGaugeColor(sender.color) else {
            renderGaugeAppearance()
            return
        }
        apply(.statusGaugeBorderColorChanged(color))
    }

    @objc private func gaugeFillColorChanged(_ sender: NSColorWell) {
        guard let color = normalizedGaugeColor(sender.color) else {
            renderGaugeAppearance()
            return
        }
        apply(.statusGaugeFillColorChanged(color))
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
    var gaugeSection: String { localized("settings.section.gauge-colors") }
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
    var gaugePresetAccessibilityLabel: String {
        localized("settings.gauge.preset.accessibility")
    }
    var gaugeBorderColor: String { localized("settings.gauge.border") }
    var gaugeFillColor: String { localized("settings.gauge.fill") }
    var gaugeCustom: String { localized("settings.gauge.preset.custom") }
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

    func gaugePresetName(_ preset: StatusGaugePreset) -> String {
        localized("settings.gauge.preset.\(preset.rawValue)")
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

private final class SettingsFormDocumentView: NSView {
    override var isFlipped: Bool {
        true
    }
}
