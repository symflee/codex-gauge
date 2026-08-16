import Foundation

@MainActor
public protocol WallClockOneShotScheduling: AnyObject {
    func schedule(
        deadline: Date,
        tolerance: TimeInterval,
        action: @escaping @MainActor () -> Void
    )

    func cancel()
}

@MainActor
public final class RunLoopWallClockOneShotScheduler: NSObject,
    WallClockOneShotScheduling {
    private var timer: Timer?
    private var action: (@MainActor () -> Void)?

    public override init() {
        super.init()
    }

    public func schedule(
        deadline: Date,
        tolerance: TimeInterval,
        action: @escaping @MainActor () -> Void
    ) {
        cancel()
        self.action = action
        let timer = Timer(
            fireAt: deadline,
            interval: 0,
            target: self,
            selector: #selector(timerDidFire(_:)),
            userInfo: nil,
            repeats: false
        )
        timer.tolerance = max(tolerance, 0)
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    public func cancel() {
        timer?.invalidate()
        timer = nil
        action = nil
    }

    @objc
    private func timerDidFire(_ timer: Timer) {
        _ = timer
        let pendingAction = action
        self.timer?.invalidate()
        self.timer = nil
        action = nil
        pendingAction?()
    }
}
