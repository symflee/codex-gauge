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
        case .quotaReset(let now):
            quotaReset(at: now, state: &state, commands: &commands)
        case .resumeAfterSystemWake(let now):
            resumeAfterSystemWake(at: now, state: &state, commands: &commands)
        case .scheduledRefreshFired(let generation, let now):
            fireSchedule(generation, at: now, state: &state, commands: &commands)
        case .lowPowerModeChanged(let isEnabled, let now):
            changeLowPowerMode(isEnabled, at: now, state: &state, commands: &commands)
        case .profileChanged(let profile, let now):
            changeProfile(profile, at: now, state: &state, commands: &commands)
        case .requestAdmission(let generation, let now):
            admitRequest(generation, at: now, state: &state, commands: &commands)
        case .requestSucceeded(let generation, let samples, let now):
            succeed(generation, samples: samples, at: now, state: &state, commands: &commands)
        case .transientFailure(let generation, let now):
            fail(generation, at: now, state: &state, commands: &commands)
        case .terminalFailure(let generation, let now):
            failPermanently(generation, at: now, state: &state, commands: &commands)
        case .suspend(let now):
            suspend(at: now, state: &state, commands: &commands)
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
        expireBurst(at: now, state: &state, commands: &commands)
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
        if profile == .manual { endBurst(at: now, state: &state) }
        state.profile = profile
        guard profile != .manual else {
            enterManual(at: now, state: &state, commands: &commands)
            return
        }
        guard state.isRunning, state.inFlightRequest == nil else {
            return
        }
        guard state.scheduledRefresh?.reason != .retry else {
            return
        }
        expireBurst(at: now, state: &state, commands: &commands)
        scheduleNext(at: now, state: &state, commands: &commands)
    }

    private func enterManual(
        at now: ContinuousClock.Instant,
        state: inout RefreshState,
        commands: inout [RefreshCommand]
    ) {
        cancelSchedule(state: &state, commands: &commands)
        if let request = state.inFlightRequest {
            commands.append(.cancelRequest(generation: request.generation))
            state.lastRequestCompletedAt = now
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

    private func resumeAfterSystemWake(
        at now: ContinuousClock.Instant,
        state: inout RefreshState,
        commands: inout [RefreshCommand]
    ) {
        guard !state.isRunning else {
            wake(at: now, state: &state, commands: &commands)
            return
        }
        state.isRunning = true
        state.baseline = nil
        state.burstDeadline = nil
        guard state.profile != .manual else {
            return
        }
        request(.wakeBaseline, at: now, state: &state, commands: &commands)
    }

    private func quotaReset(
        at now: ContinuousClock.Instant,
        state: inout RefreshState,
        commands: inout [RefreshCommand]
    ) {
        guard state.profile != .manual else {
            return
        }
        request(.quotaReset, at: now, state: &state, commands: &commands)
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
        expireBurst(at: now, state: &state, commands: &commands)
        if state.inFlightRequest != nil {
            coalesce(reason, state: &state)
            return
        }
        if reason != .manual, let retry = state.retryNotBefore, retry > now {
            schedule(deadline: automaticDeadline(retry, state: state), reason: .retry, state: &state, commands: &commands)
            return
        }
        if reason != .manual, let floor = automaticFloor(state), floor > now {
            let scheduledReason: RefreshScheduleReason
            if reason == .quotaReset || state.scheduledRefresh?.reason == .quotaReset {
                scheduledReason = .quotaReset
            } else {
                scheduledReason = .wakeBaseline
            }
            schedule(deadline: floor, reason: scheduledReason, state: &state, commands: &commands)
            return
        }
        beginRequest(reason, state: &state, commands: &commands)
    }

    private func admitRequest(
        _ generation: UInt64,
        at now: ContinuousClock.Instant,
        state: inout RefreshState,
        commands: inout [RefreshCommand]
    ) {
        guard state.isRunning, state.inFlightRequest?.generation == generation else { return }
        expireBurst(at: now, state: &state, commands: &commands)
        guard let request = state.inFlightRequest else {
            scheduleNext(at: now, state: &state, commands: &commands)
            return
        }
        guard !request.isUserInitiated, request.reason != .startup else { return }
        let deadline = max(automaticFloor(state) ?? now, state.retryNotBefore ?? now)
        guard deadline > now else { return }
        // A request waiting for retirement or a factory result has not consumed
        // its policy admission yet. Recheck before launching under a new policy.
        state.inFlightRequest = nil
        let reason: RefreshScheduleReason
        if let retry = state.retryNotBefore, retry > now {
            reason = .retry
        } else {
            switch request.reason {
            case .normal: reason = .normal
            case .burst: reason = .burst
            case .retry: reason = .retry
            case .quotaReset: reason = .quotaReset
            case .wakeBaseline: reason = .wakeBaseline
            case .startup, .manual: return
            }
        }
        schedule(deadline: deadline, reason: reason, state: &state, commands: &commands)
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
        if let deadline = state.burstDeadline {
            schedule(deadline: deadline, reason: .burstExpiry, state: &state, commands: &commands)
        }
    }

    private func coalesce(
        _ reason: RefreshRequestReason,
        state: inout RefreshState
    ) {
        guard let current = state.inFlightRequest else {
            return
        }
        let isUserInitiated = current.isUserInitiated || reason == .manual
        let reason = coalescedReason(current: current.reason, incoming: reason)
        guard reason != current.reason || isUserInitiated != current.isUserInitiated else {
            return
        }
        state.inFlightRequest = RefreshRequest(
            generation: current.generation,
            reason: reason,
            isUserInitiated: isUserInitiated
        )
    }

    private func coalescedReason(
        current: RefreshRequestReason,
        incoming: RefreshRequestReason
    ) -> RefreshRequestReason {
        if current == .quotaReset || incoming == .quotaReset {
            return .quotaReset
        }
        if current == .wakeBaseline || incoming == .wakeBaseline {
            return .wakeBaseline
        }
        return current
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
        guard now >= schedule.deadline else { return }
        state.scheduledRefresh = nil
        let wasBurst = state.burstDeadline != nil
        expireBurst(at: now, state: &state, commands: &commands)
        if schedule.reason == .burstExpiry || (wasBurst && state.burstDeadline == nil) {
            scheduleNext(at: now, state: &state, commands: &commands)
            return
        }
        let reason: RefreshRequestReason
        switch schedule.reason {
        case .normal: reason = .normal
        case .burst: reason = .burst
        case .retry: reason = .retry
        case .wakeBaseline: reason = .wakeBaseline
        case .quotaReset: reason = .quotaReset
        case .burstExpiry: return
        }
        if let floor = automaticFloor(state), floor > now {
            self.schedule(deadline: floor, reason: schedule.reason, state: &state, commands: &commands)
            return
        }
        beginRequest(reason, state: &state, commands: &commands)
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
        if let deadline = state.burstDeadline, now >= deadline {
            expireBurst(at: now, state: &state, commands: &commands)
            scheduleNext(at: now, state: &state, commands: &commands)
            return
        }
        state.inFlightRequest = nil
        state.lastRequestCompletedAt = now
        state.retryNotBefore = nil
        state.consecutiveTransientFailures = 0
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
            endBurst(at: now, state: &state)
            return
        }
        guard let baseline = state.baseline else {
            state.baseline = samples
            state.burstDeadline = nil
            return
        }
        let change = sampleChange(from: baseline, to: samples)
        state.baseline = samples
        if state.requiresNormalBurstRearm {
            guard reason == .normal, state.burstCooldownDeadline.map({ now >= $0 }) ?? true else {
                return
            }
            state.requiresNormalBurstRearm = false
            state.burstCooldownDeadline = nil
        }
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
            if state.burstDeadline == nil {
                state.burstDeadline = now.advanced(by: Self.burstDuration)
            }
        case .baselineChanged:
            endBurst(at: now, state: &state)
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
        state.lastRequestCompletedAt = now
        endBurst(at: now, state: &state)
        cancelSchedule(state: &state, commands: &commands)
        incrementFailureCount(state: &state)
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

    private func failPermanently(
        _ generation: UInt64,
        at now: ContinuousClock.Instant?,
        state: inout RefreshState,
        commands: inout [RefreshCommand]
    ) {
        guard state.isRunning, state.inFlightRequest?.generation == generation else { return }
        if let now {
            state.lastRequestCompletedAt = now
            endBurst(at: now, state: &state)
        } else {
            state.burstDeadline = nil
        }
        cancelSchedule(state: &state, commands: &commands)
        state.inFlightRequest = nil
        state.baseline = nil
        state.retryNotBefore = nil
        state.consecutiveTransientFailures = 0
    }

    private func scheduleRetry(
        at now: ContinuousClock.Instant,
        state: inout RefreshState,
        commands: inout [RefreshCommand]
    ) {
        let index = max(state.consecutiveTransientFailures - 1, 0)
        let delay = Self.backoffIntervals[index]
        let deadline = automaticDeadline(now.advanced(by: delay), state: state)
        state.retryNotBefore = deadline
        schedule(
            deadline: deadline,
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
                reason: deadline == burstDeadline ? .burstExpiry : .burst,
                state: &state,
                commands: &commands
            )
            return
        }
        guard let interval = intervals.normal else {
            return
        }
        schedule(
            deadline: max(now.advanced(by: interval), state.burstCooldownDeadline ?? now),
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
        var deadline = deadline
        var reason = reason
        if let burstDeadline = state.burstDeadline, burstDeadline <= deadline {
            deadline = burstDeadline
            reason = .burstExpiry
        }
        if let current = state.scheduledRefresh, current.deadline == deadline, current.reason == reason {
            return
        }
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

    private func automaticFloor(_ state: RefreshState) -> ContinuousClock.Instant? {
        guard let completed = state.lastRequestCompletedAt,
              let interval = state.profile.effectiveIntervals(lowPowerModeEnabled: state.lowPowerModeEnabled).burst else {
            return nil
        }
        return completed.advanced(by: interval)
    }

    private func automaticDeadline(_ deadline: ContinuousClock.Instant, state: RefreshState) -> ContinuousClock.Instant {
        max(deadline, automaticFloor(state) ?? deadline)
    }

    private func endBurst(at now: ContinuousClock.Instant, state: inout RefreshState) {
        guard state.burstDeadline != nil else { return }
        state.burstDeadline = nil
        state.requiresNormalBurstRearm = true
        if let interval = state.profile.effectiveIntervals(lowPowerModeEnabled: state.lowPowerModeEnabled).normal {
            state.burstCooldownDeadline = now.advanced(by: interval)
        }
    }

    private func expireBurst(
        at now: ContinuousClock.Instant,
        state: inout RefreshState,
        commands: inout [RefreshCommand]
    ) {
        guard let deadline = state.burstDeadline, now >= deadline else { return }
        if let request = state.inFlightRequest {
            commands.append(.cancelRequest(generation: request.generation))
            state.inFlightRequest = nil
            state.lastRequestCompletedAt = now
        }
        endBurst(at: now, state: &state)
        cancelSchedule(state: &state, commands: &commands)
    }

    private func suspend(
        at now: ContinuousClock.Instant,
        state: inout RefreshState,
        commands: inout [RefreshCommand]
    ) {
        cancelSchedule(state: &state, commands: &commands)
        if let request = state.inFlightRequest {
            commands.append(.cancelRequest(generation: request.generation))
            state.lastRequestCompletedAt = now
        }
        endBurst(at: now, state: &state)
        state.isRunning = false
        state.inFlightRequest = nil
        state.baseline = nil
        // Sleeping must not reset a server failure's retry deadline or ladder.
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
