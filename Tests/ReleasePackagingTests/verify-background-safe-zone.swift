import AppKit
import Foundation

guard CommandLine.arguments.count == 2 else {
    FileHandle.standardError.write(
        Data("Usage: verify-background-safe-zone.swift <background.png>\n".utf8)
    )
    exit(64)
}

let backgroundPath = CommandLine.arguments[1]
guard let backgroundData = try? Data(contentsOf: URL(fileURLWithPath: backgroundPath)),
      let bitmap = NSBitmapImageRep(data: backgroundData),
      let baseline = NSBitmapImageRep(
          bitmapDataPlanes: nil,
          pixelsWide: 640,
          pixelsHigh: 420,
          bitsPerSample: 8,
          samplesPerPixel: 4,
          hasAlpha: true,
          isPlanar: false,
          colorSpaceName: .deviceRGB,
          bytesPerRow: 0,
          bitsPerPixel: 0
      ) else {
    FileHandle.standardError.write(Data("Unable to read background PNG\n".utf8))
    exit(1)
}

let context = NSGraphicsContext(bitmapImageRep: baseline)
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = context
let canvas = NSRect(x: 0, y: 0, width: 640, height: 420)
let gradient = NSGradient(
    starting: NSColor(calibratedWhite: 0.99, alpha: 1),
    ending: NSColor(calibratedRed: 0.91, green: 0.95, blue: 0.98, alpha: 1)
)
gradient?.draw(in: canvas, angle: -90)
NSGraphicsContext.restoreGraphicsState()

guard let baselineData = baseline.representation(using: .png, properties: [:]),
      let encodedBaseline = NSBitmapImageRep(data: baselineData) else {
    FileHandle.standardError.write(Data("Unable to generate background baseline\n".utf8))
    exit(1)
}

let guideSafeZone = NSRect(x: 160, y: 245, width: 320, height: 165)

for y in Int(guideSafeZone.minY)..<Int(guideSafeZone.maxY) {
    for x in Int(guideSafeZone.minX)..<Int(guideSafeZone.maxX) {
        guard bitmap.colorAt(x: x, y: y) == encodedBaseline.colorAt(x: x, y: y) else {
            FileHandle.standardError.write(
                Data("DMG guide safe zone contains background decoration at \(x),\(y)\n".utf8)
            )
            exit(1)
        }
    }
}
