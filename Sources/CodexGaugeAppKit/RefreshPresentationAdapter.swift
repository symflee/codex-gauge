import CodexGaugeCore
import CodexGaugeRefresh
import Foundation

public struct RefreshPresentation: Equatable, Sendable {
    public let frames: [DisplayFrame]
    public let menuInput: QuotaDetailsMenuInput
    public let discoveredQuotaIDs: Set<QuotaSelectionID>

    public init(
        frames: [DisplayFrame],
        menuInput: QuotaDetailsMenuInput,
        discoveredQuotaIDs: Set<QuotaSelectionID>
    ) {
        self.frames = frames
        self.menuInput = menuInput
        self.discoveredQuotaIDs = discoveredQuotaIDs
    }
}

public struct RefreshPresentationAdapter: Sendable {
    private let frameBuilder = DisplayFrameBuilder()

    public init() {}

    public func makePresentation(
        publication: RefreshPublication,
        preference: DisplayPreference,
        canOpenCodexApplication: Bool,
        now: Date
    ) -> RefreshPresentation {
        let states = productStates(from: publication)
        let menuInput = makeMenuInput(
            publication: publication,
            productStates: states,
            canOpenCodexApplication: canOpenCodexApplication
        )
        return RefreshPresentation(
            frames: frameBuilder.makeFrames(
                preference: preference,
                productStates: states,
                now: now
            ),
            menuInput: menuInput,
            discoveredQuotaIDs: discoveredQuotaIDs(from: publication)
        )
    }

    private func productStates(
        from publication: RefreshPublication
    ) -> [UsageProduct: ProductUsageState] {
        Dictionary(uniqueKeysWithValues: UsageProduct.allCases.map { product in
            (product, publication.products[product]?.usageState ?? .unavailable)
        })
    }

    private func makeMenuInput(
        publication: RefreshPublication,
        productStates: [UsageProduct: ProductUsageState],
        canOpenCodexApplication: Bool
    ) -> QuotaDetailsMenuInput {
        QuotaDetailsMenuInput(
            productStates: productStates,
            issuesByProduct: issues(from: publication),
            lastSuccessfulRefreshByProduct: successfulRefreshes(from: publication),
            codexAvailability: availability(
                for: publication.failure,
                canOpenCodexApplication: canOpenCodexApplication
            )
        )
    }

    private func issues(
        from publication: RefreshPublication
    ) -> [UsageProduct: QuotaMenuIssue] {
        if let failure = publication.failure {
            let issue = menuIssue(for: failure)
            return Dictionary(uniqueKeysWithValues: UsageProduct.allCases.map {
                ($0, issue)
            })
        }
        return publication.products.compactMapValues { product in
            product.issue.flatMap(menuIssue)
        }
    }

    private func menuIssue(
        for issue: RefreshProductIssue
    ) -> QuotaMenuIssue? {
        switch issue {
        case .partial:
            .partialData
        case .malformed:
            .incompatibleProtocol
        case .unavailable:
            nil
        }
    }

    private func menuIssue(
        for failure: RefreshFailure
    ) -> QuotaMenuIssue {
        switch failure {
        case .codexNotFound, .invalidCodexSelection:
            .codexNotFound
        case .timeout:
            .timeout
        case .protocolIncompatible:
            .incompatibleProtocol
        case .signedOut:
            .signedOut
        case .unsupportedAuthentication:
            .unsupportedAccount
        case .processUnavailable, .connectionInterrupted, .server:
            .refreshFailed
        }
    }

    private func availability(
        for failure: RefreshFailure?,
        canOpenCodexApplication: Bool
    ) -> CodexMenuAvailability {
        guard let failure else {
            return canOpenCodexApplication ? .available : .needsSelection
        }
        return switch failure {
        case .codexNotFound, .invalidCodexSelection:
            .needsSelection
        default:
            canOpenCodexApplication ? .available : .needsSelection
        }
    }

    private func successfulRefreshes(
        from publication: RefreshPublication
    ) -> [UsageProduct: Date] {
        publication.products.compactMapValues(\.lastSuccessfulRefresh)
    }

    private func discoveredQuotaIDs(
        from publication: RefreshPublication
    ) -> Set<QuotaSelectionID> {
        Set(publication.products.flatMap { product, result in
            result.rateLimits?.windows.map {
                QuotaSelectionID(
                    product: product,
                    rawDurationMinutes: $0.windowDurationMinutes
                )
            } ?? []
        })
    }
}
