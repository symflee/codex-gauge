import CodexGaugeCore
import Foundation

func quotaDomainTests() -> [TestCase] {
    [
        rejectsNonFiniteUsedPercentTest(),
        clampsUsedPercentTest(),
        floorsRemainingPercentTest(),
        normalizesNonpositiveDurationTest(),
        knownDurationBadgesTest(),
        exactDurationBadgesTest(),
        resetDateTest(),
        immutableSnapshotTest(),
        sendableDomainValuesTest()
    ]
}

private func rejectsNonFiniteUsedPercentTest() -> TestCase {
    TestCase(name: "quota rejects non-finite used percent") {
        let notANumber = makeOptionalWindow(usedPercent: .nan)
        let infinity = makeOptionalWindow(usedPercent: .infinity)

        try expect(notANumber == nil, "Expected NaN to be rejected")
        try expect(infinity == nil, "Expected infinity to be rejected")
    }
}

private func clampsUsedPercentTest() -> TestCase {
    TestCase(name: "quota clamps used percent to valid bounds") {
        let belowZero = try makeWindow(usedPercent: -12.5)
        let aboveHundred = try makeWindow(usedPercent: 134.8)

        try expect(belowZero.usedPercent == 0, "Expected lower bound of zero")
        try expect(belowZero.remainingPercent == 100, "Expected all quota remaining")
        try expect(aboveHundred.usedPercent == 100, "Expected upper bound of 100")
        try expect(aboveHundred.remainingPercent == 0, "Expected no quota remaining")
    }
}

private func floorsRemainingPercentTest() -> TestCase {
    TestCase(name: "quota floors displayed and comparison percentages") {
        let quota = try makeWindow(usedPercent: 16.2)
        let sameComparisonBucket = try makeWindow(usedPercent: 16.9)
        let nextComparisonBucket = try makeWindow(usedPercent: 17)

        try expect(quota.remainingPercent == 83, "Expected conservative remaining value")
        try expect(quota.comparisonUsedPercent == 16, "Expected integer comparison value")
        try expect(
            quota.comparisonUsedPercent == sameComparisonBucket.comparisonUsedPercent,
            "Expected fractional changes to stay in the same comparison bucket"
        )
        try expect(
            nextComparisonBucket.comparisonUsedPercent == 17,
            "Expected the next whole-percent comparison bucket"
        )
    }
}

private func normalizesNonpositiveDurationTest() -> TestCase {
    TestCase(name: "quota treats nonpositive duration as unknown") {
        let zero = try makeWindow(windowDurationMinutes: 0)
        let negative = try makeWindow(windowDurationMinutes: -300)

        try expect(zero.windowDurationMinutes == nil, "Expected zero duration to become nil")
        try expect(negative.windowDurationMinutes == nil, "Expected negative duration to become nil")
        try expect(zero.durationBadge == .unknown, "Expected an unknown zero-duration badge")
        try expect(negative.durationBadge == .unknown, "Expected an unknown negative-duration badge")
    }
}

private func knownDurationBadgesTest() -> TestCase {
    TestCase(name: "duration badge preserves known product labels") {
        let expectations = [
            DurationExpectation(minutes: 300, label: "5h", accessibilityLabel: "5시간"),
            DurationExpectation(minutes: 1_440, label: "d", accessibilityLabel: "1일"),
            DurationExpectation(minutes: 10_080, label: "w", accessibilityLabel: "1주"),
            DurationExpectation(minutes: 20_160, label: "2w", accessibilityLabel: "2주"),
            DurationExpectation(minutes: 43_200, label: "30d", accessibilityLabel: "30일")
        ]

        for expectation in expectations {
            try verify(expectation)
        }
    }
}

private func exactDurationBadgesTest() -> TestCase {
    TestCase(name: "duration badge labels only exact safe units") {
        let expectations = [
            DurationExpectation(minutes: 60, label: "1h", accessibilityLabel: "1시간"),
            DurationExpectation(minutes: 120, label: "2h", accessibilityLabel: "2시간"),
            DurationExpectation(minutes: 2_880, label: "2d", accessibilityLabel: "2일"),
            DurationExpectation(minutes: 30_240, label: "21d", accessibilityLabel: "21일")
        ]

        for expectation in expectations {
            try verify(expectation)
        }

        let inexact = DurationBadge(windowDurationMinutes: 90)
        try expect(inexact == .unknown, "Expected inexact units to remain unknown")
    }
}

private func resetDateTest() -> TestCase {
    TestCase(name: "quota represents reset epoch seconds as a date") {
        let resetUnixSeconds = 1_893_456_000.0
        let quota = try makeWindow(resetUnixSeconds: resetUnixSeconds)
        let expectedDate = Date(timeIntervalSince1970: resetUnixSeconds)

        try expect(quota.resetsAt == expectedDate, "Expected reset epoch to become Date")
    }
}

private func immutableSnapshotTest() -> TestCase {
    TestCase(name: "usage snapshot owns immutable product values") {
        let quota = try makeWindow(usedPercent: 17, windowDurationMinutes: 300)
        var source = [UsageProduct.codex: [quota]]
        let capturedAt = Date(timeIntervalSince1970: 1_893_000_000)
        let snapshot = UsageSnapshot(capturedAt: capturedAt, quotasByProduct: source)

        source[.codex] = []
        var exported = snapshot.quotasByProduct
        exported[.codex] = []

        try expect(snapshot.capturedAt == capturedAt, "Expected snapshot capture date")
        try expect(snapshot.quotaWindows(for: .codex) == [quota], "Expected owned Codex quota")
        try expect(snapshot.quotaWindows(for: .spark).isEmpty, "Expected absent Spark quota")
    }
}

private func sendableDomainValuesTest() -> TestCase {
    TestCase(name: "quota domain values are sendable and equatable") {
        let quota = try makeWindow()
        let snapshot = UsageSnapshot(
            capturedAt: Date(timeIntervalSince1970: 1_893_000_000),
            quotasByProduct: [.spark: [quota]]
        )

        requireSendable(UsageProduct.codex)
        requireSendable(QuotaSlot.primary)
        requireSendable(quota)
        requireSendable(snapshot)
        try expect(snapshot == snapshot, "Expected value equality")
    }
}

private struct DurationExpectation {
    let minutes: Int
    let label: String
    let accessibilityLabel: String
}

private func verify(_ expectation: DurationExpectation) throws {
    let badge = DurationBadge(windowDurationMinutes: expectation.minutes)

    try expect(badge.label == expectation.label, "Unexpected compact duration label")
    try expect(
        badge.accessibilityLabel == expectation.accessibilityLabel,
        "Unexpected accessible duration label"
    )
}

private func makeOptionalWindow(
    usedPercent: Double = 17,
    windowDurationMinutes: Int? = 300,
    resetUnixSeconds: TimeInterval? = nil
) -> QuotaWindow? {
    QuotaWindow(
        slot: .primary,
        usedPercent: usedPercent,
        windowDurationMinutes: windowDurationMinutes,
        resetUnixSeconds: resetUnixSeconds
    )
}

private func makeWindow(
    usedPercent: Double = 17,
    windowDurationMinutes: Int? = 300,
    resetUnixSeconds: TimeInterval? = nil
) throws -> QuotaWindow {
    guard let quota = makeOptionalWindow(
        usedPercent: usedPercent,
        windowDurationMinutes: windowDurationMinutes,
        resetUnixSeconds: resetUnixSeconds
    ) else {
        throw TestFailure(description: "Expected a valid quota window")
    }
    return quota
}

private func requireSendable<Value: Sendable>(_ value: Value) {
    _ = value
}
