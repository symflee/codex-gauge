import AppKit
import CodexGaugeCore
import CodexGaugeSettings

public enum StatusDurationMode: Equatable, Sendable {
    case full
    case compactSingleCriterion
}

public struct StatusGaugeVisualLabelFormatter: Sendable {
    public init() {}

    public func format(
        _ frame: DisplayFrame,
        durationMode: StatusDurationMode = .full
    ) -> String {
        switch frame {
        case .single(let quota):
            singleLabel(quota, durationMode: durationMode)
        case .comparison(let codex, let spark):
            comparisonLabel(
                codex: codex,
                spark: spark,
                durationMode: durationMode
            )
        }
    }

    private func singleLabel(
        _ quota: DisplayQuota,
        durationMode: StatusDurationMode
    ) -> String {
        var components: [String] = []
        if quota.identifier.product == .spark {
            components.append("S")
        }
        appendDuration(of: quota, mode: durationMode, to: &components)
        components.append(valueLabel(quota.value))
        return components.joined(separator: " ")
    }

    private func comparisonLabel(
        codex: DisplayQuota,
        spark: DisplayQuota,
        durationMode: StatusDurationMode
    ) -> String {
        guard hasSharedDuration(codex: codex, spark: spark) else {
            return mixedDurationLabel(
                codex: codex,
                spark: spark,
                durationMode: durationMode
            )
        }
        return sharedDurationLabel(
            codex: codex,
            spark: spark,
            durationMode: durationMode
        )
    }

    private func sharedDurationLabel(
        codex: DisplayQuota,
        spark: DisplayQuota,
        durationMode: StatusDurationMode
    ) -> String {
        let values = "C\(valueLabel(codex.value)) · S\(valueLabel(spark.value))"
        guard let duration = durationLabel(of: codex, mode: durationMode) else {
            return values
        }
        return "\(duration) \(values)"
    }

    private func mixedDurationLabel(
        codex: DisplayQuota,
        spark: DisplayQuota,
        durationMode: StatusDurationMode
    ) -> String {
        let codexLabel = productLabel("C", quota: codex, durationMode: durationMode)
        let sparkLabel = productLabel("S", quota: spark, durationMode: durationMode)
        return "\(codexLabel) · \(sparkLabel)"
    }

    private func hasSharedDuration(
        codex: DisplayQuota,
        spark: DisplayQuota
    ) -> Bool {
        codex.identifier.rawDurationMinutes == spark.identifier.rawDurationMinutes
    }

    private func productLabel(
        _ product: String,
        quota: DisplayQuota,
        durationMode: StatusDurationMode
    ) -> String {
        var components = [product]
        appendDuration(of: quota, mode: durationMode, to: &components)
        components.append(valueLabel(quota.value))
        return components.joined(separator: " ")
    }

    private func appendDuration(
        of quota: DisplayQuota,
        mode: StatusDurationMode,
        to components: inout [String]
    ) {
        guard let duration = durationLabel(of: quota, mode: mode) else {
            return
        }
        components.append(duration)
    }

    private func durationLabel(
        of quota: DisplayQuota,
        mode: StatusDurationMode
    ) -> String? {
        let durationBadge = quota.durationBadge
        guard mode == .compactSingleCriterion else {
            return durationBadge.label
        }
        guard durationBadge == .unknown else {
            return nil
        }
        return durationBadge.label
    }

    private func valueLabel(_ value: DisplayValueState) -> String {
        switch value {
        case .fresh(let percent):
            "\(percent)%"
        case .stale(let percent):
            "~\(percent)%"
        case .loading:
            "…"
        case .unavailable:
            "—"
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
        durationMode: StatusDurationMode,
        appearance: NSAppearance?
    ) -> RenderedStatusFrame
}

public extension StatusFrameRendering {
    func appearanceVariant(for appearance: NSAppearance?) -> StatusAppearanceVariant {
        .resolve(appearance)
    }
    func render(
        _ frame: DisplayFrame,
        appearance: NSAppearance?
    ) -> RenderedStatusFrame {
        render(frame, durationMode: .full, appearance: appearance)
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
        durationMode: StatusDurationMode,
        appearance: NSAppearance?
    ) -> RenderedStatusFrame {
        let semanticTitle = titleFormatter.format(frame).title
        let visualLabel = visualLabelFormatter.format(
            frame,
            durationMode: durationMode
        )
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
