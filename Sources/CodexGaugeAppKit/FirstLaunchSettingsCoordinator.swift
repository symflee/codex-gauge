import CodexGaugeSettings

@MainActor
public final class FirstLaunchSettingsCoordinator {
    private let repository: AppPreferencesRepository
    private let settingsRuntime: any ApplicationSettingsRuntime
    private let testingOptions: FirstLaunchTestingOptions
    private var hasAttemptedAutomaticPresentation = false

    public init(
        repository: AppPreferencesRepository,
        settingsRuntime: any ApplicationSettingsRuntime,
        testingOptions: FirstLaunchTestingOptions = .production
    ) {
        self.repository = repository
        self.settingsRuntime = settingsRuntime
        self.testingOptions = testingOptions
    }

    public func runAfterInitialRefreshStarted() async {
        guard !hasAttemptedAutomaticPresentation else {
            return
        }
        hasAttemptedAutomaticPresentation = true
        guard !Task.isCancelled else {
            return
        }
        guard await applyTestingResetIfNeeded() else {
            return
        }
        let preferences = await repository.load()
        guard !Task.isCancelled, !preferences.hasCompletedFirstLaunch else {
            return
        }
        let isVisible = await settingsRuntime.showSettings()
        guard isVisible else {
            return
        }
        try? await repository.markFirstLaunchCompleted()
    }

    private func applyTestingResetIfNeeded() async -> Bool {
        guard testingOptions.shouldResetCompletion else {
            return true
        }
        do {
            try await repository.resetFirstLaunchCompletionForUITesting()
            return !Task.isCancelled
        } catch {
            return false
        }
    }
}
