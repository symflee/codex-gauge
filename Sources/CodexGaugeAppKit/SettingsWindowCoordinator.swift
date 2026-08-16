import CodexGaugeCore
import CodexGaugeSettings

@MainActor
public final class SettingsWindowCoordinator {
    public private(set) var activeWindowController: SettingsWindowController?

    private let repository: AppPreferencesRepository
    private let discoveredQuotaProvider: @MainActor () -> Set<QuotaSelectionID>
    private var pendingSave: Task<Void, Never>?

    public init(
        repository: AppPreferencesRepository,
        discoveredQuotaProvider: @escaping @MainActor () -> Set<QuotaSelectionID>
    ) {
        self.repository = repository
        self.discoveredQuotaProvider = discoveredQuotaProvider
    }

    @discardableResult
    public func showSettings() async -> SettingsWindowController {
        if let controller = activeWindowController {
            controller.showWindow(nil)
            controller.window?.makeKeyAndOrderFront(nil)
            return controller
        }
        await pendingSave?.value
        let preferences = await repository.load()
        if let controller = activeWindowController {
            return controller
        }
        return makeWindowController(preferences: preferences)
    }

    public func flushPendingSave() async {
        await pendingSave?.value
    }

    private func makeWindowController(
        preferences: AppPreferences
    ) -> SettingsWindowController {
        let state = SettingsFormState(
            preferences: preferences,
            discoveredQuotaIDs: discoveredQuotaProvider()
        )
        let controller = SettingsWindowController(
            formState: state,
            onFormValuesChanged: { [weak self] values in
                self?.enqueueSave(values)
            },
            onClose: { [weak self] closingController in
                self?.release(closingController)
            }
        )
        activeWindowController = controller
        controller.showWindow(nil)
        controller.window?.makeKeyAndOrderFront(nil)
        return controller
    }

    private func enqueueSave(_ values: SettingsFormValues) {
        let previousSave = pendingSave
        let repository = repository
        pendingSave = Task {
            await previousSave?.value
            try? await repository.saveSettingsForm(values)
        }
    }

    private func release(_ controller: SettingsWindowController) {
        guard activeWindowController === controller else {
            return
        }
        activeWindowController = nil
    }
}
