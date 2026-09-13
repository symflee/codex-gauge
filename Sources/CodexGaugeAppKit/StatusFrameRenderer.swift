import AppKit
import CodexGaugeCore
import CodexGaugeSettings

public struct StatusGaugeVisualLabelFormatter: Sendable {
    public init() {}

    public func format(_ frame: DisplayFrame) -> String {
        switch frame {
        case .single(let quota):
            switch quota.value {
            case .fresh(let percent): "\(percent)%"
            case .stale(let percent): "~\(percent)%"
            case .loading: "…"
            case .unavailable: "—"
            }
        }
    }
}

@MainActor
public struct RenderedStatusFrame {
    public let image: NSImage
    public let semanticTitle: String
    public let visualLabel: String
    public let accessibilityLabel: String
    public let measuredWidth: CGFloat

    func hasSamePresentation(as other: RenderedStatusFrame) -> Bool {
        image === other.image && accessibilityLabel == other.accessibilityLabel
            && semanticTitle == other.semanticTitle && measuredWidth == other.measuredWidth
    }

    public init(
        image: NSImage,
        semanticTitle: String,
        visualLabel: String,
        accessibilityLabel: String,
        measuredWidth: CGFloat
    ) {
        self.image = image
        self.semanticTitle = semanticTitle
        self.visualLabel = visualLabel
        self.accessibilityLabel = accessibilityLabel
        self.measuredWidth = measuredWidth
    }
}

public enum StatusAppearanceVariant: Equatable, Sendable {
    case light
    case dark
    case independentOfSystem

    @MainActor
    static func resolve(_ appearance: NSAppearance?) -> Self {
        appearance?.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? .dark : .light
    }
}

@MainActor
public protocol StatusFrameRendering: AnyObject {
    func appearanceVariant(for appearance: NSAppearance?) -> StatusAppearanceVariant
    func render(
        _ frame: DisplayFrame,
        appearance: NSAppearance?
    ) -> RenderedStatusFrame
}

public extension StatusFrameRendering {
    func appearanceVariant(for appearance: NSAppearance?) -> StatusAppearanceVariant {
        .resolve(appearance)
    }
}

@MainActor
public final class StatusFrameRenderer: StatusFrameRendering {
    private let titleFormatter: DisplayFrameFormatter
    private let visualLabelFormatter: StatusGaugeVisualLabelFormatter
    private let accessibilityFormatter: StatusAccessibilityFormatter
    private let statusGaugeAppearance: StatusGaugeAppearance
    private let cache: StatusGaugeImageCache

    public func appearanceVariant(for appearance: NSAppearance?) -> StatusAppearanceVariant {
        guard statusGaugeAppearance == .preset(.neutral) else {
            return .independentOfSystem
        }
        return .resolve(appearance)
    }

    public init(
        titleFormatter: DisplayFrameFormatter = DisplayFrameFormatter(),
        visualLabelFormatter: StatusGaugeVisualLabelFormatter
            = StatusGaugeVisualLabelFormatter(),
        accessibilityFormatter: StatusAccessibilityFormatter
            = StatusAccessibilityFormatter(),
        statusGaugeAppearance: StatusGaugeAppearance = .default,
        cache: StatusGaugeImageCache = StatusGaugeImageCache()
    ) {
        self.titleFormatter = titleFormatter
        self.visualLabelFormatter = visualLabelFormatter
        self.accessibilityFormatter = accessibilityFormatter
        self.statusGaugeAppearance = statusGaugeAppearance
        self.cache = cache
    }

    public convenience init(
        language: AppLanguage,
        statusGaugeAppearance: StatusGaugeAppearance = .default,
        cache: StatusGaugeImageCache = StatusGaugeImageCache()
    ) {
        self.init(
            accessibilityFormatter: StatusAccessibilityFormatter(language: language),
            statusGaugeAppearance: statusGaugeAppearance,
            cache: cache
        )
    }

    public func render(
        _ frame: DisplayFrame,
        appearance: NSAppearance?
    ) -> RenderedStatusFrame {
        let semanticTitle = titleFormatter.format(frame).title
        let visualLabel = visualLabelFormatter.format(frame)
        return makeRenderedFrame(
            frame,
            semanticTitle: semanticTitle,
            visualLabel: visualLabel,
            appearance: appearance
        )
    }

    private func makeRenderedFrame(
        _ frame: DisplayFrame,
        semanticTitle: String,
        visualLabel: String,
        appearance: NSAppearance?
    ) -> RenderedStatusFrame {
        let image = cache.image(
            label: visualLabel,
            appearance: statusGaugeAppearance,
            systemAppearance: appearance
        )
        return RenderedStatusFrame(
            image: image,
            semanticTitle: semanticTitle,
            visualLabel: visualLabel,
            accessibilityLabel: accessibilityFormatter.format(frame),
            measuredWidth: ceil(image.size.width)
        )
    }
}
