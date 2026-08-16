import CodexGaugeCore
import CodexGaugeRefresh
import Testing

@Test("Refresh profiles expose exact configured and low-power intervals")
func refreshProfileIntervalContracts() {
    let clamped = RefreshIntervals(
        normal: .seconds(600),
        burst: .seconds(60)
    )
    let cases = [
        RefreshProfileContractCase(
            profile: .manual,
            configured: RefreshIntervals(normal: nil, burst: nil),
            lowPower: RefreshIntervals(normal: nil, burst: nil)
        ),
        RefreshProfileContractCase(
            profile: .eco,
            configured: clamped,
            lowPower: clamped
        ),
        RefreshProfileContractCase(
            profile: .balanced,
            configured: RefreshIntervals(
                normal: .seconds(180),
                burst: .seconds(20)
            ),
            lowPower: clamped
        ),
        RefreshProfileContractCase(
            profile: .fast,
            configured: RefreshIntervals(
                normal: .seconds(60),
                burst: .seconds(10)
            ),
            lowPower: clamped
        )
    ]

    for contract in cases {
        #expect(contract.profile.intervals == contract.configured)
        #expect(
            contract.profile.effectiveIntervals(lowPowerModeEnabled: true)
                == contract.lowPower
        )
    }
}

@Test("An integer quota increase starts burst polling")
func quotaIncreaseStartsBurstPolling() throws {
    var harness = StandardRefreshHarness()
    let normalSchedule = try establishStandardBaseline(&harness, usedPercent: 10)

    #expect(normalSchedule.reason == .normal)
    #expect(normalSchedule.deadline == standardRefreshInstant(180))

    let request = try requireStandardRequest(
        harness.send(.manualRefresh(at: standardRefreshInstant(10)))
    )
    let commands = harness.send(
        .requestSucceeded(
            generation: request.generation,
            samples: standardRefreshSamples(usedPercent: 11),
            at: standardRefreshInstant(10)
        )
    )
    let burstSchedule = try requireStandardSchedule(commands)

    #expect(harness.state.burstDeadline == standardRefreshInstant(310))
    #expect(burstSchedule.reason == .burst)
    #expect(burstSchedule.deadline == standardRefreshInstant(30))
}

@Test("Unchanged quota samples keep the burst deadline and let it expire")
func unchangedQuotaSamplesEndBurstAtOriginalDeadline() throws {
    var harness = StandardRefreshHarness()
    _ = try establishStandardBaseline(&harness, usedPercent: 10)
    var schedule = try completeStandardRefresh(
        &harness,
        usedPercent: 11,
        at: standardRefreshInstant(10)
    )
    let originalDeadline = try #require(harness.state.burstDeadline)

    schedule = try completeScheduledBurst(
        &harness,
        schedule: schedule,
        usedPercent: 11
    )

    #expect(harness.state.burstDeadline == originalDeadline)
    let commands = harness.send(
        .scheduledRefreshFired(
            generation: schedule.generation,
            at: originalDeadline
        )
    )
    let finalSchedule = try requireStandardSchedule(commands)

    #expect(refreshRequests(in: commands).isEmpty)
    #expect(harness.state.burstDeadline == nil)
    #expect(finalSchedule.reason == .normal)
    #expect(finalSchedule.deadline == originalDeadline.advanced(by: .seconds(180)))
}

@Test("A later integer increase extends the burst deadline")
func laterQuotaIncreaseExtendsBurstDeadline() throws {
    var harness = StandardRefreshHarness()
    _ = try establishStandardBaseline(&harness, usedPercent: 10)
    let firstSchedule = try completeStandardRefresh(
        &harness,
        usedPercent: 11,
        at: standardRefreshInstant(10)
    )
    let originalDeadline = try #require(harness.state.burstDeadline)

    _ = try completeScheduledBurst(
        &harness,
        schedule: firstSchedule,
        usedPercent: 12
    )

    #expect(originalDeadline == standardRefreshInstant(310))
    #expect(harness.state.burstDeadline == standardRefreshInstant(330))
}

@Test("Transient failures follow the bounded exponential backoff ladder")
func transientFailureBackoffContract() throws {
    let delays = [30, 60, 120, 240, 480, 960, 1_800, 1_800]
    var harness = StandardRefreshHarness()
    var request = try requireStandardRequest(
        harness.send(.start(at: standardRefreshInstant(0)))
    )
    var failureTime = standardRefreshInstant(0)

    for (index, delay) in delays.enumerated() {
        let commands = harness.send(
            .transientFailure(
                generation: request.generation,
                at: failureTime
            )
        )
        let retrySchedule = try requireStandardSchedule(commands)

        #expect(retrySchedule.reason == .retry)
        #expect(
            retrySchedule.deadline
                == failureTime.advanced(by: .seconds(Int64(delay)))
        )
        guard index < delays.count - 1 else {
            continue
        }
        request = try requireStandardRequest(
            harness.send(
                .scheduledRefreshFired(
                    generation: retrySchedule.generation,
                    at: retrySchedule.deadline
                )
            )
        )
        failureTime = retrySchedule.deadline
    }

    #expect(harness.state.consecutiveTransientFailures == 7)
}

@Test("Overlapping refresh triggers coalesce with reset precedence")
func overlappingRefreshTriggersCoalesce() throws {
    var harness = StandardRefreshHarness()
    let normalSchedule = try establishStandardBaseline(&harness, usedPercent: 10)
    let request = try requireStandardRequest(
        harness.send(
            .scheduledRefreshFired(
                generation: normalSchedule.generation,
                at: normalSchedule.deadline
            )
        )
    )

    #expect(harness.send(.manualRefresh(at: standardRefreshInstant(181))).isEmpty)
    #expect(harness.send(.wakeBaseline(at: standardRefreshInstant(182))).isEmpty)
    #expect(harness.send(.quotaReset(at: standardRefreshInstant(183))).isEmpty)
    #expect(harness.state.inFlightRequest?.generation == request.generation)
    #expect(harness.state.inFlightRequest?.reason == .quotaReset)
}

@Test("Suspend and resume establish one reset-prioritized baseline")
func suspendResumeBaselineContract() throws {
    var harness = StandardRefreshHarness()
    let schedule = try establishStandardBaseline(&harness, usedPercent: 10)
    let stopCommands = harness.send(.stop)

    #expect(
        stopCommands.contains(
            .cancelScheduledRefresh(generation: schedule.generation)
        )
    )
    #expect(harness.state.isRunning == false)
    #expect(harness.state.baseline == nil)

    let wakeRequest = try requireStandardRequest(
        harness.send(.resumeAfterSystemWake(at: standardRefreshInstant(5)))
    )
    let resetCommands = harness.send(
        .quotaReset(at: standardRefreshInstant(6))
    )

    #expect(resetCommands.isEmpty)
    #expect(harness.state.inFlightRequest?.generation == wakeRequest.generation)
    #expect(harness.state.inFlightRequest?.reason == .quotaReset)

    let completionCommands = harness.send(
        .requestSucceeded(
            generation: wakeRequest.generation,
            samples: standardRefreshSamples(usedPercent: 90),
            at: standardRefreshInstant(6)
        )
    )
    let nextSchedule = try requireStandardSchedule(completionCommands)

    #expect(harness.state.baseline == standardRefreshSamples(usedPercent: 90))
    #expect(harness.state.burstDeadline == nil)
    #expect(nextSchedule.reason == .normal)
}

private struct RefreshProfileContractCase {
    let profile: RefreshProfile
    let configured: RefreshIntervals
    let lowPower: RefreshIntervals
}

private struct StandardRefreshHarness {
    private let reducer = RefreshReducer()
    private(set) var state: RefreshState

    init(profile: RefreshProfile = .balanced) {
        state = RefreshState(profile: profile)
    }

    mutating func send(_ event: RefreshEvent) -> [RefreshCommand] {
        let transition = reducer.reduce(state: state, event: event)
        state = transition.state
        return transition.commands
    }
}

private func establishStandardBaseline(
    _ harness: inout StandardRefreshHarness,
    usedPercent: Int
) throws -> RefreshSchedule {
    let request = try requireStandardRequest(
        harness.send(.start(at: standardRefreshInstant(0)))
    )
    let commands = harness.send(
        .requestSucceeded(
            generation: request.generation,
            samples: standardRefreshSamples(usedPercent: usedPercent),
            at: standardRefreshInstant(0)
        )
    )
    return try requireStandardSchedule(commands)
}

private func completeStandardRefresh(
    _ harness: inout StandardRefreshHarness,
    usedPercent: Int,
    at instant: ContinuousClock.Instant
) throws -> RefreshSchedule {
    let request = try requireStandardRequest(
        harness.send(.manualRefresh(at: instant))
    )
    let commands = harness.send(
        .requestSucceeded(
            generation: request.generation,
            samples: standardRefreshSamples(usedPercent: usedPercent),
            at: instant
        )
    )
    return try requireStandardSchedule(commands)
}

private func completeScheduledBurst(
    _ harness: inout StandardRefreshHarness,
    schedule: RefreshSchedule,
    usedPercent: Int
) throws -> RefreshSchedule {
    let request = try requireStandardRequest(
        harness.send(
            .scheduledRefreshFired(
                generation: schedule.generation,
                at: schedule.deadline
            )
        )
    )
    let commands = harness.send(
        .requestSucceeded(
            generation: request.generation,
            samples: standardRefreshSamples(usedPercent: usedPercent),
            at: schedule.deadline
        )
    )
    return try requireStandardSchedule(commands)
}

private func standardRefreshSamples(
    usedPercent: Int
) -> SelectedQuotaSamples {
    SelectedQuotaSamples([
        RefreshQuotaKey(
            product: .codex,
            rawDurationMinutes: 300,
            resetsAt: nil
        ): usedPercent
    ])
}

private let standardRefreshBaseInstant = ContinuousClock().now

private func standardRefreshInstant(
    _ offsetSeconds: Int64
) -> ContinuousClock.Instant {
    standardRefreshBaseInstant.advanced(by: .seconds(offsetSeconds))
}

private func requireStandardRequest(
    _ commands: [RefreshCommand]
) throws -> RefreshRequest {
    let requests = refreshRequests(in: commands)
    #expect(requests.count == 1)
    return try #require(requests.first)
}

private func refreshRequests(
    in commands: [RefreshCommand]
) -> [RefreshRequest] {
    commands.compactMap { command in
        guard case .startRequest(let request) = command else {
            return nil
        }
        return request
    }
}

private func requireStandardSchedule(
    _ commands: [RefreshCommand]
) throws -> RefreshSchedule {
    let schedules = commands.compactMap { command -> RefreshSchedule? in
        guard case .scheduleRefresh(let schedule) = command else {
            return nil
        }
        return schedule
    }
    #expect(schedules.count == 1)
    return try #require(schedules.first)
}
