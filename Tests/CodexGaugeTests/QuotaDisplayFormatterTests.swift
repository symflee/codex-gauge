import CodexGaugeCore
import Foundation

func displayFrameFormatterTests() -> [TestCase] {
    [
        singleFrameFormattingTest(),
        comparisonFrameFormattingTest()
    ]
}

private func singleFrameFormattingTest() -> TestCase {
    TestCase(name: "formatter renders every single-frame value state") {
        for (product, value, expected) in singleFormatterExpectations {
            let item = formatterItem(product: product, duration: 300, value: value)
            let output = DisplayFrameFormatter().format(.single(item))
            try expect(output.title == expected, "Unexpected single-frame title")
        }
    }
}

private func comparisonFrameFormattingTest() -> TestCase {
    TestCase(name: "formatter renders shared mixed and independent comparisons") {
        for (codex, spark, expected) in comparisonFormatterExpectations {
            let frame = DisplayFrame.comparison(codex: codex, spark: spark)
            let output = DisplayFrameFormatter().format(frame)
            try expect(output.title == expected, "Unexpected comparison title")
        }
    }
}

private let singleFormatterExpectations: [(UsageProduct, DisplayValueState, String)] = [
    (.codex, .fresh(83), "[5h] 83%"),
    (.spark, .fresh(91), "S[5h] 91%"),
    (.codex, .stale(83), "[5h] ~83%"),
    (.codex, .loading, "[5h] …"),
    (.codex, .unavailable, "[5h] —")
]

private let comparisonFormatterExpectations: [(DisplayQuota, DisplayQuota, String)] = [
    (
        formatterItem(product: .codex, duration: 10_080, value: .fresh(75)),
        formatterItem(product: .spark, duration: 10_080, value: .fresh(82)),
        "[w] C75% · S82%"
    ),
    (
        formatterItem(product: .codex, duration: 300, value: .fresh(75)),
        formatterItem(product: .spark, duration: 10_080, value: .fresh(82)),
        "C[5h]75% · S[w]82%"
    ),
    (
        formatterItem(product: .codex, duration: 300, value: .stale(75)),
        formatterItem(product: .spark, duration: 300, value: .unavailable),
        "[5h] C~75% · S—"
    )
]

private func formatterItem(
    product: UsageProduct,
    duration: Int?,
    value: DisplayValueState
) -> DisplayQuota {
    DisplayQuota(
        identifier: QuotaSelectionID(
            product: product,
            rawDurationMinutes: duration
        ),
        value: value
    )
}
