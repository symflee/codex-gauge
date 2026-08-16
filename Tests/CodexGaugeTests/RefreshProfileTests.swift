import CodexGaugeRefresh

func refreshTests() -> [TestCase] {
    refreshProfileTests()
        + adaptiveRefreshReducerTests()
        + refreshCoordinatorTests()
}

private func refreshProfileTests() -> [TestCase] {
    [
        refreshProfileIntervalsTest(),
        lowPowerIntervalsTest(),
        refreshProfileDefaultsAndSendabilityTest()
    ]
}

private func refreshProfileIntervalsTest() -> TestCase {
    TestCase(name: "refresh profiles expose exact normal and burst intervals") {
        try expect(
            RefreshProfile.manual.intervals == RefreshIntervals(normal: nil, burst: nil),
            "Unexpected manual intervals"
        )
        try expect(
            RefreshProfile.eco.intervals == RefreshIntervals(
                normal: .seconds(600),
                burst: .seconds(60)
            ),
            "Unexpected eco intervals"
        )
        try expect(
            RefreshProfile.balanced.intervals == RefreshIntervals(
                normal: .seconds(180),
                burst: .seconds(20)
            ),
            "Unexpected balanced intervals"
        )
        try expect(
            RefreshProfile.fast.intervals == RefreshIntervals(
                normal: .seconds(60),
                burst: .seconds(10)
            ),
            "Unexpected fast intervals"
        )
    }
}

private func lowPowerIntervalsTest() -> TestCase {
    TestCase(name: "low power clamps automatic refresh intervals") {
        let manual = RefreshProfile.manual.effectiveIntervals(lowPowerModeEnabled: true)
        let eco = RefreshProfile.eco.effectiveIntervals(lowPowerModeEnabled: true)
        let balanced = RefreshProfile.balanced.effectiveIntervals(lowPowerModeEnabled: true)
        let fast = RefreshProfile.fast.effectiveIntervals(lowPowerModeEnabled: true)

        let clamped = RefreshIntervals(
            normal: .seconds(600),
            burst: .seconds(60)
        )
        try expect(manual == RefreshIntervals(normal: nil, burst: nil), "Expected manual unchanged")
        try expect(eco == clamped, "Expected eco unchanged")
        try expect(balanced == clamped, "Expected balance clamp")
        try expect(fast == clamped, "Expected fast clamp")
    }
}

private func refreshProfileDefaultsAndSendabilityTest() -> TestCase {
    TestCase(name: "balanced is the sendable default refresh profile") {
        let state = RefreshState()

        requireRefreshSendable(RefreshProfile.default)
        requireRefreshSendable(state)
        try expect(RefreshProfile.default == .balanced, "Expected balanced profile default")
        try expect(state.profile == .balanced, "Expected balanced state default")
    }
}

private func requireRefreshSendable<Value: Sendable>(_ value: Value) {
    _ = value
}
