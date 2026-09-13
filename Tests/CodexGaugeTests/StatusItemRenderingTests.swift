import AppKit
import CodexGaugeAppKit
import CodexGaugeCore
import CodexGaugeSettings
import CoreText

func statusItemRenderingTests() -> [TestCase] {
    [
        explicitAppLocalizationTest(),
        unchangedStatusInputTest(),
        unchangedStatusAppearanceTest(),
        transientNativeAppearanceTest(),
        fixedPaletteIgnoresAppearanceTest(),
        renderedPercentageBoundaryTest(),
        systemPresenterUsesImageOnlyTest(),
        statusRendererReplacementTest(),
        gaugeImageCacheTest(),
        gaugeTextContrastTest(),
        vividPresetTextContrastTest(),
        capsuleBitmapRenderingTest(),
        capsuleFontAndClippingTest(),
        slimCapsuleAppearanceTest(),
        slimCapsuleNativeAppearanceObservationTest(),
        singleStatusStatesTest(),
        fixedCapsuleAllocationTest(),
        localizedSingleAccessibilityTest(),
        singleFrameReplacementTest(),
        singleAppearanceRefreshTest(),
    ]
}

private func explicitAppLocalizationTest() -> TestCase {
    TestCase(name: "app localization resolves explicit Korean and English bundles") {
        let korean = AppLocalization(language: .korean)
        let english = AppLocalization(language: .english)

        try expect(
            korean.string("menu.action.refresh") == "새로 고침",
            "Expected explicit Korean bundle"
        )
        try expect(
            english.string("menu.action.refresh") == "Refresh",
            "Expected explicit English bundle"
        )
        try expect(korean.locale.identifier == "ko", "Expected Korean locale")
        try expect(english.locale.identifier == "en", "Expected English locale")
    }
}

private func unchangedStatusInputTest() -> TestCase {
    TestCase(name: "status unchanged input performs no rendering presentation or scheduling") {
        try await MainActor.run {
            let fixture = makeControllerFixture()
            let frames = singleFrames()
            fixture.controller.setFrames(frames)
            let renders = fixture.renderer.renderCount
            let presentations = fixture.presenter.presentedSemanticTitles.count
            let lengths = fixture.presenter.lengths.count
            for _ in 0..<100 { fixture.controller.setFrames(frames) }
            try expect(fixture.renderer.renderCount == renders, "Unchanged input must not render")
            try expect(fixture.presenter.presentedSemanticTitles.count == presentations, "Unchanged input must not present")
            try expect(fixture.presenter.lengths.count == lengths, "Unchanged input must not set width")
        }
    }
}

private func unchangedStatusAppearanceTest() -> TestCase {
    TestCase(name: "status unchanged appearance performs no rendering") {
        try await MainActor.run {
            let fixture = makeControllerFixture()
            fixture.controller.setFrames(singleFrames())
            let renders = fixture.renderer.renderCount
            for _ in 0..<100 { fixture.presenter.appearanceChangeHandler?() }
            try expect(fixture.renderer.renderCount == renders, "Equivalent appearance notifications must settle")
        }
    }
}

private func transientNativeAppearanceTest() -> TestCase {
    TestCase(name: "status native appearance burst settles without rerendering restored colors") {
        try await transientNativeAppearanceScenario()
    }
}

private func fixedPaletteIgnoresAppearanceTest() -> TestCase {
    TestCase(name: "status fixed palette ignores system appearance changes") {
        try await MainActor.run {
            let presenter = RecordingStatusItemPresenter()
            let controller = StatusItemController(
                presenter: presenter,
                renderer: StatusFrameRenderer(statusGaugeAppearance: .preset(.blue))
            )
            controller.setFrames(singleFrames())
            let count = presenter.images.count
            presenter.effectiveAppearance = try appearance(named: .darkAqua)
            presenter.appearanceChangeHandler?()
            try expect(presenter.images.count == count, "A fixed palette must not present on system color changes")
        }
    }
}

private func renderedPercentageBoundaryTest() -> TestCase {
    TestCase(name: "status capsule renders zero one eighty-three and one hundred percent") {
        try await MainActor.run {
            let renderer = StatusFrameRenderer()
            let aqua = try appearance(named: .aqua)
            for percent in [0, 1, 83, 100] {
                let frame = menubarFrame(
                    product: .codex,
                    duration: 300,
                    value: .fresh(percent)
                )
                let rendered = renderer.render(frame, appearance: aqua)
                try expect(
                    rendered.visualLabel == "\(percent)%",
                    "Unexpected percentage boundary label"
                )
                try expect(
                    rendered.semanticTitle == "[5h] \(percent)%",
                    "Unexpected percentage boundary semantics"
                )
            }
        }
    }
}

private func systemPresenterUsesImageOnlyTest() -> TestCase {
    TestCase(name: "system status presenter uses an unscaled image without a title") {
        try await MainActor.run {
            let statusItem = NSStatusItem()
            let button = NSStatusBarButton(frame: .zero)
            button.attributedTitle = NSAttributedString(string: "legacy title")
            let presenter = SystemStatusItemPresenter(
                statusItem: statusItem,
                button: button
            )
            let image = StatusGaugeImageCache().image(
                label: "83%",
                appearance: .default
            )
            let frame = RenderedStatusFrame(
                image: image,
                semanticTitle: "[5h] 83%",
                visualLabel: "83%",
                accessibilityLabel: "synthetic accessibility label",
                measuredWidth: image.size.width
            )

            presenter.present(frame)

            try expect(button.image === image, "Expected the rendered capsule image")
            try expect(button.imagePosition == .imageOnly, "Expected image-only layout")
            try expect(button.imageScaling == .scaleNone, "Expected no image scaling")
            try expect(button.attributedTitle.length == 0, "Expected the title to be cleared")
        }
    }
}

private func statusRendererReplacementTest() -> TestCase {
    TestCase(name: "status controller replaces its renderer for immediate localization") {
        try await MainActor.run {
            let presenter = RecordingStatusItemPresenter()
            let controller = StatusItemController(
                presenter: presenter,
                renderer: StatusFrameRenderer(language: .korean)
            )
            let frame = menubarFrame(
                product: .codex,
                duration: 300,
                value: .fresh(83)
            )

            controller.setFrames([frame])
            controller.replaceRenderer(StatusFrameRenderer(language: .english))
            controller.setFrames([frame])

            try expect(
                presenter.accessibilityLabels == [
                    "Codex 5시간 한도 남은 사용량 83퍼센트",
                    "Codex 5 hours quota, 83 percent remaining"
                ],
                "Expected replacement renderer to use the selected language"
            )
        }
    }
}

private func gaugeImageCacheTest() -> TestCase {
    TestCase(name: "status gauge cache keys colors and refreshes LRU hits") {
        try await MainActor.run {
            let cache = StatusGaugeImageCache(capacity: 2)
            let blue = StatusGaugeAppearance.preset(.blue)
            let green = StatusGaugeAppearance.preset(.green)
            let first = cache.image(label: "83%", appearance: blue)
            let second = cache.image(label: "82%", appearance: blue)
            let reused = cache.image(label: "83%", appearance: blue)
            let recolored = cache.image(label: "83%", appearance: green)
            let secondAfterEviction = cache.image(label: "82%", appearance: blue)

            try expect(first === reused, "Expected identical cached image")
            try expect(first !== recolored, "Expected colors in the cache key")
            try expect(second !== secondAfterEviction, "Expected least-recently-used eviction")
            try expect(cache.count == 2, "Expected bounded cache capacity")
            try expect(!first.isTemplate, "Expected a non-template color image")
        }
    }
}

private func gaugeTextContrastTest() -> TestCase {
    TestCase(name: "status gauge text selects the higher black or white contrast") {
        let belowCrossover = StatusGaugeColor(red: 117, green: 117, blue: 117)
        let aboveCrossover = StatusGaugeColor(red: 118, green: 118, blue: 118)

        try expect(
            StatusGaugeTextContrast.usesDarkText(for: belowCrossover) == false,
            "Expected white text below the WCAG contrast crossover"
        )
        try expect(
            StatusGaugeTextContrast.usesDarkText(for: aboveCrossover),
            "Expected black text above the WCAG contrast crossover"
        )
    }
}

private func vividPresetTextContrastTest() -> TestCase {
    TestCase(name: "vivid gauge presets use dark text with accessible contrast") {
        for preset in StatusGaugePreset.allCases {
            let fillColor = preset.fillColor
            try expect(
                StatusGaugeTextContrast.usesDarkText(for: fillColor),
                "Expected dark text for \(preset.rawValue)"
            )
            try expect(
                blackTextContrastRatio(for: fillColor) >= 4.5,
                "Expected accessible text contrast for \(preset.rawValue)"
            )
        }
    }
}

private func capsuleBitmapRenderingTest() -> TestCase {
    TestCase(name: "status slim capsule keeps readable text and compact bitmap bounds") {
        try await MainActor.run {
            let cache = StatusGaugeImageCache(capacity: 2)
            let appearance = StatusGaugeAppearance.default
            let label = "83%"
            let image = cache.image(label: label, appearance: appearance)
            let expectedFont = try expectedCapsuleFont()
            let textWidth = ("00%" as NSString).size(
                withAttributes: [.font: expectedFont]
            ).width

            try expect(image.size.height == 20, "Expected a twenty-point image")
            try expect(
                image.size.width == ceil(textWidth) + 8,
                "Expected the measured two-digit width plus four points per side"
            )
            try expect(!image.isTemplate, "Expected explicit capsule colors")
            let representations = image.representations.compactMap {
                $0 as? NSBitmapImageRep
            }
            let pixelSizes = Set(representations.map {
                "\($0.pixelsWide)x\($0.pixelsHigh)"
            })
            let width = Int(image.size.width)
            try expect(
                representations.count == image.representations.count,
                "Expected no lazy drawing representation"
            )
            try expect(
                pixelSizes == ["\(width)x20", "\(width * 2)x40"],
                "Expected eager one-times and two-times bitmaps"
            )

            let bitmap = try bitmapRepresentation(of: image)
            let corner = try bitmapPixel(bitmap, image: image, point: .zero)
            let fill = try bitmapPixel(
                bitmap,
                image: image,
                point: NSPoint(x: 4, y: image.size.height / 2)
            )
            let border = try bitmapPixel(
                bitmap,
                image: image,
                point: NSPoint(x: image.size.width / 2, y: 0)
            )

            try expect(corner.alpha < 26, "Expected transparent rounded corners")
            try expect(
                fill == BitmapPixel(color: appearance.fillColor),
                "Expected an opaque configured fill"
            )
            try expect(
                border == BitmapPixel(color: StatusGaugeColor(red: 0xA5, green: 0xAC, blue: 0xB6)),
                "Expected the contrasting light neutral border"
            )
            let roundedEdge = try bitmapPixel(
                bitmap, image: image, point: NSPoint(x: 5, y: 0)
            )
            try expect(roundedEdge.alpha == 255, "Expected a five-point corner radius")
        }
    }
}

private func slimCapsuleAppearanceTest() -> TestCase {
    TestCase(name: "status slim capsule adapts neutral colors and caches each appearance") {
        try await MainActor.run {
            let cache = StatusGaugeImageCache()
            let renderer = StatusFrameRenderer(cache: cache)
            let frame = menubarFrame(product: .codex, duration: 300, value: .fresh(83))
            let light = renderer.render(frame, appearance: try appearance(named: .aqua))
            let dark = renderer.render(frame, appearance: try appearance(named: .darkAqua))
            let repeated = renderer.render(frame, appearance: try appearance(named: .aqua))
            try expect(light.image !== dark.image, "Expected separate light and dark bitmaps")
            try expect(light.image === repeated.image, "Expected a cache hit after switching back")
            try expect(light.measuredWidth == dark.measuredWidth, "Expected appearance-stable width")
            let matchingCustom = cache.image(
                label: "83%",
                borderColor: StatusGaugePreset.neutral.borderColor,
                fillColor: StatusGaugePreset.neutral.fillColor
            )
            try expect(matchingCustom !== light.image, "Expected custom text and border styles in the cache key")
            for (rendered, color, borderColor) in [
                (light, StatusGaugeColor(red: 0xD8, green: 0xDE, blue: 0xE6),
                 StatusGaugeColor(red: 0xA5, green: 0xAC, blue: 0xB6)),
                (dark, StatusGaugeColor(red: 0x42, green: 0x4B, blue: 0x5B),
                 StatusGaugeColor(red: 0x77, green: 0x81, blue: 0x91))
            ] {
                for bitmap in rendered.image.representations.compactMap({ $0 as? NSBitmapImageRep }) {
                    let fill = try bitmapPixel(bitmap, image: rendered.image, point: NSPoint(x: 3, y: 9))
                    try expect(fill == BitmapPixel(color: color), "Expected the resolved neutral fill")
                    let edge = try bitmapPixel(bitmap, image: rendered.image,
                                               point: NSPoint(x: rendered.image.size.width / 2, y: 0))
                    try expect(edge == BitmapPixel(color: borderColor), "Expected the resolved neutral border at both scales")
                }
            }
            let custom = StatusGaugeAppearance.custom(
                borderColor: .init(red: 0, green: 0, blue: 0),
                fillColor: .init(red: 255, green: 255, blue: 255)
            )
            let customImage = cache.image(label: "83%", appearance: custom)
            let bitmap = try bitmapRepresentation(of: customImage)
            let edge = try bitmapPixel(bitmap, image: customImage, point: NSPoint(x: 10, y: 0))
            try expect(edge != BitmapPixel(color: custom.fillColor), "Expected custom border preservation")
        }
    }
}

@MainActor
private func expectedCapsuleFont() throws -> NSFont {
    guard let face = NSFont(name: "Pretendard-SemiBold", size: 16) else {
        throw TestFailure(description: "Expected the bundled Pretendard SemiBold to be registered")
    }
    let descriptor = face.fontDescriptor.addingAttributes([
        .featureSettings: [[
            NSFontDescriptor.FeatureKey.typeIdentifier: kNumberSpacingType,
            NSFontDescriptor.FeatureKey.selectorIdentifier: kMonospacedNumbersSelector
        ]]
    ])
    guard let font = NSFont(descriptor: descriptor, size: 16) else {
        throw TestFailure(description: "Expected Pretendard with tabular figures")
    }
    try expect(font.fontName == "Pretendard-SemiBold" && font.pointSize == 16,
               "Expected the real SemiBold face at sixteen points")
    return font
}

private func capsuleFontAndClippingTest() -> TestCase {
    TestCase(name: "status Pretendard digits keep their size while long labels clip inside the border") {
        try await MainActor.run {
            let cache = StatusGaugeImageCache()
            let style = StatusGaugeAppearance.custom(
                borderColor: .init(red: 255, green: 0, blue: 0),
                fillColor: .init(red: 255, green: 255, blue: 255)
            )
            let reference = cache.image(label: "00%", appearance: style)
            let font = try expectedCapsuleFont()
            let advances = (0...9).map { (String($0) as NSString).size(withAttributes: [.font: font]).width }
            try expect(advances.max()! - advances.min()! < 0.01, "Expected equal-width digits")
            let longWidth = ("~100%" as NSString).size(withAttributes: [.font: font]).width
            try expect(longWidth > reference.size.width, "Expected the long label to exercise clipping")

            for referenceBitmap in reference.representations.compactMap({ $0 as? NSBitmapImageRep }) {
                let scale = referenceBitmap.pixelsHigh / 20
                let referenceRows = try blackInkRows(referenceBitmap)
                try expect(referenceRows.count >= 9 * scale, "Expected readable sixteen-point glyphs")
                for label in ["00%", "82%", "100%", "~100%"] {
                    let image = cache.image(label: label, appearance: style)
                    guard let bitmap = image.representations.compactMap({ $0 as? NSBitmapImageRep })
                        .first(where: { $0.pixelsHigh == referenceBitmap.pixelsHigh }) else {
                        throw TestFailure(description: "Expected both bitmap scales")
                    }
                    try expect(image.size == reference.size, "Expected no expansion for longer text")
                    let rows = try blackInkRows(bitmap)
                    let line = CTLineCreateWithAttributedString(NSAttributedString(
                        string: label, attributes: [.font: font]
                    ))
                    let expectedInkHeight = Int(ceil(CTLineGetImageBounds(line, nil).height * CGFloat(scale)))
                    try expect(abs(rows.count - expectedInkHeight) <= 1,
                               "Expected each label's unscaled glyph height within one raster edge pixel")
                    try expect(rows.first! > 0 && rows.last! < bitmap.pixelsHigh - 1,
                               "Expected numeric glyphs to fit vertically")
                    let corner = try bitmapPixel(bitmap, image: image, point: .zero)
                    try expect(corner.alpha < 26, "Expected text clipped to the rounded capsule")
                }
                if scale == 2 {
                    for row in 0..<3 {
                        let edge = try bitmapPixel(referenceBitmap, image: reference,
                            point: NSPoint(x: reference.size.width / 2, y: CGFloat(row) / 2))
                        try expect(edge == BitmapPixel(red: 255, green: 0, blue: 0, alpha: 255),
                                   "Expected a 1.5pt border to occupy three Retina pixels")
                    }
                    let inside = try bitmapPixel(referenceBitmap, image: reference,
                        point: NSPoint(x: reference.size.width / 2, y: 1.5))
                    try expect(inside == BitmapPixel(red: 255, green: 255, blue: 255, alpha: 255),
                               "Expected the border to end after 1.5pt")
                }
            }
            for value in 0...100 { _ = cache.image(label: "\(value)%", appearance: style) }
            try expect(cache.count == 32, "Expected the unchanged default cache bound")
        }
    }
}

private func blackInkRows(_ bitmap: NSBitmapImageRep) throws -> [Int] {
    guard bitmap.bitsPerPixel == 32, let data = bitmap.bitmapData else {
        throw TestFailure(description: "Expected an RGBA bitmap")
    }
    return (0..<bitmap.pixelsHigh).filter { row in
        (0..<bitmap.pixelsWide).contains { column in
            let offset = row * bitmap.bytesPerRow + column * 4
            return data[offset] < 96 && data[offset + 1] < 96
                && data[offset + 2] < 96 && data[offset + 3] > 200
        }
    }
}

private func slimCapsuleNativeAppearanceObservationTest() -> TestCase {
    TestCase(name: "status slim capsule observes the native button appearance") {
        try await slimCapsuleNativeAppearanceObservationScenario()
    }
}

@MainActor
private func transientNativeAppearanceScenario() async throws {
    let button = NSStatusBarButton(frame: .zero)
    button.appearance = try appearance(named: .aqua)
    let presenter = SystemStatusItemPresenter(statusItem: NSStatusItem(), button: button)
    let renderer = RecordingStatusFrameRenderer()
    let controller = StatusItemController(presenter: presenter, renderer: renderer)
    controller.setFrames(singleFrames())
    let renders = renderer.renderCount
    for _ in 0..<100 {
        button.appearance = try appearance(named: .darkAqua)
        button.appearance = try appearance(named: .aqua)
    }
    for _ in 0..<100 { await Task.yield() }
    try expect(renderer.renderCount == renders, "Transient snapshot overrides must not rerender")
    button.appearance = try appearance(named: .darkAqua)
    for _ in 0..<100 {
        if renderer.renderCount > renders { break }
        await Task.yield()
    }
    try expect(renderer.renderCount == renders + singleFrames().count, "A real appearance change must rerender once")
    withExtendedLifetime(controller) {}
}

@MainActor
private func slimCapsuleNativeAppearanceObservationScenario() async throws {
    let statusItem = NSStatusItem()
    let button = NSStatusBarButton(frame: .zero)
    button.appearance = try appearance(named: .aqua)
    let presenter = SystemStatusItemPresenter(statusItem: statusItem, button: button)
    let controller = StatusItemController(presenter: presenter)
    controller.setFrames([menubarFrame(product: .codex, duration: 300, value: .fresh(83))])
    let lightImage = button.image
    let length = statusItem.length
    button.appearance = try appearance(named: .darkAqua)
    for _ in 0..<100 {
        if button.image !== lightImage { break }
        await Task.yield()
    }
    try expect(button.image !== lightImage, "Expected the native KVO notification to replace the image")
    try expect(statusItem.length == length, "Expected no native appearance resize")
    withExtendedLifetime(controller) {}
}

private func menubarFrame(
    product: UsageProduct,
    duration: Int?,
    value: DisplayValueState
) -> DisplayFrame {
    .single(
        DisplayQuota(
            identifier: QuotaSelectionID(
                product: product,
                rawDurationMinutes: duration
            ),
            value: value
        )
    )
}

@MainActor
private func appearance(named name: NSAppearance.Name) throws -> NSAppearance {
    guard let appearance = NSAppearance(named: name) else {
        throw TestFailure(description: "Expected system appearance")
    }
    return appearance
}

@MainActor
private func bitmapRepresentation(of image: NSImage) throws -> NSBitmapImageRep {
    let representations = image.representations.compactMap { representation in
        representation as? NSBitmapImageRep
    }
    guard let bitmap = representations.min(by: { left, right in
        left.pixelsWide < right.pixelsWide
    }) else {
        throw TestFailure(description: "Expected a bitmap representation")
    }
    return bitmap
}

@MainActor
private func bitmapPixel(
    _ bitmap: NSBitmapImageRep,
    image: NSImage,
    point: NSPoint
) throws -> BitmapPixel {
    let horizontalScale = CGFloat(bitmap.pixelsWide) / image.size.width
    let verticalScale = CGFloat(bitmap.pixelsHigh) / image.size.height
    let horizontal = min(
        max(Int(point.x * horizontalScale), 0),
        bitmap.pixelsWide - 1
    )
    let vertical = min(
        max(Int(point.y * verticalScale), 0),
        bitmap.pixelsHigh - 1
    )
    guard bitmap.bitsPerPixel == 32, let data = bitmap.bitmapData else {
        throw TestFailure(description: "Expected an 8-bit RGBA bitmap")
    }
    let offset = vertical * bitmap.bytesPerRow + horizontal * 4
    return BitmapPixel(
        red: data[offset],
        green: data[offset + 1],
        blue: data[offset + 2],
        alpha: data[offset + 3]
    )
}

private struct BitmapPixel: Equatable {
    let red: UInt8
    let green: UInt8
    let blue: UInt8
    let alpha: UInt8

    init(red: UInt8, green: UInt8, blue: UInt8, alpha: UInt8) {
        self.red = red
        self.green = green
        self.blue = blue
        self.alpha = alpha
    }

    init(color: StatusGaugeColor) {
        self.init(red: color.red, green: color.green, blue: color.blue, alpha: .max)
    }
}

private func blackTextContrastRatio(for color: StatusGaugeColor) -> Double {
    (relativeLuminance(of: color) + 0.05) / 0.05
}

private func relativeLuminance(of color: StatusGaugeColor) -> Double {
    0.2126 * linearColorComponent(color.red)
        + 0.7152 * linearColorComponent(color.green)
        + 0.0722 * linearColorComponent(color.blue)
}

private func linearColorComponent(_ component: UInt8) -> Double {
    let value = Double(component) / Double(UInt8.max)
    guard value > 0.04045 else {
        return value / 12.92
    }
    return pow((value + 0.055) / 1.055, 2.4)
}

private enum StatusTestLanguage {
    case korean
    case english
}

private func statusVocabulary(
    language: StatusTestLanguage
) -> StatusAccessibilityVocabulary {
    switch language {
    case .korean:
        StatusAccessibilityVocabulary(
            quotaFormat: "{product} {duration} 한도 {value}",
            freshValueFormat: "남은 사용량 {percent}퍼센트",
            staleValueFormat: "남은 사용량 마지막 확인값 {percent}퍼센트",
            loadingValue: "사용량 확인 중",
            unavailableValue: "사용량 확인 불가"
        )
    case .english:
        StatusAccessibilityVocabulary(
            quotaFormat: "{product} {duration} quota, {value}",
            freshValueFormat: "{percent} percent remaining",
            staleValueFormat: "last confirmed value {percent} percent remaining",
            loadingValue: "checking usage",
            unavailableValue: "usage unavailable"
        )
    }
}

private func durationVocabulary(
    language: StatusTestLanguage
) -> SettingsDurationAccessibilityVocabulary {
    switch language {
    case .korean:
        SettingsDurationAccessibilityVocabulary(
            unknown: "기간 미상",
            oneHour: "1시간",
            hours: "{count}시간",
            oneDay: "1일",
            days: "{count}일",
            oneWeek: "1주",
            weeks: "{count}주"
        )
    case .english:
        SettingsDurationAccessibilityVocabulary(
            unknown: "unknown duration",
            oneHour: "1 hour",
            hours: "{count} hours",
            oneDay: "1 day",
            days: "{count} days",
            oneWeek: "1 week",
            weeks: "{count} weeks"
        )
    }
}

@MainActor
private final class RecordingStatusItemPresenter: StatusItemPresenting {
    private(set) var presentedSemanticTitles: [String] = []
    private(set) var accessibilityLabels: [String] = []
    private(set) var lengths: [CGFloat] = []
    private(set) var announcementCount = 0
    private(set) var inputOutputCount = 0
    var effectiveAppearance: NSAppearance?
    var appearanceChangeHandler: (@MainActor @Sendable () -> Void)?
    private(set) var images: [NSImage] = []

    init() {
        effectiveAppearance = NSAppearance(named: .aqua)
    }

    func setLength(_ length: CGFloat) {
        lengths.append(length)
    }

    func setAppearanceChangeHandler(_ handler: @escaping @MainActor @Sendable () -> Void) {
        appearanceChangeHandler = handler
    }

    func present(_ frame: RenderedStatusFrame) {
        images.append(frame.image)
        presentedSemanticTitles.append(frame.semanticTitle)
        accessibilityLabels.append(frame.accessibilityLabel)
    }
}

@MainActor
private final class RecordingStatusFrameRenderer: StatusFrameRendering {
    private let widths: [String: CGFloat]
    private let formatter = DisplayFrameFormatter()
    private let accessibilityFormatter = StatusAccessibilityFormatter(
        vocabulary: statusVocabulary(language: .korean),
        durationVocabulary: durationVocabulary(language: .korean)
    )
    private(set) var renderCount = 0

    init(widths: [String: CGFloat] = [:]) {
        self.widths = widths
    }

    func render(
        _ frame: DisplayFrame,
        appearance: NSAppearance?
    ) -> RenderedStatusFrame {
        _ = appearance
        renderCount += 1
        let formatted = formatter.format(frame)
        let measuredWidth = widths[formatted.title] ?? CGFloat(formatted.title.count * 8)
        return RenderedStatusFrame(
            image: NSImage(size: NSSize(width: measuredWidth, height: 20)),
            semanticTitle: formatted.title,
            visualLabel: formatted.title,
            accessibilityLabel: accessibilityFormatter.format(frame),
            measuredWidth: measuredWidth
        )
    }
}

private func singleStatusStatesTest() -> TestCase {
    TestCase(name: "single status shows only percentages and preserves state markers") {
        try await MainActor.run {
            let renderer = StatusFrameRenderer()
            let durations: [Int?] = [300, 10_080, 90, nil]
            let states: [(DisplayValueState, String)] = [
                (.fresh(83), "83%"), (.stale(83), "~83%"),
                (.loading, "…"), (.unavailable, "—")
            ]
            for duration in durations {
                for (value, label) in states {
                    let rendered = renderer.render(
                        menubarFrame(product: .codex, duration: duration, value: value),
                        appearance: nil
                    )
                    try expect(rendered.visualLabel == label, "Expected a value-only capsule")
                    try expect(rendered.measuredWidth == rendered.image.size.width, "Expected full capsule width")
                }
            }
        }
    }
}

private func fixedCapsuleAllocationTest() -> TestCase {
    TestCase(name: "single capsule fills its fixed width with two-point outer insets at every scale") {
        try await MainActor.run {
            let presenter = RecordingStatusItemPresenter()
            let controller = StatusItemController(presenter: presenter)
            let reference = StatusGaugeImageCache().image(label: "00%", appearance: .default)
            let font = try expectedCapsuleFont()
            let values = (0...100).flatMap { [DisplayValueState.fresh($0), .stale($0)] }
                + [.loading, .unavailable]
            let expectedWidth = ceil(("00%" as NSString).size(withAttributes: [.font: font]).width) + 8
            try expect(reference.size.width == expectedWidth, "Expected the native two-digit measurement")
            for appearanceName in [NSAppearance.Name.aqua, .darkAqua] {
                presenter.effectiveAppearance = try appearance(named: appearanceName)
                for value in values {
                    controller.setFrames([menubarFrame(product: .codex, duration: 300, value: value)])
                    guard let image = presenter.images.last else {
                        throw TestFailure(description: "Expected a capsule image")
                    }
                    try expect(image.size == NSSize(width: expectedWidth, height: 20), "Expected minimal fixed capsule geometry")
                    for bitmap in image.representations.compactMap({ $0 as? NSBitmapImageRep }) {
                        let left = try bitmapPixel(bitmap, image: image, point: NSPoint(x: 1, y: 10))
                        let right = try bitmapPixel(bitmap, image: image, point: NSPoint(x: image.size.width - 2, y: 10))
                        try expect(left.alpha == 255 && right.alpha == 255, "Expected capsule fill to span the allocated image")
                    }
                }
            }
            try expect(presenter.lengths == [expectedWidth + 4], "Expected exactly two outer points per side without resizing")
        }
    }
}

private func localizedSingleAccessibilityTest() -> TestCase {
    TestCase(name: "single status retains localized duration and stale accessibility") {
        let frame = menubarFrame(product: .codex, duration: 300, value: .stale(75))
        try expect(StatusAccessibilityFormatter(language: .korean).format(frame)
            == "Codex 5시간 한도 남은 사용량 마지막 확인값 75퍼센트", "Expected Korean duration and freshness")
        try expect(StatusAccessibilityFormatter(language: .english).format(frame)
            == "Codex 5 hours quota, last confirmed value 75 percent remaining", "Expected English duration and freshness")
        let unknown = menubarFrame(product: .codex, duration: nil, value: .unavailable)
        try expect(StatusAccessibilityFormatter(language: .english).format(unknown)
            == "Codex unknown duration quota, usage unavailable", "Expected missing duration and value without fake zero")
    }
}

private func singleFrameReplacementTest() -> TestCase {
    TestCase(name: "status replaces one selected value without retaining rotation candidates") {
        try await MainActor.run {
            let fixture = makeControllerFixture()
            let first = singleFrames()[0]
            let second = menubarFrame(product: .codex, duration: 10_080, value: .fresh(42))
            fixture.controller.setFrames([first, second])
            try expect(fixture.renderer.renderCount == 1, "Expected only one selected frame to render")
            fixture.controller.setFrames([second])
            try expect(fixture.presenter.presentedSemanticTitles == ["[5h] 83%", "[w] 42%"], "Expected direct selected frame replacement")
            try expect(fixture.presenter.accessibilityLabels.last == "Codex 1주 한도 남은 사용량 42퍼센트", "Expected updated accessible selection")
            try expect(fixture.presenter.announcementCount == 0, "Expected no unsolicited announcements")
        }
    }
}

private func singleAppearanceRefreshTest() -> TestCase {
    TestCase(name: "single status recolors once while preserving value and allocation") {
        try await MainActor.run {
            let presenter = RecordingStatusItemPresenter()
            let controller = StatusItemController(presenter: presenter)
            controller.setFrames(singleFrames())
            let originalImage = presenter.images.last
            presenter.effectiveAppearance = try appearance(named: .darkAqua)
            for _ in 0..<100 { presenter.appearanceChangeHandler?() }
            try expect(presenter.images.count == 2, "Expected one actual palette update")
            try expect(presenter.images.last !== originalImage, "Expected recolored image")
            try expect(presenter.presentedSemanticTitles == ["[5h] 83%", "[5h] 83%"], "Expected unchanged selection")
            try expect(presenter.lengths.count == 1, "Expected no appearance resize")
        }
    }
}

@MainActor
private struct ControllerFixture {
    let controller: StatusItemController
    let presenter: RecordingStatusItemPresenter
    let renderer: RecordingStatusFrameRenderer
}

@MainActor
private func makeControllerFixture() -> ControllerFixture {
    let presenter = RecordingStatusItemPresenter()
    let renderer = RecordingStatusFrameRenderer()
    return ControllerFixture(
        controller: StatusItemController(presenter: presenter, renderer: renderer),
        presenter: presenter,
        renderer: renderer
    )
}

private func singleFrames() -> [DisplayFrame] {
    [menubarFrame(product: .codex, duration: 300, value: .fresh(83))]
}
