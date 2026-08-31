import CodexGaugeAppKit

func applicationActivityGateTests() -> [TestCase] {
    [
        applicationActivitySuspendsOnlyForFirstReasonTest(),
        applicationActivityResumesOnlyAfterLastReasonTest(),
        applicationActivityIgnoresDuplicateEventsTest()
    ]
}

private func applicationActivitySuspendsOnlyForFirstReasonTest() -> TestCase {
    TestCase(name: "application activity suspends once across overlapping reasons") {
        let reducer = ApplicationActivityReducer()
        let sleeping = reducer.reduce(state: .active, event: .began(.sleep))
        let alsoLocked = reducer.reduce(
            state: sleeping.state,
            event: .began(.sessionLocked)
        )

        try expect(sleeping.command == .suspend, "Expected first reason to suspend")
        try expect(alsoLocked.command == nil, "Expected no duplicate suspension")
        try expect(
            alsoLocked.state.reasons == [.sleep, .sessionLocked],
            "Expected both reasons retained"
        )
    }
}

private func applicationActivityResumesOnlyAfterLastReasonTest() -> TestCase {
    TestCase(name: "application activity resumes after every reason ends") {
        let reducer = ApplicationActivityReducer()
        let suspended = ApplicationActivityState(
            reasons: [.sleep, .sessionLocked]
        )
        let awake = reducer.reduce(state: suspended, event: .ended(.sleep))
        let unlocked = reducer.reduce(
            state: awake.state,
            event: .ended(.sessionLocked)
        )

        try expect(awake.command == nil, "Expected lock to keep activity suspended")
        try expect(unlocked.command == .resume, "Expected final reason to resume")
        try expect(unlocked.state == .active, "Expected active state")
    }
}

private func applicationActivityIgnoresDuplicateEventsTest() -> TestCase {
    TestCase(name: "application activity ignores duplicate begin and end events") {
        let reducer = ApplicationActivityReducer()
        let sleeping = ApplicationActivityState(reasons: [.sleep])
        let duplicate = reducer.reduce(state: sleeping, event: .began(.sleep))
        let irrelevantEnd = reducer.reduce(
            state: sleeping,
            event: .ended(.sessionLocked)
        )

        try expect(duplicate == ApplicationActivityTransition(state: sleeping), "Expected duplicate ignored")
        try expect(
            irrelevantEnd == ApplicationActivityTransition(state: sleeping),
            "Expected missing reason end ignored"
        )
    }
}
