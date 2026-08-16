import AppKit
import CodexGaugeCore

@MainActor
public protocol StatusItemPresenting: AnyObject {
    var effectiveAppearance: NSAppearance? { get }

    func setLength(_ length: CGFloat)
    func present(_ frame: RenderedStatusFrame)
}

@MainActor
public final class SystemStatusItemPresenter: StatusItemPresenting {
    private let statusItem: NSStatusItem

    public init(statusItem: NSStatusItem) {
        self.statusItem = statusItem
    }

    public convenience init(statusBar: NSStatusBar = .system) {
        let statusItem = statusBar.statusItem(withLength: NSStatusItem.variableLength)
        self.init(statusItem: statusItem)
    }

    public var effectiveAppearance: NSAppearance? {
        statusItem.button?.effectiveAppearance
    }

    public func setLength(_ length: CGFloat) {
        statusItem.length = length
    }

    public func present(_ frame: RenderedStatusFrame) {
        statusItem.button?.attributedTitle = frame.attributedTitle
        statusItem.button?.setAccessibilityLabel(frame.accessibilityLabel)
    }
}

@MainActor
public final class StatusItemController {
    private static let horizontalPadding: CGFloat = 12

    private let presenter: StatusItemPresenting
    private let renderer: StatusFrameRendering
    private let rotation: StatusFrameRotation
    private let prototypeBuilder = StatusWidthPrototypeBuilder()

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

    public func setFrames(
        _ frames: [DisplayFrame],
        widthPrototypes: [DisplayFrame] = []
    ) {
        let renderedFrames = render(frames)
        let derivedPrototypes = prototypeBuilder.prototypes(for: frames)
        let widthCandidates = renderedFrames + render(derivedPrototypes + widthPrototypes)
        updateLength(using: widthCandidates)
        rotation.setFrames(renderedFrames)
    }

    public func setPaused(_ paused: Bool, for reason: StatusRotationPauseReason) {
        rotation.setPaused(paused, for: reason)
    }

    private func render(_ frames: [DisplayFrame]) -> [RenderedStatusFrame] {
        frames.map { frame in
            renderer.render(frame, appearance: presenter.effectiveAppearance)
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
