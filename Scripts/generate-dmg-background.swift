import AppKit
import Foundation

let canvasWidth = 640
let canvasHeight = 420

guard CommandLine.arguments.count == 2 else {
    FileHandle.standardError.write(Data("Usage: generate-dmg-background.swift <output.png>\n".utf8))
    exit(64)
}

guard let bitmap = NSBitmapImageRep(
    bitmapDataPlanes: nil,
    pixelsWide: canvasWidth,
    pixelsHigh: canvasHeight,
    bitsPerSample: 8,
    samplesPerPixel: 4,
    hasAlpha: true,
    isPlanar: false,
    colorSpaceName: .deviceRGB,
    bytesPerRow: 0,
    bitsPerPixel: 0
) else {
    FileHandle.standardError.write(Data("Unable to allocate background bitmap\n".utf8))
    exit(1)
}

let context = NSGraphicsContext(bitmapImageRep: bitmap)
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = context

let canvas = NSRect(x: 0, y: 0, width: canvasWidth, height: canvasHeight)
let gradient = NSGradient(
    starting: NSColor(calibratedWhite: 0.99, alpha: 1),
    ending: NSColor(calibratedRed: 0.91, green: 0.95, blue: 0.98, alpha: 1)
)
gradient?.draw(in: canvas, angle: -90)

let accent = NSColor(calibratedRed: 0.12, green: 0.38, blue: 0.58, alpha: 1)
let muted = NSColor(calibratedWhite: 0.29, alpha: 1)

func drawCentered(_ text: String, y: CGFloat, font: NSFont, color: NSColor) {
    let attributes: [NSAttributedString.Key: Any] = [
        .font: font,
        .foregroundColor: color,
    ]
    let size = text.size(withAttributes: attributes)
    let origin = NSPoint(x: (CGFloat(canvasWidth) - size.width) / 2, y: y)
    text.draw(at: origin, withAttributes: attributes)
}

drawCentered(
    "Applications로 드래그 / Drag to Applications",
    y: 350,
    font: .systemFont(ofSize: 21, weight: .semibold),
    color: muted
)
drawCentered(
    "실행이 차단되면 설치 안내를 여세요",
    y: 317,
    font: .systemFont(ofSize: 14, weight: .medium),
    color: muted
)
drawCentered(
    "If blocked, open the guide",
    y: 298,
    font: .systemFont(ofSize: 12, weight: .regular),
    color: muted
)

accent.setStroke()
let arrow = NSBezierPath()
arrow.lineWidth = 5
arrow.lineCapStyle = .round
arrow.move(to: NSPoint(x: 250, y: 222))
arrow.line(to: NSPoint(x: 390, y: 222))
arrow.stroke()

accent.setFill()
let arrowHead = NSBezierPath()
arrowHead.move(to: NSPoint(x: 390, y: 222))
arrowHead.line(to: NSPoint(x: 370, y: 237))
arrowHead.line(to: NSPoint(x: 370, y: 207))
arrowHead.close()
arrowHead.fill()

NSGraphicsContext.restoreGraphicsState()

guard let png = bitmap.representation(using: .png, properties: [:]) else {
    FileHandle.standardError.write(Data("Unable to encode background PNG\n".utf8))
    exit(1)
}

let output = URL(fileURLWithPath: CommandLine.arguments[1])
do {
    try png.write(to: output, options: .atomic)
} catch {
    FileHandle.standardError.write(Data("Unable to write background PNG\n".utf8))
    exit(1)
}
