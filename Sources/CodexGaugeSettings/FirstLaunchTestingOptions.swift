public struct FirstLaunchTestingOptions: Equatable, Sendable {
    public static let resetCompletionArgument =
        "--codex-gauge-ui-test-reset-first-launch"
    public static let production = FirstLaunchTestingOptions(arguments: [])

    public let shouldResetCompletion: Bool

    public init(arguments: [String]) {
        shouldResetCompletion = arguments.contains(Self.resetCompletionArgument)
    }
}
