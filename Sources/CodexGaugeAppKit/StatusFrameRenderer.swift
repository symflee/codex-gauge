import AppKit
import CodexGaugeCore

@MainActor
public struct RenderedStatusFrame {
    public let attributedTitle: NSAttributedString
    public let semanticTitle: String
    public let accessibilityLabel: String
    public let badgeLabels: [String]
    public let measuredWidth: CGFloat

    public init(
        attributedTitle: NSAttributedString,
        semanticTitle: String,
        accessibilityLabel: String,
        badgeLabels: [String],
        measuredWidth: CGFloat
    ) {
        self.attributedTitle = attributedTitle
        self.semanticTitle = semanticTitle
        self.accessibilityLabel = accessibilityLabel
        self.badgeLabels = badgeLabels
        self.measuredWidth = measuredWidth
    }
}

@MainActor
public protocol StatusFrameRendering: AnyObject {
    func render(
        _ frame: DisplayFrame,
        appearance: NSAppearance?
    ) -> RenderedStatusFrame
}

@MainActor
public final class StatusFrameRenderer: StatusFrameRendering {
    private let titleFormatter: DisplayFrameFormatter
    private let accessibilityFormatter: StatusAccessibilityFormatter
    private let badgeCache: StatusBadgeImageCache

    public init(
        titleFormatter: DisplayFrameFormatter = DisplayFrameFormatter(),
        accessibilityFormatter: StatusAccessibilityFormatter = StatusAccessibilityFormatter(),
        badgeCache: StatusBadgeImageCache = StatusBadgeImageCache()
    ) {
        self.titleFormatter = titleFormatter
        self.accessibilityFormatter = accessibilityFormatter
        self.badgeCache = badgeCache
    }

    public func render(
        _ frame: DisplayFrame,
        appearance: NSAppearance?
    ) -> RenderedStatusFrame {
        let formatted = titleFormatter.format(frame)
        let result = makeAttributedTitle(formatted.title, appearance: appearance)
        return RenderedStatusFrame(
            attributedTitle: result.title,
            semanticTitle: formatted.title,
            accessibilityLabel: accessibilityFormatter.format(frame),
            badgeLabels: result.badgeLabels,
            measuredWidth: ceil(result.title.size().width)
        )
    }

    private func makeAttributedTitle(
        _ title: String,
        appearance: NSAppearance?
    ) -> AttributedTitleResult {
        let result = NSMutableAttributedString()
        var remaining = title[...]
        var labels: [String] = []
        while let badge = nextBadge(in: remaining) {
            appendText(String(remaining[..<badge.opening]), to: result)
            let label = String(remaining[badge.labelRange])
            appendBadge(label, appearance: appearance, to: result)
            labels.append(label)
            remaining = remaining[badge.remainderStart...]
        }
        appendText(String(remaining), to: result)
        return AttributedTitleResult(title: result, badgeLabels: labels)
    }

    private func nextBadge(in text: Substring) -> BadgeRange? {
        guard let opening = text.firstIndex(of: "[") else {
            return nil
        }
        let labelStart = text.index(after: opening)
        guard let closing = text[labelStart...].firstIndex(of: "]") else {
            return nil
        }
        return BadgeRange(
            opening: opening,
            labelRange: labelStart..<closing,
            remainderStart: text.index(after: closing)
        )
    }

    private func appendText(_ text: String, to title: NSMutableAttributedString) {
        guard !text.isEmpty else {
            return
        }
        let font = NSFont.monospacedDigitSystemFont(
            ofSize: NSFont.systemFontSize,
            weight: .regular
        )
        title.append(NSAttributedString(string: text, attributes: [.font: font]))
    }

    private func appendBadge(
        _ label: String,
        appearance: NSAppearance?,
        to title: NSMutableAttributedString
    ) {
        let attachment = NSTextAttachment()
        attachment.image = badgeCache.image(label: label, appearance: appearance)
        attachment.bounds.origin.y = -2
        title.append(NSAttributedString(attachment: attachment))
    }
}

private struct BadgeRange {
    let opening: Substring.Index
    let labelRange: Range<Substring.Index>
    let remainderStart: Substring.Index
}

@MainActor
private struct AttributedTitleResult {
    let title: NSAttributedString
    let badgeLabels: [String]
}
