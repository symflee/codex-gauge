import CodexGaugeCore
import Foundation

func displayFrameFormatterTests() -> [TestCase] {
    [
        codexFreshTitleTest(),
        sparkFreshTitleTest(),
        sameDurationComparisonTitleTest(),
        mixedDurationComparisonTitleTest(),
        staleTitleTest(),
        loadingTitleTest(),
        unavailableTitleTest(),
        independentComparisonTitleTest()
    ]
}

private func codexFreshTitleTest() -> TestCase {
    TestCase(name: "formatter renders Codex fresh title") {
        let item = formatterItem(product: .codex, duration: 300, value: .fresh(83))
        let output = DisplayFrameFormatter().format(.single(item))

        try expect(output.title == "[5h] 83%", "Unexpected Codex title")
    }
}

private func sparkFreshTitleTest() -> TestCase {
    TestCase(name: "formatter renders Spark fresh title") {
        let item = formatterItem(product: .spark, duration: 300, value: .fresh(91))
        let output = DisplayFrameFormatter().format(.single(item))

        try expect(output.title == "S[5h] 91%", "Unexpected Spark title")
    }
}

private func sameDurationComparisonTitleTest() -> TestCase {
    TestCase(name: "formatter shares badge for equal comparison durations") {
        let codex = formatterItem(product: .codex, duration: 10_080, value: .fresh(75))
        let spark = formatterItem(product: .spark, duration: 10_080, value: .fresh(82))
        let output = DisplayFrameFormatter().format(.comparison(codex: codex, spark: spark))

        try expect(output.title == "[w] C75% · S82%", "Unexpected shared-duration title")
    }
}

private func mixedDurationComparisonTitleTest() -> TestCase {
    TestCase(name: "formatter keeps both badges for mixed durations") {
        let codex = formatterItem(product: .codex, duration: 300, value: .fresh(75))
        let spark = formatterItem(product: .spark, duration: 10_080, value: .fresh(82))
        let output = DisplayFrameFormatter().format(.comparison(codex: codex, spark: spark))

        try expect(output.title == "C[5h]75% · S[w]82%", "Unexpected mixed-duration title")
    }
}

private func staleTitleTest() -> TestCase {
    TestCase(name: "formatter marks a stale value with tilde") {
        let item = formatterItem(product: .codex, duration: 300, value: .stale(83))
        let output = DisplayFrameFormatter().format(.single(item))

        try expect(output.title == "[5h] ~83%", "Unexpected stale title")
    }
}

private func loadingTitleTest() -> TestCase {
    TestCase(name: "formatter renders loading without animation") {
        let item = formatterItem(product: .codex, duration: 300, value: .loading)
        let output = DisplayFrameFormatter().format(.single(item))

        try expect(output.title == "[5h] …", "Unexpected loading title")
    }
}

private func unavailableTitleTest() -> TestCase {
    TestCase(name: "formatter renders unavailable without zero") {
        let item = formatterItem(product: .codex, duration: 300, value: .unavailable)
        let output = DisplayFrameFormatter().format(.single(item))

        try expect(output.title == "[5h] —", "Unexpected unavailable title")
    }
}

private func independentComparisonTitleTest() -> TestCase {
    TestCase(name: "formatter keeps comparison product states independent") {
        let codex = formatterItem(product: .codex, duration: 300, value: .stale(75))
        let spark = formatterItem(product: .spark, duration: 300, value: .unavailable)
        let output = DisplayFrameFormatter().format(.comparison(codex: codex, spark: spark))

        try expect(output.title == "[5h] C~75% · S—", "Unexpected independent comparison title")
    }
}

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
