import CodexGaugeCore
import CodexGaugeProtocol
import CodexGaugeRefresh
import Foundation

func refreshCoordinatorTests() -> [TestCase] {
    [
        selectedQuotaSampleMappingTest(),
        normalPollingSessionLifecycleTest(),
        burstSessionReuseAndExtensionTest(),
        transientFailureRetryTest(),
        serverRPCFailuresRetryTest(),
        deterministicRawRPCFailuresStopRetryTest(),
        deterministicRPCFailureStopsBurstTest(),
        terminalFailureWaitsForManualRetryTest(),
        missingExecutableFailureTest(),
        lateResultDiscardTest(),
        concurrentTriggerCoalescingExecutionTest(),
        manualAndSuspendCleanupTest(),
        systemResumeDelayTest(),
        resetDuringSystemResumeCoalescingTest(),
        stoppedCoordinatorClearsPendingResumeResetTest(),
        quotaResetTriggerTest(),
        quotaResetUpgradesInFlightRequestTest(),
        lowPowerCoordinatorSchedulingTest(),
        incompatibleRateLimitResponseStopsPollingTest(),
        refreshPublicationMalformedWithoutPriorTest(),
        refreshPublicationPartialProductTest(),
        delayedStopCoalescesPendingRequestTest(),
        unconfirmedStopWaitsForLateExitTest(),
        hardBurstCapClosesInflightSessionTest(),
        cancelledFactoryCannotStartNewSessionTest(),
        terminationBarrierWaitsForRetirementTest(),
        retirementLowPowerFloorTest(),
        retirementProfileFloorTest(),
        retirementManualRequestFloorExemptionTest(),
        retirementManualUpgradeFloorExemptionTest(),
        factoryPolicyFloorRevalidationTest(),
        factoryManualFloorExemptionTest()
    ]
}

private func retirementLowPowerFloorTest() -> TestCase {
    TestCase(name: "pending retirement automatic request honors a newly enabled low-power floor") {
        try await verifyRetirementPolicyFloor(policy: .lowPower, manualIntent: .none)
    }
}

private func retirementProfileFloorTest() -> TestCase {
    TestCase(name: "pending retirement automatic request honors a newly selected eco floor") {
        try await verifyRetirementPolicyFloor(policy: .ecoProfile, manualIntent: .none)
    }
}

private func retirementManualRequestFloorExemptionTest() -> TestCase {
    TestCase(name: "pending retirement manual request remains exempt from a changed policy floor") {
        for policy in RetirementPolicyChange.allCases {
            try await verifyRetirementPolicyFloor(policy: policy, manualIntent: .queued)
        }
    }
}

private func retirementManualUpgradeFloorExemptionTest() -> TestCase {
    TestCase(name: "pending retirement automatic request explicitly refreshed by user becomes floor exempt") {
        for policy in RetirementPolicyChange.allCases {
            try await verifyRetirementPolicyFloor(policy: policy, manualIntent: .upgrade)
        }
    }
}

private enum RetirementPolicyChange: CaseIterable {
    case lowPower
    case ecoProfile
}

private enum RetirementManualIntent: Equatable {
    case none
    case queued
    case upgrade
}

private func verifyRetirementPolicyFloor(
    policy: RetirementPolicyChange,
    manualIntent: RetirementManualIntent
) async throws {
    let exitGate = TestReadGate()
    let readGate = TestReadGate()
    let clock = TestRefreshClock()
    let origin = await clock.now()
    let provider = TestRefreshSessionProvider(plans: [
        [.success(coordinatorResult(codexUsed: 10))],
        [.gated(readGate, coordinatorResult(codexUsed: 10))]
    ], exitGates: [1: exitGate])
    let coordinator = makeCoordinator(clock: clock, provider: provider)
    do {
        await coordinator.start()
        try await eventually { await provider.metrics().stopAttempts == 1 }
        let completed = await coordinator.state
        try expect(completed.lastRequestCompletedAt == origin, "Expected startup completion at t=0")

        await clock.advance(by: .seconds(20))
        if manualIntent == .queued {
            await coordinator.refreshManually()
        } else {
            await coordinator.refreshAfterQuotaReset()
        }
        let pending = await coordinator.state
        try expect(pending.inFlightRequest != nil, "Expected one request queued behind retirement at t=20")
        let beforePolicy = await provider.metrics()
        try expect(beforePolicy.created == 1, "Expected no second factory before prior exit")

        await clock.advance(by: .seconds(1))
        switch policy {
        case .lowPower:
            await coordinator.setLowPowerMode(true)
        case .ecoProfile:
            await coordinator.updateProfile(.eco)
        }
        if manualIntent == .upgrade { await coordinator.refreshManually() }

        await clock.advance(by: .seconds(1))
        await exitGate.release()
        if manualIntent == .none {
            // Wait for an observable decision: premature launch in the old
            // implementation, or a deferred timer in the corrected engine.
            try await eventually {
                let metrics = await provider.metrics()
                let state = await coordinator.state
                return metrics.starts > 1 || (metrics.stops == 1 && state.scheduledRefresh != nil)
            }
            let retired = await provider.metrics()
            try expect(
                retired.created == 1 && retired.starts == 1 && retired.reads == 1,
                "Expected pending automatic request not to create, start or read at t=22 before the new t=60 floor"
            )
            let deferred = await coordinator.state
            try expect(
                deferred.scheduledRefresh?.deadline == origin.advanced(by: .seconds(60)),
                "Expected floor anchored to t=0 completion, not retirement or policy-change time"
            )
            try await eventually { await clock.pendingSleeperCount() == 1 }
            await clock.advance(by: .seconds(37))
            let beforeFloor = await provider.metrics()
            try expect(beforeFloor.starts == 1 && beforeFloor.reads == 1, "Expected no request before t=60")
            await clock.advance(by: .seconds(1))
        }
        try await expectMetrics(provider, starts: 2, reads: 2, stops: 1)
        let startedAt = await clock.now()
        let expectedStartOffset: Duration = manualIntent == .none ? .seconds(60) : .seconds(22)
        try expect(
            startedAt == origin.advanced(by: expectedStartOffset),
            "Expected automatic request at t=60 and an explicit manual request immediately after t=22 exit"
        )
        let started = await provider.metrics()
        try expect(started.maximumLiveSessions == 1, "Expected floor handling to preserve single session ownership")
        await readGate.release()
        try await expectMetrics(provider, starts: 2, reads: 2, stops: 2)
        await coordinator.stop()
        await coordinator.waitForTermination()
    } catch {
        await exitGate.release()
        await readGate.release()
        await coordinator.stop()
        await coordinator.waitForTermination()
        throw error
    }
}

private func factoryPolicyFloorRevalidationTest() -> TestCase {
    TestCase(name: "pending factory result rechecks changed policy before process start") {
        for policy in RetirementPolicyChange.allCases {
            try await verifyFactoryPolicyFloor(policy: policy, manualUpgrade: false)
        }
    }
}

private func factoryManualFloorExemptionTest() -> TestCase {
    TestCase(name: "pending factory result preserves explicit manual exemption after policy change") {
        for policy in RetirementPolicyChange.allCases {
            try await verifyFactoryPolicyFloor(policy: policy, manualUpgrade: true)
        }
    }
}

private func verifyFactoryPolicyFloor(
    policy: RetirementPolicyChange,
    manualUpgrade: Bool
) async throws {
    let factoryGate = TestReadGate()
    let readGate = TestReadGate()
    let clock = TestRefreshClock()
    let origin = await clock.now()
    let provider = TestRefreshSessionProvider(
        plans: [
            [.success(coordinatorResult(codexUsed: 10))],
            [.success(coordinatorResult(codexUsed: 10))],
            [.gated(readGate, coordinatorResult(codexUsed: 10))]
        ],
        factoryGates: [2: factoryGate]
    )
    let coordinator = makeCoordinator(clock: clock, provider: provider)
    do {
        await coordinator.start()
        try await expectMetrics(provider, starts: 1, reads: 1, stops: 1)
        await clock.advance(by: .seconds(20))
        await coordinator.refreshAfterQuotaReset()
        try await eventually { await provider.metrics().created == 2 }
        let held = await provider.metrics()
        try expect(held.starts == 1 && held.reads == 1, "Expected second factory held before process start")
        await clock.advance(by: .seconds(1))
        switch policy {
        case .lowPower: await coordinator.setLowPowerMode(true)
        case .ecoProfile: await coordinator.updateProfile(.eco)
        }
        if manualUpgrade { await coordinator.refreshManually() }
        await clock.advance(by: .seconds(1))
        await factoryGate.release()
        if manualUpgrade {
            try await expectMetrics(provider, starts: 2, reads: 2, stops: 2)
            let instant = await clock.now()
            try expect(instant == origin.advanced(by: .seconds(22)), "Expected explicit manual upgrade admitted at t=22")
        } else {
            try await eventually { await provider.metrics().stops == 2 }
            let retired = await provider.metrics()
            try expect(
                retired.starts == 1 && retired.reads == 1,
                "Expected a stale factory admission to retire without process start or read before t=60"
            )
            let deferred = await coordinator.state
            try expect(deferred.scheduledRefresh?.deadline == origin.advanced(by: .seconds(60)), "Expected current floor after asynchronous factory return")
            try await eventually { await clock.pendingSleeperCount() == 1 }
            await clock.advance(by: .seconds(38))
            try await expectMetrics(provider, starts: 2, reads: 2, stops: 2)
            await readGate.release()
            try await expectMetrics(provider, starts: 2, reads: 2, stops: 3)
        }
        let finished = await provider.metrics()
        try expect(finished.maximumLiveSessions == 1, "Expected factory revalidation to preserve lease ownership")
        await coordinator.stop()
        await coordinator.waitForTermination()
    } catch {
        await factoryGate.release()
        await readGate.release()
        await coordinator.stop()
        await coordinator.waitForTermination()
        throw error
    }
}

private func delayedStopCoalescesPendingRequestTest() -> TestCase {
    TestCase(name: "one pending request waits until the previous session confirms stop") {
        let stopGate = TestReadGate()
        let readGate = TestReadGate()
        let clock = TestRefreshClock()
        let provider = TestRefreshSessionProvider(plans: [
            [.success(coordinatorResult(codexUsed: 10))],
            [.gated(readGate, coordinatorResult(codexUsed: 10))]
        ], stopGates: [1: stopGate])
        let recorder = await MainActor.run { RefreshPublicationRecorder() }
        let coordinator = makeCoordinator(clock: clock, provider: provider, recorder: recorder)
        await coordinator.start()
        try await eventually { await provider.metrics().stopAttempts == 1 }
        let triggers = Task {
            await withTaskGroup(of: Void.self) { group in
                for _ in 0..<100 { group.addTask { await coordinator.refreshManually() } }
            }
        }
        try await eventually { await coordinator.state.inFlightRequest != nil }
        await drainExecutor()
        let waiting = await provider.metrics()
        try expect(waiting.created == 1 && waiting.starts == 1, "Expected no factory or process while stop is pending")
        await stopGate.release()
        await triggers.value
        try await expectMetrics(provider, starts: 2, reads: 2, stops: 1)
        await readGate.release()
        try await expectMetrics(provider, starts: 2, reads: 2, stops: 2)
        let finished = await provider.metrics()
        try expect(finished.maximumLiveSessions == 1, "Expected process lifetime overlap prevented")
        let refreshingSequence = await MainActor.run { recorder.values.map(\.isRefreshing) }
        try expect(
            refreshingSequence == [true, false, true, false],
            "Expected delayed cleanup not to republish a newer request's state"
        )
        await coordinator.stop()
    }
}

private func unconfirmedStopWaitsForLateExitTest() -> TestCase {
    TestCase(name: "unconfirmed stop retains ownership across restart until a late actual exit") {
        let exitGate = TestReadGate()
        let readGate = TestReadGate()
        let clock = TestRefreshClock()
        let provider = TestRefreshSessionProvider(plans: [
            [.success(coordinatorResult(codexUsed: 10))],
            [.gated(readGate, coordinatorResult(codexUsed: 10))]
        ], exitGates: [1: exitGate])
        let coordinator = makeCoordinator(clock: clock, provider: provider)
        await coordinator.start()
        try await eventually { await provider.metrics().stopAttempts == 1 }
        await coordinator.refreshManually()
        await coordinator.stop()
        await coordinator.start()
        for _ in 0..<100 { await coordinator.refreshManually() }
        let waiting = await provider.metrics()
        try expect(waiting.created == 1 && waiting.stopAttempts == 1, "Expected one retained owner and one stop attempt")
        await exitGate.release()
        try await expectMetrics(provider, starts: 2, reads: 2, stops: 1)
        await readGate.release()
        try await expectMetrics(provider, starts: 2, reads: 2, stops: 2)
        let finished = await provider.metrics()
        try expect(finished.maximumLiveSessions == 1, "Expected no overlap after late termination")
        await coordinator.stop()
    }
}

private func hardBurstCapClosesInflightSessionTest() -> TestCase {
    TestCase(name: "burst cap cancels a held read and closes its retained session at 300 seconds") {
        let gate = TestReadGate()
        let clock = TestRefreshClock()
        let provider = TestRefreshSessionProvider(plans: [
            [.success(coordinatorResult(codexUsed: 10))],
            [.success(coordinatorResult(codexUsed: 11)), .gated(gate, coordinatorResult(codexUsed: 99))]
        ])
        let coordinator = makeCoordinator(clock: clock, provider: provider)
        await coordinator.start()
        try await expectMetrics(provider, starts: 1, reads: 1, stops: 1)
        await coordinator.refreshManually()
        try await eventually { await coordinator.state.burstDeadline != nil }
        await clock.advance(by: .seconds(20))
        try await expectMetrics(provider, starts: 2, reads: 3, stops: 1)
        try await eventually { await clock.pendingSleeperCount() == 1 }
        await clock.advance(by: .seconds(280))
        try await expectMetrics(provider, starts: 2, reads: 3, stops: 2)
        let expired = await coordinator.state
        try expect(expired.inFlightRequest == nil && expired.burstDeadline == nil, "Expected cap to cancel request and burst")
        try expect(expired.scheduledRefresh?.reason == .normal, "Expected cooldown normal timer")
        await gate.release()
        await drainExecutor()
        let publication = await coordinator.publication
        try expect(coordinatorUsedPercent(publication, product: .codex) == 11, "Expected late cancelled quota ignored")
        await coordinator.stop()
    }
}

private func cancelledFactoryCannotStartNewSessionTest() -> TestCase {
    TestCase(name: "cancelled factory result is retired before a newer generation acquires a session") {
        let factoryGate = TestReadGate()
        let readGate = TestReadGate()
        let clock = TestRefreshClock()
        let provider = TestRefreshSessionProvider(plans: [
            [.success(coordinatorResult(codexUsed: 99))],
            [.gated(readGate, coordinatorResult(codexUsed: 10))]
        ], factoryGate: factoryGate)
        let coordinator = makeCoordinator(clock: clock, provider: provider)
        await coordinator.start()
        try await eventually { await provider.metrics().created == 1 }
        await coordinator.stop()
        await coordinator.start()
        await drainExecutor()
        let waiting = await provider.metrics()
        try expect(waiting.created == 1 && waiting.starts == 0, "Expected old acquisition to keep the slot")
        await factoryGate.release()
        try await expectMetrics(provider, starts: 1, reads: 1, stops: 1)
        let acquired = await provider.metrics()
        try expect(acquired.created == 2, "Expected newer acquisition only after retirement")
        await readGate.release()
        try await expectMetrics(provider, starts: 1, reads: 1, stops: 2)
        await coordinator.stop()
    }
}

private func terminationBarrierWaitsForRetirementTest() -> TestCase {
    TestCase(name: "coordinator replacement barrier waits for late exit and cancelled factory retirement") {
        for delayedFactory in [false, true] {
            let gate = TestReadGate()
            let clock = TestRefreshClock()
            let provider = TestRefreshSessionProvider(
                plans: [[.success(coordinatorResult(codexUsed: 10))]],
                exitGates: delayedFactory ? [:] : [1: gate],
                factoryGate: delayedFactory ? gate : nil
            )
            let coordinator = makeCoordinator(clock: clock, provider: provider)
            await coordinator.start()
            if delayedFactory {
                try await eventually { await provider.metrics().created == 1 }
            } else {
                try await eventually { await provider.metrics().stopAttempts == 1 }
            }
            await coordinator.stop()
            let completion = TestBarrierCompletion()
            let barrier = Task {
                await coordinator.waitForTermination()
                await completion.finish()
            }
            await drainExecutor()
            let prematurelyFinished = await completion.isFinished
            try expect(!prematurelyFinished, "Expected replacement barrier to remain pending")
            await gate.release()
            await barrier.value
            let finished = await provider.metrics()
            try expect(finished.stops == 1, "Expected cancelled acquisition or late exit retired before replacement")
            try expect(finished.starts == (delayedFactory ? 0 : 1), "Expected cancelled factory never to launch")
            await coordinator.waitForTermination()
        }
    }
}

private actor TestBarrierCompletion {
    private(set) var isFinished = false
    func finish() { isFinished = true }
}

private func selectedQuotaSampleMappingTest() -> TestCase {
    TestCase(name: "refresh samples follow the single displayed quota and omit missing selections") {
        let result = coordinatorResult(codexWindows: [
            coordinatorWindow(.primary, used: 10.9, duration: 300, reset: 1_900_100_000),
            coordinatorWindow(.secondary, used: 20.4, duration: 10_080, reset: 1_900_200_000)
        ])
        let cases: [(DisplayQuotaSelection, Int, TimeInterval, Int)] = [
            (.automatic, 300, 1_900_100_000, 10),
            (.manual(QuotaSelectionID(product: .codex, rawDurationMinutes: 10_080)), 10_080, 1_900_200_000, 20)
        ]
        for (selection, duration, reset, used) in cases {
            let preference = DisplayPreference(quotaSelection: selection)
            let samples = DisplayPreferenceQuotaSampleSelector().samples(from: result, preference: preference)
            try expect(samples.values == [coordinatorKey(.codex, duration: duration, reset: reset): used], "Expected exactly the selected sample")
            let frames = DisplayFrameBuilder().makeFrames(
                preference: preference,
                productStates: [.codex: .value(
                    ProductQuotaValue(capturedAt: result.capturedAt, quotaWindows: result.rateLimits(for: .codex).windows),
                    freshness: .fresh
                )],
                now: result.capturedAt
            )
            try expect(frames.count == 1, "Expected one displayed quota")
            guard case .single(let quota) = frames.first else {
                throw TestFailure(description: "Expected a single Codex frame")
            }
            try expect(quota.identifier.rawDurationMinutes == duration, "Expected display and refresh selection agreement")
        }
        let missing = DisplayPreference(quotaSelection: .manual(
            QuotaSelectionID(product: .codex, rawDurationMinutes: 60)
        ))
        let samples = DisplayPreferenceQuotaSampleSelector().samples(from: result, preference: missing)
        try expect(samples.values.isEmpty, "Expected missing manual quota not to fall back to automatic")
    }
}

private func normalPollingSessionLifecycleTest() -> TestCase {
    TestCase(name: "normal polling starts and stops one transient session per request") {
        let clock = TestRefreshClock()
        let provider = TestRefreshSessionProvider(plans: [
            [.success(coordinatorResult(codexUsed: 10))],
            [.success(coordinatorResult(codexUsed: 10))]
        ])
        let recorder = await MainActor.run { RefreshPublicationRecorder() }
        let coordinator = makeCoordinator(clock: clock, provider: provider, recorder: recorder)

        await coordinator.start()
        try await expectMetrics(provider, starts: 1, reads: 1, stops: 1)
        try await eventually { await coordinator.state.scheduledRefresh?.reason == .normal }

        await clock.advance(by: .seconds(180))
        try await expectMetrics(provider, starts: 2, reads: 2, stops: 2)
        try await eventually { await coordinator.state.scheduledRefresh?.reason == .normal }

        let publication = await coordinator.publication
        let recordedPublication = await MainActor.run { recorder.values.last }
        try expect(publication.isRefreshing == false, "Expected completed publication")
        try expect(coordinatorUsedPercent(publication, product: .codex) == 10, "Expected quota value")
        try expect(recordedPublication == publication, "Expected ordered MainActor publication")
        let refreshingSequence = await MainActor.run { recorder.values.map(\.isRefreshing) }
        try expect(
            refreshingSequence == [true, false, true, false],
            "Expected each request start and completion delivered once, before its process stops"
        )
        await coordinator.stop()
        let stoppedState = await coordinator.state
        try expect(stoppedState.scheduledRefresh == nil, "Expected timer state cleanup")
        await clock.advance(by: .seconds(180))
        await drainExecutor()
        try await expectMetrics(provider, starts: 2, reads: 2, stops: 2)
    }
}

private func burstSessionReuseAndExtensionTest() -> TestCase {
    TestCase(name: "burst reuses one session and increases preserve the hard deadline") {
        let clock = TestRefreshClock()
        let provider = TestRefreshSessionProvider(plans: [
            [.success(coordinatorResult(codexUsed: 10))],
            [
                .success(coordinatorResult(codexUsed: 11)),
                .success(coordinatorResult(codexUsed: 12)),
                .success(coordinatorResult(codexUsed: 12))
            ]
        ])
        let coordinator = makeCoordinator(clock: clock, provider: provider)

        await coordinator.start()
        try await expectMetrics(provider, starts: 1, reads: 1, stops: 1)
        await coordinator.refreshManually()
        try await expectMetrics(provider, starts: 2, reads: 2, stops: 1)
        try await eventually {
            let state = await coordinator.state
            return state.inFlightRequest == nil && state.burstDeadline != nil
        }
        let firstDeadline = try await requireBurstDeadline(coordinator)

        await clock.advance(by: .seconds(20))
        try await expectMetrics(provider, starts: 2, reads: 3, stops: 1)
        try await eventually { await coordinator.state.inFlightRequest == nil }
        let extendedDeadline = try await requireBurstDeadline(coordinator)
        try expect(extendedDeadline == firstDeadline, "Expected fixed five-minute cap")

        await clock.advance(by: .seconds(20))
        try await expectMetrics(provider, starts: 2, reads: 4, stops: 1)
        try await eventually {
            let state = await coordinator.state
            return state.inFlightRequest == nil && state.burstDeadline == extendedDeadline
        }
        let unchangedDeadline = try await requireBurstDeadline(coordinator)
        try expect(
            unchangedDeadline == extendedDeadline,
            "Expected unchanged quota not to extend the burst"
        )
        await coordinator.stop()
        try await expectMetrics(provider, starts: 2, reads: 4, stops: 2)
    }
}

private func transientFailureRetryTest() -> TestCase {
    TestCase(name: "transient refresh failure stops its session and retries on backoff") {
        let clock = TestRefreshClock()
        let provider = TestRefreshSessionProvider(plans: [
            [.failure(.timeout(.rateLimits))],
            [.success(coordinatorResult(codexUsed: 17))]
        ])
        let coordinator = makeCoordinator(clock: clock, provider: provider)

        await coordinator.start()
        try await expectMetrics(provider, starts: 1, reads: 1, stops: 1)
        var publication = await coordinator.publication
        try expect(publication.failure == .timeout, "Expected sanitized timeout failure")

        await clock.advance(by: .seconds(30))
        try await expectMetrics(provider, starts: 2, reads: 2, stops: 2)
        publication = await coordinator.publication
        try expect(publication.failure == nil, "Expected retry success to clear failure")
        try expect(coordinatorUsedPercent(publication, product: .codex) == 17, "Expected retry value")
        await coordinator.stop()
    }
}

private func serverRPCFailuresRetryTest() -> TestCase {
    TestCase(name: "server JSON-RPC failures retain backoff retries") {
        for code in [-32_603, -32_001, 42] {
            try await expectRPCFailureRetry(code: code)
        }
    }
}

private func deterministicRPCFailureStopsBurstTest() -> TestCase {
    TestCase(name: "deterministic JSON-RPC failure stops polling and retained burst child") {
        let clock = TestRefreshClock()
        let provider = TestRefreshSessionProvider(plans: [
            [.success(coordinatorResult(codexUsed: 10))],
            [
                .success(coordinatorResult(codexUsed: 11)),
                .failure(.protocolIncompatible)
            ]
        ])
        let coordinator = makeCoordinator(clock: clock, provider: provider)

        await coordinator.start()
        try await expectMetrics(provider, starts: 1, reads: 1, stops: 1)
        await coordinator.refreshManually()
        try await expectMetrics(provider, starts: 2, reads: 2, stops: 1)
        try await eventually { await coordinator.state.burstDeadline != nil }

        await clock.advance(by: .seconds(20))
        try await expectMetrics(provider, starts: 2, reads: 3, stops: 2)
        let publication = await coordinator.publication
        let state = await coordinator.state
        let sleeperCount = await clock.pendingSleeperCount()
        try expect(
            publication.failure == .protocolIncompatible,
            "Expected a typed protocol failure publication"
        )
        try expect(state.scheduledRefresh == nil, "Expected no automatic retry")
        try expect(state.burstDeadline == nil, "Expected the retained burst state cleared")
        try expect(sleeperCount == 0, "Expected no retained polling timer")

        await clock.advance(by: .seconds(180))
        await drainExecutor()
        try await expectMetrics(provider, starts: 2, reads: 3, stops: 2)
        await coordinator.stop()
    }
}

private func deterministicRawRPCFailuresStopRetryTest() -> TestCase {
    TestCase(name: "reserved deterministic JSON-RPC failures never retry") {
        for code in [-32_700, -32_600, -32_601, -32_602] {
            try await expectRPCFailureStopsRetry(code: code)
        }
    }
}

private func expectRPCFailureStopsRetry(code: Int) async throws {
    let clock = TestRefreshClock()
    let provider = TestRefreshSessionProvider(plans: [
        [.failure(.rpcFailure(code: code))]
    ])
    let coordinator = makeCoordinator(clock: clock, provider: provider)

    await coordinator.start()
    try await expectMetrics(provider, starts: 1, reads: 1, stops: 1)
    let publication = await coordinator.publication
    let state = await coordinator.state
    let sleeperCount = await clock.pendingSleeperCount()
    try expect(
        publication.failure == .protocolIncompatible,
        "Expected a typed protocol failure"
    )
    try expect(state.scheduledRefresh == nil, "Expected no automatic retry")
    try expect(sleeperCount == 0, "Expected no backoff timer")
    await coordinator.stop()
}

private func expectRPCFailureRetry(code: Int) async throws {
    let clock = TestRefreshClock()
    let provider = TestRefreshSessionProvider(plans: [
        [.failure(.rpcFailure(code: code))],
        [.success(coordinatorResult(codexUsed: 17))]
    ])
    let coordinator = makeCoordinator(clock: clock, provider: provider)

    await coordinator.start()
    try await expectMetrics(provider, starts: 1, reads: 1, stops: 1)
    let failedPublication = await coordinator.publication
    try expect(
        failedPublication.failure == .server(code: code),
        "Expected a typed transient server failure"
    )

    await clock.advance(by: .seconds(30))
    try await expectMetrics(provider, starts: 2, reads: 2, stops: 2)
    let recoveredPublication = await coordinator.publication
    try expect(recoveredPublication.failure == nil, "Expected retry recovery")
    await coordinator.stop()
}

private func terminalFailureWaitsForManualRetryTest() -> TestCase {
    TestCase(name: "terminal refresh failure does not loop and permits manual recovery") {
        let clock = TestRefreshClock()
        let provider = TestRefreshSessionProvider(plans: [
            [.failure(.signedOut)],
            [.success(coordinatorResult(codexUsed: 22))]
        ])
        let coordinator = makeCoordinator(clock: clock, provider: provider)

        await coordinator.start()
        try await expectMetrics(provider, starts: 1, reads: 1, stops: 1)
        let signedOutPublication = await coordinator.publication
        let signedOutSleeperCount = await clock.pendingSleeperCount()
        try expect(signedOutPublication.failure == .signedOut, "Expected signed-out state")
        try expect(signedOutSleeperCount == 0, "Expected no terminal retry timer")

        await coordinator.refreshManually()
        try await expectMetrics(provider, starts: 2, reads: 2, stops: 2)
        let recoveredPublication = await coordinator.publication
        try expect(recoveredPublication.failure == nil, "Expected manual recovery")
        await coordinator.stop()
    }
}

private func missingExecutableFailureTest() -> TestCase {
    TestCase(name: "missing executable publishes a terminal action state") {
        let clock = TestRefreshClock()
        let coordinator = makeCoordinator(
            clock: clock,
            provider: MissingExecutableSessionProvider()
        )

        await coordinator.start()
        try await eventually {
            await coordinator.publication.failure == .codexNotFound
        }

        let publication = await coordinator.publication
        let sleeperCount = await clock.pendingSleeperCount()
        try expect(publication.failure == .codexNotFound, "Expected missing Codex reason")
        try expect(sleeperCount == 0, "Expected no missing-executable retry")
        await coordinator.stop()
    }
}

private func lateResultDiscardTest() -> TestCase {
    TestCase(name: "late cancelled result cannot overwrite a newer coordinator generation") {
        let gate = TestReadGate()
        let clock = TestRefreshClock()
        let provider = TestRefreshSessionProvider(plans: [
            [.gated(gate, coordinatorResult(codexUsed: 99))],
            [.success(coordinatorResult(codexUsed: 25))]
        ])
        let coordinator = makeCoordinator(clock: clock, provider: provider)

        await coordinator.start()
        try await expectMetrics(provider, starts: 1, reads: 1, stops: 0)
        await coordinator.stop()
        try await expectMetrics(provider, starts: 1, reads: 1, stops: 1)
        await coordinator.start()
        try await expectMetrics(provider, starts: 2, reads: 2, stops: 2)

        await gate.release()
        await drainExecutor()
        let publication = await coordinator.publication
        try expect(coordinatorUsedPercent(publication, product: .codex) == 25, "Expected late value discarded")
        await coordinator.stop()
    }
}

private func concurrentTriggerCoalescingExecutionTest() -> TestCase {
    TestCase(name: "concurrent coordinator triggers share one in-flight request") {
        let gate = TestReadGate()
        let clock = TestRefreshClock()
        let provider = TestRefreshSessionProvider(plans: [
            [.gated(gate, coordinatorResult(codexUsed: 42))]
        ])
        let coordinator = makeCoordinator(clock: clock, provider: provider)

        await coordinator.start()
        try await expectMetrics(provider, starts: 1, reads: 1, stops: 0)
        await withTaskGroup(of: Void.self) { group in
            group.addTask { await coordinator.refreshManually() }
            group.addTask { await coordinator.establishWakeBaseline() }
            group.addTask { await coordinator.refreshManually() }
        }
        try await expectMetrics(provider, starts: 1, reads: 1, stops: 0)

        await gate.release()
        try await expectMetrics(provider, starts: 1, reads: 1, stops: 1)
        let state = await coordinator.state
        try expect(state.burstDeadline == nil, "Expected coalesced wake to establish baseline")
        await coordinator.stop()
    }
}

private func manualAndSuspendCleanupTest() -> TestCase {
    TestCase(name: "manual mode and suspension cancel timers and retained burst sessions") {
        let clock = TestRefreshClock()
        let provider = TestRefreshSessionProvider(plans: [
            [.success(coordinatorResult(codexUsed: 10))],
            [.success(coordinatorResult(codexUsed: 11))],
            [.success(coordinatorResult(codexUsed: 11))]
        ])
        let coordinator = makeCoordinator(clock: clock, provider: provider)

        await coordinator.start()
        try await expectMetrics(provider, starts: 1, reads: 1, stops: 1)
        await coordinator.refreshManually()
        try await expectMetrics(provider, starts: 2, reads: 2, stops: 1)
        try await eventually {
            let state = await coordinator.state
            return state.inFlightRequest == nil && state.burstDeadline != nil
        }
        await coordinator.updateProfile(.manual)
        try await expectMetrics(provider, starts: 2, reads: 2, stops: 2)
        let manualState = await coordinator.state
        try expect(manualState.scheduledRefresh == nil, "Expected manual timer cleanup")
        await clock.advance(by: .seconds(180))
        await drainExecutor()
        try await expectMetrics(provider, starts: 2, reads: 2, stops: 2)

        await coordinator.updateProfile(.balanced)
        await coordinator.refreshManually()
        try await expectMetrics(provider, starts: 3, reads: 3, stops: 3)
        await coordinator.suspend()
        let suspendedState = await coordinator.state
        try expect(suspendedState.isRunning == false, "Expected suspended reducer")
        try expect(suspendedState.scheduledRefresh == nil, "Expected suspend timer cleanup")
        await clock.advance(by: .seconds(1_800))
        await drainExecutor()
        try await expectMetrics(provider, starts: 3, reads: 3, stops: 3)
    }
}

private func systemResumeDelayTest() -> TestCase {
    TestCase(name: "system resume coalesces after five-second delay and automatic completion floor") {
        let gate = TestReadGate()
        let clock = TestRefreshClock()
        let provider = TestRefreshSessionProvider(plans: [
            [.success(coordinatorResult(codexUsed: 10))],
            [.gated(gate, coordinatorResult(codexUsed: 70))]
        ])
        let coordinator = makeCoordinator(clock: clock, provider: provider)

        await coordinator.start()
        try await expectMetrics(provider, starts: 1, reads: 1, stops: 1)
        await coordinator.suspend()
        await coordinator.resumeAfterSystemWake()
        await coordinator.resumeAfterSystemWake()
        let isAwaitingSystemResume = await coordinator.isAwaitingSystemResume()
        try expect(
            isAwaitingSystemResume,
            "Expected observable pending resume phase"
        )
        try await eventually { await clock.pendingSleeperCount() == 1 }

        await clock.advance(by: .seconds(4))
        await drainExecutor()
        try await expectMetrics(provider, starts: 1, reads: 1, stops: 1)

        await clock.advance(by: .seconds(1))
        await drainExecutor()
        try await expectMetrics(provider, starts: 1, reads: 1, stops: 1)
        await clock.advance(by: .seconds(15))
        try await expectMetrics(provider, starts: 2, reads: 2, stops: 1)
        let didClearSystemResume = await coordinator.isAwaitingSystemResume() == false
        try expect(
            didClearSystemResume,
            "Expected fired resume phase to clear"
        )
        let inFlight = await coordinator.state.inFlightRequest
        try expect(inFlight?.reason == .wakeBaseline, "Expected a wake-baseline request")

        await gate.release()
        try await expectMetrics(provider, starts: 2, reads: 2, stops: 2)
        try await eventually { await coordinator.state.inFlightRequest == nil }
        let resumedState = await coordinator.state
        try expect(resumedState.burstDeadline == nil, "Expected wake not to start burst")
        await coordinator.stop()
    }
}

private func resetDuringSystemResumeCoalescingTest() -> TestCase {
    TestCase(name: "quota reset during system resume becomes one delayed reset request") {
        let gate = TestReadGate()
        let clock = TestRefreshClock()
        let provider = TestRefreshSessionProvider(plans: [
            [.success(coordinatorResult(codexUsed: 90))],
            [.gated(gate, coordinatorResult(codexUsed: 5))]
        ])
        let coordinator = makeCoordinator(clock: clock, provider: provider)

        await coordinator.start()
        try await expectMetrics(provider, starts: 1, reads: 1, stops: 1)
        await coordinator.suspend()
        await coordinator.refreshAfterQuotaReset()
        await coordinator.resumeAfterSystemWake()
        await clock.advance(by: .seconds(4))
        await coordinator.refreshAfterQuotaReset()
        await coordinator.resumeAfterSystemWake()
        try await expectMetrics(provider, starts: 1, reads: 1, stops: 1)

        await clock.advance(by: .seconds(1))
        await drainExecutor()
        try await expectMetrics(provider, starts: 1, reads: 1, stops: 1)
        await clock.advance(by: .seconds(15))
        try await expectMetrics(provider, starts: 2, reads: 2, stops: 1)
        let request = await coordinator.state.inFlightRequest
        try expect(request?.reason == .quotaReset, "Expected reset to win after resume delay and completion floor")

        await gate.release()
        try await expectMetrics(provider, starts: 2, reads: 2, stops: 2)
        let resumedState = await coordinator.state
        try expect(resumedState.burstDeadline == nil, "Expected reset baseline without burst")
        await coordinator.stop()
    }
}

private func stoppedCoordinatorClearsPendingResumeResetTest() -> TestCase {
    TestCase(name: "explicit stop clears a pending system-resume reset") {
        let gate = TestReadGate()
        let clock = TestRefreshClock()
        let provider = TestRefreshSessionProvider(plans: [
            [.success(coordinatorResult(codexUsed: 90))],
            [.gated(gate, coordinatorResult(codexUsed: 25))]
        ])
        let coordinator = makeCoordinator(clock: clock, provider: provider)

        await coordinator.start()
        try await expectMetrics(provider, starts: 1, reads: 1, stops: 1)
        await coordinator.suspend()
        await coordinator.refreshAfterQuotaReset()
        await coordinator.stop()
        await coordinator.start()
        try await expectMetrics(provider, starts: 2, reads: 2, stops: 1)

        let request = await coordinator.state.inFlightRequest
        try expect(request?.reason == .startup, "Expected fresh startup rather than stale reset")
        await gate.release()
        try await expectMetrics(provider, starts: 2, reads: 2, stops: 2)
        await coordinator.stop()
    }
}

private func lowPowerCoordinatorSchedulingTest() -> TestCase {
    TestCase(name: "coordinator applies low-power clamping to its monotonic timer") {
        let clock = TestRefreshClock()
        let provider = TestRefreshSessionProvider(plans: [
            [.success(coordinatorResult(codexUsed: 10))],
            [.success(coordinatorResult(codexUsed: 10))]
        ])
        let coordinator = makeCoordinator(clock: clock, provider: provider, profile: .fast)

        await coordinator.start()
        try await expectMetrics(provider, starts: 1, reads: 1, stops: 1)
        await coordinator.setLowPowerMode(true)
        await clock.advance(by: .seconds(60))
        await drainExecutor()
        try await expectMetrics(provider, starts: 1, reads: 1, stops: 1)

        await clock.advance(by: .seconds(540))
        try await expectMetrics(provider, starts: 2, reads: 2, stops: 2)
        await coordinator.stop()
    }
}

private func quotaResetTriggerTest() -> TestCase {
    TestCase(name: "quota reset seam coalesces one baseline refresh without burst") {
        let gate = TestReadGate()
        let clock = TestRefreshClock()
        let provider = TestRefreshSessionProvider(plans: [
            [.success(coordinatorResult(codexUsed: 90))],
            [.gated(gate, coordinatorResult(codexUsed: 5))]
        ])
        let coordinator = makeCoordinator(clock: clock, provider: provider)

        await coordinator.start()
        try await expectMetrics(provider, starts: 1, reads: 1, stops: 1)
        await coordinator.refreshAfterQuotaReset()
        await coordinator.refreshAfterQuotaReset()
        try await expectMetrics(provider, starts: 1, reads: 1, stops: 1)
        await clock.advance(by: .seconds(20))
        try await expectMetrics(provider, starts: 2, reads: 2, stops: 1)
        let request = await coordinator.state.inFlightRequest
        try expect(request?.reason == .quotaReset, "Expected quota-reset baseline reason")

        await gate.release()
        try await expectMetrics(provider, starts: 2, reads: 2, stops: 2)
        try await eventually { await coordinator.state.inFlightRequest == nil }
        let state = await coordinator.state
        try expect(state.burstDeadline == nil, "Expected reset baseline not to start burst")
        await coordinator.stop()
    }
}

private func quotaResetUpgradesInFlightRequestTest() -> TestCase {
    TestCase(name: "quota reset upgrades a normal request and wins over wake baseline") {
        let gate = TestReadGate()
        let clock = TestRefreshClock()
        let provider = TestRefreshSessionProvider(plans: [
            [.success(coordinatorResult(codexUsed: 10))],
            [.gated(gate, coordinatorResult(codexUsed: 80))]
        ])
        let coordinator = makeCoordinator(clock: clock, provider: provider)

        await coordinator.start()
        try await expectMetrics(provider, starts: 1, reads: 1, stops: 1)
        await clock.advance(by: .seconds(180))
        try await expectMetrics(provider, starts: 2, reads: 2, stops: 1)
        let normalRequest = await coordinator.state.inFlightRequest
        try expect(normalRequest?.reason == .normal, "Expected gated normal request")

        await coordinator.refreshAfterQuotaReset()
        let resetRequest = await coordinator.state.inFlightRequest
        try expect(resetRequest?.reason == .quotaReset, "Expected reset reason upgrade")
        await coordinator.establishWakeBaseline()
        let resetAfterWake = await coordinator.state.inFlightRequest
        try expect(resetAfterWake?.reason == .quotaReset, "Expected reset precedence over wake")

        await gate.release()
        try await expectMetrics(provider, starts: 2, reads: 2, stops: 2)
        try await eventually { await coordinator.state.inFlightRequest == nil }
        let completedState = await coordinator.state
        try expect(completedState.burstDeadline == nil, "Expected baseline-only reset success")
        await coordinator.stop()
    }
}

private func refreshPublicationPartialProductTest() -> TestCase {
    TestCase(name: "refresh publication preserves Codex partial stale and unavailable states") {
        let clock = TestRefreshClock()
        let completeDate = Date(timeIntervalSince1970: 1_900_000_000)
        let partialDate = Date(timeIntervalSince1970: 1_900_000_100)
        let malformedDate = Date(timeIntervalSince1970: 1_900_000_200)
        let emptyDate = Date(timeIntervalSince1970: 1_900_000_300)
        let complete = coordinatorResult(codexUsed: 10, capturedAt: completeDate)
        let partial = coordinatorResult(
            codexWindows: [coordinatorWindow(.primary, used: 10, duration: 300, reset: 1_000)],
            codexState: .partial,
            capturedAt: partialDate
        )
        let malformed = coordinatorResult(codexWindows: [], codexState: .malformed, capturedAt: malformedDate)
        let empty = coordinatorResult(codexWindows: [], codexState: .unavailable, capturedAt: emptyDate)
        let provider = TestRefreshSessionProvider(plans: [
            [.success(complete)], [.success(partial)], [.success(malformed)], [.success(empty)]
        ])
        let coordinator = makeCoordinator(clock: clock, provider: provider)

        await coordinator.start()
        try await expectMetrics(provider, starts: 1, reads: 1, stops: 1)
        await coordinator.refreshManually()
        try await expectMetrics(provider, starts: 2, reads: 2, stops: 2)
        try await eventually { await coordinator.state.inFlightRequest == nil }
        let publication = await coordinator.publication
        try expect(coordinatorFreshness(publication, product: .codex) == .fresh, "Expected fresh partial Codex")
        try expect(publication.products[.codex]?.issue == .partial, "Expected explicit partial issue")
        try expect(publication.products[.codex]?.lastSuccessfulRefresh == partialDate, "Expected valid partial response to advance success time")
        try expect(publication.lastSuccessfulRefresh == partialDate, "Expected global partial success")

        await coordinator.refreshManually()
        try await expectMetrics(provider, starts: 3, reads: 3, stops: 3)
        try await eventually { await coordinator.state.inFlightRequest == nil }
        let stalePublication = await coordinator.publication
        try expect(coordinatorFreshness(stalePublication, product: .codex) == .stale, "Expected malformed response to retain a stale value")
        try expect(coordinatorUsedPercent(stalePublication, product: .codex) == 10, "Expected last valid Codex value")
        try expect(stalePublication.products[.codex]?.issue == .malformed, "Expected malformed issue beside stale value")
        try expect(stalePublication.products[.codex]?.lastSuccessfulRefresh == partialDate, "Expected malformed response to preserve success time")
        try expect(stalePublication.lastSuccessfulRefresh == partialDate, "Expected malformed response not to advance global success")
        try expect(stalePublication.lastAcceptedRateLimitResponse == malformedDate, "Expected accepted malformed envelope time")

        await coordinator.refreshManually()
        try await expectMetrics(provider, starts: 4, reads: 4, stops: 4)
        try await eventually { await coordinator.state.inFlightRequest == nil }
        let emptyPublication = await coordinator.publication
        try expect(emptyPublication.lastSuccessfulRefresh == partialDate, "Expected empty response not to advance global success")
        try expect(emptyPublication.lastAcceptedRateLimitResponse == emptyDate, "Expected empty response to record its protocol exchange")
        try expect(emptyPublication.products[.codex]?.lastSuccessfulRefresh == partialDate, "Expected unavailable response to retain success time")
        try expect(emptyPublication.products[.codex]?.usageState == .unavailable, "Expected accepted unavailable Codex to clear its displayed value")
        try expect(emptyPublication.products[.codex]?.issue == .unavailable, "Expected accepted unavailable issue")
        await coordinator.stop()
    }
}

private func refreshPublicationMalformedWithoutPriorTest() -> TestCase {
    TestCase(name: "refresh publication exposes malformed empty product without a prior value") {
        let clock = TestRefreshClock()
        let capturedAt = Date(timeIntervalSince1970: 1_900_000_300)
        let result = coordinatorResult(
            codexWindows: [],
            codexState: .malformed,
            capturedAt: capturedAt
        )
        let provider = TestRefreshSessionProvider(plans: [[.success(result)]])
        let coordinator = makeCoordinator(clock: clock, provider: provider)

        await coordinator.start()
        try await expectMetrics(provider, starts: 1, reads: 1, stops: 1)
        try await eventually { await coordinator.state.inFlightRequest == nil }

        let publication = await coordinator.publication
        try expect(
            publication.products[.codex]?.usageState == .unavailable,
            "Expected no invented stale value without a prior success"
        )
        try expect(
            publication.products[.codex]?.issue == .malformed,
            "Expected malformed issue to remain explicit"
        )
        try expect(
            publication.products[.codex]?.lastSuccessfulRefresh == nil,
            "Expected no product success time without a valid window"
        )
        try expect(
            publication.lastAcceptedRateLimitResponse == capturedAt,
            "Expected accepted outer response time"
        )
        await coordinator.stop()
    }
}

private func incompatibleRateLimitResponseStopsPollingTest() -> TestCase {
    TestCase(name: "incompatible rate-limit envelope stops automatic polling") {
        let clock = TestRefreshClock()
        let result = coordinatorResult(
            codexWindows: [],
            responseStatus: .incompatible
        )
        let provider = TestRefreshSessionProvider(plans: [[.success(result)]])
        let coordinator = makeCoordinator(clock: clock, provider: provider)

        await coordinator.start()
        try await expectMetrics(provider, starts: 1, reads: 1, stops: 1)
        try await eventually { await coordinator.state.inFlightRequest == nil }

        let publication = await coordinator.publication
        let finalState = await coordinator.state
        try expect(
            publication.failure == .protocolIncompatible,
            "Expected a typed protocol failure"
        )
        try expect(
            finalState.scheduledRefresh == nil,
            "Expected no automatic retry"
        )
        try expect(
            publication.lastAcceptedRateLimitResponse == nil,
            "Expected incompatible data not to count as accepted"
        )
        await coordinator.stop()
    }
}

private func makeCoordinator(
    clock: TestRefreshClock,
    provider: any RefreshSessionProviding,
    preference: DisplayPreference = .default,
    profile: RefreshProfile = .balanced,
    recorder: RefreshPublicationRecorder? = nil
) -> RefreshCoordinator {
    let callback: RefreshPublicationHandler?
    if let recorder {
        callback = { publication in
            recorder.record(publication)
        }
    } else {
        callback = nil
    }
    return RefreshCoordinator(
        provider: provider,
        clock: clock,
        profile: profile,
        displayPreference: preference,
        publicationHandler: callback
    )
}

private func expectMetrics(
    _ provider: TestRefreshSessionProvider,
    starts: Int,
    reads: Int,
    stops: Int
) async throws {
    try await eventually {
        let metrics = await provider.metrics()
        return metrics.starts == starts && metrics.reads == reads && metrics.stops == stops
    }
}

private func requireBurstDeadline(
    _ coordinator: RefreshCoordinator
) async throws -> ContinuousClock.Instant {
    guard let deadline = await coordinator.state.burstDeadline else {
        throw TestFailure(description: "Expected an active burst deadline")
    }
    return deadline
}

private func coordinatorUsedPercent(
    _ publication: RefreshPublication,
    product: UsageProduct
) -> Int? {
    guard case let .value(value, _) = publication.products[product]?.usageState else {
        return nil
    }
    return value.quotaWindows.first?.comparisonUsedPercent
}

private func coordinatorFreshness(
    _ publication: RefreshPublication,
    product: UsageProduct
) -> ProductValueFreshness? {
    guard case let .value(_, freshness) = publication.products[product]?.usageState else {
        return nil
    }
    return freshness
}

private func coordinatorResult(
    codexUsed: Double,
    capturedAt: Date = Date(timeIntervalSince1970: 1_900_000_000)
) -> RateLimitReadResult {
    coordinatorResult(
        codexWindows: [coordinatorWindow(.primary, used: codexUsed, duration: 300, reset: 1_000)],
        capturedAt: capturedAt
    )
}

private func coordinatorResult(
    codexWindows: [QuotaWindow],
    codexState: ProductRateLimitState? = nil,
    capturedAt: Date = Date(timeIntervalSince1970: 1_900_000_000),
    responseStatus: RateLimitResponseStatus = .accepted
) -> RateLimitReadResult {
    let inferredCodexState: ProductRateLimitState = codexWindows.isEmpty ? .unavailable : .available
    return RateLimitReadResult(
        capturedAt: capturedAt,
        responseStatus: responseStatus,
        rateLimitsByProduct: [
            .codex: ProductRateLimits(state: codexState ?? inferredCodexState, windows: codexWindows)
        ]
    )
}

private func coordinatorWindow(
    _ slot: QuotaSlot,
    used: Double,
    duration: Int,
    reset: TimeInterval
) -> QuotaWindow {
    guard let window = QuotaWindow(
        slot: slot,
        usedPercent: used,
        windowDurationMinutes: duration,
        resetUnixSeconds: reset
    ) else {
        preconditionFailure("Synthetic quota window must be valid")
    }
    return window
}

private func coordinatorKey(
    _ product: UsageProduct,
    duration: Int,
    reset: TimeInterval
) -> RefreshQuotaKey {
    RefreshQuotaKey(
        product: product,
        rawDurationMinutes: duration,
        resetsAt: Date(timeIntervalSince1970: reset)
    )
}

private func eventually(
    _ condition: () async -> Bool
) async throws {
    for _ in 0..<2_000 {
        if await condition() {
            return
        }
        await Task.yield()
    }
    throw TestFailure(description: "Expected asynchronous condition")
}

private func drainExecutor() async {
    for _ in 0..<50 {
        await Task.yield()
    }
}

@MainActor
private final class RefreshPublicationRecorder {
    private(set) var values = [RefreshPublication]()

    func record(_ publication: RefreshPublication) {
        values.append(publication)
    }
}

private actor TestRefreshClock: RefreshClock {
    private struct Sleeper {
        let deadline: ContinuousClock.Instant
        let continuation: CheckedContinuation<Void, any Error>
    }

    private var instant = ContinuousClock().now
    private var date = Date(timeIntervalSince1970: 1_900_000_000)
    private var nextIdentifier: UInt64 = 0
    private var sleepers = [UInt64: Sleeper]()
    private var cancelledSleepers = Set<UInt64>()

    func now() -> ContinuousClock.Instant {
        instant
    }

    func currentDate() -> Date {
        date
    }

    func sleep(until deadline: ContinuousClock.Instant) async throws {
        try Task.checkCancellation()
        if instant >= deadline {
            return
        }
        nextIdentifier += 1
        let identifier = nextIdentifier
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation {
                (continuation: CheckedContinuation<Void, any Error>) in
                guard cancelledSleepers.remove(identifier) == nil else {
                    continuation.resume(throwing: CancellationError())
                    return
                }
                sleepers[identifier] = Sleeper(
                    deadline: deadline,
                    continuation: continuation
                )
            }
        } onCancel: {
            Task { await self.cancelSleeper(identifier) }
        }
    }

    func advance(by duration: Duration) {
        instant = instant.advanced(by: duration)
        date = date.addingTimeInterval(durationSeconds(duration))
        resumeReadySleepers()
    }

    func pendingSleeperCount() -> Int {
        sleepers.count
    }

    private func cancelSleeper(_ identifier: UInt64) {
        guard let sleeper = sleepers.removeValue(forKey: identifier) else {
            cancelledSleepers.insert(identifier)
            return
        }
        sleeper.continuation.resume(throwing: CancellationError())
    }

    private func resumeReadySleepers() {
        let ready = sleepers.filter { $0.value.deadline <= instant }
        for (identifier, sleeper) in ready {
            sleepers.removeValue(forKey: identifier)
            sleeper.continuation.resume()
        }
    }

    private func durationSeconds(_ duration: Duration) -> TimeInterval {
        let components = duration.components
        let seconds = Double(components.seconds)
        let fraction = Double(components.attoseconds) / 1_000_000_000_000_000_000
        return seconds + fraction
    }
}

private actor TestReadGate {
    private var continuations = [CheckedContinuation<Void, Never>]()
    private var isReleased = false

    func wait() async {
        guard isReleased == false else {
            return
        }
        await withCheckedContinuation { continuation in
            continuations.append(continuation)
        }
    }

    func release() {
        isReleased = true
        let pending = continuations
        continuations.removeAll()
        pending.forEach { $0.resume() }
    }
}

private enum TestReadOutcome: Sendable {
    case success(RateLimitReadResult)
    case failure(UsageSessionError)
    case gated(TestReadGate, RateLimitReadResult)
}

private struct MissingExecutableSessionProvider: RefreshSessionProviding, Sendable {
    func makeSession() async throws -> any RefreshUsageSession {
        throw CodexLocationError.notFound
    }
}

private struct TestSessionMetrics: Sendable {
    let created: Int
    let starts: Int
    let reads: Int
    let stops: Int
    let stopAttempts: Int
    let maximumLiveSessions: Int
}

private actor TestRefreshSessionProvider: RefreshSessionProviding {
    private var plans: [[TestReadOutcome]]
    private var created = 0
    private var starts = 0
    private var reads = 0
    private var stops = 0
    private var stoppedIdentifiers = Set<Int>()
    private var liveIdentifiers = Set<Int>()
    private var stopAttempts = 0
    private var maximumLiveSessions = 0
    private let stopGates: [Int: TestReadGate]
    private let exitGates: [Int: TestReadGate]
    private let factoryGate: TestReadGate?
    private let factoryGates: [Int: TestReadGate]

    init(plans: [[TestReadOutcome]], stopGates: [Int: TestReadGate] = [:], exitGates: [Int: TestReadGate] = [:], factoryGate: TestReadGate? = nil, factoryGates: [Int: TestReadGate] = [:]) {
        self.plans = plans
        self.stopGates = stopGates
        self.exitGates = exitGates
        self.factoryGate = factoryGate
        self.factoryGates = factoryGates
    }

    func makeSession() async throws -> any RefreshUsageSession {
        guard plans.isEmpty == false else {
            throw UsageSessionError.launchFailed
        }
        created += 1
        let identifier = created
        let plan = plans.removeFirst()
        if identifier == 1 { await factoryGate?.wait() }
        await factoryGates[identifier]?.wait()
        return TestRefreshUsageSession(identifier: identifier, outcomes: plan, provider: self)
    }

    func recordStart(identifier: Int) {
        starts += 1
        liveIdentifiers.insert(identifier)
        maximumLiveSessions = max(maximumLiveSessions, liveIdentifiers.count)
    }

    func stopSession(identifier: Int) async -> UsageSessionStopResult {
        stopAttempts += 1
        await stopGates[identifier]?.wait()
        if exitGates[identifier] != nil { return .unconfirmed }
        recordStop(identifier: identifier)
        return .exited
    }

    func waitForTermination(identifier: Int) async {
        await exitGates[identifier]?.wait()
        recordStop(identifier: identifier)
    }

    func recordRead() {
        reads += 1
    }

    func recordStop(identifier: Int) {
        guard stoppedIdentifiers.insert(identifier).inserted else {
            return
        }
        stops += 1
        liveIdentifiers.remove(identifier)
    }

    func metrics() -> TestSessionMetrics {
        TestSessionMetrics(created: created, starts: starts, reads: reads, stops: stops, stopAttempts: stopAttempts, maximumLiveSessions: maximumLiveSessions)
    }
}

private actor TestRefreshUsageSession: RefreshUsageSession {
    private let identifier: Int
    private var outcomes: [TestReadOutcome]
    private let provider: TestRefreshSessionProvider

    init(
        identifier: Int,
        outcomes: [TestReadOutcome],
        provider: TestRefreshSessionProvider
    ) {
        self.identifier = identifier
        self.outcomes = outcomes
        self.provider = provider
    }

    func start() async throws {
        await provider.recordStart(identifier: identifier)
    }

    func readRateLimits(capturedAt: Date) async throws -> RateLimitReadResult {
        _ = capturedAt
        await provider.recordRead()
        guard outcomes.isEmpty == false else {
            throw UsageSessionError.endOfFile
        }
        let outcome = outcomes.removeFirst()
        return try await resolve(outcome)
    }

    func stop() async -> UsageSessionStopResult {
        await provider.stopSession(identifier: identifier)
    }

    func waitForTermination() async {
        await provider.waitForTermination(identifier: identifier)
    }

    private func resolve(_ outcome: TestReadOutcome) async throws -> RateLimitReadResult {
        switch outcome {
        case let .success(result):
            return result
        case let .failure(error):
            throw error
        case let .gated(gate, result):
            await gate.wait()
            return result
        }
    }
}
