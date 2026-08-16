import CodexGaugeAppKit
import CodexGaugeCore
import CodexGaugeProtocol
import CodexGaugeRefresh
import Foundation

func refreshPresentationAdapterTests() -> [TestCase] {
    [
        refreshPresentationBuildsFramesAndMenuInputTest(),
        refreshPresentationMapsSpendControlWithoutChangingStatusFramesTest(),
        refreshPresentationPreservesIncompleteSpendControlMeaningTest(),
        refreshPresentationKeepsProductIssuesIndependentTest(),
        refreshPresentationMapsGlobalFailuresTest(),
        refreshPresentationUsesExecutableSelectionWithoutApplicationTest(),
        refreshPresentationPreservesLoadingStateTest(),
        refreshPresentationValuesAreSendableTest()
    ]
}

private func refreshPresentationMapsSpendControlWithoutChangingStatusFramesTest() -> TestCase {
    TestCase(name: "refresh presentation maps spend controls without changing status frames") {
        let capturedAt = Date(timeIntervalSince1970: 1_900_000_000)
        let codexWindow = try presentationWindow(used: 17, duration: 300)
        let sparkWindow = try presentationWindow(used: 9, duration: 10_080)
        let productsWithSpendControl: [UsageProduct: RefreshProductResult] = [
            .codex: presentationProduct(
                windows: [codexWindow],
                freshness: .fresh,
                capturedAt: capturedAt,
                spendControl: SpendControlLimit(remainingPercent: 67, reached: true)
            ),
            .spark: presentationProduct(
                windows: [sparkWindow],
                freshness: .fresh,
                capturedAt: capturedAt,
                spendControl: SpendControlLimit(remainingPercent: 72, reached: nil)
            )
        ]
        let productsWithoutSpendControl = productsWithSpendControl.mapValues { product in
            RefreshProductResult(
                usageState: product.usageState,
                rateLimits: product.rateLimits.map {
                    ProductRateLimits(state: $0.state, windows: $0.windows)
                },
                issue: product.issue,
                lastSuccessfulRefresh: product.lastSuccessfulRefresh
            )
        }
        let preference = DisplayPreference(
            productMode: .both,
            quotaSelection: .manual([
                QuotaSelectionID(product: .codex, rawDurationMinutes: 300),
                QuotaSelectionID(product: .spark, rawDurationMinutes: 10_080)
            ])
        )
        let withSpendControl = RefreshPresentationAdapter().makePresentation(
            publication: presentationPublication(
                products: productsWithSpendControl,
                capturedAt: capturedAt
            ),
            preference: preference,
            canOpenCodexApplication: true,
            now: capturedAt
        )
        let withoutSpendControl = RefreshPresentationAdapter().makePresentation(
            publication: presentationPublication(
                products: productsWithoutSpendControl,
                capturedAt: capturedAt
            ),
            preference: preference,
            canOpenCodexApplication: true,
            now: capturedAt
        )

        try expect(
            withSpendControl.menuInput.spendControlsByProduct == [
                .codex: .reached,
                .spark: .remaining(percent: 72)
            ],
            "Expected reached to take precedence and products to remain independent"
        )
        try expect(
            withSpendControl.frames == withoutSpendControl.frames,
            "Expected spend control to stay out of toolbar frames"
        )
        try expect(
            withSpendControl.frames.count == 2,
            "Expected identical multi-frame rotation input"
        )
        let formatter = DisplayFrameFormatter()
        try expect(
            withSpendControl.frames.map(formatter.format)
                == withoutSpendControl.frames.map(formatter.format),
            "Expected identical toolbar titles, accessibility, and width content"
        )
        try expect(
            withSpendControl.discoveredQuotaIDs == withoutSpendControl.discoveredQuotaIDs,
            "Expected spend control to stay out of rotation and width inputs"
        )
    }
}

private func refreshPresentationPreservesIncompleteSpendControlMeaningTest() -> TestCase {
    TestCase(name: "refresh presentation preserves explicit non-reached spend state") {
        let capturedAt = Date(timeIntervalSince1970: 1_900_000_100)
        let window = try presentationWindow(used: 22, duration: 300)
        let publication = presentationPublication(
            products: [
                .codex: presentationProduct(
                    windows: [window],
                    freshness: .fresh,
                    capturedAt: capturedAt,
                    spendControl: SpendControlLimit(remainingPercent: nil, reached: false)
                ),
                .spark: RefreshProductResult(
                    usageState: .unavailable,
                    rateLimits: ProductRateLimits(state: .malformed, windows: []),
                    issue: .malformed,
                    lastSuccessfulRefresh: nil
                )
            ],
            capturedAt: capturedAt
        )

        let presentation = RefreshPresentationAdapter().makePresentation(
            publication: publication,
            preference: .default,
            canOpenCodexApplication: true,
            now: capturedAt
        )

        try expect(
            presentation.menuInput.spendControlsByProduct
                == [.codex: .notReachedWithoutRemainingPercent],
            "Expected incomplete but explicit state without an invented percentage"
        )
        guard case let .value(codexValue, freshness)? =
            presentation.menuInput.productStates[.codex]
        else {
            throw TestFailure(description: "Expected independent Codex quota value")
        }
        try expect(codexValue.quotaWindows == [window], "Expected intact quota window")
        try expect(freshness == .fresh, "Expected intact quota freshness")
        try expect(
            presentation.menuInput.spendControlsByProduct[.spark] == nil,
            "Expected malformed or missing spend control to remain absent"
        )
        try expect(
            presentation.menuInput.productStates[.spark] == .unavailable,
            "Expected malformed spend data not to invent a quota value"
        )
    }
}

private func refreshPresentationBuildsFramesAndMenuInputTest() -> TestCase {
    TestCase(name: "refresh presentation builds frames menu state and discovered quotas") {
        let capturedAt = Date(timeIntervalSince1970: 1_900_000_000)
        let codexWindow = try presentationWindow(used: 17, duration: 300)
        let sparkWindow = try presentationWindow(used: 9, duration: 300)
        let publication = RefreshPublication(
            products: [
                .codex: presentationProduct(
                    windows: [codexWindow],
                    freshness: .fresh,
                    capturedAt: capturedAt
                ),
                .spark: presentationProduct(
                    windows: [sparkWindow],
                    freshness: .fresh,
                    capturedAt: capturedAt
                )
            ],
            lastSuccessfulRefresh: capturedAt,
            failure: nil,
            isRefreshing: false
        )
        let preference = DisplayPreference(
            productMode: .both,
            quotaSelection: .automatic
        )

        let presentation = RefreshPresentationAdapter().makePresentation(
            publication: publication,
            preference: preference,
            canOpenCodexApplication: true,
            now: capturedAt
        )

        try expect(presentation.frames.count == 1, "Expected one automatic comparison")
        guard case let .comparison(codex, spark) = presentation.frames[0] else {
            throw TestFailure(description: "Expected comparison frame")
        }
        try expect(codex.value == .fresh(83), "Expected Codex remaining percent")
        try expect(spark.value == .fresh(91), "Expected Spark remaining percent")
        try expect(presentation.discoveredQuotaIDs == [
            QuotaSelectionID(product: .codex, rawDurationMinutes: 300),
            QuotaSelectionID(product: .spark, rawDurationMinutes: 300)
        ], "Expected product-specific discovered IDs")
        try expect(
            presentation.menuInput.lastSuccessfulRefreshByProduct == [
                .codex: capturedAt,
                .spark: capturedAt
            ],
            "Expected product-specific success times"
        )
        try expect(
            presentation.menuInput.codexAvailability == .available,
            "Expected Codex open action"
        )
        try expect(
            presentation.menuInput.currentDate == capturedAt,
            "Expected toolbar and cached menu to share one presentation time"
        )
    }
}

private func refreshPresentationKeepsProductIssuesIndependentTest() -> TestCase {
    TestCase(name: "refresh presentation maps product issues without contaminating siblings") {
        let capturedAt = Date(timeIntervalSince1970: 1_900_000_100)
        let codexWindow = try presentationWindow(used: 25, duration: 10_080)
        let codex = presentationProduct(
            windows: [codexWindow],
            freshness: .fresh,
            capturedAt: capturedAt,
            issue: .partial
        )
        let spark = RefreshProductResult(
            usageState: .unavailable,
            rateLimits: ProductRateLimits(state: .malformed, windows: []),
            issue: .malformed,
            lastSuccessfulRefresh: nil
        )
        let publication = RefreshPublication(
            products: [.codex: codex, .spark: spark],
            lastSuccessfulRefresh: capturedAt,
            failure: nil,
            isRefreshing: false
        )

        let presentation = RefreshPresentationAdapter().makePresentation(
            publication: publication,
            preference: .default,
            canOpenCodexApplication: true,
            now: capturedAt
        )

        try expect(
            presentation.menuInput.issuesByProduct == [
                .codex: .partialData,
                .spark: .incompatibleProtocol
            ],
            "Expected independent partial and malformed reasons"
        )
        try expect(
            presentation.menuInput.productStates[.codex] == codex.usageState,
            "Expected successful sibling preserved"
        )
        try expect(
            presentation.menuInput.productStates[.spark] == .unavailable,
            "Expected malformed product unavailable"
        )
    }
}

private func refreshPresentationMapsGlobalFailuresTest() -> TestCase {
    TestCase(name: "refresh presentation maps sanitized global failures to menu recovery") {
        let expected: [(RefreshFailure, QuotaMenuIssue, CodexMenuAvailability)] = [
            (.codexNotFound, .codexNotFound, .needsSelection),
            (.invalidCodexSelection, .codexNotFound, .needsSelection),
            (.timeout, .timeout, .available),
            (.processUnavailable, .refreshFailed, .available),
            (.connectionInterrupted, .refreshFailed, .available),
            (.protocolIncompatible, .incompatibleProtocol, .available),
            (.signedOut, .signedOut, .available),
            (.unsupportedAuthentication, .unsupportedAccount, .available),
            (.server(code: -32_000), .refreshFailed, .available)
        ]

        for (failure, issue, availability) in expected {
            let presentation = RefreshPresentationAdapter().makePresentation(
                publication: RefreshPublication(
                    products: RefreshPublication.initial.products,
                    lastSuccessfulRefresh: nil,
                    failure: failure,
                    isRefreshing: false
                ),
                preference: .default,
                canOpenCodexApplication: true,
                now: Date(timeIntervalSince1970: 1_900_000_000)
            )

            try expect(
                presentation.menuInput.issuesByProduct == [
                    .codex: issue,
                    .spark: issue
                ],
                "Expected global failure mapped for every product"
            )
            try expect(
                presentation.menuInput.codexAvailability == availability,
                "Expected matching recovery action"
            )
        }
    }
}

private func refreshPresentationUsesExecutableSelectionWithoutApplicationTest() -> TestCase {
    TestCase(name: "refresh presentation selects an executable when no application can open") {
        let presentation = RefreshPresentationAdapter().makePresentation(
            publication: .initial,
            preference: .default,
            canOpenCodexApplication: false,
            now: Date(timeIntervalSince1970: 1_900_000_000)
        )

        try expect(
            presentation.menuInput.codexAvailability == .needsSelection,
            "Expected an actionable executable selection instead of a no-op open action"
        )
    }
}

private func refreshPresentationPreservesLoadingStateTest() -> TestCase {
    TestCase(name: "refresh presentation preserves initial loading without fake errors") {
        let presentation = RefreshPresentationAdapter().makePresentation(
            publication: .initial,
            preference: .default,
            canOpenCodexApplication: true,
            now: Date(timeIntervalSince1970: 1_900_000_000)
        )

        try expect(presentation.menuInput.issuesByProduct.isEmpty, "Expected no loading error")
        try expect(
            presentation.menuInput.productStates.values.allSatisfy { $0 == .loading },
            "Expected loading for both products"
        )
        try expect(presentation.discoveredQuotaIDs.isEmpty, "Expected no invented quotas")
    }
}

private func refreshPresentationValuesAreSendableTest() -> TestCase {
    TestCase(name: "refresh presentation values are immutable and Sendable") {
        let presentation = RefreshPresentationAdapter().makePresentation(
            publication: .initial,
            preference: .default,
            canOpenCodexApplication: true,
            now: Date(timeIntervalSince1970: 1_900_000_000)
        )
        requireRefreshPresentationSendable(RefreshPresentationAdapter())
        requireRefreshPresentationSendable(presentation)
    }
}

private func presentationProduct(
    windows: [QuotaWindow],
    freshness: ProductValueFreshness,
    capturedAt: Date,
    issue: RefreshProductIssue? = nil,
    spendControl: SpendControlLimit? = nil
) -> RefreshProductResult {
    RefreshProductResult(
        usageState: .value(
            ProductQuotaValue(capturedAt: capturedAt, quotaWindows: windows),
            freshness: freshness
        ),
        rateLimits: ProductRateLimits(
            state: issue == .partial ? .partial : .available,
            windows: windows,
            spendControlLimit: spendControl
        ),
        issue: issue,
        lastSuccessfulRefresh: capturedAt
    )
}

private func presentationPublication(
    products: [UsageProduct: RefreshProductResult],
    capturedAt: Date
) -> RefreshPublication {
    RefreshPublication(
        products: products,
        lastSuccessfulRefresh: capturedAt,
        failure: nil,
        isRefreshing: false
    )
}

private func presentationWindow(
    used: Double,
    duration: Int?
) throws -> QuotaWindow {
    guard let window = QuotaWindow(
        slot: .primary,
        usedPercent: used,
        windowDurationMinutes: duration,
        resetUnixSeconds: 1_900_003_600
    ) else {
        throw TestFailure(description: "Expected synthetic quota")
    }
    return window
}

private func requireRefreshPresentationSendable<Value: Sendable>(_ value: Value) {
    _ = value
}
