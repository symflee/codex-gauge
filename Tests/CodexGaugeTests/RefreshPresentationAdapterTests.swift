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
        refreshPresentationPreservesLoadingStateTest()
    ]
}

private func refreshPresentationMapsSpendControlWithoutChangingStatusFramesTest() -> TestCase {
    TestCase(name: "refresh presentation maps spend controls without changing status frames") {
        let capturedAt = Date(timeIntervalSince1970: 1_900_000_000)
        let codexWindow = try presentationWindow(used: 17, duration: 300)
        let productsWithSpendControl: [UsageProduct: RefreshProductResult] = [
            .codex: presentationProduct(
                windows: [codexWindow],
                freshness: .fresh,
                capturedAt: capturedAt,
                spendControl: SpendControlLimit(remainingPercent: 67, reached: true)
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
            quotaSelection: .manual(QuotaSelectionID(product: .codex, rawDurationMinutes: 300))
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
                .codex: .reached
            ],
            "Expected reached to take precedence and products to remain independent"
        )
        try expect(
            withSpendControl.frames == withoutSpendControl.frames,
            "Expected spend control to stay out of toolbar frames"
        )
        try expect(
            withSpendControl.frames.count == 1,
            "Expected exactly one selected frame"
        )
        let formatter = DisplayFrameFormatter()
        try expect(
            withSpendControl.frames.map(formatter.format)
                == withoutSpendControl.frames.map(formatter.format),
            "Expected identical toolbar titles, accessibility, and width content"
        )
        try expect(
            withSpendControl.discoveredQuotaIDs == withoutSpendControl.discoveredQuotaIDs,
            "Expected spend control to stay out of display selection"
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
    }
}

private func refreshPresentationBuildsFramesAndMenuInputTest() -> TestCase {
    TestCase(name: "refresh presentation builds frames menu state and discovered quotas") {
        let capturedAt = Date(timeIntervalSince1970: 1_900_000_000)
        let codexWindow = try presentationWindow(used: 17, duration: 300)
        let publication = RefreshPublication(
            products: [
                .codex: presentationProduct(
                    windows: [codexWindow],
                    freshness: .fresh,
                    capturedAt: capturedAt
                )
            ],
            lastSuccessfulRefresh: capturedAt,
            failure: nil,
            isRefreshing: false
        )
        let preference = DisplayPreference(
            quotaSelection: .automatic
        )

        let presentation = RefreshPresentationAdapter().makePresentation(
            publication: publication,
            preference: preference,
            canOpenCodexApplication: true,
            now: capturedAt
        )

        try expect(presentation.frames.count == 1, "Expected one automatic Codex frame")
        guard case let .single(codex) = presentation.frames[0] else {
            throw TestFailure(description: "Expected single frame")
        }
        try expect(codex.value == .fresh(83), "Expected Codex remaining percent")
        try expect(presentation.discoveredQuotaIDs == [
            QuotaSelectionID(product: .codex, rawDurationMinutes: 300),
        ], "Expected product-specific discovered IDs")
        try expect(
            presentation.menuInput.lastSuccessfulRefreshByProduct == [
                .codex: capturedAt
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
    TestCase(name: "refresh presentation preserves partial quota issues with the available value") {
        let capturedAt = Date(timeIntervalSince1970: 1_900_000_100)
        let codexWindow = try presentationWindow(used: 25, duration: 10_080)
        let codex = presentationProduct(
            windows: [codexWindow],
            freshness: .fresh,
            capturedAt: capturedAt,
            issue: .partial
        )
        let publication = RefreshPublication(
            products: [.codex: codex],
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
                .codex: .partialData
            ],
            "Expected the Codex partial issue"
        )
        try expect(
            presentation.menuInput.productStates[.codex] == codex.usageState,
            "Expected partial quota value preserved"
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
                    .codex: issue
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
            "Expected loading for Codex"
        )
        try expect(presentation.discoveredQuotaIDs.isEmpty, "Expected no invented quotas")
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
