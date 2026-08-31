import AppKit
import CodexGaugeSettings

public enum StatusGaugeTextContrast {
    public static func usesDarkText(for color: StatusGaugeColor) -> Bool {
        let luminance = relativeLuminance(of: color)
        let blackContrast = (luminance + 0.05) / 0.05
        let whiteContrast = 1.05 / (luminance + 0.05)
        return blackContrast >= whiteContrast
    }

    private static func relativeLuminance(of color: StatusGaugeColor) -> Double {
        0.2126 * linearComponent(color.red)
            + 0.7152 * linearComponent(color.green)
            + 0.0722 * linearComponent(color.blue)
    }

    private static func linearComponent(_ component: UInt8) -> Double {
        let value = Double(component) / Double(UInt8.max)
        guard value > 0.04045 else {
            return value / 12.92
        }
        return pow((value + 0.055) / 1.055, 2.4)
    }
}

@MainActor
public final class StatusGaugeImageCache {
    private struct Key: Hashable {
        let label: String
        let borderHex: String
        let fillHex: String
    }

    private let capacity: Int
    private var images: [Key: NSImage] = [:]
    private var useOrder: [Key] = []

    public init(capacity: Int = 32) {
        self.capacity = max(1, capacity)
    }

    public var count: Int {
        images.count
    }

    public func image(
        label: String,
        appearance: StatusGaugeAppearance
    ) -> NSImage {
        image(
            label: label,
            borderColor: appearance.borderColor,
            fillColor: appearance.fillColor
        )
    }

    public func image(
        label: String,
        borderColor: StatusGaugeColor,
        fillColor: StatusGaugeColor
    ) -> NSImage {
        let key = Key(
            label: label,
            borderHex: borderColor.hexString,
            fillHex: fillColor.hexString
        )
        guard let cachedImage = images[key] else {
            return makeAndCacheImage(
                label: label,
                borderColor: borderColor,
                fillColor: fillColor,
                key: key
            )
        }
        markMostRecentlyUsed(key)
        return cachedImage
    }

    private func makeAndCacheImage(
        label: String,
        borderColor: StatusGaugeColor,
        fillColor: StatusGaugeColor,
        key: Key
    ) -> NSImage {
        let image = makeImage(
            label: label,
            borderColor: borderColor,
            fillColor: fillColor
        )
        images[key] = image
        markMostRecentlyUsed(key)
        evictIfNeeded()
        return image
    }

    private func markMostRecentlyUsed(_ key: Key) {
        useOrder.removeAll { $0 == key }
        useOrder.append(key)
    }

    private func evictIfNeeded() {
        guard images.count > capacity, let leastRecentlyUsed = useOrder.first else {
            return
        }
        images.removeValue(forKey: leastRecentlyUsed)
        useOrder.removeFirst()
    }

    private func makeImage(
        label: String,
        borderColor: StatusGaugeColor,
        fillColor: StatusGaugeColor
    ) -> NSImage {
        let metrics = StatusGaugeImageMetrics(label: label, fillColor: fillColor)
        let image = NSImage(size: metrics.imageSize)
        for scale in [1, 2] {
            guard let representation = Self.makeBitmapRepresentation(
                label: label,
                metrics: metrics,
                borderColor: borderColor,
                fillColor: fillColor,
                scale: scale
            ) else {
                continue
            }
            image.addRepresentation(representation)
        }
        image.isTemplate = false
        return image
    }

    private static func makeBitmapRepresentation(
        label: String,
        metrics: StatusGaugeImageMetrics,
        borderColor: StatusGaugeColor,
        fillColor: StatusGaugeColor,
        scale: Int
    ) -> NSBitmapImageRep? {
        guard let context = bitmapContext(
            size: metrics.imageSize,
            scale: scale
        ) else {
            return nil
        }
        draw(
            label: label,
            metrics: metrics,
            borderColor: borderColor,
            fillColor: fillColor,
            scale: scale,
            context: context
        )
        guard let image = context.makeImage() else {
            return nil
        }
        let representation = NSBitmapImageRep(cgImage: image)
        representation.size = metrics.imageSize
        return representation
    }

    private static func bitmapContext(
        size: NSSize,
        scale: Int
    ) -> CGContext? {
        let width = Int(size.width) * scale
        let height = Int(size.height) * scale
        guard let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) else {
            return nil
        }
        return CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )
    }

    private static func draw(
        label: String,
        metrics: StatusGaugeImageMetrics,
        borderColor: StatusGaugeColor,
        fillColor: StatusGaugeColor,
        scale: Int,
        context: CGContext
    ) {
        NSGraphicsContext.saveGraphicsState()
        defer {
            NSGraphicsContext.restoreGraphicsState()
        }
        NSGraphicsContext.current = NSGraphicsContext(
            cgContext: context,
            flipped: false
        )
        context.setShouldAntialias(true)
        context.scaleBy(x: CGFloat(scale), y: CGFloat(scale))
        drawCapsule(
            label: label,
            bounds: NSRect(origin: .zero, size: metrics.imageSize),
            metrics: metrics,
            borderColor: borderColor,
            fillColor: fillColor
        )
        context.flush()
    }

    private static func drawCapsule(
        label: String,
        bounds: NSRect,
        metrics: StatusGaugeImageMetrics,
        borderColor: StatusGaugeColor,
        fillColor: StatusGaugeColor
    ) {
        drawFill(in: bounds, color: fillColor)
        drawBorder(in: bounds, color: borderColor)
        drawLabel(label, in: bounds, metrics: metrics)
    }

    private static func drawFill(in bounds: NSRect, color: StatusGaugeColor) {
        let path = NSBezierPath(roundedRect: bounds, xRadius: 10, yRadius: 10)
        color.appKitColor.setFill()
        path.fill()
    }

    private static func drawBorder(in bounds: NSRect, color: StatusGaugeColor) {
        let borderBounds = bounds.insetBy(dx: 0.5, dy: 0.5)
        let path = NSBezierPath(
            roundedRect: borderBounds,
            xRadius: 9.5,
            yRadius: 9.5
        )
        path.lineWidth = 1
        color.appKitColor.setStroke()
        path.stroke()
    }

    private static func drawLabel(
        _ label: String,
        in bounds: NSRect,
        metrics: StatusGaugeImageMetrics
    ) {
        let origin = NSPoint(
            x: (bounds.width - metrics.labelSize.width) / 2,
            y: (bounds.height - metrics.labelSize.height) / 2
        )
        label.draw(at: origin, withAttributes: metrics.textAttributes)
    }
}

@MainActor
private struct StatusGaugeImageMetrics {
    static let height: CGFloat = 20
    static let horizontalPadding: CGFloat = 10

    let labelSize: NSSize
    let textAttributes: [NSAttributedString.Key: Any]

    init(label: String, fillColor: StatusGaugeColor) {
        let font = NSFont.monospacedDigitSystemFont(ofSize: 13, weight: .semibold)
        let usesDarkText = StatusGaugeTextContrast.usesDarkText(for: fillColor)
        textAttributes = [
            .font: font,
            .foregroundColor: usesDarkText ? NSColor.black : NSColor.white
        ]
        labelSize = (label as NSString).size(withAttributes: textAttributes)
    }

    var imageSize: NSSize {
        NSSize(
            width: ceil(labelSize.width) + Self.horizontalPadding * 2,
            height: Self.height
        )
    }
}

private extension StatusGaugeColor {
    var appKitColor: NSColor {
        let divisor = CGFloat(UInt8.max)
        return NSColor(
            srgbRed: CGFloat(red) / divisor,
            green: CGFloat(green) / divisor,
            blue: CGFloat(blue) / divisor,
            alpha: 1
        )
    }
}
