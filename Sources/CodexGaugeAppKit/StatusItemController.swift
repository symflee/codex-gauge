import AppKit
import CodexGaugeCore

@MainActor
public protocol StatusItemPresenting: AnyObject {
    var effectiveAppearance: NSAppearance? { get }

    func setLength(_ length: CGFloat)
    func present(_ frame: RenderedStatusFrame)

    func setAppearanceChangeHandler(_ handler: @escaping @MainActor @Sendable () -> Void)
}

public extension StatusItemPresenting {
    func setAppearanceChangeHandler(_ handler: @escaping @MainActor @Sendable () -> Void) {}
}

@MainActor
public final class SystemStatusItemPresenter: StatusItemPresenting, StatusMenuPresenting {
    private let statusItem: NSStatusItem
    private let button: NSStatusBarButton?
    private var appearanceObservation: NSKeyValueObservation?
    private var appearanceDelivery: Task<Void, Never>?
    private var appearanceHandler: (@MainActor @Sendable () -> Void)?
    private var lastLength: CGFloat?
    private var lastAccessibilityLabel: String?

    public init(statusItem: NSStatusItem) {
        self.statusItem = statusItem
        button = statusItem.button
        configure(button)
    }

    public init(statusItem: NSStatusItem, button: NSStatusBarButton) {
        self.statusItem = statusItem
        self.button = button
        configure(button)
    }

    public convenience init(statusBar: NSStatusBar = .system) {
        let statusItem = statusBar.statusItem(withLength: NSStatusItem.variableLength)
        self.init(statusItem: statusItem)
    }

    public var effectiveAppearance: NSAppearance? {
        button?.effectiveAppearance
    }

    public func setLength(_ length: CGFloat) {
        guard lastLength != length else { return }
        lastLength = length
        statusItem.length = length
    }

    public func present(_ frame: RenderedStatusFrame) {
        guard let button else {
            return
        }
        if button.image !== frame.image {
            button.image = frame.image
        }
        if lastAccessibilityLabel != frame.accessibilityLabel {
            lastAccessibilityLabel = frame.accessibilityLabel
            button.setAccessibilityLabel(frame.accessibilityLabel)
        }
    }

    public func setMenu(_ menu: NSMenu) {
        statusItem.menu = menu
    }

    public func setAppearanceChangeHandler(_ handler: @escaping @MainActor @Sendable () -> Void) {
        appearanceDelivery?.cancel()
        appearanceDelivery = nil
        appearanceHandler = handler
        appearanceObservation = button?.observe(\.effectiveAppearance) { [weak self] _, _ in
            // AppKit view mutations and their synchronous KVO delivery run on the main thread.
            MainActor.assumeIsolated {
                self?.scheduleAppearanceDelivery()
            }
        }
    }

    private func scheduleAppearanceDelivery() {
        guard appearanceDelivery == nil else { return }
        appearanceDelivery = Task { @MainActor [weak self] in
            guard !Task.isCancelled, let self else { return }
            // Read the settled appearance after AppKit has restored its snapshot overrides.
            self.appearanceHandler?()
            self.appearanceDelivery = nil
        }
    }

    private func configure(_ button: NSStatusBarButton?) {
        guard let button else {
            return
        }
        button.setAccessibilityIdentifier(
            CodexGaugeAccessibilityIdentifier.statusItem
        )
        // Clearing an inherited title can itself change AppKit's image position.
        clearTitle(on: button)
        button.imagePosition = .imageOnly
        button.imageScaling = .scaleNone
    }

    private func clearTitle(on button: NSStatusBarButton) {
        button.title = ""
        button.attributedTitle = NSAttributedString(string: "")
    }
}

@MainActor
public final class StatusItemController {
    private static let horizontalPadding: CGFloat = 4

    private let presenter: StatusItemPresenting
    private var renderer: StatusFrameRendering
    private var sourceFrame: DisplayFrame?
    private var lastAppearance: StatusAppearanceVariant?
    private var lastRenderedFrame: RenderedStatusFrame?
    private var lastLength: CGFloat?
    private var rendererInvalidated = true

    public init(
        presenter: StatusItemPresenting,
        renderer: StatusFrameRendering = StatusFrameRenderer()
    ) {
        self.presenter = presenter
        self.renderer = renderer
        presenter.setAppearanceChangeHandler { [weak self] in
            self?.refreshAppearance()
        }
    }

    public func replaceRenderer(_ renderer: StatusFrameRendering) {
        self.renderer = renderer
        rendererInvalidated = true
    }

    public func setFrames(_ frames: [DisplayFrame]) {
        guard let frame = frames.first else { return }
        let appearance = renderer.appearanceVariant(for: presenter.effectiveAppearance)
        guard rendererInvalidated || sourceFrame != frame || lastAppearance != appearance else {
            return
        }
        sourceFrame = frame
        lastAppearance = appearance
        rendererInvalidated = false
        renderAndPresent(frame)
    }

    private func refreshAppearance() {
        let appearance = renderer.appearanceVariant(for: presenter.effectiveAppearance)
        guard let sourceFrame, lastAppearance != appearance else { return }
        lastAppearance = appearance
        renderAndPresent(sourceFrame)
    }

    private func renderAndPresent(_ frame: DisplayFrame) {
        let rendered = renderer.render(frame, appearance: presenter.effectiveAppearance)
        let length = ceil(rendered.measuredWidth) + Self.horizontalPadding
        if lastLength != length {
            lastLength = length
            presenter.setLength(length)
        }
        if let lastRenderedFrame, rendered.hasSamePresentation(as: lastRenderedFrame) { return }
        lastRenderedFrame = rendered
        presenter.present(rendered)
    }
}
