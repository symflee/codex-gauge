import Foundation

public enum StatusRotationPauseReason: Hashable, Sendable, CaseIterable {
    case menuOpen
    case screenLocked
    case sleeping
    case voiceOver
    case reduceMotion
}

@MainActor
public protocol StatusRotationScheduling: AnyObject, Sendable {
    func schedule(
        interval: TimeInterval,
        tolerance: TimeInterval,
        action: @escaping @MainActor () -> Void
    )

    func cancel()
}

@MainActor
public final class RunLoopStatusRotationScheduler: NSObject, StatusRotationScheduling {
    private var timer: Timer?
    private var action: (@MainActor () -> Void)?

    public override init() {
        super.init()
    }

    public func schedule(
        interval: TimeInterval,
        tolerance: TimeInterval,
        action: @escaping @MainActor () -> Void
    ) {
        invalidateTimer()
        self.action = action
        let timer = Timer(
            timeInterval: interval,
            target: self,
            selector: #selector(timerDidFire(_:)),
            userInfo: nil,
            repeats: true
        )
        timer.tolerance = tolerance
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    public func cancel() {
        invalidateTimer()
        action = nil
    }

    @objc
    private func timerDidFire(_ timer: Timer) {
        _ = timer
        action?()
    }

    private func invalidateTimer() {
        timer?.invalidate()
        timer = nil
    }
}

@MainActor
final class StatusFrameRotation {
    private static let interval: TimeInterval = 5
    private static let tolerance: TimeInterval = 1

    private let scheduler: StatusRotationScheduling
    private let present: (RenderedStatusFrame) -> Void
    private var frames: [RenderedStatusFrame] = []
    private var pauseReasons: Set<StatusRotationPauseReason> = []
    private var currentIndex = 0
    private var isScheduled = false

    init(
        scheduler: StatusRotationScheduling,
        present: @escaping (RenderedStatusFrame) -> Void
    ) {
        self.scheduler = scheduler
        self.present = present
    }

    deinit {
        let scheduler = scheduler
        Task { @MainActor in scheduler.cancel() }
    }

    func setFrames(_ frames: [RenderedStatusFrame]) {
        stopSchedule()
        self.frames = frames
        currentIndex = 0
        presentCurrentFrame()
        startScheduleIfNeeded()
    }

    func setPaused(_ paused: Bool, for reason: StatusRotationPauseReason) {
        let wasPaused = !pauseReasons.isEmpty
        updatePauseReasons(paused, reason: reason)
        let isPaused = !pauseReasons.isEmpty
        handlePauseTransition(from: wasPaused, to: isPaused)
    }

    func replaceRenderedFrames(_ frames: [RenderedStatusFrame]) {
        guard frames.count == self.frames.count else {
            return
        }
        let changed = frames.indices.contains(currentIndex)
            && !frames[currentIndex].hasSamePresentation(as: self.frames[currentIndex])
        self.frames = frames
        if changed { presentCurrentFrame() }
    }

    private func updatePauseReasons(_ paused: Bool, reason: StatusRotationPauseReason) {
        guard paused else {
            pauseReasons.remove(reason)
            return
        }
        pauseReasons.insert(reason)
    }

    private func handlePauseTransition(from wasPaused: Bool, to isPaused: Bool) {
        guard wasPaused != isPaused else {
            return
        }
        guard !isPaused else {
            stopSchedule()
            return
        }
        currentIndex = 0
        presentCurrentFrame()
        startScheduleIfNeeded()
    }

    private func startScheduleIfNeeded() {
        guard frames.count > 1, pauseReasons.isEmpty else {
            return
        }
        isScheduled = true
        scheduler.schedule(
            interval: Self.interval,
            tolerance: Self.tolerance
        ) { [weak self] in
            self?.advance()
        }
    }

    private func stopSchedule() {
        guard isScheduled else {
            return
        }
        scheduler.cancel()
        isScheduled = false
    }

    private func advance() {
        guard isScheduled, pauseReasons.isEmpty, frames.count > 1 else {
            return
        }
        currentIndex = (currentIndex + 1) % frames.count
        presentCurrentFrame()
    }

    private func presentCurrentFrame() {
        guard frames.indices.contains(currentIndex) else {
            return
        }
        present(frames[currentIndex])
    }
}
