import CodexGaugeAppKit
import CodexGaugeCore
import Foundation

func quotaResetRefreshSchedulerTests() -> [TestCase] {
    [
        quotaResetSchedulesEarliestFutureDateTest(),
        quotaResetFiresEachResetOnceTest(),
        quotaResetReplacesChangedPublicationTest(),
        quotaResetRefreshesPastDateOnceTest(),
        quotaResetReevaluatesClockChangesTest(),
        quotaResetReschedulesAfterEarlyFireTest(),
        quotaResetSuspendsForSleepTest(),
        quotaResetWakeHandlesElapsedDateTest(),
        quotaResetStopIsFinalTest(),
        quotaResetSchedulesValidityExpiryTest(),
        quotaResetSchedulesOldestProductExpiryTest(),
        quotaResetHandlesPastValidityExpiryOnceTest(),
        quotaResetCombinesCoincidentDeadlineReasonsTest(),
        quotaResetPrunesHandledDeadlinesTest(),
        quotaResetIgnoresEmptySnapshotTest()
    ]
}

private func quotaResetSchedulesEarliestFutureDateTest() -> TestCase {
    TestCase(name: "quota reset schedules the earliest unique future date once") {
        try await MainActor.run {
            let fixture = ResetSchedulerFixture(nowOffset: 0)
            let productStates = try resetProductStates(
                codexOffsets: [600, 300, nil],
                sparkOffsets: [300]
            )

            fixture.controller.publish(productStates: productStates)

            try expect(fixture.timer.requests == [
                WallClockTimerRequest(
                    deadline: resetDate(300),
                    tolerance: 5
                )
            ], "Expected one earliest reset timer")
            try expect(
                fixture.controller.scheduledDeadlineDate == resetDate(300),
                "Expected visible scheduled reset"
            )
            try expect(fixture.handledReasons.isEmpty, "Expected no early deadline")
        }
    }
}

private func quotaResetFiresEachResetOnceTest() -> TestCase {
    TestCase(name: "quota reset fires once and ignores duplicate timer delivery") {
        try await MainActor.run {
            let fixture = ResetSchedulerFixture(nowOffset: 0)
            let productStates = try resetProductStates(codexOffsets: [300, 600])
            fixture.controller.publish(productStates: productStates)
            fixture.clock.now = resetDate(300)

            fixture.timer.fireCurrent()
            fixture.timer.fireRequest(at: 0)

            try expect(fixture.resetRefreshCount == 1, "Expected first reset once")
            try expect(
                fixture.controller.scheduledDeadlineDate == resetDate(600),
                "Expected next distinct reset"
            )

            fixture.clock.now = resetDate(600)
            fixture.timer.fireCurrent()
            fixture.postClockChange()

            try expect(fixture.resetRefreshCount == 2, "Expected each distinct reset once")
            try expect(
                fixture.controller.scheduledDeadlineDate == resetDate(86_400),
                "Expected validity expiry after resets"
            )
        }
    }
}

private func quotaResetReplacesChangedPublicationTest() -> TestCase {
    TestCase(name: "quota reset replaces changed product states and cancels cleared data") {
        try await MainActor.run {
            let fixture = ResetSchedulerFixture(nowOffset: 0)
            fixture.controller.publish(
                productStates: try resetProductStates(codexOffsets: [600])
            )
            fixture.controller.publish(
                productStates: try resetProductStates(sparkOffsets: [300])
            )
            fixture.controller.publish(
                productStates: try resetProductStates(sparkOffsets: [300])
            )
            fixture.timer.fireRequest(at: 0)

            try expect(fixture.timer.requests.map(\.deadline) == [
                resetDate(600),
                resetDate(300)
            ], "Expected unchanged deadline not to churn")
            try expect(fixture.timer.cancelCount == 1, "Expected replaced timer cancellation")
            try expect(fixture.handledReasons.isEmpty, "Expected stale timer ignored")

            fixture.controller.publish(productStates: [:])

            try expect(fixture.timer.cancelCount == 2, "Expected cleared snapshot cancellation")
            try expect(fixture.controller.scheduledDeadlineDate == nil, "Expected cleared deadline")
        }
    }
}

private func quotaResetRefreshesPastDateOnceTest() -> TestCase {
    TestCase(name: "previously unobserved past quota reset never triggers a refresh") {
        try await MainActor.run {
            let fixture = ResetSchedulerFixture(nowOffset: 500)
            let productStates = try resetProductStates(
                codexOffsets: [100, 300, 700],
                sparkOffsets: [200, 300]
            )
            let originalQuota = try resetQuotas(offsets: [100])[0]

            fixture.controller.publish(productStates: productStates)
            fixture.controller.publish(productStates: productStates)
            fixture.postClockChange()

            try expect(fixture.resetRefreshCount == 0, "Expected past response dates never to trigger a read")
            try expect(
                fixture.controller.scheduledDeadlineDate == resetDate(700),
                "Expected remaining future reset"
            )
            try expect(originalQuota.remainingPercent == 83, "Expected no synthetic 100 percent")
        }
    }
}

private func quotaResetIgnoresEmptySnapshotTest() -> TestCase {
    TestCase(name: "quota reset slot ignores loading and unavailable products") {
        try await MainActor.run {
            let fixture = ResetSchedulerFixture(nowOffset: 90_000)

            fixture.controller.publish(productStates: [
                .codex: .loading,
                .spark: .unavailable
            ])

            try expect(fixture.timer.requests.isEmpty, "Expected no empty publication timer")
            try expect(fixture.handledReasons.isEmpty, "Expected no empty publication event")
        }
    }
}

private func quotaResetReevaluatesClockChangesTest() -> TestCase {
    TestCase(name: "quota reset reevaluates forward and backward wall-clock changes") {
        try await MainActor.run {
            let fixture = ResetSchedulerFixture(nowOffset: 0)
            fixture.controller.publish(
                productStates: try resetProductStates(codexOffsets: [300, 900])
            )
            fixture.clock.now = resetDate(400)

            fixture.postClockChange()

            try expect(fixture.resetRefreshCount == 1, "Expected elapsed reset refresh")
            try expect(
                fixture.controller.scheduledDeadlineDate == resetDate(900),
                "Expected next future reset after forward change"
            )
            let requestCount = fixture.timer.requests.count
            fixture.clock.now = resetDate(200)

            fixture.postClockChange()

            try expect(
                fixture.timer.requests.count == requestCount + 1,
                "Expected same deadline rescheduled after backward change"
            )
            try expect(fixture.resetRefreshCount == 1, "Expected handled reset not to repeat")
        }
    }
}

private func quotaResetReschedulesAfterEarlyFireTest() -> TestCase {
    TestCase(name: "quota reset reschedules an early timer without refreshing") {
        try await MainActor.run {
            let fixture = ResetSchedulerFixture(nowOffset: 0)
            fixture.controller.publish(
                productStates: try resetProductStates(codexOffsets: [300])
            )
            fixture.clock.now = resetDate(299)

            fixture.timer.fireCurrent()

            try expect(fixture.handledReasons.isEmpty, "Expected no early deadline")
            try expect(fixture.timer.requests.count == 2, "Expected replacement one-shot timer")
            try expect(
                fixture.controller.scheduledDeadlineDate == resetDate(300),
                "Expected same reset deadline"
            )
        }
    }
}

private func quotaResetSuspendsForSleepTest() -> TestCase {
    TestCase(name: "quota reset sleep cancels and defers new snapshot scheduling") {
        try await MainActor.run {
            let fixture = ResetSchedulerFixture(nowOffset: 0)
            fixture.controller.publish(
                productStates: try resetProductStates(codexOffsets: [300])
            )

            fixture.controller.systemDidSleep()
            fixture.controller.publish(
                productStates: try resetProductStates(sparkOffsets: [600])
            )

            try expect(fixture.timer.cancelCount == 1, "Expected sleep cancellation")
            try expect(fixture.timer.requests.count == 1, "Expected no timer during sleep")
            try expect(fixture.controller.scheduledDeadlineDate == nil, "Expected suspended deadline")

            fixture.controller.systemDidWake()

            try expect(fixture.timer.requests.last?.deadline == resetDate(600), "Expected wake timer")
        }
    }
}

private func quotaResetWakeHandlesElapsedDateTest() -> TestCase {
    TestCase(name: "quota reset wake refreshes a reset elapsed during sleep once") {
        try await MainActor.run {
            let fixture = ResetSchedulerFixture(nowOffset: 0)
            fixture.controller.publish(
                productStates: try resetProductStates(codexOffsets: [300])
            )
            fixture.controller.systemDidSleep()
            fixture.clock.now = resetDate(400)

            fixture.controller.systemDidWake()
            fixture.controller.systemDidWake()

            try expect(fixture.resetRefreshCount == 1, "Expected one elapsed wake refresh")
            try expect(
                fixture.controller.scheduledDeadlineDate == resetDate(86_400),
                "Expected retained validity expiry"
            )
        }
    }
}

private func quotaResetStopIsFinalTest() -> TestCase {
    TestCase(name: "quota reset stop cancels and rejects late work") {
        try await MainActor.run {
            let fixture = ResetSchedulerFixture(nowOffset: 0)
            fixture.controller.publish(
                productStates: try resetProductStates(codexOffsets: [300])
            )

            fixture.controller.stop()
            fixture.clock.now = resetDate(400)
            fixture.timer.fireRequest(at: 0)
            fixture.postClockChange()
            fixture.controller.systemDidWake()
            fixture.controller.publish(
                productStates: try resetProductStates(sparkOffsets: [500])
            )

            try expect(fixture.timer.cancelCount == 1, "Expected stop cancellation")
            try expect(fixture.timer.requests.count == 1, "Expected no post-stop timer")
            try expect(fixture.handledReasons.isEmpty, "Expected late callback ignored")
            try expect(fixture.controller.scheduledDeadlineDate == nil, "Expected stopped state")
        }
    }
}

private func quotaResetSchedulesValidityExpiryTest() -> TestCase {
    TestCase(name: "quota reset slot schedules product value validity expiry") {
        try await MainActor.run {
            let fixture = ResetSchedulerFixture(nowOffset: 0)
            fixture.controller.publish(
                productStates: try resetProductStates(codexOffsets: [100_000, nil])
            )

            try expect(
                fixture.timer.requests == [WallClockTimerRequest(
                    deadline: resetDate(86_400),
                    tolerance: 5
                )],
                "Expected expiry before later quota reset"
            )
            fixture.clock.now = resetDate(86_400)
            fixture.timer.fireCurrent()
            fixture.timer.fireRequest(at: 0)

            try expect(fixture.invalidationCount == 1, "Expected one presentation invalidation")
            try expect(fixture.resetRefreshCount == 0, "Expected no reset read for expiry")
            try expect(
                fixture.controller.scheduledDeadlineDate == resetDate(100_000),
                "Expected later quota reset retained"
            )
        }
    }
}

private func quotaResetSchedulesOldestProductExpiryTest() -> TestCase {
    TestCase(name: "quota reset slot preserves each product capture expiry") {
        try await MainActor.run {
            let fixture = ResetSchedulerFixture(nowOffset: 0)
            let productStates = try resetProductStates(
                codexOffsets: [100_000],
                sparkOffsets: [100_000],
                codexCapturedAtOffset: 0,
                sparkCapturedAtOffset: 600,
                sparkFreshness: .stale
            )

            fixture.controller.publish(productStates: productStates)

            try expect(
                fixture.controller.scheduledDeadlineDate == resetDate(86_400),
                "Expected the older Codex value to expire first"
            )
            fixture.clock.now = resetDate(86_400)
            fixture.timer.fireCurrent()

            try expect(fixture.invalidationCount == 1, "Expected Codex expiry invalidation")
            try expect(
                fixture.controller.scheduledDeadlineDate == resetDate(87_000),
                "Expected stale Spark value to retain its own later expiry"
            )
            fixture.clock.now = resetDate(87_000)
            fixture.timer.fireCurrent()

            try expect(fixture.invalidationCount == 2, "Expected each product expiry once")
        }
    }
}

private func quotaResetHandlesPastValidityExpiryOnceTest() -> TestCase {
    TestCase(name: "past product validity expiry invalidates presentation once") {
        try await MainActor.run {
            let fixture = ResetSchedulerFixture(nowOffset: 90_000)
            let productStates = try resetProductStates(codexOffsets: [nil])

            fixture.controller.publish(productStates: productStates)
            fixture.controller.publish(productStates: productStates)
            fixture.controller.systemDidWake()
            fixture.postClockChange()

            try expect(fixture.invalidationCount == 1, "Expected one past expiry invalidation")
            try expect(fixture.resetRefreshCount == 0, "Expected no speculative quota read")
            try expect(fixture.timer.requests.isEmpty, "Expected no expired timer")
        }
    }
}

private func quotaResetCombinesCoincidentDeadlineReasonsTest() -> TestCase {
    TestCase(name: "one timer delivers coincident reset and expiry reasons once") {
        try await MainActor.run {
            let fixture = ResetSchedulerFixture(nowOffset: 0)
            fixture.controller.publish(
                productStates: try resetProductStates(codexOffsets: [86_400])
            )

            try expect(fixture.timer.requests.count == 1, "Expected one shared timer slot")
            fixture.clock.now = resetDate(86_400)
            fixture.timer.fireCurrent()
            fixture.postClockChange()

            try expect(
                fixture.handledReasons == [.validityExpired, .quotaReset],
                "Expected deterministic typed deadline reasons"
            )
            try expect(fixture.controller.scheduledDeadlineDate == nil, "Expected all deadlines handled")
        }
    }
}

private func quotaResetPrunesHandledDeadlinesTest() -> TestCase {
    TestCase(name: "handled deadlines stay bounded to the latest product states") {
        try await MainActor.run {
            let fixture = ResetSchedulerFixture(nowOffset: 500)
            let firstStates = try resetProductStates(
                codexOffsets: [100],
                codexCapturedAtOffset: 0
            )
            let secondStates = try resetProductStates(
                sparkOffsets: [200],
                sparkCapturedAtOffset: 1
            )

            fixture.controller.publish(productStates: firstStates)
            fixture.controller.publish(productStates: secondStates)
            fixture.timer.fireRequest(at: 0)

            try expect(fixture.resetRefreshCount == 0, "Expected alternating past responses not to trigger reads")
            for _ in 0..<100 {
                fixture.controller.publish(productStates: firstStates)
                fixture.controller.publish(productStates: secondStates)
            }
            try expect(fixture.resetRefreshCount == 0, "Expected no A/B immediate request chain")
        }
    }
}

@MainActor
private final class ResetSchedulerFixture {
    let clock: MutableWallClock
    let timer = ManualWallClockOneShotScheduler()
    let notificationCenter = NotificationCenter()
    private(set) var handledReasons: [UsageDeadlineReason] = []
    var resetRefreshCount: Int {
        handledReasons.filter { $0 == .quotaReset }.count
    }
    var invalidationCount: Int {
        handledReasons.filter { $0 == .validityExpired }.count
    }
    lazy var controller = QuotaResetRefreshScheduler(
        timerScheduler: timer,
        now: clock.read,
        notificationCenter: notificationCenter,
        handleDeadline: { [weak self] reason in
            self?.handledReasons.append(reason)
        }
    )

    init(nowOffset: TimeInterval) {
        clock = MutableWallClock(now: resetDate(nowOffset))
    }

    func postClockChange() {
        notificationCenter.post(name: .NSSystemClockDidChange, object: nil)
    }
}

@MainActor
private final class MutableWallClock {
    var now: Date

    init(now: Date) {
        self.now = now
    }

    func read() -> Date {
        now
    }
}

private struct WallClockTimerRequest: Equatable {
    let deadline: Date
    let tolerance: TimeInterval
}

@MainActor
private final class ManualWallClockOneShotScheduler: WallClockOneShotScheduling {
    private(set) var requests: [WallClockTimerRequest] = []
    private(set) var cancelCount = 0
    private var currentAction: (@MainActor () -> Void)?
    private var actions: [@MainActor () -> Void] = []

    func schedule(
        deadline: Date,
        tolerance: TimeInterval,
        action: @escaping @MainActor () -> Void
    ) {
        requests.append(WallClockTimerRequest(deadline: deadline, tolerance: tolerance))
        currentAction = action
        actions.append(action)
    }

    func cancel() {
        cancelCount += 1
        currentAction = nil
    }

    func fireCurrent() {
        let action = currentAction
        currentAction = nil
        action?()
    }

    func fireRequest(at index: Int) {
        guard actions.indices.contains(index) else {
            return
        }
        actions[index]()
    }
}

private let resetBaseDate = Date(timeIntervalSince1970: 1_900_000_000)

private func resetDate(_ offset: TimeInterval) -> Date {
    resetBaseDate.addingTimeInterval(offset)
}

private func resetProductStates(
    codexOffsets: [TimeInterval?] = [],
    sparkOffsets: [TimeInterval?] = [],
    codexCapturedAtOffset: TimeInterval = 0,
    sparkCapturedAtOffset: TimeInterval = 0,
    sparkFreshness: ProductValueFreshness = .fresh
) throws -> [UsageProduct: ProductUsageState] {
    [
        .codex: .value(
            ProductQuotaValue(
                capturedAt: resetDate(codexCapturedAtOffset),
                quotaWindows: try resetQuotas(offsets: codexOffsets)
            ),
            freshness: .fresh
        ),
        .spark: .value(
            ProductQuotaValue(
                capturedAt: resetDate(sparkCapturedAtOffset),
                quotaWindows: try resetQuotas(offsets: sparkOffsets)
            ),
            freshness: sparkFreshness
        )
    ]
}

private func resetQuotas(offsets: [TimeInterval?]) throws -> [QuotaWindow] {
    try offsets.enumerated().map { index, offset in
        guard let quota = QuotaWindow(
            slot: index.isMultiple(of: 2) ? .primary : .secondary,
            usedPercent: 17,
            windowDurationMinutes: 300 + index,
            resetUnixSeconds: offset.map { resetDate($0).timeIntervalSince1970 }
        ) else {
            throw TestFailure(description: "Expected synthetic reset quota")
        }
        return quota
    }
}
