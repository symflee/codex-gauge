import CodexGaugeCore
import CodexGaugeRefresh
import Foundation

func adaptiveRefreshReducerTests() -> [TestCase] {
    [
        startupBaselineTest(),
        firstSuccessBaselineTest(),
        wakeBaselineTest(),
        increaseAndExtensionTest(),
        decreaseAndResetChangeTest(),
        multiSelectionIncreaseTest(),
        burstDeadlineTest(),
        backoffLadderTest(),
        successResetsBackoffTest(),
        burstFailureCutoffTest(),
        concurrentTriggerCoalescingTest(),
        lateGenerationDiscardTest(),
        manualProfileBehaviorTest(),
        explicitStopTest(),
        lowPowerSchedulingTest(),
        sameProfileChangeTest(),
        automaticProfileChangeTest(),
        burstProfileChangeTest(),
        inFlightProfileChangeTest(),
        retryProfileChangeTest(),
        manualEntryCleanupTest(),
        manualToAutomaticTest(),
        lowPowerProfileChangeTest()
    ]
}

private func firstSuccessBaselineTest() -> TestCase {
    TestCase(name: "first success after failure establishes baseline without burst") {
        var harness = RefreshHarness()
        let startup = try refreshRequest(from: harness.send(.start(at: refreshInstant(0))))
        let retryCommands = harness.send(
            .transientFailure(generation: startup.generation, at: refreshInstant(0))
        )
        let retrySchedule = try refreshSchedule(from: retryCommands)
        let retry = try refreshRequest(
            from: harness.send(
                .scheduledRefreshFired(
                    generation: retrySchedule.generation,
                    at: retrySchedule.deadline
                )
            )
        )
        let samples = refreshSamples(codexUsed: 80)

        let commands = harness.send(
            .requestSucceeded(
                generation: retry.generation,
                samples: samples,
                at: retrySchedule.deadline
            )
        )
        let schedule = try refreshSchedule(from: commands)

        try expect(retry.reason == .retry, "Expected retry request")
        try expect(harness.state.baseline == samples, "Expected first-success baseline")
        try expect(harness.state.burstDeadline == nil, "Expected no first-success burst")
        try expect(schedule.reason == .normal, "Expected normal schedule after first success")
    }
}

private func startupBaselineTest() -> TestCase {
    TestCase(name: "startup success establishes baseline without burst") {
        var harness = RefreshHarness()
        let now = refreshInstant(0)
        let request = try refreshRequest(from: harness.send(.start(at: now)))
        let samples = refreshSamples(codexUsed: 71)

        let commands = harness.send(
            .requestSucceeded(generation: request.generation, samples: samples, at: now)
        )
        let schedule = try refreshSchedule(from: commands)

        try expect(request.reason == .startup, "Expected startup request")
        try expect(harness.state.baseline == samples, "Expected startup baseline")
        try expect(harness.state.burstDeadline == nil, "Expected no startup burst")
        try expect(schedule.reason == .normal, "Expected normal schedule after startup")
        try expect(schedule.deadline == refreshInstant(180), "Expected balanced normal interval")
    }
}

private func wakeBaselineTest() -> TestCase {
    TestCase(name: "wake success replaces baseline without burst") {
        var harness = RefreshHarness()
        try establishBaseline(&harness, samples: refreshSamples(codexUsed: 10))
        let wakeTime = refreshInstant(20)
        let request = try refreshRequest(from: harness.send(.wakeBaseline(at: wakeTime)))

        let commands = harness.send(
            .requestSucceeded(
                generation: request.generation,
                samples: refreshSamples(codexUsed: 30),
                at: wakeTime
            )
        )
        let schedule = try refreshSchedule(from: commands)

        try expect(request.reason == .wakeBaseline, "Expected wake baseline request")
        try expect(harness.state.burstDeadline == nil, "Expected wake not to start burst")
        try expect(schedule.reason == .normal, "Expected normal schedule after wake")
    }
}

private func increaseAndExtensionTest() -> TestCase {
    TestCase(name: "same-cycle increase starts and re-extends burst") {
        var harness = RefreshHarness()
        try establishBaseline(&harness, samples: refreshSamples(codexUsed: 10))

        let firstDeadline = try completeManualRefresh(
            &harness,
            samples: refreshSamples(codexUsed: 11),
            at: refreshInstant(10)
        )
        let unchangedDeadline = try completeManualRefresh(
            &harness,
            samples: refreshSamples(codexUsed: 11),
            at: refreshInstant(20)
        )
        let extendedDeadline = try completeManualRefresh(
            &harness,
            samples: refreshSamples(codexUsed: 12),
            at: refreshInstant(30)
        )

        try expect(firstDeadline == refreshInstant(310), "Expected five-minute burst")
        try expect(unchangedDeadline == firstDeadline, "Expected unchanged sample not to extend")
        try expect(extendedDeadline == refreshInstant(330), "Expected increase to re-extend burst")
    }
}

private func decreaseAndResetChangeTest() -> TestCase {
    TestCase(name: "decrease and reset-cycle change clear burst and update baseline") {
        var harness = RefreshHarness()
        let firstCycle = refreshSamples(codexUsed: 20, resetOffset: 1_000)
        try establishBaseline(&harness, samples: firstCycle)
        _ = try completeManualRefresh(
            &harness,
            samples: refreshSamples(codexUsed: 21, resetOffset: 1_000),
            at: refreshInstant(10)
        )

        let decreased = refreshSamples(codexUsed: 19, resetOffset: 1_000)
        _ = try completeManualRefresh(&harness, samples: decreased, at: refreshInstant(20))
        try expect(harness.state.burstDeadline == nil, "Expected decrease to clear burst")
        try expect(harness.state.baseline == decreased, "Expected decreased baseline")

        _ = try completeManualRefresh(
            &harness,
            samples: refreshSamples(codexUsed: 20, resetOffset: 1_000),
            at: refreshInstant(30)
        )
        let nextCycle = refreshSamples(codexUsed: 80, resetOffset: 2_000)
        _ = try completeManualRefresh(&harness, samples: nextCycle, at: refreshInstant(40))

        try expect(harness.state.burstDeadline == nil, "Expected reset change to clear burst")
        try expect(harness.state.baseline == nextCycle, "Expected next-cycle baseline")
    }
}

private func multiSelectionIncreaseTest() -> TestCase {
    TestCase(name: "any selected quota increase starts burst") {
        var harness = RefreshHarness()
        let baseline = refreshSamples(codexUsed: 10, sparkUsed: 20)
        try establishBaseline(&harness, samples: baseline)
        let changed = refreshSamples(codexUsed: 10, sparkUsed: 21)

        _ = try completeManualRefresh(&harness, samples: changed, at: refreshInstant(15))

        try expect(harness.state.burstDeadline == refreshInstant(315), "Expected Spark increase burst")
    }
}

private func burstDeadlineTest() -> TestCase {
    TestCase(name: "burst ends at deadline without another request") {
        var harness = RefreshHarness()
        try establishBaseline(&harness, samples: refreshSamples(codexUsed: 10))
        let request = try refreshRequest(from: harness.send(.manualRefresh(at: refreshInstant(10))))
        let commands = harness.send(
            .requestSucceeded(
                generation: request.generation,
                samples: refreshSamples(codexUsed: 11),
                at: refreshInstant(10)
            )
        )
        let burstSchedule = try refreshSchedule(from: commands)

        let deadlineCommands = harness.send(
            .scheduledRefreshFired(
                generation: burstSchedule.generation,
                at: refreshInstant(310)
            )
        )
        let normalSchedule = try refreshSchedule(from: deadlineCommands)

        try expect(refreshRequests(in: deadlineCommands).isEmpty, "Expected no deadline request")
        try expect(harness.state.burstDeadline == nil, "Expected burst to end")
        try expect(normalSchedule.reason == .normal, "Expected normal schedule after burst")
    }
}

private func backoffLadderTest() -> TestCase {
    TestCase(name: "transient failures follow capped backoff ladder") {
        var harness = RefreshHarness()
        var request = try refreshRequest(from: harness.send(.start(at: refreshInstant(0))))
        var failureTime = refreshInstant(0)
        let expectedDelays: [Duration] = [
            .seconds(30),
            .seconds(60),
            .seconds(120),
            .seconds(240),
            .seconds(480),
            .seconds(960),
            .seconds(1_800),
            .seconds(1_800)
        ]

        for expectedDelay in expectedDelays {
            let commands = harness.send(
                .transientFailure(generation: request.generation, at: failureTime)
            )
            let schedule = try refreshSchedule(from: commands)
            try expect(
                schedule.deadline == failureTime.advanced(by: expectedDelay),
                "Unexpected backoff deadline"
            )
            failureTime = schedule.deadline
            request = try refreshRequest(
                from: harness.send(
                    .scheduledRefreshFired(generation: schedule.generation, at: failureTime)
                )
            )
        }

        try expect(harness.state.consecutiveTransientFailures == 7, "Expected capped failure count")
    }
}

private func successResetsBackoffTest() -> TestCase {
    TestCase(name: "any success resets transient backoff") {
        var harness = RefreshHarness()
        var request = try refreshRequest(from: harness.send(.start(at: refreshInstant(0))))
        var now = refreshInstant(0)

        for _ in 0..<3 {
            let failureCommands = harness.send(
                .transientFailure(generation: request.generation, at: now)
            )
            let schedule = try refreshSchedule(from: failureCommands)
            now = schedule.deadline
            request = try refreshRequest(
                from: harness.send(
                    .scheduledRefreshFired(generation: schedule.generation, at: now)
                )
            )
        }

        let commands = harness.send(
            .requestSucceeded(
                generation: request.generation,
                samples: refreshSamples(codexUsed: 10),
                at: now
            )
        )
        let schedule = try refreshSchedule(from: commands)

        try expect(harness.state.consecutiveTransientFailures == 0, "Expected failure reset")
        try expect(schedule.reason == .normal, "Expected normal schedule after success")
    }
}

private func burstFailureCutoffTest() -> TestCase {
    TestCase(name: "three consecutive transient failures cut off burst") {
        var harness = RefreshHarness()
        try establishBaseline(&harness, samples: refreshSamples(codexUsed: 10))
        _ = try completeManualRefresh(
            &harness,
            samples: refreshSamples(codexUsed: 11),
            at: refreshInstant(10)
        )

        guard var schedule = harness.state.scheduledRefresh else {
            throw TestFailure(description: "Expected active burst schedule")
        }
        for failure in 1...3 {
            let request = try refreshRequest(
                from: harness.send(
                    .scheduledRefreshFired(
                        generation: schedule.generation,
                        at: schedule.deadline
                    )
                )
            )
            schedule = try refreshSchedule(
                from: harness.send(
                    .transientFailure(
                        generation: request.generation,
                        at: schedule.deadline
                    )
                )
            )
            if failure < 3 {
                try expect(harness.state.burstDeadline != nil, "Expected burst before cutoff")
            }
        }

        try expect(harness.state.burstDeadline == nil, "Expected burst failure cutoff")
        try expect(harness.state.consecutiveTransientFailures == 3, "Expected three failures")
    }
}

private func concurrentTriggerCoalescingTest() -> TestCase {
    TestCase(name: "concurrent triggers coalesce into one in-flight request") {
        var harness = RefreshHarness()
        let request = try refreshRequest(from: harness.send(.start(at: refreshInstant(0))))

        let manualCommands = harness.send(.manualRefresh(at: refreshInstant(1)))
        let wakeCommands = harness.send(.wakeBaseline(at: refreshInstant(2)))

        try expect(manualCommands.isEmpty, "Expected manual trigger to coalesce")
        try expect(wakeCommands.isEmpty, "Expected wake trigger to coalesce")
        try expect(harness.state.inFlightRequest?.generation == request.generation, "Expected one request")
        try expect(harness.state.inFlightRequest?.reason == .wakeBaseline, "Expected baseline upgrade")

        let commands = harness.send(
            .requestSucceeded(
                generation: request.generation,
                samples: refreshSamples(codexUsed: 90),
                at: refreshInstant(2)
            )
        )
        try expect(refreshRequests(in: commands).isEmpty, "Expected no queued duplicate request")
        try expect(harness.state.burstDeadline == nil, "Expected coalesced wake baseline")
    }
}

private func lateGenerationDiscardTest() -> TestCase {
    TestCase(name: "late completion generation is discarded after restart") {
        var harness = RefreshHarness()
        let first = try refreshRequest(from: harness.send(.start(at: refreshInstant(0))))
        let stopCommands = harness.send(.stop)
        let second = try refreshRequest(from: harness.send(.start(at: refreshInstant(1))))
        let stateBeforeLateCompletion = harness.state

        let lateCommands = harness.send(
            .requestSucceeded(
                generation: first.generation,
                samples: refreshSamples(codexUsed: 99),
                at: refreshInstant(2)
            )
        )

        try expect(second.generation > first.generation, "Expected monotonic generation")
        try expect(
            stopCommands.contains(.cancelRequest(generation: first.generation)),
            "Expected in-flight cancellation"
        )
        try expect(lateCommands.isEmpty, "Expected late completion to emit nothing")
        try expect(harness.state == stateBeforeLateCompletion, "Expected late completion discarded")
    }
}

private func manualProfileBehaviorTest() -> TestCase {
    TestCase(name: "manual profile runs startup and user refresh only") {
        var harness = RefreshHarness(profile: .manual)
        let startup = try refreshRequest(from: harness.send(.start(at: refreshInstant(0))))
        let startupCommands = harness.send(
            .requestSucceeded(
                generation: startup.generation,
                samples: refreshSamples(codexUsed: 10),
                at: refreshInstant(0)
            )
        )

        try expect(startupCommands.isEmpty, "Expected no manual schedule")
        try expect(harness.send(.wakeBaseline(at: refreshInstant(1))).isEmpty, "Expected wake ignored")

        let manual = try refreshRequest(from: harness.send(.manualRefresh(at: refreshInstant(2))))
        let successCommands = harness.send(
            .requestSucceeded(
                generation: manual.generation,
                samples: refreshSamples(codexUsed: 11),
                at: refreshInstant(2)
            )
        )
        try expect(successCommands.isEmpty, "Expected no manual burst schedule")
        try expect(harness.state.burstDeadline == nil, "Expected no manual burst")

        let failed = try refreshRequest(from: harness.send(.manualRefresh(at: refreshInstant(3))))
        let failureCommands = harness.send(
            .transientFailure(generation: failed.generation, at: refreshInstant(3))
        )
        try expect(failureCommands.isEmpty, "Expected no automatic manual retry")
    }
}

private func explicitStopTest() -> TestCase {
    TestCase(name: "explicit stop cancels scheduled work and clears refresh state") {
        var harness = RefreshHarness()
        try establishBaseline(&harness, samples: refreshSamples(codexUsed: 10))
        let scheduledGeneration = try requireScheduledGeneration(harness.state)

        let commands = harness.send(.stop)

        try expect(
            commands.contains(.cancelScheduledRefresh(generation: scheduledGeneration)),
            "Expected scheduled refresh cancellation"
        )
        try expect(!harness.state.isRunning, "Expected stopped state")
        try expect(harness.state.baseline == nil, "Expected cleared baseline")
        try expect(harness.state.scheduledRefresh == nil, "Expected cleared schedule")
    }
}

private func lowPowerSchedulingTest() -> TestCase {
    TestCase(name: "reducer reschedules with effective low-power interval") {
        var harness = RefreshHarness(profile: .fast)
        let request = try refreshRequest(from: harness.send(.start(at: refreshInstant(0))))

        let initialCommands = harness.send(
            .requestSucceeded(
                generation: request.generation,
                samples: refreshSamples(codexUsed: 10),
                at: refreshInstant(0)
            )
        )
        let initialSchedule = try refreshSchedule(from: initialCommands)
        let commands = harness.send(
            .lowPowerModeChanged(isEnabled: true, at: refreshInstant(10))
        )
        let schedule = try refreshSchedule(from: commands)

        try expect(initialSchedule.deadline == refreshInstant(60), "Expected fast normal interval")
        try expect(
            commands.contains(.cancelScheduledRefresh(generation: initialSchedule.generation)),
            "Expected old interval cancellation"
        )
        try expect(schedule.deadline == refreshInstant(610), "Expected low-power normal clamp")
    }
}

private func sameProfileChangeTest() -> TestCase {
    TestCase(name: "changing to the active refresh profile is a no-op") {
        var harness = RefreshHarness()
        try establishBaseline(&harness, samples: refreshSamples(codexUsed: 10))
        let originalState = harness.state

        let commands = harness.send(
            .profileChanged(profile: .balanced, at: refreshInstant(10))
        )

        try expect(commands.isEmpty, "Expected no profile change commands")
        try expect(harness.state == originalState, "Expected unchanged refresh state")
    }
}

private func automaticProfileChangeTest() -> TestCase {
    TestCase(name: "automatic profile change replaces the normal schedule") {
        var harness = RefreshHarness()
        try establishBaseline(&harness, samples: refreshSamples(codexUsed: 10))
        guard let oldSchedule = harness.state.scheduledRefresh else {
            throw TestFailure(description: "Expected original normal schedule")
        }

        let commands = harness.send(
            .profileChanged(profile: .fast, at: refreshInstant(10))
        )
        let newSchedule = try refreshSchedule(from: commands)
        let changedState = harness.state

        try expect(harness.state.profile == .fast, "Expected fast profile")
        try expect(newSchedule.reason == .normal, "Expected normal schedule")
        try expect(newSchedule.deadline == refreshInstant(70), "Expected fast interval from change")
        try expect(
            commands.contains(.cancelScheduledRefresh(generation: oldSchedule.generation)),
            "Expected prior schedule cancellation"
        )

        let staleCommands = harness.send(
            .scheduledRefreshFired(
                generation: oldSchedule.generation,
                at: oldSchedule.deadline
            )
        )
        try expect(staleCommands.isEmpty, "Expected stale schedule to be ignored")
        try expect(harness.state == changedState, "Expected stale schedule not to mutate state")
    }
}

private func burstProfileChangeTest() -> TestCase {
    TestCase(name: "automatic profile change replaces the burst schedule") {
        var harness = RefreshHarness(profile: .balanced)
        try establishBaseline(&harness, samples: refreshSamples(codexUsed: 10))
        _ = try completeManualRefresh(
            &harness,
            samples: refreshSamples(codexUsed: 11),
            at: refreshInstant(10)
        )
        guard let oldSchedule = harness.state.scheduledRefresh else {
            throw TestFailure(description: "Expected original burst schedule")
        }

        let commands = harness.send(
            .profileChanged(profile: .eco, at: refreshInstant(15))
        )
        let newSchedule = try refreshSchedule(from: commands)

        try expect(newSchedule.reason == .burst, "Expected burst schedule")
        try expect(newSchedule.deadline == refreshInstant(75), "Expected eco burst interval")
        try expect(harness.state.burstDeadline == refreshInstant(310), "Expected burst deadline kept")
        try expect(
            commands.contains(.cancelScheduledRefresh(generation: oldSchedule.generation)),
            "Expected old burst schedule cancellation"
        )
    }
}

private func inFlightProfileChangeTest() -> TestCase {
    TestCase(name: "in-flight request completes under the new refresh profile") {
        var harness = RefreshHarness(profile: .balanced)
        let request = try refreshRequest(from: harness.send(.start(at: refreshInstant(0))))

        let changeCommands = harness.send(
            .profileChanged(profile: .fast, at: refreshInstant(1))
        )
        let completionCommands = harness.send(
            .requestSucceeded(
                generation: request.generation,
                samples: refreshSamples(codexUsed: 10),
                at: refreshInstant(2)
            )
        )
        let schedule = try refreshSchedule(from: completionCommands)

        try expect(changeCommands.isEmpty, "Expected in-flight request to remain")
        try expect(harness.state.profile == .fast, "Expected updated profile")
        try expect(schedule.deadline == refreshInstant(62), "Expected new profile interval")
    }
}

private func retryProfileChangeTest() -> TestCase {
    TestCase(name: "automatic profile change preserves an existing retry schedule") {
        var harness = RefreshHarness(profile: .balanced)
        let request = try refreshRequest(from: harness.send(.start(at: refreshInstant(0))))
        let failureCommands = harness.send(
            .transientFailure(generation: request.generation, at: refreshInstant(0))
        )
        let retrySchedule = try refreshSchedule(from: failureCommands)

        let changeCommands = harness.send(
            .profileChanged(profile: .fast, at: refreshInstant(5))
        )

        try expect(changeCommands.isEmpty, "Expected retry schedule to remain")
        try expect(harness.state.profile == .fast, "Expected updated profile")
        try expect(harness.state.scheduledRefresh == retrySchedule, "Expected same retry schedule")

        let retry = try refreshRequest(
            from: harness.send(
                .scheduledRefreshFired(
                    generation: retrySchedule.generation,
                    at: retrySchedule.deadline
                )
            )
        )
        let successCommands = harness.send(
            .requestSucceeded(
                generation: retry.generation,
                samples: refreshSamples(codexUsed: 10),
                at: retrySchedule.deadline
            )
        )
        let nextSchedule = try refreshSchedule(from: successCommands)
        try expect(
            nextSchedule.deadline == refreshInstant(90),
            "Expected fast interval after retry success"
        )
    }
}

private func manualEntryCleanupTest() -> TestCase {
    TestCase(name: "manual profile entry cancels automatic work and ignores late completion") {
        var scheduledHarness = RefreshHarness()
        let baseline = refreshSamples(codexUsed: 10)
        try establishBaseline(&scheduledHarness, samples: baseline)
        _ = try completeManualRefresh(
            &scheduledHarness,
            samples: refreshSamples(codexUsed: 11),
            at: refreshInstant(10)
        )
        guard let burstSchedule = scheduledHarness.state.scheduledRefresh else {
            throw TestFailure(description: "Expected burst schedule")
        }
        let burstRequest = try refreshRequest(
            from: scheduledHarness.send(
                .scheduledRefreshFired(
                    generation: burstSchedule.generation,
                    at: burstSchedule.deadline
                )
            )
        )
        let failureCommands = scheduledHarness.send(
            .transientFailure(
                generation: burstRequest.generation,
                at: burstSchedule.deadline
            )
        )
        let retrySchedule = try refreshSchedule(from: failureCommands)

        let manualCommands = scheduledHarness.send(
            .profileChanged(profile: .manual, at: refreshInstant(40))
        )

        try expect(scheduledHarness.state.profile == .manual, "Expected manual profile")
        try expect(scheduledHarness.state.isRunning, "Expected app refresh state to remain running")
        try expect(scheduledHarness.state.baseline != nil, "Expected baseline preserved")
        try expect(scheduledHarness.state.burstDeadline == nil, "Expected burst cleared")
        try expect(scheduledHarness.state.consecutiveTransientFailures == 0, "Expected failures cleared")
        try expect(scheduledHarness.state.scheduledRefresh == nil, "Expected schedule cleared")
        try expect(
            manualCommands.contains(
                .cancelScheduledRefresh(generation: retrySchedule.generation)
            ),
            "Expected retry cancellation"
        )

        var requestHarness = RefreshHarness()
        let request = try refreshRequest(from: requestHarness.send(.start(at: refreshInstant(0))))
        let cancelCommands = requestHarness.send(
            .profileChanged(profile: .manual, at: refreshInstant(1))
        )
        let stateAfterCancellation = requestHarness.state
        let lateCommands = requestHarness.send(
            .requestSucceeded(
                generation: request.generation,
                samples: refreshSamples(codexUsed: 99),
                at: refreshInstant(2)
            )
        )

        try expect(
            cancelCommands.contains(.cancelRequest(generation: request.generation)),
            "Expected in-flight cancellation"
        )
        try expect(requestHarness.state.inFlightRequest == nil, "Expected no in-flight request")
        try expect(lateCommands.isEmpty, "Expected late completion ignored")
        try expect(requestHarness.state == stateAfterCancellation, "Expected late state unchanged")
    }
}

private func manualToAutomaticTest() -> TestCase {
    TestCase(name: "manual to automatic profile keeps baseline and schedules normally") {
        var harness = RefreshHarness(profile: .manual)
        let baseline = refreshSamples(codexUsed: 10)
        try establishBaseline(&harness, samples: baseline)

        let commands = harness.send(
            .profileChanged(profile: .balanced, at: refreshInstant(10))
        )
        let schedule = try refreshSchedule(from: commands)

        try expect(refreshRequests(in: commands).isEmpty, "Expected no immediate request")
        try expect(harness.state.baseline == baseline, "Expected baseline preserved")
        try expect(schedule.reason == .normal, "Expected normal schedule")
        try expect(schedule.deadline == refreshInstant(190), "Expected balanced interval")
    }
}

private func lowPowerProfileChangeTest() -> TestCase {
    TestCase(name: "profile change reschedules with low-power clamping") {
        var harness = RefreshHarness(profile: .balanced, lowPowerModeEnabled: true)
        try establishBaseline(&harness, samples: refreshSamples(codexUsed: 10))
        guard let oldSchedule = harness.state.scheduledRefresh else {
            throw TestFailure(description: "Expected low-power schedule")
        }

        let commands = harness.send(
            .profileChanged(profile: .fast, at: refreshInstant(10))
        )
        let schedule = try refreshSchedule(from: commands)

        try expect(
            commands.contains(.cancelScheduledRefresh(generation: oldSchedule.generation)),
            "Expected prior low-power schedule cancellation"
        )
        try expect(schedule.deadline == refreshInstant(610), "Expected low-power clamped interval")
    }
}

private struct RefreshHarness {
    private let reducer = RefreshReducer()
    private(set) var state: RefreshState

    init(
        profile: RefreshProfile = .balanced,
        lowPowerModeEnabled: Bool = false
    ) {
        state = RefreshState(
            profile: profile,
            lowPowerModeEnabled: lowPowerModeEnabled
        )
    }

    mutating func send(_ event: RefreshEvent) -> [RefreshCommand] {
        let transition = reducer.reduce(state: state, event: event)
        state = transition.state
        return transition.commands
    }
}

private func establishBaseline(
    _ harness: inout RefreshHarness,
    samples: SelectedQuotaSamples
) throws {
    let request = try refreshRequest(from: harness.send(.start(at: refreshInstant(0))))
    _ = harness.send(
        .requestSucceeded(generation: request.generation, samples: samples, at: refreshInstant(0))
    )
}

private func completeManualRefresh(
    _ harness: inout RefreshHarness,
    samples: SelectedQuotaSamples,
    at instant: ContinuousClock.Instant
) throws -> ContinuousClock.Instant? {
    let request = try refreshRequest(from: harness.send(.manualRefresh(at: instant)))
    _ = harness.send(
        .requestSucceeded(
            generation: request.generation,
            samples: samples,
            at: instant
        )
    )
    return harness.state.burstDeadline
}

private func refreshSamples(
    codexUsed: Int,
    sparkUsed: Int? = nil,
    resetOffset: TimeInterval = 1_000
) -> SelectedQuotaSamples {
    var values = [
        RefreshQuotaKey(
            product: .codex,
            rawDurationMinutes: 300,
            resetsAt: refreshResetDate(resetOffset)
        ): codexUsed
    ]
    if let sparkUsed {
        values[
            RefreshQuotaKey(
                product: .spark,
                rawDurationMinutes: 300,
                resetsAt: refreshResetDate(resetOffset)
            )
        ] = sparkUsed
    }
    return SelectedQuotaSamples(values)
}

private let refreshBaseInstant = ContinuousClock().now

private func refreshInstant(_ offsetSeconds: Int64) -> ContinuousClock.Instant {
    refreshBaseInstant.advanced(by: .seconds(offsetSeconds))
}

private func refreshResetDate(_ offset: TimeInterval) -> Date {
    Date(timeIntervalSince1970: 1_900_000_000 + offset)
}

private func refreshRequest(from commands: [RefreshCommand]) throws -> RefreshRequest {
    let requests = refreshRequests(in: commands)
    guard requests.count == 1, let request = requests.first else {
        throw TestFailure(description: "Expected one refresh request command")
    }
    return request
}

private func refreshRequests(in commands: [RefreshCommand]) -> [RefreshRequest] {
    commands.compactMap { command in
        guard case .startRequest(let request) = command else {
            return nil
        }
        return request
    }
}

private func refreshSchedule(from commands: [RefreshCommand]) throws -> RefreshSchedule {
    let schedules = commands.compactMap { command -> RefreshSchedule? in
        guard case .scheduleRefresh(let schedule) = command else {
            return nil
        }
        return schedule
    }
    guard schedules.count == 1, let schedule = schedules.first else {
        throw TestFailure(description: "Expected one refresh schedule command")
    }
    return schedule
}

private func requireScheduledGeneration(_ state: RefreshState) throws -> UInt64 {
    guard let generation = state.scheduledRefresh?.generation else {
        throw TestFailure(description: "Expected scheduled refresh generation")
    }
    return generation
}
