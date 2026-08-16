import AppKit

@MainActor
public final class CodexGaugeApplicationDelegate: NSObject, NSApplicationDelegate {
    public typealias RuntimeFactory = @MainActor () -> any CodexGaugeApplicationRunning
    public typealias TerminationReply = @MainActor (NSApplication, Bool) -> Void

    private let runtimeFactory: RuntimeFactory
    private let terminationReply: TerminationReply
    private var applicationRuntime: (any CodexGaugeApplicationRunning)?
    private var terminationTask: Task<Void, Never>?
    private var hasCompletedTerminationDrain = false

    public override convenience init() {
        self.init(runtimeFactory: { CodexGaugeApplicationFactory.makeDefault() })
    }

    public init(
        runtimeFactory: @escaping RuntimeFactory,
        terminationReply: @escaping TerminationReply = { application, answer in
            application.reply(toApplicationShouldTerminate: answer)
        }
    ) {
        self.runtimeFactory = runtimeFactory
        self.terminationReply = terminationReply
        super.init()
    }

    public func applicationDidFinishLaunching(_ notification: Notification) {
        _ = notification
        guard applicationRuntime == nil else {
            return
        }
        let runtime = runtimeFactory()
        applicationRuntime = runtime
        runtime.start()
    }

    public func applicationDidBecomeActive(_ notification: Notification) {
        _ = notification
        applicationRuntime?.refreshLaunchAtLoginStatus()
    }

    public func applicationShouldTerminate(
        _ sender: NSApplication
    ) -> NSApplication.TerminateReply {
        guard let applicationRuntime else {
            return .terminateNow
        }
        guard !hasCompletedTerminationDrain else {
            return .terminateNow
        }
        startTerminationDrainIfNeeded(
            applicationRuntime: applicationRuntime,
            sender: sender
        )
        return .terminateLater
    }

    private func startTerminationDrainIfNeeded(
        applicationRuntime: any CodexGaugeApplicationRunning,
        sender: NSApplication
    ) {
        guard terminationTask == nil else {
            return
        }
        terminationTask = Task { @MainActor in
            await applicationRuntime.shutdown()
            hasCompletedTerminationDrain = true
            terminationReply(sender, true)
        }
    }
}
