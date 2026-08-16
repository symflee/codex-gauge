import CodexGaugeCore
import CodexGaugeProtocol
import Foundation

public enum RefreshFailure: Equatable, Sendable {
    case codexNotFound
    case invalidCodexSelection
    case timeout
    case processUnavailable
    case connectionInterrupted
    case protocolIncompatible
    case signedOut
    case unsupportedAuthentication
    case server(code: Int)
}

public enum RefreshProductIssue: Equatable, Sendable {
    case partial
    case unavailable
    case malformed
}

public struct RefreshProductResult: Equatable, Sendable {
    public let usageState: ProductUsageState
    public let rateLimits: ProductRateLimits?
    public let issue: RefreshProductIssue?
    public let lastSuccessfulRefresh: Date?

    public init(
        usageState: ProductUsageState,
        rateLimits: ProductRateLimits?,
        issue: RefreshProductIssue?,
        lastSuccessfulRefresh: Date?
    ) {
        self.usageState = usageState
        self.rateLimits = rateLimits
        self.issue = issue
        self.lastSuccessfulRefresh = lastSuccessfulRefresh
    }
}

public struct RefreshPublication: Equatable, Sendable {
    public static let initial = RefreshPublication(
        products: Dictionary(
            uniqueKeysWithValues: UsageProduct.allCases.map {
                ($0, RefreshProductResult(
                    usageState: .loading,
                    rateLimits: nil,
                    issue: nil,
                    lastSuccessfulRefresh: nil
                ))
            }
        ),
        lastSuccessfulRefresh: nil,
        lastAcceptedRateLimitResponse: nil,
        failure: nil,
        isRefreshing: false
    )

    public let products: [UsageProduct: RefreshProductResult]
    public let lastSuccessfulRefresh: Date?
    public let lastAcceptedRateLimitResponse: Date?
    public let failure: RefreshFailure?
    public let isRefreshing: Bool

    public init(
        products: [UsageProduct: RefreshProductResult],
        lastSuccessfulRefresh: Date?,
        lastAcceptedRateLimitResponse: Date? = nil,
        failure: RefreshFailure?,
        isRefreshing: Bool
    ) {
        self.products = products
        self.lastSuccessfulRefresh = lastSuccessfulRefresh
        self.lastAcceptedRateLimitResponse = lastAcceptedRateLimitResponse
        self.failure = failure
        self.isRefreshing = isRefreshing
    }
}

public typealias RefreshPublicationHandler = @MainActor @Sendable (RefreshPublication) -> Void

extension RefreshPublication {
    func settingRefreshing(_ refreshing: Bool) -> RefreshPublication {
        RefreshPublication(
            products: products,
            lastSuccessfulRefresh: lastSuccessfulRefresh,
            lastAcceptedRateLimitResponse: lastAcceptedRateLimitResponse,
            failure: failure,
            isRefreshing: refreshing
        )
    }

    func applying(_ result: RateLimitReadResult) -> RefreshPublication {
        let updated = Dictionary(uniqueKeysWithValues: UsageProduct.allCases.map { product in
            (product, productResult(product, from: result))
        })
        let successfulRefresh = updated.values.contains(where: Self.isFresh)
        return RefreshPublication(
            products: updated,
            lastSuccessfulRefresh: successfulRefresh ? result.capturedAt : lastSuccessfulRefresh,
            lastAcceptedRateLimitResponse: result.capturedAt,
            failure: nil,
            isRefreshing: false
        )
    }

    func applying(_ failure: RefreshFailure) -> RefreshPublication {
        let staleProducts = products.mapValues(Self.markStale)
        return RefreshPublication(
            products: staleProducts,
            lastSuccessfulRefresh: lastSuccessfulRefresh,
            lastAcceptedRateLimitResponse: lastAcceptedRateLimitResponse,
            failure: failure,
            isRefreshing: false
        )
    }

    private func productResult(
        _ product: UsageProduct,
        from result: RateLimitReadResult
    ) -> RefreshProductResult {
        let limits = result.rateLimits(for: product)
        guard limits.windows.isEmpty == false else {
            return emptyResult(limits, prior: products[product])
        }
        let value = ProductQuotaValue(
            capturedAt: result.capturedAt,
            quotaWindows: limits.windows
        )
        return RefreshProductResult(
            usageState: .value(value, freshness: .fresh),
            rateLimits: limits,
            issue: Self.issue(for: limits.state),
            lastSuccessfulRefresh: result.capturedAt
        )
    }

    private func emptyResult(
        _ limits: ProductRateLimits,
        prior: RefreshProductResult?
    ) -> RefreshProductResult {
        guard limits.state != .unavailable else {
            return acceptedUnavailableResult(limits, prior: prior)
        }
        let state = prior.map(Self.markStale)?.usageState ?? .unavailable
        return RefreshProductResult(
            usageState: state,
            rateLimits: limits,
            issue: Self.issue(for: limits.state) ?? .unavailable,
            lastSuccessfulRefresh: prior?.lastSuccessfulRefresh
        )
    }

    private func acceptedUnavailableResult(
        _ limits: ProductRateLimits,
        prior: RefreshProductResult?
    ) -> RefreshProductResult {
        RefreshProductResult(
            usageState: .unavailable,
            rateLimits: limits,
            issue: .unavailable,
            lastSuccessfulRefresh: prior?.lastSuccessfulRefresh
        )
    }

    private static func markStale(
        _ result: RefreshProductResult
    ) -> RefreshProductResult {
        RefreshProductResult(
            usageState: staleState(result.usageState),
            rateLimits: result.rateLimits,
            issue: result.issue,
            lastSuccessfulRefresh: result.lastSuccessfulRefresh
        )
    }

    private static func isFresh(
        _ result: RefreshProductResult
    ) -> Bool {
        guard case .value(_, freshness: .fresh) = result.usageState else {
            return false
        }
        return true
    }

    private static func staleState(_ state: ProductUsageState) -> ProductUsageState {
        guard case let .value(value, _) = state else {
            return .unavailable
        }
        return .value(value, freshness: .stale)
    }

    private static func issue(
        for state: ProductRateLimitState
    ) -> RefreshProductIssue? {
        switch state {
        case .available:
            nil
        case .partial:
            .partial
        case .unavailable:
            .unavailable
        case .malformed:
            .malformed
        }
    }
}
