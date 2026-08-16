import CodexGaugeCore
import Foundation

public struct InitializeAcknowledgement: Equatable, Sendable {
    public init() {}
}

public enum AccountStatus: Equatable, Sendable {
    case rateLimitsAvailable
    case signedOut
    case unsupportedProvider
    case unknownProvider
}

public enum ProductRateLimitState: Equatable, Sendable {
    case available
    case partial
    case unavailable
    case malformed
}

public struct SpendControlLimit: Equatable, Sendable {
    public let remainingPercent: Int?
    public let reached: Bool?

    public init(remainingPercent: Int?, reached: Bool?) {
        self.remainingPercent = remainingPercent
        self.reached = reached
    }
}

public struct ProductRateLimits: Equatable, Sendable {
    public let state: ProductRateLimitState
    public let windows: [QuotaWindow]
    public let spendControlLimit: SpendControlLimit?

    public init(
        state: ProductRateLimitState,
        windows: [QuotaWindow],
        spendControlLimit: SpendControlLimit? = nil
    ) {
        self.state = state
        self.windows = windows
        self.spendControlLimit = spendControlLimit
    }
}

public struct RateLimitReadResult: Equatable, Sendable {
    public let capturedAt: Date
    public let rateLimitsByProduct: [UsageProduct: ProductRateLimits]

    public init(
        capturedAt: Date,
        rateLimitsByProduct: [UsageProduct: ProductRateLimits]
    ) {
        self.capturedAt = capturedAt
        self.rateLimitsByProduct = rateLimitsByProduct
    }

    public func rateLimits(for product: UsageProduct) -> ProductRateLimits {
        rateLimitsByProduct[product] ?? ProductRateLimits(
            state: .unavailable,
            windows: [],
            spendControlLimit: nil
        )
    }

    public var snapshot: UsageSnapshot {
        let quotas = rateLimitsByProduct.mapValues(\.windows)
        return UsageSnapshot(capturedAt: capturedAt, quotasByProduct: quotas)
    }
}

public enum AppServerInterpretationError: Error, Equatable, Sendable {
    case rpcFailure(code: Int)
    case invalidInitializeResult
    case invalidAccountResult
    case invalidRateLimitsResult
}

public struct AppServerResponseInterpreter: Sendable {
    public init() {}

    public func initialize(
        from response: JSONRPCResponse
    ) throws -> InitializeAcknowledgement {
        let result = try result(from: response)
        guard result.objectValue != nil else {
            throw AppServerInterpretationError.invalidInitializeResult
        }
        return InitializeAcknowledgement()
    }

    public func account(
        from response: JSONRPCResponse
    ) throws -> AccountStatus {
        let result = try result(from: response)
        guard let object = result.objectValue else {
            throw AppServerInterpretationError.invalidAccountResult
        }
        return try AccountStatusDecoder().decode(object)
    }

    public func rateLimits(
        from response: JSONRPCResponse,
        capturedAt: Date
    ) throws -> RateLimitReadResult {
        let result = try result(from: response)
        guard let object = result.objectValue else {
            throw AppServerInterpretationError.invalidRateLimitsResult
        }
        return RateLimitResultDecoder(capturedAt: capturedAt).decode(object)
    }

    private func result(from response: JSONRPCResponse) throws -> JSONValue {
        switch response.payload {
        case let .result(result):
            result
        case let .failure(failure):
            throw AppServerInterpretationError.rpcFailure(code: failure.code)
        }
    }
}

private struct AccountStatusDecoder {
    func decode(
        _ object: [String: JSONValue]
    ) throws -> AccountStatus {
        guard let account = object["account"] else {
            throw AppServerInterpretationError.invalidAccountResult
        }
        guard account != .null else {
            return try statusWithoutAccount(object)
        }
        guard let accountObject = account.objectValue else {
            throw AppServerInterpretationError.invalidAccountResult
        }
        return try status(for: accountObject)
    }

    private func statusWithoutAccount(
        _ object: [String: JSONValue]
    ) throws -> AccountStatus {
        guard let requiresAuth = object["requiresOpenaiAuth"]?.booleanValue else {
            throw AppServerInterpretationError.invalidAccountResult
        }
        guard requiresAuth else {
            return .unsupportedProvider
        }
        return .signedOut
    }

    private func status(
        for account: [String: JSONValue]
    ) throws -> AccountStatus {
        guard let typeValue = account["type"] else {
            return .unknownProvider
        }
        guard let type = typeValue.stringValue else {
            throw AppServerInterpretationError.invalidAccountResult
        }
        if Self.rateLimitProviders.contains(type) {
            return .rateLimitsAvailable
        }
        if Self.unsupportedProviders.contains(type) {
            return .unsupportedProvider
        }
        return .unknownProvider
    }

    private static let rateLimitProviders = Set([
        "chatgpt",
        "chatgptAuthTokens",
        "agentIdentity",
        "personalAccessToken"
    ])

    private static let unsupportedProviders = Set([
        "apiKey",
        "amazonBedrock"
    ])
}

private struct RateLimitResultDecoder {
    let capturedAt: Date

    func decode(
        _ object: [String: JSONValue]
    ) -> RateLimitReadResult {
        let products = decodeProducts(object)
        return RateLimitReadResult(
            capturedAt: capturedAt,
            rateLimitsByProduct: products
        )
    }

    private func decodeProducts(
        _ object: [String: JSONValue]
    ) -> [UsageProduct: ProductRateLimits] {
        guard let multiBucket = object["rateLimitsByLimitId"] else {
            return decodeLegacy(object["rateLimits"])
        }
        guard multiBucket != .null else {
            return decodeLegacy(object["rateLimits"])
        }
        guard let buckets = multiBucket.objectValue else {
            return malformedProducts()
        }
        return [
            .codex: decodeBucket(buckets["codex"]),
            .spark: decodeBucket(buckets["codex_bengalfox"])
        ]
    }

    private func decodeLegacy(
        _ bucket: JSONValue?
    ) -> [UsageProduct: ProductRateLimits] {
        [
            .codex: decodeBucket(bucket),
            .spark: unavailableProduct()
        ]
    }

    private func malformedProducts() -> [UsageProduct: ProductRateLimits] {
        let malformed = ProductRateLimits(
            state: .malformed,
            windows: [],
            spendControlLimit: nil
        )
        return [.codex: malformed, .spark: malformed]
    }

    private func decodeBucket(
        _ value: JSONValue?
    ) -> ProductRateLimits {
        guard let value, value != .null else {
            return unavailableProduct()
        }
        guard let object = value.objectValue else {
            return ProductRateLimits(
                state: .malformed,
                windows: [],
                spendControlLimit: nil
            )
        }
        return BucketDecoder().decode(object)
    }

    private func unavailableProduct() -> ProductRateLimits {
        ProductRateLimits(
            state: .unavailable,
            windows: [],
            spendControlLimit: nil
        )
    }
}

private struct BucketDecoder {
    func decode(
        _ object: [String: JSONValue]
    ) -> ProductRateLimits {
        let results = QuotaSlot.allCases.map {
            decodeWindow(slot: $0, value: object[$0.rawValue])
        }
        let windows = results.compactMap(\.window)
        let malformed = results.contains { $0.isMalformed }
        return ProductRateLimits(
            state: state(windows: windows, malformed: malformed),
            windows: windows,
            spendControlLimit: SpendControlDecoder().decode(object)
        )
    }

    private func decodeWindow(
        slot: QuotaSlot,
        value: JSONValue?
    ) -> WindowDecodingResult {
        guard let value, value != .null else {
            return .absent
        }
        guard let object = value.objectValue else {
            return .malformed
        }
        guard let window = makeWindow(slot: slot, object: object) else {
            return .malformed
        }
        return .window(window)
    }

    private func makeWindow(
        slot: QuotaSlot,
        object: [String: JSONValue]
    ) -> QuotaWindow? {
        guard let usedPercent = object["usedPercent"]?.numericValue else {
            return nil
        }
        guard let duration = optionalInteger(object["windowDurationMins"]) else {
            return nil
        }
        guard let reset = optionalNumber(object["resetsAt"]) else {
            return nil
        }
        return QuotaWindow(
            slot: slot,
            usedPercent: usedPercent,
            windowDurationMinutes: duration,
            resetUnixSeconds: reset
        )
    }

    private func optionalInteger(_ value: JSONValue?) -> Int?? {
        guard let value, value != .null else {
            return .some(nil)
        }
        guard let integer = value.integerValue else {
            return nil
        }
        guard let converted = Int(exactly: integer) else {
            return nil
        }
        return .some(converted)
    }

    private func optionalNumber(_ value: JSONValue?) -> Double?? {
        guard let value, value != .null else {
            return .some(nil)
        }
        guard let number = value.numericValue, number.isFinite else {
            return nil
        }
        return .some(number)
    }

    private func state(
        windows: [QuotaWindow],
        malformed: Bool
    ) -> ProductRateLimitState {
        guard malformed else {
            return windows.isEmpty ? .unavailable : .available
        }
        return windows.isEmpty ? .malformed : .partial
    }
}

private struct SpendControlDecoder {
    func decode(
        _ object: [String: JSONValue]
    ) -> SpendControlLimit? {
        let individualLimit = object["individualLimit"]?.objectValue
        let reached = object["spendControlReached"]?.booleanValue
        let remainingPercent = remainingPercent(from: individualLimit)
        guard remainingPercent != nil || reached != nil else {
            return nil
        }
        return SpendControlLimit(
            remainingPercent: remainingPercent,
            reached: reached
        )
    }

    private func remainingPercent(
        from individualLimit: [String: JSONValue]?
    ) -> Int? {
        guard
            let value = individualLimit?["remainingPercent"]?.numericValue,
            value.isFinite
        else {
            return nil
        }
        let bounded = min(max(value, 0), 100)
        return Int(bounded.rounded(.down))
    }
}

private enum WindowDecodingResult {
    case absent
    case window(QuotaWindow)
    case malformed

    var window: QuotaWindow? {
        guard case let .window(window) = self else {
            return nil
        }
        return window
    }

    var isMalformed: Bool {
        guard case .malformed = self else {
            return false
        }
        return true
    }
}
