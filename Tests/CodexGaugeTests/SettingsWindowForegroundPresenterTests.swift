import CodexGaugeAppKit

func settingsWindowForegroundPresenterTests() -> [TestCase] {
    [
        settingsWindowForegroundPresentationOrderTest(),
        settingsWindowForegroundMissingWindowTest()
    ]
}

private func settingsWindowForegroundPresentationOrderTest() -> TestCase {
    TestCase(name: "settings foreground activation precedes every front request") {
        try await settingsWindowForegroundPresentationOrderScenario()
    }
}

@MainActor
private func settingsWindowForegroundPresentationOrderScenario() throws {
    let events = SettingsForegroundEventRecorder()
    let activation = SettingsWindowActivationSpy(events: events)
    let window = SettingsWindowFrontSpy(events: events)
    let presenter = SettingsWindowForegroundPresenter(
        applicationActivator: activation
    )

    let firstResult = presenter.present(window)
    let secondResult = presenter.present(window)

    try expect(firstResult, "Expected first foreground presentation")
    try expect(secondResult, "Expected repeated foreground presentation")
    try expect(
        events.values == [
            .activate(ignoringOtherApps: true),
            .show,
            .makeKeyAndOrderFront,
            .activate(ignoringOtherApps: true),
            .show,
            .makeKeyAndOrderFront
        ],
        "Expected activation before each show and front request"
    )
    try expect(
        activation.ignoringOtherAppsValues == [true, true],
        "Expected one foreground activation per presentation"
    )
}

private func settingsWindowForegroundMissingWindowTest() -> TestCase {
    TestCase(name: "settings foreground skips activation without a window") {
        try await settingsWindowForegroundMissingWindowScenario()
    }
}

@MainActor
private func settingsWindowForegroundMissingWindowScenario() throws {
    let events = SettingsForegroundEventRecorder()
    let activation = SettingsWindowActivationSpy(events: events)
    let window = SettingsWindowFrontSpy(events: events, hasWindow: false)
    let presenter = SettingsWindowForegroundPresenter(
        applicationActivator: activation
    )

    let result = presenter.present(window)

    try expect(!result, "Expected missing window presentation failure")
    try expect(events.values.isEmpty, "Expected no foreground side effects")
    try expect(
        activation.ignoringOtherAppsValues.isEmpty,
        "Expected no application activation without a window"
    )
}

@MainActor
private enum SettingsForegroundEvent: Equatable {
    case activate(ignoringOtherApps: Bool)
    case show
    case makeKeyAndOrderFront
}

@MainActor
private final class SettingsForegroundEventRecorder {
    private(set) var values = [SettingsForegroundEvent]()

    func append(_ event: SettingsForegroundEvent) {
        values.append(event)
    }
}

@MainActor
private final class SettingsWindowActivationSpy: SettingsWindowApplicationActivating {
    private let events: SettingsForegroundEventRecorder
    private(set) var ignoringOtherAppsValues = [Bool]()

    init(events: SettingsForegroundEventRecorder) {
        self.events = events
    }

    func activate(ignoringOtherApps: Bool) {
        ignoringOtherAppsValues.append(ignoringOtherApps)
        events.append(.activate(ignoringOtherApps: ignoringOtherApps))
    }
}

@MainActor
private final class SettingsWindowFrontSpy: SettingsWindowFronting {
    private let events: SettingsForegroundEventRecorder
    private(set) var hasSettingsWindow: Bool
    private(set) var isSettingsWindowVisible = false

    init(
        events: SettingsForegroundEventRecorder,
        hasWindow: Bool = true
    ) {
        self.events = events
        hasSettingsWindow = hasWindow
    }

    func showSettingsWindow() {
        events.append(.show)
        isSettingsWindowVisible = true
    }

    func makeSettingsWindowKeyAndOrderFront() {
        events.append(.makeKeyAndOrderFront)
    }
}
