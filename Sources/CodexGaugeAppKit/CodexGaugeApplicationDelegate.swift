import AppKit

@MainActor
public final class CodexGaugeApplicationDelegate: NSObject, NSApplicationDelegate {
    public typealias RuntimeFactory = @MainActor () -> any CodexGaugeApplicationRunning

    private let runtimeFactory: RuntimeFactory
    private var applicationRuntime: (any CodexGaugeApplicationRunning)?

    public override convenience init() {
        self.init(runtimeFactory: { CodexGaugeApplicationFactory.makeDefault() })
    }

    public init(runtimeFactory: @escaping RuntimeFactory) {
        self.runtimeFactory = runtimeFactory
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
}
