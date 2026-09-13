import AppKit
import CoreText

@MainActor
enum StatusGaugeFont {
    // Static initialization bounds registration and fallback to one attempt per process.
    static let font: NSFont = {
        let fallback = NSFont.monospacedDigitSystemFont(ofSize: 16, weight: .semibold)
        guard let url = Bundle.module.url(forResource: "Pretendard-SemiBold", withExtension: "otf") else {
            return fallback
        }
        CTFontManagerRegisterFontsForURL(url as CFURL, .process, nil)
        let descriptor = NSFontDescriptor(fontAttributes: [
            .name: "Pretendard-SemiBold",
            NSFontDescriptor.AttributeName(rawValue: kCTFontURLAttribute as String): url,
            .featureSettings: [[
                NSFontDescriptor.FeatureKey.typeIdentifier: kNumberSpacingType,
                NSFontDescriptor.FeatureKey.selectorIdentifier: kMonospacedNumbersSelector
            ]]
        ])
        guard let font = NSFont(descriptor: descriptor, size: 16),
              font.fontName == "Pretendard-SemiBold" else {
            return fallback
        }
        return font
    }()
}
