public struct RefreshReducer: Sendable {
    private static let burstDuration: Duration = .seconds(300)
    private static let backoffIntervals: [Duration] = [
        .seconds(30),
        .seconds(60),
        .seconds(120),
        .seconds(240),
        .seconds(480),
        .seconds(960),
        .seconds(1_800)
    ]

    public init() {}

    public func reduce(
        state originalState: RefreshState,
        event: RefreshEvent
    ) -> RefreshTransition {
        var state = originalState
        var commands = [RefreshCommand]()
        handle(event, state: &state, commands: &commands)
        return RefreshTransition(state: state, commands: commands)
    }

    private func handle(
        _ event: RefreshEvent,
        state: inout RefreshState,
        commands: inout [RefreshCommand]
    ) {
        switch event {
        case .start:
            start(state: &state, commands: &commands)
        case .manualRefresh(let now):
            request(.manual, at: now, state: &state, commands: &commands)
        case .wakeBaseline(let now):
            wake(at: now, state: &state, commands: &commands)
        case .scheduledRefreshFired(let generation, let now):
            fireSchedule(generation, at: now, state: &state, commands: &commands)
        case .lowPowerModeChanged(let isEnabled, let now):
            changeLowPowerMode(isEnabled, at: now, state: &state, commands: &commands)
        case .profileChanged(let profile, let now):
            changeProfile(profile, at: now, state: &state, commands: &commands)
        case .requestSucceeded(let generation, let samples, let now):
            succeed(generation, samples: samples, at: now, state: &state, commands: &commands)
        case .transientFailure(let generation, let now):
            fail(generation, at: now, state: &state, commands: &commands)
        case .stop:
            stop(state: &state, commands: &commands)
        }
    }

    private func changeLowPowerMode(
        _ isEnabled: Bool,
        at now: ContinuousClock.Instant,
        state: inout RefreshState,
        commands: inout [RefreshCommand]
    ) {
        guard state.lowPowerModeEnabled != isEnabled else {
            return
        }
        state.lowPowerModeEnabled = isEnabled
        guard state.isRunning, state.inFlightRequest == nil else {
            return
        }
        guard state.scheduledRefresh?.reason != .retry else {
            return
        }
        expireBurst(at: now, state: &state)
        scheduleNext(at: now, state: &state, commands: &commands)
    }

    private func changeProfile(
        _ profile: RefreshProfile,
        at now: ContinuousClock.Instant,
        state: inout RefreshState,
        commands: inout [RefreshCommand]
    ) {
        guard state.profile != profile else {
            return
        }
        state.profile = profile
        guard profile != .manual else {
            enterManual(state: &state, commands: &commands)
            return
        }
        guard state.isRunning, state.inFlightRequest == nil else {
            return
        }
        guard state.scheduledRefresh?.reason != .retry else {
            return
        }
        expireBurst(at: now, state: &state)
        scheduleNext(at: now, state: &state, commands: &commands)
    }

    private func enterManual(
        state: inout RefreshState,
        commands: inout [RefreshCommand]
    ) {
        cancelSchedule(state: &state, commands: &commands)
        if let request = state.inFlightRequest {
            commands.append(.cancelRequest(generation: request.generation))
        }
        state.inFlightRequest = nil
        state.burstDeadline = nil
        state.consecutiveTransientFailures = 0
    }

    private func start(
        state: inout RefreshState,
        commands: inout [RefreshCommand]
    ) {
        guard !state.isRunning else {
            return
        }
        state.isRunning = true
        state.baseline = nil
        state.burstDeadline = nil
        state.consecutiveTransientFailures = 0
        beginRequest(.startup, state: &state, commands: &commands)
    }

    private func wake(
        at now: ContinuousClock.Instant,
        state: inout RefreshState,
        commands: inout [RefreshCommand]
    ) {
        guard state.profile != .manual else {
            return
        }
        request(.wakeBaseline, at: now, state: &state, commands: &commands)
    }

    private func request(
        _ reason: RefreshRequestReason,
        at now: ContinuousClock.Instant,
        state: inout RefreshState,
        commands: inout [RefreshCommand]
    ) {
        guard state.isRunning else {
            return
        }
        expireBurst(at: now, state: &state)
        beginRequest(reason, state: &state, commands: &commands)
    }

    private func beginRequest(
        _ reason: RefreshRequestReason,
        state: inout RefreshState,
        commands: inout [RefreshCommand]
    ) {
        guard state.inFlightRequest == nil else {
            coalesce(reason, state: &state)
            return
        }
        cancelSchedule(state: &state, commands: &commands)
        state.nextRequestGeneration += 1
        let request = RefreshRequest(
            generation: state.nextRequestGeneration,
            reason: reason
        )
        state.inFlightRequest = request
        commands.append(.startRequest(request))
    }

    private func coalesce(
        _ reason: RefreshRequestReason,
        state: inout RefreshState
    ) {
        guard reason == .wakeBaseline, let current = state.inFlightRequest else {
            return
        }
        state.inFlightRequest = RefreshRequest(
            generation: current.generation,
            reason: .wakeBaseline
        )
    }

    private func fireSchedule(
        _ generation: UInt64,
        at now: ContinuousClock.Instant,
        state: inout RefreshState,
        commands: inout [RefreshCommand]
    ) {
        guard state.isRunning, let schedule = state.scheduledRefresh else {
            return
        }
        guard schedule.generation == generation else {
            return
        }
        state.scheduledRefresh = nil
        expireBurst(at: now, state: &state)
        guard schedule.reason != .burst || state.burstDeadline != nil else {
            scheduleNext(at: now, state: &state, commands: &commands)
            return
        }
        beginRequest(
            requestReason(for: schedule.reason),
            state: &state,
            commands: &commands
        )
    }

    private func requestReason(
        for scheduleReason: RefreshScheduleReason
    ) -> RefreshRequestReason {
        switch scheduleReason {
        case .normal:
            .normal
        case .burst:
            .burst
        case .retry:
            .retry
        }
    }

    private func succeed(
        _ generation: UInt64,
        samples: SelectedQuotaSamples,
        at now: ContinuousClock.Instant,
        state: inout RefreshState,
        commands: inout [RefreshCommand]
    ) {
        guard state.isRunning, let request = state.inFlightRequest else {
            return
        }
        guard request.generation == generation else {
            return
        }
        state.inFlightRequest = nil
        state.consecutiveTransientFailures = 0
        expireBurst(at: now, state: &state)
        applySuccess(samples, reason: request.reason, at: now, state: &state)
        scheduleNext(at: now, state: &state, commands: &commands)
    }

    private func applySuccess(
        _ samples: SelectedQuotaSamples,
        reason: RefreshRequestReason,
        at now: ContinuousClock.Instant,
        state: inout RefreshState
    ) {
        guard !reason.establishesBaseline else {
            state.baseline = samples
            state.burstDeadline = nil
            return
        }
        guard let baseline = state.baseline else {
            state.baseline = samples
            state.burstDeadline = nil
            return
        }
        let change = sampleChange(from: baseline, to: samples)
        state.baseline = samples
        apply(change, at: now, state: &state)
    }

    private func apply(
        _ change: SampleChange,
        at now: ContinuousClock.Instant,
        state: inout RefreshState
    ) {
        guard state.profile.intervals.burst != nil else {
            state.burstDeadline = nil
            return
        }
        switch change {
        case .increased:
            state.burstDeadline = now.advanced(by: Self.burstDuration)
        case .baselineChanged:
            state.burstDeadline = nil
        case .unchanged:
            return
        }
    }

    private func sampleChange(
        from baseline: SelectedQuotaSamples,
        to samples: SelectedQuotaSamples
    ) -> SampleChange {
        var baselineChanged = Set(baseline.values.keys) != Set(samples.values.keys)
        var increased = false
        for (key, usedPercent) in samples.values {
            guard let priorUsedPercent = baseline.values[key] else {
                continue
            }
            increased = increased || usedPercent > priorUsedPercent
            baselineChanged = baselineChanged || usedPercent < priorUsedPercent
        }
        if increased {
            return .increased
        }
        if baselineChanged {
            return .baselineChanged
        }
        return .unchanged
    }

    private func fail(
        _ generation: UInt64,
        at now: ContinuousClock.Instant,
        state: inout RefreshState,
        commands: inout [RefreshCommand]
    ) {
        guard state.isRunning, state.inFlightRequest?.generation == generation else {
            return
        }
        state.inFlightRequest = nil
        expireBurst(at: now, state: &state)
        incrementFailureCount(state: &state)
        if state.burstDeadline != nil, state.consecutiveTransientFailures >= 3 {
            state.burstDeadline = nil
        }
        guard state.profile != .manual else {
            return
        }
        scheduleRetry(at: now, state: &state, commands: &commands)
    }

    private func incrementFailureCount(state: inout RefreshState) {
        let maximumCount = Self.backoffIntervals.count
        state.consecutiveTransientFailures = min(
            state.consecutiveTransientFailures + 1,
            maximumCount
        )
    }

    private func scheduleRetry(
        at now: ContinuousClock.Instant,
        state: inout RefreshState,
        commands: inout [RefreshCommand]
    ) {
        let index = max(state.consecutiveTransientFailures - 1, 0)
        let delay = Self.backoffIntervals[index]
        schedule(
            deadline: now.advanced(by: delay),
            reason: .retry,
            state: &state,
            commands: &commands
        )
    }

    private func scheduleNext(
        at now: ContinuousClock.Instant,
        state: inout RefreshState,
        commands: inout [RefreshCommand]
    ) {
        let intervals = state.profile.effectiveIntervals(
            lowPowerModeEnabled: state.lowPowerModeEnabled
        )
        if let burstDeadline = state.burstDeadline, let interval = intervals.burst {
            let proposed = now.advanced(by: interval)
            let deadline = min(proposed, burstDeadline)
            schedule(
                deadline: deadline,
                reason: .burst,
                state: &state,
                commands: &commands
            )
            return
        }
        guard let interval = intervals.normal else {
            return
        }
        schedule(
            deadline: now.advanced(by: interval),
            reason: .normal,
            state: &state,
            commands: &commands
        )
    }

    private func schedule(
        deadline: ContinuousClock.Instant,
        reason: RefreshScheduleReason,
        state: inout RefreshState,
        commands: inout [RefreshCommand]
    ) {
        cancelSchedule(state: &state, commands: &commands)
        state.nextScheduleGeneration += 1
        let schedule = RefreshSchedule(
            generation: state.nextScheduleGeneration,
            deadline: deadline,
            reason: reason
        )
        state.scheduledRefresh = schedule
        commands.append(.scheduleRefresh(schedule))
    }

    private func cancelSchedule(
        state: inout RefreshState,
        commands: inout [RefreshCommand]
    ) {
        guard let schedule = state.scheduledRefresh else {
            return
        }
        state.scheduledRefresh = nil
        commands.append(.cancelScheduledRefresh(generation: schedule.generation))
    }

    private func expireBurst(
        at now: ContinuousClock.Instant,
        state: inout RefreshState
    ) {
        guard let deadline = state.burstDeadline, now >= deadline else {
            return
        }
        state.burstDeadline = nil
    }

    private func stop(
        state: inout RefreshState,
        commands: inout [RefreshCommand]
    ) {
        cancelSchedule(state: &state, commands: &commands)
        if let request = state.inFlightRequest {
            commands.append(.cancelRequest(generation: request.generation))
        }
        state.isRunning = false
        state.inFlightRequest = nil
        state.baseline = nil
        state.burstDeadline = nil
        state.consecutiveTransientFailures = 0
    }
}

private enum SampleChange {
    case increased
    case baselineChanged
    case unchanged
}
