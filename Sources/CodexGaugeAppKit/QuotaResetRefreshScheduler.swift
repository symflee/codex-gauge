import CodexGaugeCore
import Foundation

public enum UsageDeadlineReason: Equatable, Hashable, Sendable {
    case quotaReset
    case validityExpired
}

@MainActor
public final class QuotaResetRefreshScheduler {
    public static let defaultTolerance: TimeInterval = 5
    public private(set) var scheduledDeadlineDate: Date?

    private let timerScheduler: WallClockOneShotScheduling
    private let now: @MainActor () -> Date
    private let notificationCenter: NotificationCenter
    private let handleDeadline: @MainActor (UsageDeadlineReason) -> Void
    private var clockChangeObservation: (any NSObjectProtocol)?
    private var latestDeadlines = Set<UsageDeadline>()
    private var handledDeadlines = Set<UsageDeadline>()
    private var nextTimerGeneration: UInt64 = 0
    private var activeTimerGeneration: UInt64?
    private var isSleeping = false
    private var isStopped = false

    public init(
        timerScheduler: WallClockOneShotScheduling = RunLoopWallClockOneShotScheduler(),
        now: @escaping @MainActor () -> Date = { Date() },
        notificationCenter: NotificationCenter = .default,
        handleDeadline: @escaping @MainActor (UsageDeadlineReason) -> Void
    ) {
        self.timerScheduler = timerScheduler
        self.now = now
        self.notificationCenter = notificationCenter
        self.handleDeadline = handleDeadline
        observeSystemClockChanges()
    }

    public func publish(productStates: [UsageProduct: ProductUsageState]) {
        guard !isStopped else {
            return
        }
        let deadlines = deadlines(in: productStates)
        let currentDate = now()
        // Only a reset observed in the future may later request a read. Repeated
        // responses containing alternating past reset dates cannot create work.
        let newlyObservedPastResets = deadlines.subtracting(latestDeadlines).filter {
            $0.reason == .quotaReset && $0.date <= currentDate
        }
        handledDeadlines.formIntersection(deadlines)
        handledDeadlines.formUnion(newlyObservedPastResets)
        latestDeadlines = deadlines
        reevaluate(forceReschedule: false)
    }

    public func systemDidSleep() {
        guard !isStopped, !isSleeping else {
            return
        }
        isSleeping = true
        cancelTimer()
    }

    public func systemDidWake() {
        guard !isStopped else {
            return
        }
        isSleeping = false
        reevaluate(forceReschedule: false)
    }

    public func stop() {
        guard !isStopped else {
            return
        }
        isStopped = true
        latestDeadlines.removeAll()
        handledDeadlines.removeAll()
        cancelTimer()
        removeClockChangeObservation()
    }

    private func observeSystemClockChanges() {
        let token = notificationCenter.addObserver(
            forName: .NSSystemClockDidChange,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.systemClockDidChange()
            }
        }
        clockChangeObservation = token
    }

    private func systemClockDidChange() {
        guard !isStopped else {
            return
        }
        reevaluate(forceReschedule: true)
    }

    private func reevaluate(forceReschedule: Bool) {
        guard !isStopped, !isSleeping else {
            return
        }
        let currentDate = now()
        let due = unhandledDueDeadlines(latestDeadlines, at: currentDate)
        handledDeadlines.formUnion(due)
        let futureDate = earliestUnhandledFutureDate(latestDeadlines, after: currentDate)
        updateTimer(deadline: futureDate, force: forceReschedule)
        deliver(due)
    }

    private func deadlines(
        in productStates: [UsageProduct: ProductUsageState]
    ) -> Set<UsageDeadline> {
        productStates.values.reduce(into: Set<UsageDeadline>()) { deadlines, state in
            addDeadlines(from: state, to: &deadlines)
        }
    }

    private func addDeadlines(
        from state: ProductUsageState,
        to deadlines: inout Set<UsageDeadline>
    ) {
        guard case .value(let value, _) = state, !value.quotaWindows.isEmpty else {
            return
        }
        value.quotaWindows.compactMap(\.resetsAt).forEach { resetDate in
            deadlines.insert(UsageDeadline(date: resetDate, reason: .quotaReset))
        }
        deadlines.insert(UsageDeadline(
            date: value.capturedAt.addingTimeInterval(
                QuotaValueValidityPolicy.maximumValueAge
            ),
            reason: .validityExpired
        ))
    }

    private func unhandledDueDeadlines(
        _ candidates: Set<UsageDeadline>,
        at currentDate: Date
    ) -> Set<UsageDeadline> {
        Set(candidates.filter { deadline in
            deadline.date <= currentDate && !handledDeadlines.contains(deadline)
        })
    }

    private func earliestUnhandledFutureDate(
        _ candidates: Set<UsageDeadline>,
        after currentDate: Date
    ) -> Date? {
        candidates.lazy
            .filter { deadline in
                deadline.date > currentDate && !self.handledDeadlines.contains(deadline)
            }
            .map(\.date)
            .min()
    }

    private func updateTimer(deadline: Date?, force: Bool) {
        guard let deadline else {
            cancelTimer()
            return
        }
        guard force || scheduledDeadlineDate != deadline else {
            return
        }
        cancelTimer()
        nextTimerGeneration &+= 1
        let generation = nextTimerGeneration
        activeTimerGeneration = generation
        scheduledDeadlineDate = deadline
        timerScheduler.schedule(
            deadline: deadline,
            tolerance: Self.defaultTolerance
        ) { [weak self] in
            self?.timerDidFire(generation: generation)
        }
    }

    private func timerDidFire(generation: UInt64) {
        guard activeTimerGeneration == generation else {
            return
        }
        guard !isStopped, !isSleeping else {
            return
        }
        activeTimerGeneration = nil
        scheduledDeadlineDate = nil
        reevaluate(forceReschedule: false)
    }

    private func cancelTimer() {
        guard activeTimerGeneration != nil else {
            scheduledDeadlineDate = nil
            return
        }
        timerScheduler.cancel()
        activeTimerGeneration = nil
        scheduledDeadlineDate = nil
    }

    private func deliver(_ deadlines: Set<UsageDeadline>) {
        let reasons = Set(deadlines.map(\.reason)).sorted(by: reasonAscending)
        for reason in reasons {
            guard !isStopped else {
                return
            }
            handleDeadline(reason)
        }
    }

    private func reasonAscending(
        _ left: UsageDeadlineReason,
        _ right: UsageDeadlineReason
    ) -> Bool {
        reasonRank(left) < reasonRank(right)
    }

    private func reasonRank(_ reason: UsageDeadlineReason) -> Int {
        switch reason {
        case .validityExpired:
            0
        case .quotaReset:
            1
        }
    }

    private func removeClockChangeObservation() {
        guard let observation = clockChangeObservation else {
            return
        }
        notificationCenter.removeObserver(observation)
        clockChangeObservation = nil
    }
}

private struct UsageDeadline: Equatable, Hashable {
    let date: Date
    let reason: UsageDeadlineReason
}
