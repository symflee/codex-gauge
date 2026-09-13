import CodexGaugeCore
import Foundation

func displayFrameFormatterTests() -> [TestCase] {
    [
        singleFrameFormattingTest(),
        unknownDurationFormattingTest()
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

private func unknownDurationFormattingTest() -> TestCase {
    TestCase(name: "formatter keeps unknown duration in semantic title") {
        let quota = formatterItem(product: .codex, duration: nil, value: .unavailable)
        try expect(DisplayFrameFormatter().format(.single(quota)).title == "[?] —", "Expected honest unknown duration")
    }
}

private let singleFormatterExpectations: [(UsageProduct, DisplayValueState, String)] = [
    (.codex, .fresh(83), "[5h] 83%"),
    (.codex, .stale(83), "[5h] ~83%"),
    (.codex, .loading, "[5h] …"),
    (.codex, .unavailable, "[5h] —")
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
