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
        let palette: StatusGaugePalette
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
        appearance: StatusGaugeAppearance,
        systemAppearance: NSAppearance? = nil
    ) -> NSImage {
        image(
            label: label,
            palette: StatusGaugePalette(appearance: appearance, systemAppearance: systemAppearance)
        )
    }

    public func image(
        label: String,
        borderColor: StatusGaugeColor,
        fillColor: StatusGaugeColor
    ) -> NSImage {
        image(
            label: label,
            palette: StatusGaugePalette(borderColor: borderColor, fillColor: fillColor)
        )
    }

    private func image(label: String, palette: StatusGaugePalette) -> NSImage {
        let key = Key(label: label, palette: palette)
        guard let cachedImage = images[key] else {
            return makeAndCacheImage(
                label: label,
                palette: palette,
                key: key
            )
        }
        markMostRecentlyUsed(key)
        return cachedImage
    }

    private func makeAndCacheImage(
        label: String,
        palette: StatusGaugePalette,
        key: Key
    ) -> NSImage {
        let image = makeImage(
            label: label,
            palette: palette
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
        palette: StatusGaugePalette
    ) -> NSImage {
        let metrics = StatusGaugeImageMetrics(label: label, textColor: palette.textColor)
        let image = NSImage(size: metrics.imageSize)
        for scale in [1, 2] {
            guard let representation = Self.makeBitmapRepresentation(
                label: label,
                metrics: metrics,
                palette: palette,
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
        palette: StatusGaugePalette,
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
            palette: palette,
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
        palette: StatusGaugePalette,
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
            palette: palette
        )
        context.flush()
    }

    private static func drawCapsule(
        label: String,
        bounds: NSRect,
        metrics: StatusGaugeImageMetrics,
        palette: StatusGaugePalette
    ) {
        drawFill(in: bounds, color: palette.fillColor)
        NSGraphicsContext.saveGraphicsState()
        NSBezierPath(roundedRect: bounds, xRadius: 5, yRadius: 5).addClip()
        drawLabel(label, in: bounds, metrics: metrics)
        NSGraphicsContext.restoreGraphicsState()
        if let borderColor = palette.borderColor {
            drawBorder(in: bounds, color: borderColor)
        }
    }

    private static func drawFill(in bounds: NSRect, color: StatusGaugeColor) {
        let path = NSBezierPath(roundedRect: bounds, xRadius: 5, yRadius: 5)
        color.appKitColor.setFill()
        path.fill()
    }

    private static func drawBorder(in bounds: NSRect, color: StatusGaugeColor) {
        let borderBounds = bounds.insetBy(dx: 0.75, dy: 0.75)
        let path = NSBezierPath(
            roundedRect: borderBounds,
            xRadius: 4.25,
            yRadius: 4.25
        )
        path.lineWidth = 1.5
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
    static let horizontalPadding: CGFloat = 4

    private static let fixedWidth: CGFloat = {
        let width = ("00%" as NSString).size(withAttributes: [.font: StatusGaugeFont.font]).width
        return ceil(width) + horizontalPadding * 2
    }()

    let labelSize: NSSize
    let textAttributes: [NSAttributedString.Key: Any]

    init(label: String, textColor: StatusGaugeColor) {
        textAttributes = [
            .font: StatusGaugeFont.font,
            .foregroundColor: textColor.appKitColor
        ]
        labelSize = (label as NSString).size(withAttributes: textAttributes)
    }

    var imageSize: NSSize {
        NSSize(
            width: Self.fixedWidth,
            height: Self.height
        )
    }
}

private struct StatusGaugePalette: Hashable {
    let borderColor: StatusGaugeColor?
    let fillColor: StatusGaugeColor
    let textColor: StatusGaugeColor

    private init(borderColor: StatusGaugeColor?, fillColor: StatusGaugeColor, textColor: StatusGaugeColor) {
        self.borderColor = borderColor
        self.fillColor = fillColor
        self.textColor = textColor
    }

    init(borderColor: StatusGaugeColor, fillColor: StatusGaugeColor) {
        self.borderColor = borderColor
        self.fillColor = fillColor
        let component: UInt8 = StatusGaugeTextContrast.usesDarkText(for: fillColor) ? 0 : 255
        textColor = StatusGaugeColor(red: component, green: component, blue: component)
    }

    @MainActor
    init(appearance: StatusGaugeAppearance, systemAppearance: NSAppearance?) {
        guard appearance == .preset(.neutral) else {
            self.init(borderColor: appearance.borderColor, fillColor: appearance.fillColor)
            return
        }
        let isDark = systemAppearance?.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        self.init(
            borderColor: isDark
                ? StatusGaugeColor(red: 0x77, green: 0x81, blue: 0x91)
                : StatusGaugePreset.neutral.borderColor,
            fillColor: isDark
                ? StatusGaugeColor(red: 0x42, green: 0x4B, blue: 0x5B)
                : StatusGaugePreset.neutral.fillColor,
            textColor: isDark
                ? StatusGaugeColor(red: 0xF0, green: 0xF2, blue: 0xF6)
                : StatusGaugeColor(red: 0x25, green: 0x28, blue: 0x30)
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
