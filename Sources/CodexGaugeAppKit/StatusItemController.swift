import AppKit
import CodexGaugeCore

@MainActor
public protocol StatusItemPresenting: AnyObject {
    var effectiveAppearance: NSAppearance? { get }

    func setLength(_ length: CGFloat)
    func present(_ frame: RenderedStatusFrame)
}

@MainActor
public final class SystemStatusItemPresenter: StatusItemPresenting, StatusMenuPresenting {
    private let statusItem: NSStatusItem
    private let button: NSStatusBarButton?

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
        statusItem.length = length
    }

    public func present(_ frame: RenderedStatusFrame) {
        guard let button else {
            return
        }
        clearTitle(on: button)
        button.imagePosition = .imageOnly
        button.imageScaling = .scaleNone
        button.image = frame.image
        button.setAccessibilityLabel(frame.accessibilityLabel)
    }

    public func setMenu(_ menu: NSMenu) {
        statusItem.menu = menu
    }

    private func configure(_ button: NSStatusBarButton?) {
        guard let button else {
            return
        }
        button.setAccessibilityIdentifier(
            CodexGaugeAccessibilityIdentifier.statusItem
        )
        button.imagePosition = .imageOnly
        button.imageScaling = .scaleNone
        clearTitle(on: button)
    }

    private func clearTitle(on button: NSStatusBarButton) {
        button.title = ""
        button.attributedTitle = NSAttributedString(string: "")
    }
}

@MainActor
public final class StatusItemController {
    private static let horizontalPadding: CGFloat = 12

    private let presenter: StatusItemPresenting
    private var renderer: StatusFrameRendering
    private let rotation: StatusFrameRotation
    private let prototypeBuilder = StatusWidthPrototypeBuilder()
    private let durationPresentationPolicy = StatusDurationPresentationPolicy()

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
    }

    public func replaceRenderer(_ renderer: StatusFrameRendering) {
        self.renderer = renderer
    }

    public func setFrames(
        _ frames: [DisplayFrame],
        widthPrototypes: [DisplayFrame] = []
    ) {
        let durationMode = durationPresentationPolicy.mode(for: frames)
        let renderedFrames = render(frames, durationMode: durationMode)
        let derivedPrototypes = prototypeBuilder.prototypes(for: frames)
        let widthCandidates = renderedFrames + render(
            derivedPrototypes + widthPrototypes,
            durationMode: durationMode
        )
        updateLength(using: widthCandidates)
        rotation.setFrames(renderedFrames)
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
