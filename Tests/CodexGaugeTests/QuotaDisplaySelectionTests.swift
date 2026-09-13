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
        manualMissingSelectionTest(),
        productStatePlaceholderTest(),
        freshnessDeadlineTest(),
        resetDeadlineTest(),
        singleQuotaSelectionTest()
    ]
}

private func productStatePlaceholderTest() -> TestCase {
    TestCase(name: "automatic frames preserve loading and unavailable states") {
        let now = displayReferenceDate()
        let loadingPreference = DisplayPreference(
            quotaSelection: .automatic
        )
        let unavailablePreference = DisplayPreference(
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

private func manualMissingSelectionTest() -> TestCase {
    TestCase(name: "manual missing selection remains unavailable") {
        let now = displayReferenceDate()
        let available = try displayWindow(usedPercent: 17, durationMinutes: 300)
        let missingID = QuotaSelectionID(product: .codex, rawDurationMinutes: 10_080)
        let normalizedID = QuotaSelectionID(product: .codex, rawDurationMinutes: 0)
        let preference = DisplayPreference(
            quotaSelection: .manual(missingID)
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

private func freshnessDeadlineTest() -> TestCase {
    TestCase(name: "quota value expires at twenty-four hours") {
        let now = displayReferenceDate()
        let quota = try displayWindow(usedPercent: 17, durationMinutes: 300)
        let identifier = QuotaSelectionID(product: .codex, rawDurationMinutes: 300)
        let preference = DisplayPreference(
            quotaSelection: .manual(identifier)
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
    capturedAt: Date
) -> [UsageProduct: ProductUsageState] {
    [
        .codex: productValueState(codex, capturedAt: capturedAt)
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
    let preference = DisplayPreference(quotaSelection: .automatic)
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

private func singleQuotaSelectionTest() -> TestCase {
    TestCase(name: "single quota chooses automatic or exactly one manual duration") {
        let now = displayReferenceDate()
        let states = displayStates(codex: [
            try displayWindow(usedPercent: 25, durationMinutes: 300),
            try displayWindow(usedPercent: 18, durationMinutes: 10_080),
            try displayWindow(usedPercent: 40, durationMinutes: nil)
        ], capturedAt: now)
        let automatic = try singleDisplayItem(from: makeFrames(.default, states, now))
        try expect(automatic.identifier.rawDurationMinutes == 300 && automatic.value == .fresh(75), "Expected automatic five-hour remaining percent")
        for (duration, percent) in [(10_080 as Int?, 82), (nil, 60)] {
            let identifier = QuotaSelectionID(product: .codex, rawDurationMinutes: duration)
            let preference = DisplayPreference(quotaSelection: .manual(identifier))
            let manual = try singleDisplayItem(from: makeFrames(preference, states, now))
            try expect(manual.identifier == identifier && manual.value == .fresh(percent), "Expected only the explicitly selected quota")
        }
    }
}
