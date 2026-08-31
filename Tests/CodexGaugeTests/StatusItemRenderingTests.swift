import AppKit
import CodexGaugeAppKit
import CodexGaugeCore
import CodexGaugeSettings

func statusItemRenderingTests() -> [TestCase] {
    [
        explicitAppLocalizationTest(),
        visualLabelFormattingTest(),
        compactVisualLabelFormattingTest(),
        compactUnknownDurationBadgeFormattingTest(),
        statusDurationPresentationPolicyTest(),
        statusDurationModeTransitionTest(),
        widthPrototypePreservesActualDurationModeTest(),
        gaugeImageCacheTest(),
        gaugeTextContrastTest(),
        vividPresetTextContrastTest(),
        capsuleBitmapRenderingTest(),
        systemPresenterUsesImageOnlyTest(),
        localizedAccessibilityTest(),
        statusRendererReplacementTest(),
        capsuleFrameRenderingTest(),
        renderedPercentageBoundaryTest(),
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
                    rendered.visualLabel == "5h \(percent)%",
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
            let presenter = SystemStatusItemPresenter(
                statusItem: statusItem,
                button: button
            )
            let image = StatusGaugeImageCache().image(
                label: "5h 83%",
                appearance: .default
            )
            let frame = RenderedStatusFrame(
                image: image,
                semanticTitle: "[5h] 83%",
                visualLabel: "5h 83%",
                accessibilityLabel: "synthetic accessibility label",
                measuredWidth: image.size.width
            )
            button.attributedTitle = NSAttributedString(string: "legacy title")

            presenter.present(frame)

            try expect(button.image === image, "Expected the rendered capsule image")
            try expect(button.imagePosition == .imageOnly, "Expected image-only layout")
            try expect(button.imageScaling == .scaleNone, "Expected no image scaling")
            try expect(button.attributedTitle.length == 0, "Expected the title to be cleared")
        }
    }
}

private func visualLabelFormattingTest() -> TestCase {
    TestCase(name: "status visual labels use the capsule layout") {
        let formatter = StatusGaugeVisualLabelFormatter()
        let codex = menubarFrame(
            product: .codex,
            duration: 300,
            value: .fresh(83)
        )
        let spark = menubarFrame(
            product: .spark,
            duration: 300,
            value: .fresh(91)
        )
        let sharedDuration = DisplayFrame.comparison(
            codex: menubarQuota(product: .codex, duration: 10_080, value: .fresh(75)),
            spark: menubarQuota(product: .spark, duration: 10_080, value: .fresh(82))
        )

        try expect(formatter.format(codex) == "5h 83%", "Unexpected Codex label")
        try expect(formatter.format(spark) == "S 5h 91%", "Unexpected Spark label")
        try expect(
            formatter.format(sharedDuration) == "w C75% · S82%",
            "Unexpected shared-duration label"
        )
        try expect(
            formatter.format(mixedComparisonFrame()) == "C 5h 75% · S w 82%",
            "Unexpected mixed-duration label"
        )
    }
}

private func compactVisualLabelFormattingTest() -> TestCase {
    TestCase(name: "compact status labels omit only known durations") {
        let formatter = StatusGaugeVisualLabelFormatter()
        let mode = StatusDurationMode.compactSingleCriterion
        let codex = menubarFrame(
            product: .codex,
            duration: 300,
            value: .fresh(83)
        )
        let spark = menubarFrame(
            product: .spark,
            duration: 300,
            value: .fresh(91)
        )
        let unknown = menubarFrame(
            product: .codex,
            duration: nil,
            value: .stale(83)
        )
        let unknownSpark = menubarFrame(
            product: .spark,
            duration: nil,
            value: .fresh(91)
        )
        let sharedDuration = DisplayFrame.comparison(
            codex: menubarQuota(product: .codex, duration: 10_080, value: .fresh(75)),
            spark: menubarQuota(product: .spark, duration: 10_080, value: .fresh(82))
        )
        let unknownSharedDuration = DisplayFrame.comparison(
            codex: menubarQuota(product: .codex, duration: nil, value: .loading),
            spark: menubarQuota(product: .spark, duration: nil, value: .unavailable)
        )

        try expect(formatter.format(codex, durationMode: mode) == "83%", "Unexpected Codex label")
        try expect(formatter.format(spark, durationMode: mode) == "S 91%", "Unexpected Spark label")
        try expect(
            formatter.format(unknown, durationMode: mode) == "? ~83%",
            "Expected unknown duration"
        )
        try expect(
            formatter.format(unknownSpark, durationMode: mode) == "S ? 91%",
            "Expected the Spark unknown duration marker"
        )
        let stateExpectations: [(DisplayValueState, String)] = [
            (.fresh(83), "83%"),
            (.stale(83), "~83%"),
            (.loading, "…"),
            (.unavailable, "—")
        ]
        for expectation in stateExpectations {
            let frame = menubarFrame(product: .codex, duration: 300, value: expectation.0)
            try expect(
                formatter.format(frame, durationMode: mode) == expectation.1,
                "Unexpected compact value state"
            )
        }
        try expect(
            formatter.format(sharedDuration, durationMode: mode) == "C75% · S82%",
            "Unexpected same-duration comparison label"
        )
        try expect(
            formatter.format(unknownSharedDuration, durationMode: mode) == "? C… · S—",
            "Expected a shared unknown duration marker"
        )
    }
}

private func compactUnknownDurationBadgeFormattingTest() -> TestCase {
    TestCase(name: "compact status labels preserve unrepresentable duration markers") {
        let formatter = StatusGaugeVisualLabelFormatter()
        let mode = StatusDurationMode.compactSingleCriterion
        let single = menubarFrame(
            product: .codex,
            duration: 90,
            value: .fresh(83)
        )
        let comparison = DisplayFrame.comparison(
            codex: menubarQuota(product: .codex, duration: 90, value: .fresh(75)),
            spark: menubarQuota(product: .spark, duration: 90, value: .fresh(82))
        )

        try expect(
            formatter.format(single, durationMode: mode) == "? 83%",
            "Expected an unrepresentable single duration marker"
        )
        try expect(
            formatter.format(comparison, durationMode: mode) == "? C75% · S82%",
            "Expected an unrepresentable shared duration marker"
        )
    }
}

private func statusDurationModeTransitionTest() -> TestCase {
    TestCase(name: "status duration mode follows one multiple one transitions") {
        try await MainActor.run {
            let fixture = makeControllerFixture()
            let single = menubarFrame(product: .codex, duration: 300, value: .fresh(83))
            let second = menubarFrame(product: .codex, duration: 10_080, value: .fresh(82))

            fixture.controller.setFrames([single])
            fixture.controller.setFrames([single, second])
            fixture.controller.setFrames([single])

            try expect(
                fixture.renderer.durationModes == [
                    .compactSingleCriterion, .compactSingleCriterion,
                    .full, .full, .full, .full,
                    .compactSingleCriterion, .compactSingleCriterion
                ],
                "Expected mode to be recomputed from each actual frame set"
            )
        }
    }
}

private func widthPrototypePreservesActualDurationModeTest() -> TestCase {
    TestCase(name: "caller width prototype cannot expand compact duration mode") {
        try await MainActor.run {
            let single = menubarFrame(product: .codex, duration: 300, value: .fresh(83))
            let modes = renderedDurationModes(
                frames: [single],
                widthPrototypes: [mixedComparisonFrame()]
            )

            try expect(
                modes == [
                    .compactSingleCriterion,
                    .compactSingleCriterion,
                    .compactSingleCriterion
                ],
                "Expected actual derived and caller prototypes to share compact mode"
            )
        }
    }
}

private func statusDurationPresentationPolicyTest() -> TestCase {
    TestCase(name: "status duration mode counts only actual display criteria") {
        try await MainActor.run {
            let single = menubarFrame(product: .codex, duration: 300, value: .fresh(83))
            let second = menubarFrame(product: .codex, duration: 10_080, value: .fresh(82))
            let sameDuration = DisplayFrame.comparison(
                codex: menubarQuota(product: .codex, duration: 300, value: .fresh(75)),
                spark: menubarQuota(product: .spark, duration: 300, value: .fresh(82))
            )

            try expect(
                renderedDurationModes(frames: [single])
                    == [.compactSingleCriterion, .compactSingleCriterion],
                "Expected one single criterion to stay compact"
            )
            try expect(
                renderedDurationModes(frames: [sameDuration])
                    == [.compactSingleCriterion, .compactSingleCriterion],
                "Expected one shared-duration criterion to stay compact"
            )
            try expect(
                renderedDurationModes(frames: [mixedComparisonFrame()]) == [.full, .full],
                "Expected a mixed comparison to count as two criteria"
            )
            try expect(
                renderedDurationModes(frames: [single, second])
                    == [.full, .full, .full, .full],
                "Expected multiple actual criteria to retain durations"
            )
        }
    }
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

private func gaugeImageCacheTest() -> TestCase {
    TestCase(name: "status gauge cache keys colors and refreshes LRU hits") {
        try await MainActor.run {
            let cache = StatusGaugeImageCache(capacity: 2)
            let blue = StatusGaugeAppearance.preset(.blue)
            let green = StatusGaugeAppearance.preset(.green)
            let first = cache.image(label: "5h 83%", appearance: blue)
            let second = cache.image(label: "w 82%", appearance: blue)
            let reused = cache.image(label: "5h 83%", appearance: blue)
            let recolored = cache.image(label: "5h 83%", appearance: green)
            let secondAfterEviction = cache.image(label: "w 82%", appearance: blue)

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
    TestCase(name: "status gauge renders a twenty-point opaque capsule") {
        try await MainActor.run {
            let cache = StatusGaugeImageCache(capacity: 2)
            let appearance = StatusGaugeAppearance.default
            let label = "5h 83%"
            let image = cache.image(label: label, appearance: appearance)
            let expectedFont = NSFont.monospacedDigitSystemFont(
                ofSize: 13,
                weight: .semibold
            )
            let textWidth = (label as NSString).size(
                withAttributes: [.font: expectedFont]
            ).width

            try expect(image.size.height == 20, "Expected a twenty-point image")
            try expect(
                image.size.width == ceil(textWidth) + 20,
                "Expected ten-point horizontal padding"
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
                border == BitmapPixel(color: appearance.borderColor),
                "Expected a one-point configured border"
            )
        }
    }
}

private func capsuleFrameRenderingTest() -> TestCase {
    TestCase(name: "status renderer preserves semantics in one capsule image") {
        try await MainActor.run {
            let renderer = StatusFrameRenderer()
            let aqua = try appearance(named: .aqua)
            let single = renderer.render(
                menubarFrame(product: .codex, duration: 300, value: .fresh(83)),
                appearance: aqua
            )
            let comparison = renderer.render(mixedComparisonFrame(), appearance: aqua)
            let compact = renderer.render(
                menubarFrame(product: .codex, duration: 300, value: .fresh(83)),
                durationMode: .compactSingleCriterion,
                appearance: aqua
            )

            try expect(single.semanticTitle == "[5h] 83%", "Unexpected single semantic title")
            try expect(single.visualLabel == "5h 83%", "Unexpected single visual label")
            try expect(single.image.size.height == 20, "Expected one capsule image")
            try expect(single.measuredWidth == single.image.size.width, "Expected image width")
            try expect(compact.visualLabel == "83%", "Expected compact visual label")
            try expect(
                compact.semanticTitle == single.semanticTitle,
                "Expected semantic title preservation"
            )
            try expect(
                compact.accessibilityLabel == single.accessibilityLabel,
                "Expected VoiceOver sentence preservation"
            )
            try expect(
                comparison.semanticTitle == "C[5h]75% · S[w]82%",
                "Unexpected comparison semantics"
            )
            try expect(
                comparison.visualLabel == "C 5h 75% · S w 82%",
                "Unexpected comparison visual label"
            )
        }
    }
}

private func renderedStateSemanticsTest() -> TestCase {
    TestCase(name: "status renderer keeps fresh stale loading and unavailable states") {
        try await MainActor.run {
            let renderer = StatusFrameRenderer()
            let aqua = try appearance(named: .aqua)
            let expectations: [(DisplayValueState, String)] = [
                (.fresh(83), "5h 83%"),
                (.stale(83), "5h ~83%"),
                (.loading, "5h …"),
                (.unavailable, "5h —")
            ]

            for expectation in expectations {
                let frame = menubarFrame(
                    product: .codex,
                    duration: 300,
                    value: expectation.0
                )
                let rendered = renderer.render(frame, appearance: aqua)
                try expect(rendered.visualLabel == expectation.1, "Unexpected rendered state")
            }

            let unknown = renderer.render(
                menubarFrame(product: .codex, duration: nil, value: .stale(83)),
                appearance: aqua
            )
            try expect(unknown.visualLabel == "? ~83%", "Expected unknown duration meaning")
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

@MainActor
private func renderedDurationModes(
    frames: [DisplayFrame],
    widthPrototypes: [DisplayFrame] = []
) -> [StatusDurationMode] {
    let fixture = makeControllerFixture()
    fixture.controller.setFrames(frames, widthPrototypes: widthPrototypes)
    return fixture.renderer.durationModes
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
    private(set) var durationModes: [StatusDurationMode] = []

    init(widths: [String: CGFloat] = [:]) {
        self.widths = widths
    }

    func render(
        _ frame: DisplayFrame,
        durationMode: StatusDurationMode,
        appearance: NSAppearance?
    ) -> RenderedStatusFrame {
        _ = appearance
        renderCount += 1
        durationModes.append(durationMode)
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
