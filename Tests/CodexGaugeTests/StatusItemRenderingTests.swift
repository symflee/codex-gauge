import AppKit
import CodexGaugeAppKit
import CodexGaugeCore
import CodexGaugeSettings

func statusItemRenderingTests() -> [TestCase] {
    [
        explicitAppLocalizationTest(),
        badgeImageCacheTest(),
        localizedAccessibilityTest(),
        statusRendererReplacementTest(),
        attributedFrameRenderingTest(),
        renderedStateSemanticsTest(),
        fixedWidthPolicyTest(),
        derivedWidthPrototypeStabilityTest(),
        singleFrameHasNoScheduleTest(),
        rotationOrderingTest(),
        rotationPauseResumeTest(),
        rotationTickUsesCachedFramesTest(),
        accessibilityUpdateTest()
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

private func localizedAccessibilityTest() -> TestCase {
    TestCase(name: "status accessibility supports Korean and English localization") {
        let korean = StatusAccessibilityFormatter(language: .korean)
        let english = StatusAccessibilityFormatter(language: .english)
        let comparison = DisplayFrame.comparison(
            codex: menubarQuota(product: .codex, duration: 300, value: .stale(75)),
            spark: menubarQuota(product: .spark, duration: nil, value: .unavailable)
        )

        try expect(
            korean.format(comparison)
                == "Codex 5시간 한도 남은 사용량 마지막 확인값 75퍼센트, "
                + "Spark 기간 미상 한도 사용량 확인 불가",
            "Unexpected Korean status accessibility"
        )
        try expect(
            english.format(comparison)
                == "Codex 5 hours quota, last confirmed value 75 percent remaining, "
                + "Spark unknown duration quota, usage unavailable",
            "Unexpected English status accessibility"
        )
        let unknownDuration = try statusLocalizationValue(
            language: "en",
            key: "status.accessibility.duration.unknown"
        )
        try expect(
            unknownDuration == "unknown duration",
            "Expected sentence-case English duration resource"
        )
    }
}

private func statusRendererReplacementTest() -> TestCase {
    TestCase(name: "status controller replaces its renderer for immediate localization") {
        try await MainActor.run {
            let presenter = RecordingStatusItemPresenter()
            let controller = StatusItemController(
                presenter: presenter,
                renderer: StatusFrameRenderer(language: .korean),
                scheduler: ManualStatusRotationScheduler()
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

private func badgeImageCacheTest() -> TestCase {
    TestCase(name: "status badge cache reuses images and stays bounded") {
        try await MainActor.run {
            let cache = StatusBadgeImageCache(capacity: 2)
            let aqua = try appearance(named: .aqua)
            let dark = try appearance(named: .darkAqua)

            let first = cache.image(label: "5h", appearance: aqua)
            let reused = cache.image(label: "5h", appearance: aqua)
            let darkImage = cache.image(label: "5h", appearance: dark)
            _ = cache.image(label: "w", appearance: aqua)

            try expect(first === reused, "Expected identical cached image")
            try expect(first !== darkImage, "Expected appearance-specific cache key")
            try expect(cache.count == 2, "Expected bounded cache capacity")
            try expect(first.isTemplate, "Expected a monochrome template badge")
        }
    }
}

private func attributedFrameRenderingTest() -> TestCase {
    TestCase(name: "status renderer preserves formatter semantics and badges") {
        try await MainActor.run {
            let renderer = StatusFrameRenderer()
            let aqua = try appearance(named: .aqua)
            let single = renderer.render(
                menubarFrame(product: .codex, duration: 300, value: .fresh(83)),
                appearance: aqua
            )
            let comparison = renderer.render(mixedComparisonFrame(), appearance: aqua)

            try expect(single.semanticTitle == "[5h] 83%", "Unexpected single semantic title")
            try expect(single.badgeLabels == ["5h"], "Expected one five-hour badge")
            try expect(attachmentCount(single.attributedTitle) == 1, "Expected one attachment")
            try expect(hasMonospacedValueFont(single, value: "83%"), "Expected monospaced digits")
            try expect(
                comparison.semanticTitle == "C[5h]75% · S[w]82%",
                "Unexpected comparison semantics"
            )
            try expect(comparison.badgeLabels == ["5h", "w"], "Expected two period badges")
            try expect(attachmentCount(comparison.attributedTitle) == 2, "Expected two attachments")
        }
    }
}

private func renderedStateSemanticsTest() -> TestCase {
    TestCase(name: "status renderer keeps fresh stale loading and unavailable states") {
        try await MainActor.run {
            let renderer = StatusFrameRenderer()
            let aqua = try appearance(named: .aqua)
            let expectations: [(DisplayValueState, String)] = [
                (.fresh(83), "[5h] 83%"),
                (.stale(83), "[5h] ~83%"),
                (.loading, "[5h] …"),
                (.unavailable, "[5h] —")
            ]

            for expectation in expectations {
                let frame = menubarFrame(
                    product: .codex,
                    duration: 300,
                    value: expectation.0
                )
                let rendered = renderer.render(frame, appearance: aqua)
                try expect(rendered.semanticTitle == expectation.1, "Unexpected rendered state")
            }
        }
    }
}

private func fixedWidthPolicyTest() -> TestCase {
    TestCase(name: "status width uses prototypes padding without clipping") {
        try await MainActor.run {
            let presenter = RecordingStatusItemPresenter()
            let scheduler = ManualStatusRotationScheduler()
            let renderer = RecordingStatusFrameRenderer(widths: [
                "[5h] 9%": 20,
                "[w] 82%": 50,
                "[w] ~100%": 90,
                "[30d] ~100%": 300
            ])
            let controller = StatusItemController(
                presenter: presenter,
                renderer: renderer,
                scheduler: scheduler
            )
            let frames = [
                menubarFrame(product: .codex, duration: 300, value: .fresh(9)),
                menubarFrame(product: .codex, duration: 10_080, value: .fresh(82))
            ]
            let prototype = menubarFrame(
                product: .codex,
                duration: 10_080,
                value: .stale(100)
            )

            controller.setFrames(frames, widthPrototypes: [prototype])
            try expect(presenter.lengths == [102], "Expected maximum width plus padding")
            scheduler.fire()
            try expect(presenter.lengths == [102], "Expected width unchanged on tick")

            let widePrototype = menubarFrame(
                product: .codex,
                duration: 43_200,
                value: .stale(100)
            )
            controller.setFrames([frames[0]], widthPrototypes: [widePrototype])
            try expect(presenter.lengths.last == 312, "Expected full unclipped width")
        }
    }
}

private func derivedWidthPrototypeStabilityTest() -> TestCase {
    TestCase(name: "status width derives worst values without caller prototypes") {
        try await MainActor.run {
            let presenter = RecordingStatusItemPresenter()
            let renderer = RecordingStatusFrameRenderer(widths: [
                "[5h] 9%": 20,
                "[5h] 100%": 80,
                "[5h] ~100%": 90
            ])
            let controller = StatusItemController(
                presenter: presenter,
                renderer: renderer,
                scheduler: ManualStatusRotationScheduler()
            )

            controller.setFrames([
                menubarFrame(product: .codex, duration: 300, value: .fresh(9))
            ])
            controller.setFrames([
                menubarFrame(product: .codex, duration: 300, value: .fresh(100))
            ])

            try expect(presenter.lengths == [102, 102], "Expected stable derived width")
        }
    }
}

private func singleFrameHasNoScheduleTest() -> TestCase {
    TestCase(name: "one status frame creates no rotation schedule command") {
        try await MainActor.run {
            let fixture = makeControllerFixture()
            let frame = menubarFrame(product: .codex, duration: 300, value: .loading)

            fixture.controller.setFrames([frame])

            try expect(fixture.scheduler.requests.isEmpty, "Expected no schedule")
            try expect(fixture.scheduler.cancelCount == 0, "Expected no timer cancellation")
            try expect(fixture.presenter.presentedSemanticTitles == ["[5h] …"], "Expected frame")
        }
    }
}

private func rotationOrderingTest() -> TestCase {
    TestCase(name: "status frames rotate every five seconds in order") {
        try await MainActor.run {
            let fixture = makeControllerFixture()
            let frames = rotationFrames()

            fixture.controller.setFrames(frames)
            try expect(fixture.scheduler.requests == [.init(interval: 5, tolerance: 1)], "Unexpected timer")

            fixture.scheduler.fire()
            fixture.scheduler.fire()
            fixture.scheduler.fire()

            try expect(
                fixture.presenter.presentedSemanticTitles
                    == ["[5h] 83%", "[w] 82%", "[d] 81%", "[5h] 83%"],
                "Expected deterministic frame order"
            )
        }
    }
}

private func rotationPauseResumeTest() -> TestCase {
    TestCase(name: "all status pause reasons cancel and restart from frame zero") {
        try await MainActor.run {
            let fixture = makeControllerFixture()
            fixture.controller.setFrames(rotationFrames())

            for reason in StatusRotationPauseReason.allCases {
                fixture.scheduler.fire()
                fixture.controller.setPaused(true, for: reason)
                let countWhilePaused = fixture.presenter.presentedSemanticTitles.count
                fixture.scheduler.fire()
                try expect(
                    fixture.presenter.presentedSemanticTitles.count == countWhilePaused,
                    "Expected no paused tick"
                )
                fixture.controller.setPaused(false, for: reason)
                try expect(
                    fixture.presenter.presentedSemanticTitles.last == "[5h] 83%",
                    "Expected resume at frame zero"
                )
            }

            try expect(fixture.scheduler.cancelCount == 5, "Expected one cancellation per reason")
            try expect(fixture.scheduler.requests.count == 6, "Expected fresh schedule after resume")
        }
    }
}

private func rotationTickUsesCachedFramesTest() -> TestCase {
    TestCase(name: "rotation tick only presents pre-rendered cached frames") {
        try await MainActor.run {
            let fixture = makeControllerFixture()
            fixture.controller.setFrames(rotationFrames())
            let renderCount = fixture.renderer.renderCount
            let lengthCount = fixture.presenter.lengths.count

            fixture.scheduler.fire()
            fixture.scheduler.fire()

            try expect(fixture.renderer.renderCount == renderCount, "Expected no tick rendering")
            try expect(fixture.presenter.lengths.count == lengthCount, "Expected no tick resize")
            try expect(fixture.presenter.inputOutputCount == 0, "Expected no tick I/O")
        }
    }
}

private func accessibilityUpdateTest() -> TestCase {
    TestCase(name: "status accessibility follows frames without announcements") {
        try await MainActor.run {
            let fixture = makeControllerFixture()
            fixture.controller.setFrames(rotationFrames())
            fixture.scheduler.fire()

            try expect(
                fixture.presenter.accessibilityLabels == [
                    "Codex 5시간 한도 남은 사용량 83퍼센트",
                    "Codex 1주 한도 남은 사용량 82퍼센트"
                ],
                "Expected accessibility label updates"
            )
            try expect(fixture.presenter.announcementCount == 0, "Expected no announcements")
        }
    }
}

@MainActor
private func makeControllerFixture() -> ControllerFixture {
    let presenter = RecordingStatusItemPresenter()
    let scheduler = ManualStatusRotationScheduler()
    let renderer = RecordingStatusFrameRenderer()
    let controller = StatusItemController(
        presenter: presenter,
        renderer: renderer,
        scheduler: scheduler
    )
    return ControllerFixture(
        controller: controller,
        presenter: presenter,
        scheduler: scheduler,
        renderer: renderer
    )
}

private func rotationFrames() -> [DisplayFrame] {
    [
        menubarFrame(product: .codex, duration: 300, value: .fresh(83)),
        menubarFrame(product: .codex, duration: 10_080, value: .fresh(82)),
        menubarFrame(product: .codex, duration: 1_440, value: .fresh(81))
    ]
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

private func mixedComparisonFrame() -> DisplayFrame {
    let codex = menubarQuota(product: .codex, duration: 300, value: .fresh(75))
    let spark = menubarQuota(product: .spark, duration: 10_080, value: .fresh(82))
    return .comparison(codex: codex, spark: spark)
}

private func menubarQuota(
    product: UsageProduct,
    duration: Int?,
    value: DisplayValueState
) -> DisplayQuota {
    DisplayQuota(
        identifier: QuotaSelectionID(
            product: product,
            rawDurationMinutes: duration
        ),
        value: value
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
private func attachmentCount(_ title: NSAttributedString) -> Int {
    var count = 0
    let range = NSRange(location: 0, length: title.length)
    title.enumerateAttribute(.attachment, in: range) { value, _, _ in
        if value != nil {
            count += 1
        }
    }
    return count
}

@MainActor
private func hasMonospacedValueFont(
    _ frame: RenderedStatusFrame,
    value: String
) -> Bool {
    let range = (frame.attributedTitle.string as NSString).range(of: value)
    guard range.location != NSNotFound else {
        return false
    }
    let font = frame.attributedTitle.attribute(.font, at: range.location, effectiveRange: nil)
    let expected = NSFont.monospacedDigitSystemFont(
        ofSize: NSFont.systemFontSize,
        weight: .regular
    )
    return font as? NSFont == expected
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
            unavailableValue: "사용량 확인 불가",
            comparisonSeparator: ", "
        )
    case .english:
        StatusAccessibilityVocabulary(
            quotaFormat: "{product} {duration} quota, {value}",
            freshValueFormat: "{percent} percent remaining",
            staleValueFormat: "last confirmed value {percent} percent remaining",
            loadingValue: "checking usage",
            unavailableValue: "usage unavailable",
            comparisonSeparator: ", "
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

private func statusLocalizationValue(
    language: String,
    key: String
) throws -> String {
    let contents = try String(
        contentsOf: statusLocalizationFile(language: language),
        encoding: .utf8
    )
    let prefix = "\"\(key)\" = \""
    guard let line = contents.split(separator: "\n").first(where: {
        $0.hasPrefix(prefix)
    }) else {
        throw TestFailure(description: "Missing status localization key")
    }
    return String(line.dropFirst(prefix.count).dropLast(2))
}

private func statusLocalizationFile(language: String) -> URL {
    URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .appendingPathComponent("Sources/CodexGaugeAppKit/Resources")
        .appendingPathComponent("\(language).lproj/Localizable.strings")
}

@MainActor
private struct ControllerFixture {
    let controller: StatusItemController
    let presenter: RecordingStatusItemPresenter
    let scheduler: ManualStatusRotationScheduler
    let renderer: RecordingStatusFrameRenderer
}

@MainActor
private final class RecordingStatusItemPresenter: StatusItemPresenting {
    private(set) var presentedSemanticTitles: [String] = []
    private(set) var accessibilityLabels: [String] = []
    private(set) var lengths: [CGFloat] = []
    private(set) var announcementCount = 0
    private(set) var inputOutputCount = 0
    let effectiveAppearance: NSAppearance?

    init() {
        effectiveAppearance = NSAppearance(named: .aqua)
    }

    func setLength(_ length: CGFloat) {
        lengths.append(length)
    }

    func present(_ frame: RenderedStatusFrame) {
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
        return RenderedStatusFrame(
            attributedTitle: NSAttributedString(string: formatted.title),
            semanticTitle: formatted.title,
            accessibilityLabel: accessibilityFormatter.format(frame),
            badgeLabels: [],
            measuredWidth: widths[formatted.title] ?? CGFloat(formatted.title.count * 8)
        )
    }
}

@MainActor
private final class ManualStatusRotationScheduler: StatusRotationScheduling {
    struct Request: Equatable {
        let interval: TimeInterval
        let tolerance: TimeInterval
    }

    private(set) var requests: [Request] = []
    private(set) var cancelCount = 0
    private var action: (@MainActor () -> Void)?

    func schedule(
        interval: TimeInterval,
        tolerance: TimeInterval,
        action: @escaping @MainActor () -> Void
    ) {
        requests.append(Request(interval: interval, tolerance: tolerance))
        self.action = action
    }

    func cancel() {
        cancelCount += 1
        action = nil
    }

    func fire() {
        action?()
    }
}
