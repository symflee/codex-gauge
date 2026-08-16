import AppKit

@MainActor
public final class StatusBadgeImageCache {
    private struct Key: Hashable {
        let label: String
        let appearanceName: String
    }

    private let capacity: Int
    private var images: [Key: NSImage] = [:]
    private var insertionOrder: [Key] = []

    public init(capacity: Int = 16) {
        self.capacity = max(1, capacity)
    }

    public var count: Int {
        images.count
    }

    public func image(label: String, appearance: NSAppearance?) -> NSImage {
        let key = cacheKey(label: label, appearance: appearance)
        if let cachedImage = images[key] {
            return cachedImage
        }

        let image = makeImage(label: label, appearance: appearance)
        insert(image, for: key)
        return image
    }

    private func cacheKey(label: String, appearance: NSAppearance?) -> Key {
        Key(
            label: label,
            appearanceName: appearance?.name.rawValue ?? "unspecified"
        )
    }

    private func insert(_ image: NSImage, for key: Key) {
        evictOldestIfNeeded()
        images[key] = image
        insertionOrder.append(key)
    }

    private func evictOldestIfNeeded() {
        guard images.count >= capacity, let oldestKey = insertionOrder.first else {
            return
        }
        images.removeValue(forKey: oldestKey)
        insertionOrder.removeFirst()
    }

    private func makeImage(label: String, appearance: NSAppearance?) -> NSImage {
        let metrics = BadgeMetrics(label: label)
        let image = NSImage(size: metrics.imageSize, flipped: false) { bounds in
            Self.drawBadge(label: label, bounds: bounds, metrics: metrics, appearance: appearance)
            return true
        }
        image.isTemplate = true
        return image
    }

    private static func drawBadge(
        label: String,
        bounds: NSRect,
        metrics: BadgeMetrics,
        appearance: NSAppearance?
    ) {
        let drawing = {
            drawBorder(in: bounds)
            drawLabel(label, in: bounds, metrics: metrics)
        }
        guard let appearance else {
            drawing()
            return
        }
        appearance.performAsCurrentDrawingAppearance(drawing)
    }

    private static func drawBorder(in bounds: NSRect) {
        let borderBounds = bounds.insetBy(dx: 0.5, dy: 0.5)
        let border = NSBezierPath(roundedRect: borderBounds, xRadius: 3, yRadius: 3)
        border.lineWidth = 1
        NSColor.labelColor.setStroke()
        border.stroke()
    }

    private static func drawLabel(
        _ label: String,
        in bounds: NSRect,
        metrics: BadgeMetrics
    ) {
        let origin = NSPoint(
            x: (bounds.width - metrics.labelSize.width) / 2,
            y: (bounds.height - metrics.labelSize.height) / 2
        )
        label.draw(at: origin, withAttributes: metrics.textAttributes)
    }
}

@MainActor
private struct BadgeMetrics {
    let labelSize: NSSize
    let textAttributes: [NSAttributedString.Key: Any]

    init(label: String) {
        textAttributes = [
            .font: NSFont.systemFont(ofSize: 9, weight: .semibold),
            .foregroundColor: NSColor.labelColor
        ]
        labelSize = (label as NSString).size(withAttributes: textAttributes)
    }

    var imageSize: NSSize {
        NSSize(width: ceil(labelSize.width) + 8, height: 14)
    }
}
