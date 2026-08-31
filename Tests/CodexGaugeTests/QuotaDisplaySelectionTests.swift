import CodexGaugeCore
import Foundation

func quotaDisplayTests() -> [TestCase] {
    quotaSelectorTests() + displayFrameBuilderTests() + displayFrameFormatterTests()
}

private func quotaSelectorTests() -> [TestCase] {
    [
        automaticQuotaPriorityTest(),
        automaticShortestDurationTest(),
        automaticUnknownSlotPriorityTest(),
        automaticUnknownSecondaryFallbackTest(),
        duplicateLeastRemainingTest(),
        duplicateLaterResetTest(),
        duplicatePrimaryTieTest()
    ]
}

private func automaticUnknownSecondaryFallbackTest() -> TestCase {
    TestCase(name: "automatic unknown quota falls back to secondary slot") {
        let secondary = try displayWindow(
            slot: .secondary,
            usedPercent: 40,
            durationMinutes: nil
        )

        let selected = QuotaSelector().automaticQuota(from: [secondary])

        try expect(selected == secondary, "Expected unknown secondary fallback")
    }
}

private func automaticQuotaPriorityTest() -> TestCase {
    TestCase(name: "automatic quota prefers five-hour then weekly") {
        let shortest = try displayWindow(usedPercent: 10, durationMinutes: 60)
        let weekly = try displayWindow(usedPercent: 20, durationMinutes: 10_080)
        let fiveHour = try displayWindow(usedPercent: 30, durationMinutes: 300)
        let selector = QuotaSelector()

        let preferred = selector.automaticQuota(from: [shortest, weekly, fiveHour])
        let weeklyFallback = selector.automaticQuota(from: [shortest, weekly])

        try expect(preferred == fiveHour, "Expected five-hour quota first")
        try expect(weeklyFallback == weekly, "Expected weekly quota second")
    }
}

private func automaticShortestDurationTest() -> TestCase {
    TestCase(name: "automatic quota falls back to shortest positive duration") {
        let daily = try displayWindow(usedPercent: 10, durationMinutes: 1_440)
        let hourly = try displayWindow(usedPercent: 20, durationMinutes: 60)

        let selected = QuotaSelector().automaticQuota(from: [daily, hourly])

        try expect(selected == hourly, "Expected shortest positive duration")
    }
}

private func automaticUnknownSlotPriorityTest() -> TestCase {
    TestCase(name: "automatic unknown quota prefers primary slot") {
        let secondary = try displayWindow(
            slot: .secondary,
            usedPercent: 90,
            durationMinutes: nil
        )
        let primary = try displayWindow(
            slot: .primary,
            usedPercent: 10,
            durationMinutes: nil
        )

        let selected = QuotaSelector().automaticQuota(from: [secondary, primary])

        try expect(selected == primary, "Expected unknown primary before secondary")
    }
}

private func duplicateLeastRemainingTest() -> TestCase {
    TestCase(name: "same-duration duplicate keeps least remaining quota") {
        let moreRemaining = try displayWindow(
            slot: .primary,
            usedPercent: 20,
            durationMinutes: 300
        )
        let lessRemaining = try displayWindow(
            slot: .secondary,
            usedPercent: 60,
            durationMinutes: 300
        )
        let identifier = QuotaSelectionID(product: .codex, rawDurationMinutes: 300)

        let selected = QuotaSelector().quota(matching: identifier, from: [moreRemaining, lessRemaining])

        try expect(selected == lessRemaining, "Expected the conservative duplicate")
    }
}

private func duplicateLaterResetTest() -> TestCase {
    TestCase(name: "same-duration duplicate tie keeps later reset") {
        let earlier = try displayWindow(
            slot: .secondary,
            usedPercent: 40,
            durationMinutes: 300,
            resetUnixSeconds: 1_893_100_000
        )
        let later = try displayWindow(
            slot: .secondary,
            usedPercent: 40,
            durationMinutes: 300,
            resetUnixSeconds: 1_893_200_000
        )
        let identifier = QuotaSelectionID(product: .codex, rawDurationMinutes: 300)

        let selector = QuotaSelector()
        let selected = selector.quota(matching: identifier, from: [earlier, later])
        let reverseSelected = selector.quota(matching: identifier, from: [later, earlier])

        try expect(selected == later, "Expected the later reset duplicate")
        try expect(reverseSelected == later, "Expected selection independent of input order")
    }
}

private func duplicatePrimaryTieTest() -> TestCase {
    TestCase(name: "same-duration duplicate final tie keeps primary") {
        let reset = 1_893_200_000.0
        let secondary = try displayWindow(
            slot: .secondary,
            usedPercent: 40,
            durationMinutes: 300,
            resetUnixSeconds: reset
        )
        let primary = try displayWindow(
            slot: .primary,
            usedPercent: 40,
            durationMinutes: 300,
            resetUnixSeconds: reset
        )
        let identifier = QuotaSelectionID(product: .codex, rawDurationMinutes: 300)

        let selected = QuotaSelector().quota(matching: identifier, from: [secondary, primary])

        try expect(selected == primary, "Expected primary as final tie-breaker")
    }
}

private func displayFrameBuilderTests() -> [TestCase] {
    [
        automaticBothProductsFrameTest(),
        manualMissingSelectionTest(),
        manualGroupingAndOrderingTest(),
        manualProductModeFilterTest(),
        manualDisjointProductFallbackTest(),
        productStatePlaceholderTest(),
        freshnessDeadlineTest(),
        resetDeadlineTest(),
        independentProductFreshnessTest()
    ]
}

private func manualProductModeFilterTest() -> TestCase {
    TestCase(name: "manual frames respect selected product mode") {
        let now = displayReferenceDate()
        let identifiers: Set<QuotaSelectionID> = [
            QuotaSelectionID(product: .codex, rawDurationMinutes: 300),
            QuotaSelectionID(product: .spark, rawDurationMinutes: 300)
        ]
        let preference = DisplayPreference(
            productMode: .codex,
            quotaSelection: .manual(identifiers)
        )
        let states = displayStates(
            codex: [try displayWindow(usedPercent: 17, durationMinutes: 300)],
            spark: [try displayWindow(usedPercent: 9, durationMinutes: 300)],
            capturedAt: now
        )

        let item = try singleDisplayItem(from: makeFrames(preference, states, now))

        try expect(item.identifier.product == .codex, "Expected Spark selection to be filtered")
    }
}

private func manualDisjointProductFallbackTest() -> TestCase {
    TestCase(name: "manual frames recover when every identifier is off-product") {
        let now = displayReferenceDate()
        let preference = DisplayPreference(
            productMode: .codex,
            quotaSelection: .manual([
                QuotaSelectionID(product: .spark, rawDurationMinutes: 300)
            ])
        )
        let states = displayStates(
            codex: [try displayWindow(usedPercent: 17, durationMinutes: 300)],
            capturedAt: now
        )

        let item = try singleDisplayItem(from: makeFrames(preference, states, now))

        try expect(item.identifier.product == .codex, "Expected displayed product fallback")
        try expect(item.value == .fresh(83), "Expected automatic quota fallback")
    }
}

private func productStatePlaceholderTest() -> TestCase {
    TestCase(name: "automatic frames preserve loading and unavailable states") {
        let now = displayReferenceDate()
        let loadingPreference = DisplayPreference(
            productMode: .codex,
            quotaSelection: .automatic
        )
        let unavailablePreference = DisplayPreference(
            productMode: .spark,
            quotaSelection: .automatic
        )

        let loading = try singleDisplayItem(
            from: makeFrames(loadingPreference, [.codex: .loading], now)
        )
        let unavailable = try singleDisplayItem(
            from: makeFrames(unavailablePreference, [:], now)
        )

        try expect(loading.value == .loading, "Expected first-load placeholder")
        try expect(loading.identifier.rawDurationMinutes == nil, "Expected unknown loading duration")
        try expect(unavailable.value == .unavailable, "Expected missing product to be unavailable")
    }
}

private func automaticBothProductsFrameTest() -> TestCase {
    TestCase(name: "automatic both mode creates one mixed-duration frame") {
        let now = displayReferenceDate()
        let codex = try displayWindow(usedPercent: 25, durationMinutes: 300)
        let spark = try displayWindow(usedPercent: 18, durationMinutes: 10_080)
        let states = displayStates(codex: [codex], spark: [spark], capturedAt: now)
        let preference = DisplayPreference(productMode: .both, quotaSelection: .automatic)

        let frames = DisplayFrameBuilder().makeFrames(
            preference: preference,
            productStates: states,
            now: now
        )
        let pair = try displayPair(from: frames)

        try expect(frames.count == 1, "Expected one automatic comparison frame")
        try expect(pair.codex.identifier.rawDurationMinutes == 300, "Expected Codex duration")
        try expect(pair.spark.identifier.rawDurationMinutes == 10_080, "Expected Spark duration")
    }
}

private func manualMissingSelectionTest() -> TestCase {
    TestCase(name: "manual missing selection remains unavailable") {
        let now = displayReferenceDate()
        let available = try displayWindow(usedPercent: 17, durationMinutes: 300)
        let missingID = QuotaSelectionID(product: .codex, rawDurationMinutes: 10_080)
        let normalizedID = QuotaSelectionID(product: .codex, rawDurationMinutes: 0)
        let preference = DisplayPreference(
            productMode: .codex,
            quotaSelection: .manual([missingID])
        )
        let states = displayStates(codex: [available], capturedAt: now)

        let frames = DisplayFrameBuilder().makeFrames(
            preference: preference,
            productStates: states,
            now: now
        )
        let item = try singleDisplayItem(from: frames)

        try expect(item.identifier == missingID, "Expected stable manual identifier")
        try expect(item.value == .unavailable, "Expected missing selection to remain unavailable")
        try expect(normalizedID.rawDurationMinutes == nil, "Expected unknown normalized ID")
    }
}

private func manualGroupingAndOrderingTest() -> TestCase {
    TestCase(name: "manual frames group equal durations and order unknown last") {
        let now = displayReferenceDate()
        let identifiers: Set<QuotaSelectionID> = [
            QuotaSelectionID(product: .codex, rawDurationMinutes: nil),
            QuotaSelectionID(product: .spark, rawDurationMinutes: 10_080),
            QuotaSelectionID(product: .spark, rawDurationMinutes: 300),
            QuotaSelectionID(product: .codex, rawDurationMinutes: 300)
        ]
        let preference = DisplayPreference(
            productMode: .both,
            quotaSelection: .manual(identifiers)
        )
        let states = displayStates(
            codex: [
                try displayWindow(usedPercent: 20, durationMinutes: nil),
                try displayWindow(usedPercent: 30, durationMinutes: 300)
            ],
            spark: [
                try displayWindow(usedPercent: 40, durationMinutes: 10_080),
                try displayWindow(usedPercent: 50, durationMinutes: 300)
            ],
            capturedAt: now
        )

        let frames = DisplayFrameBuilder().makeFrames(
            preference: preference,
            productStates: states,
            now: now
        )

        try expect(frames.count == 3, "Expected grouped and unmatched frames")
        try expect(frameDuration(frames[0]) == 300, "Expected five-hour frame first")
        try expect(frameDuration(frames[1]) == 10_080, "Expected weekly frame second")
        try expect(frameDuration(frames[2]) == nil, "Expected unknown frame last")
        try expect(isComparison(frames[0]), "Expected equal durations to be grouped")
    }
}

private func freshnessDeadlineTest() -> TestCase {
    TestCase(name: "quota value expires at twenty-four hours") {
        let now = displayReferenceDate()
        let quota = try displayWindow(usedPercent: 17, durationMinutes: 300)
        let identifier = QuotaSelectionID(product: .codex, rawDurationMinutes: 300)
        let preference = DisplayPreference(
            productMode: .codex,
            quotaSelection: .manual([identifier])
        )
        let beforeDeadline = productValueState(
            [quota],
            freshness: .stale,
            capturedAt: now.addingTimeInterval(-86_399)
        )
        let atDeadline = productValueState(
            [quota],
            freshness: .stale,
            capturedAt: now.addingTimeInterval(-86_400)
        )

        let valid = try singleDisplayItem(from: makeFrames(preference, [.codex: beforeDeadline], now))
        let expired = try singleDisplayItem(from: makeFrames(preference, [.codex: atDeadline], now))

        try expect(valid.value == .stale(83), "Expected value before 24-hour deadline")
        try expect(expired.value == .unavailable, "Expected value invalid at 24-hour deadline")
    }
}

private func resetDeadlineTest() -> TestCase {
    TestCase(name: "quota value expires at reset time") {
        let now = displayReferenceDate()
        let validQuota = try displayWindow(
            usedPercent: 17,
            durationMinutes: 300,
            resetUnixSeconds: now.timeIntervalSince1970 + 1
        )
        let expiredQuota = try displayWindow(
            usedPercent: 17,
            durationMinutes: 300,
            resetUnixSeconds: now.timeIntervalSince1970
        )
        let valid = try displayItem(for: validQuota, now: now)
        let expired = try displayItem(for: expiredQuota, now: now)

        try expect(valid.value == .fresh(83), "Expected value before reset")
        try expect(expired.value == .unavailable, "Expected value invalid at reset")
    }
}

private func independentProductFreshnessTest() -> TestCase {
    TestCase(name: "Codex and Spark freshness remain independent") {
        let now = displayReferenceDate()
        let expiredCodex = try displayWindow(
            usedPercent: 25,
            durationMinutes: 300,
            resetUnixSeconds: now.timeIntervalSince1970
        )
        let freshSpark = try displayWindow(
            usedPercent: 18,
            durationMinutes: 300,
            resetUnixSeconds: now.timeIntervalSince1970 + 3_600
        )
        let preference = DisplayPreference(productMode: .both, quotaSelection: .automatic)
        let states = displayStates(codex: [expiredCodex], spark: [freshSpark], capturedAt: now)

        let pair = try displayPair(from: makeFrames(preference, states, now))

        try expect(pair.codex.value == .unavailable, "Expected only Codex to expire")
        try expect(pair.spark.value == .fresh(82), "Expected Spark to stay fresh")
    }
}

private func displayWindow(
    slot: QuotaSlot = .primary,
    usedPercent: Double,
    durationMinutes: Int?,
    resetUnixSeconds: TimeInterval? = nil
) throws -> QuotaWindow {
    guard let quota = QuotaWindow(
        slot: slot,
        usedPercent: usedPercent,
        windowDurationMinutes: durationMinutes,
        resetUnixSeconds: resetUnixSeconds
    ) else {
        throw TestFailure(description: "Expected valid display quota fixture")
    }
    return quota
}

private func displayReferenceDate() -> Date {
    Date(timeIntervalSince1970: 1_893_000_000)
}

private func productValueState(
    _ quotas: [QuotaWindow],
    freshness: ProductValueFreshness = .fresh,
    capturedAt: Date
) -> ProductUsageState {
    .value(
        ProductQuotaValue(capturedAt: capturedAt, quotaWindows: quotas),
        freshness: freshness
    )
}

private func displayStates(
    codex: [QuotaWindow] = [],
    spark: [QuotaWindow] = [],
    capturedAt: Date
) -> [UsageProduct: ProductUsageState] {
    [
        .codex: productValueState(codex, capturedAt: capturedAt),
        .spark: productValueState(spark, capturedAt: capturedAt)
    ]
}

private func makeFrames(
    _ preference: DisplayPreference,
    _ states: [UsageProduct: ProductUsageState],
    _ now: Date
) -> [DisplayFrame] {
    DisplayFrameBuilder().makeFrames(
        preference: preference,
        productStates: states,
        now: now
    )
}

private func displayItem(for quota: QuotaWindow, now: Date) throws -> DisplayQuota {
    let preference = DisplayPreference(productMode: .codex, quotaSelection: .automatic)
    let state = productValueState([quota], capturedAt: now)
    let frames = makeFrames(preference, [.codex: state], now)
    return try singleDisplayItem(from: frames)
}

private func singleDisplayItem(from frames: [DisplayFrame]) throws -> DisplayQuota {
    guard frames.count == 1, case .single(let item) = frames[0] else {
        throw TestFailure(description: "Expected one single-product frame")
    }
    return item
}

private func displayPair(
    from frames: [DisplayFrame]
) throws -> (codex: DisplayQuota, spark: DisplayQuota) {
    guard frames.count == 1, case .comparison(let codex, let spark) = frames[0] else {
        throw TestFailure(description: "Expected one comparison frame")
    }
    return (codex, spark)
}

private func frameDuration(_ frame: DisplayFrame) -> Int? {
    switch frame {
    case .single(let item):
        item.identifier.rawDurationMinutes
    case .comparison(let codex, _):
        codex.identifier.rawDurationMinutes
    }
}

private func isComparison(_ frame: DisplayFrame) -> Bool {
    guard case .comparison = frame else {
        return false
    }
    return true
}
