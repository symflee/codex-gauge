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
        refreshPublicationPartialProductTest(),
        refreshCoordinatorValuesAreSendableTest()
    ]
}

private func selectedQuotaSampleMappingTest() -> TestCase {
    TestCase(name: "refresh sample mapping follows the injected display preference") {
        let result = coordinatorResult(
            codexWindows: [
                coordinatorWindow(.primary, used: 10.9, duration: 300, reset: 1_000),
                coordinatorWindow(.secondary, used: 20.4, duration: 10_080, reset: 2_000)
            ],
            sparkWindows: [coordinatorWindow(.primary, used: 30.8, duration: 300, reset: 3_000)]
        )
        let preference = DisplayPreference(
            productMode: .both,
            quotaSelection: .manual([
                QuotaSelectionID(product: .codex, rawDurationMinutes: 10_080),
                QuotaSelectionID(product: .spark, rawDurationMinutes: 300)
            ])
        )

        let samples = DisplayPreferenceQuotaSampleSelector().samples(
            from: result,
            preference: preference
        )

        try expect(samples.values.count == 2, "Expected two manually selected samples")
        try expect(
            samples.values[coordinatorKey(.codex, duration: 10_080, reset: 2_000)] == 20,
            "Expected floored Codex weekly sample"
        )
        try expect(
            samples.values[coordinatorKey(.spark, duration: 300, reset: 3_000)] == 30,
            "Expected floored Spark five-hour sample"
        )
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
        await coordinator.stop()
        let stoppedState = await coordinator.state
        try expect(stoppedState.scheduledRefresh == nil, "Expected timer state cleanup")
        await clock.advance(by: .seconds(180))
        await drainExecutor()
        try await expectMetrics(provider, starts: 2, reads: 2, stops: 2)
    }
}

private func burstSessionReuseAndExtensionTest() -> TestCase {
    TestCase(name: "burst reuses one session and an increase extends its deadline") {
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
        try await eventually {
            guard let deadline = await coordinator.state.burstDeadline else {
                return false
            }
            return deadline > firstDeadline
        }
        let extendedDeadline = try await requireBurstDeadline(coordinator)
        try expect(extendedDeadline > firstDeadline, "Expected a five-minute extension")

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
    TestCase(name: "system resume coalesces and performs one wake baseline after five seconds") {
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
        try await eventually { await clock.pendingSleeperCount() == 1 }

        await clock.advance(by: .seconds(4))
        await drainExecutor()
        try await expectMetrics(provider, starts: 1, reads: 1, stops: 1)

        await clock.advance(by: .seconds(1))
        try await expectMetrics(provider, starts: 2, reads: 2, stops: 1)
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
        try await expectMetrics(provider, starts: 2, reads: 2, stops: 1)
        let request = await coordinator.state.inFlightRequest
        try expect(request?.reason == .quotaReset, "Expected reset to win at original deadline")

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
    TestCase(name: "refresh publication updates products independently and keeps stale values") {
        let clock = TestRefreshClock()
        let completeDate = Date(timeIntervalSince1970: 1_900_000_000)
        let partialDate = Date(timeIntervalSince1970: 1_900_000_100)
        let emptyDate = Date(timeIntervalSince1970: 1_900_000_200)
        let complete = coordinatorResult(
            codexUsed: 10,
            sparkUsed: 20,
            capturedAt: completeDate
        )
        let partial = coordinatorResult(
            codexWindows: [coordinatorWindow(.primary, used: 11, duration: 300, reset: 1_000)],
            sparkState: .malformed,
            sparkWindows: [],
            capturedAt: partialDate
        )
        let empty = coordinatorResult(
            codexWindows: [],
            sparkState: .malformed,
            sparkWindows: [],
            capturedAt: emptyDate
        )
        let provider = TestRefreshSessionProvider(plans: [
            [.success(complete)],
            [.success(partial), .success(empty)]
        ])
        let preference = DisplayPreference(productMode: .both, quotaSelection: .automatic)
        let coordinator = makeCoordinator(
            clock: clock,
            provider: provider,
            preference: preference
        )

        await coordinator.start()
        try await expectMetrics(provider, starts: 1, reads: 1, stops: 1)
        await coordinator.refreshManually()
        try await expectMetrics(provider, starts: 2, reads: 2, stops: 1)
        try await eventually {
            let publication = await coordinator.publication
            return coordinatorFreshness(publication, product: .spark) == .stale
        }

        let publication = await coordinator.publication
        try expect(coordinatorFreshness(publication, product: .codex) == .fresh, "Expected fresh Codex")
        try expect(coordinatorFreshness(publication, product: .spark) == .stale, "Expected stale Spark")
        try expect(publication.products[.spark]?.issue == .malformed, "Expected Spark issue")
        try expect(
            publication.products[.codex]?.lastSuccessfulRefresh == partialDate,
            "Expected Codex product success time to advance"
        )
        try expect(
            publication.products[.spark]?.lastSuccessfulRefresh == completeDate,
            "Expected Spark product success time to remain independent"
        )
        try expect(publication.lastSuccessfulRefresh == partialDate, "Expected global partial success")

        await coordinator.refreshManually()
        try await expectMetrics(provider, starts: 2, reads: 3, stops: 2)
        try await eventually { await coordinator.state.inFlightRequest == nil }
        let emptyPublication = await coordinator.publication
        try expect(
            emptyPublication.lastSuccessfulRefresh == partialDate,
            "Expected empty response not to advance global success"
        )
        try expect(
            emptyPublication.lastAcceptedRateLimitResponse == emptyDate,
            "Expected empty response to record a successful protocol exchange"
        )
        try expect(
            emptyPublication.products[.codex]?.lastSuccessfulRefresh == partialDate,
            "Expected empty Codex response to retain its success time"
        )
        try expect(
            emptyPublication.products[.spark]?.lastSuccessfulRefresh == completeDate,
            "Expected empty Spark response to retain its success time"
        )
        await coordinator.stop()
    }
}

private func incompatibleRateLimitResponseStopsPollingTest() -> TestCase {
    TestCase(name: "incompatible rate-limit envelope stops automatic polling") {
        let clock = TestRefreshClock()
        let result = coordinatorResult(
            codexWindows: [],
            sparkState: .malformed,
            sparkWindows: [],
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

private func refreshCoordinatorValuesAreSendableTest() -> TestCase {
    TestCase(name: "refresh coordinator boundary values are Sendable") {
        requireCoordinatorSendable(RefreshFailure.timeout)
        requireCoordinatorSendable(RefreshProductIssue.partial)
        requireCoordinatorSendable(RefreshPublication.initial)
        requireCoordinatorSendable(DisplayPreferenceQuotaSampleSelector())
        requireCoordinatorSendable(SystemRefreshClock())
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
    sparkUsed: Double? = nil,
    capturedAt: Date = Date(timeIntervalSince1970: 1_900_000_000)
) -> RateLimitReadResult {
    let codex = [coordinatorWindow(.primary, used: codexUsed, duration: 300, reset: 1_000)]
    let spark = sparkUsed.map {
        [coordinatorWindow(.primary, used: $0, duration: 300, reset: 2_000)]
    } ?? []
    return coordinatorResult(
        codexWindows: codex,
        sparkWindows: spark,
        capturedAt: capturedAt
    )
}

private func coordinatorResult(
    codexWindows: [QuotaWindow],
    sparkState: ProductRateLimitState? = nil,
    sparkWindows: [QuotaWindow],
    capturedAt: Date = Date(timeIntervalSince1970: 1_900_000_000),
    responseStatus: RateLimitResponseStatus = .accepted
) -> RateLimitReadResult {
    let inferredSparkState: ProductRateLimitState = sparkWindows.isEmpty ? .unavailable : .available
    return RateLimitReadResult(
        capturedAt: capturedAt,
        responseStatus: responseStatus,
        rateLimitsByProduct: [
            .codex: ProductRateLimits(
                state: codexWindows.isEmpty ? .unavailable : .available,
                windows: codexWindows
            ),
            .spark: ProductRateLimits(
                state: sparkState ?? inferredSparkState,
                windows: sparkWindows
            )
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
}

private actor TestRefreshSessionProvider: RefreshSessionProviding {
    private var plans: [[TestReadOutcome]]
    private var created = 0
    private var starts = 0
    private var reads = 0
    private var stops = 0
    private var stoppedIdentifiers = Set<Int>()

    init(plans: [[TestReadOutcome]]) {
        self.plans = plans
    }

    func makeSession() throws -> any RefreshUsageSession {
        guard plans.isEmpty == false else {
            throw UsageSessionError.launchFailed
        }
        created += 1
        let plan = plans.removeFirst()
        return TestRefreshUsageSession(identifier: created, outcomes: plan, provider: self)
    }

    func recordStart() {
        starts += 1
    }

    func recordRead() {
        reads += 1
    }

    func recordStop(identifier: Int) {
        guard stoppedIdentifiers.insert(identifier).inserted else {
            return
        }
        stops += 1
    }

    func metrics() -> TestSessionMetrics {
        TestSessionMetrics(created: created, starts: starts, reads: reads, stops: stops)
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
        await provider.recordStart()
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

    func stop() async {
        await provider.recordStop(identifier: identifier)
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

private func requireCoordinatorSendable<Value: Sendable>(_ value: Value) {
    _ = value
}
