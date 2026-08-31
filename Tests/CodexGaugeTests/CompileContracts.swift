import CodexGaugeAppKit
import CodexGaugeCore
import CodexGaugeProtocol
import CodexGaugeRefresh
import CodexGaugeSettings

private func verifySendableCompileContracts() {
    verifyCoreSendableContracts()
    verifyRuntimeSendableContracts()
}

private func verifyCoreSendableContracts() {
    requireSendable(AppPreferences.self)
    requireSendable(JSONRPCResponse.self)
    requireSendable(RateLimitReadResult.self)
    requireSendable(AppServerSmokeResult.self)
    requireSendable(CodexExecutableLocator.self)
    requireSendable(LaunchAtLoginStatus.self)
    requireSendable(LaunchAtLoginSettingsState.self)
    requireSendable(UsageDeadlineReason.self)
    requireSendable(AssistiveDisplayEvent.self)
    requireSendable(DisplayFrame.self)
}

private func verifyRuntimeSendableContracts() {
    requireSendable(UsageSession.self)
    requireSendable(RefreshPublication.self)
    requireSendable(ApplicationActivityTransition.self)
    requireSendable(SettingsFormState.self)
    requireSendable(RefreshProfile.self)
    requireSendable(RefreshPresentation.self)
    requireSendable(SystemActivityEvent.self)
    requireSendable(ConnectionDiagnosticsSnapshot.self)
}

private func requireSendable<Value: Sendable>(_ type: Value.Type) {
    _ = type
}
