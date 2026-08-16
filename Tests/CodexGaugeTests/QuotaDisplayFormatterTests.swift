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
    TestCase(name: "formatter renders Codex fresh title and accessibility") {
        let item = formatterItem(product: .codex, duration: 300, value: .fresh(83))
        let output = DisplayFrameFormatter().format(.single(item))

        try expect(output.title == "[5h] 83%", "Unexpected Codex title")
        try expect(
            output.accessibilityLabel == "Codex 5시간 한도 남은 사용량 83퍼센트",
            "Unexpected Codex accessibility label"
        )
    }
}

private func sparkFreshTitleTest() -> TestCase {
    TestCase(name: "formatter renders Spark fresh title") {
        let item = formatterItem(product: .spark, duration: 300, value: .fresh(91))
        let output = DisplayFrameFormatter().format(.single(item))

        try expect(output.title == "S[5h] 91%", "Unexpected Spark title")
        try expect(
            output.accessibilityLabel == "Spark 5시간 한도 남은 사용량 91퍼센트",
            "Unexpected Spark accessibility label"
        )
    }
}

private func sameDurationComparisonTitleTest() -> TestCase {
    TestCase(name: "formatter shares badge for equal comparison durations") {
        let codex = formatterItem(product: .codex, duration: 10_080, value: .fresh(75))
        let spark = formatterItem(product: .spark, duration: 10_080, value: .fresh(82))
        let output = DisplayFrameFormatter().format(.comparison(codex: codex, spark: spark))

        try expect(output.title == "[w] C75% · S82%", "Unexpected shared-duration title")
        try expect(
            output.accessibilityLabel
                == "Codex 1주 한도 남은 사용량 75퍼센트, Spark 1주 한도 남은 사용량 82퍼센트",
            "Unexpected comparison accessibility label"
        )
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
        try expect(
            output.accessibilityLabel == "Codex 5시간 한도 남은 사용량 마지막 확인값 83퍼센트",
            "Unexpected stale accessibility label"
        )
    }
}

private func loadingTitleTest() -> TestCase {
    TestCase(name: "formatter renders loading without animation") {
        let item = formatterItem(product: .codex, duration: 300, value: .loading)
        let output = DisplayFrameFormatter().format(.single(item))

        try expect(output.title == "[5h] …", "Unexpected loading title")
        try expect(
            output.accessibilityLabel == "Codex 5시간 한도 사용량 확인 중",
            "Unexpected loading accessibility label"
        )
    }
}

private func unavailableTitleTest() -> TestCase {
    TestCase(name: "formatter renders unavailable without zero") {
        let item = formatterItem(product: .codex, duration: 300, value: .unavailable)
        let output = DisplayFrameFormatter().format(.single(item))

        try expect(output.title == "[5h] —", "Unexpected unavailable title")
        try expect(
            output.accessibilityLabel == "Codex 5시간 한도 사용량 확인 불가",
            "Unexpected unavailable accessibility label"
        )
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
