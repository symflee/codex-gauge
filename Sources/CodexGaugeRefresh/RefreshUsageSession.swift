import CodexGaugeProtocol
import Foundation

public protocol RefreshUsageSession: Sendable {
    func start() async throws
    func readRateLimits(capturedAt: Date) async throws -> RateLimitReadResult
    func stop() async
}

extension UsageSession: RefreshUsageSession {}

public protocol RefreshSessionProviding: Sendable {
    func makeSession() async throws -> any RefreshUsageSession
}

public struct CodexRefreshSessionProvider: RefreshSessionProviding, Sendable {
    private let provider: any CodexUsageProviding

    public init(provider: any CodexUsageProviding) {
        self.provider = provider
    }

    public func makeSession() async throws -> any RefreshUsageSession {
        try provider.makeSession()
    }
}
