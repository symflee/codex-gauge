import AppKit
import CodexGaugeAppKit
import CodexGaugeCore

struct PresentationCounters: Encodable, Sendable {
    var publications = 0
    var acceptedResponses = 0
    var renderCalls = 0
    var presentCalls = 0
    var widthChanges = 0
    var settledAppearanceCallbacks = 0
    var settingsOpened = 0
    var settingsClosed = 0
    var settingsGraphsReleased = 0
    var menuModelRequests = 0
}

@MainActor
final class PresentationMeasurements {
    var counters = PresentationCounters()
}

/// Forward to the actual system status item. Counts calls, not individual AppKit setters.
@MainActor
final class MeasuredStatusPresenter: StatusItemPresenting {
    let system: SystemStatusItemPresenter
    private let measurements: PresentationMeasurements

    init(system: SystemStatusItemPresenter, measurements: PresentationMeasurements) {
        self.system = system
        self.measurements = measurements
    }

    var effectiveAppearance: NSAppearance? { system.effectiveAppearance }

    func setLength(_ length: CGFloat) {
        measurements.counters.widthChanges += 1
        system.setLength(length)
    }

    func present(_ frame: RenderedStatusFrame) {
        measurements.counters.presentCalls += 1
        system.present(frame)
    }

    func setAppearanceChangeHandler(_ handler: @escaping @MainActor @Sendable () -> Void) {
        system.setAppearanceChangeHandler { [measurements] in
            measurements.counters.settledAppearanceCallbacks += 1
            handler()
        }
    }
}

@MainActor
final class MeasuredStatusRenderer: StatusFrameRendering {
    private let renderer = StatusFrameRenderer()
    private let measurements: PresentationMeasurements

    init(measurements: PresentationMeasurements) { self.measurements = measurements }

    func appearanceVariant(for appearance: NSAppearance?) -> StatusAppearanceVariant {
        renderer.appearanceVariant(for: appearance)
    }

    func render(
        _ frame: DisplayFrame,
        appearance: NSAppearance?
    ) -> RenderedStatusFrame {
        measurements.counters.renderCalls += 1
        return renderer.render(frame, appearance: appearance)
    }
}

@MainActor
final class WeakSettingsGraph {
    weak var controller: SettingsWindowController?
    weak var window: NSWindow?
    weak var viewController: SettingsFormViewController?
    weak var view: NSView?

    init(controller: SettingsWindowController) {
        self.controller = controller
        window = controller.window
        viewController = controller.settingsViewController
        view = controller.settingsViewController.view
    }

    var isReleased: Bool {
        controller == nil && window == nil && viewController == nil && view == nil
    }
}
