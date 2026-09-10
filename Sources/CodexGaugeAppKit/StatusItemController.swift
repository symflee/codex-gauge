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
    private static let horizontalPadding: CGFloat = 8

    private let presenter: StatusItemPresenting
    private var renderer: StatusFrameRendering
    private let rotation: StatusFrameRotation
    private let prototypeBuilder = StatusWidthPrototypeBuilder()
    private let durationPresentationPolicy = StatusDurationPresentationPolicy()
    private var sourceFrames: [DisplayFrame] = []
    private var lastAppearance: StatusAppearanceVariant?
    private var callerPrototypes: [DisplayFrame] = []
    private var cachedPrototypeInputs: [DisplayFrame] = []
    private var cachedPrototypes: [RenderedStatusFrame] = []
    private var lastLength: CGFloat?
    private var rendererInvalidated = true

    public init(
        presenter: StatusItemPresenting,
        renderer: StatusFrameRendering = StatusFrameRenderer(),
        scheduler: StatusRotationScheduling = RunLoopStatusRotationScheduler()
    ) {
        self.presenter = presenter
        self.renderer = renderer
        rotation = StatusFrameRotation(scheduler: scheduler) { frame in
            presenter.present(frame)
        }
        presenter.setAppearanceChangeHandler { [weak self] in
            self?.refreshAppearance()
        }
    }

    public func replaceRenderer(_ renderer: StatusFrameRendering) {
        self.renderer = renderer
        rendererInvalidated = true
        cachedPrototypeInputs = []
        cachedPrototypes = []
    }

    public func setFrames(
        _ frames: [DisplayFrame],
        widthPrototypes: [DisplayFrame] = []
    ) {
        let appearance = renderer.appearanceVariant(for: presenter.effectiveAppearance)
        guard rendererInvalidated || sourceFrames != frames
            || callerPrototypes != widthPrototypes || lastAppearance != appearance else {
            return
        }
        let sameSelection = sourceFrames.map(selectionIdentity) == frames.map(selectionIdentity)
        let configurationChanged = rendererInvalidated
        sourceFrames = frames
        callerPrototypes = widthPrototypes
        lastAppearance = appearance
        rendererInvalidated = false
        let durationMode = durationPresentationPolicy.mode(for: frames)
        let renderedFrames = render(frames, durationMode: durationMode)
        let prototypes = prototypeBuilder.prototypes(for: frames) + widthPrototypes
        if configurationChanged || prototypes != cachedPrototypeInputs {
            cachedPrototypeInputs = prototypes
            cachedPrototypes = render(prototypes, durationMode: durationMode)
        }
        let widthCandidates = renderedFrames + cachedPrototypes
        updateLength(using: widthCandidates)
        if sameSelection {
            rotation.replaceRenderedFrames(renderedFrames)
        } else {
            rotation.setFrames(renderedFrames)
        }
    }

    private func refreshAppearance() {
        let appearance = renderer.appearanceVariant(for: presenter.effectiveAppearance)
        guard !sourceFrames.isEmpty, lastAppearance != appearance else { return }
        lastAppearance = appearance
        let durationMode = durationPresentationPolicy.mode(for: sourceFrames)
        rotation.replaceRenderedFrames(render(sourceFrames, durationMode: durationMode))
    }

    private func selectionIdentity(_ frame: DisplayFrame) -> [QuotaSelectionID] {
        switch frame {
        case .single(let quota): [quota.identifier]
        case .comparison(let codex, let spark): [codex.identifier, spark.identifier]
        }
    }

    public func setPaused(_ paused: Bool, for reason: StatusRotationPauseReason) {
        rotation.setPaused(paused, for: reason)
    }

    private func render(
        _ frames: [DisplayFrame],
        durationMode: StatusDurationMode
    ) -> [RenderedStatusFrame] {
        frames.map { frame in
            renderer.render(
                frame,
                durationMode: durationMode,
                appearance: presenter.effectiveAppearance
            )
        }
    }

    private func updateLength(using frames: [RenderedStatusFrame]) {
        guard let widestFrame = frames.max(by: widthAscending) else {
            return
        }
        let paddedWidth = ceil(widestFrame.measuredWidth) + Self.horizontalPadding
        guard lastLength != paddedWidth else { return }
        lastLength = paddedWidth
        presenter.setLength(paddedWidth)
    }

    private func widthAscending(
        _ left: RenderedStatusFrame,
        _ right: RenderedStatusFrame
    ) -> Bool {
        left.measuredWidth < right.measuredWidth
    }
}

private struct StatusDurationPresentationPolicy: Sendable {
    func mode(for frames: [DisplayFrame]) -> StatusDurationMode {
        let totalCriterionCount = frames.reduce(0) { count, frame in
            count + criterionCount(for: frame)
        }
        guard totalCriterionCount == 1 else {
            return .full
        }
        return .compactSingleCriterion
    }

    private func criterionCount(for frame: DisplayFrame) -> Int {
        switch frame {
        case .single:
            1
        case .comparison(let codex, let spark):
            comparisonCriterionCount(codex: codex, spark: spark)
        }
    }

    private func comparisonCriterionCount(
        codex: DisplayQuota,
        spark: DisplayQuota
    ) -> Int {
        guard codex.identifier.rawDurationMinutes
            == spark.identifier.rawDurationMinutes
        else {
            return 2
        }
        return 1
    }
}
