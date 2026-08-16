import AppKit
import CodexGaugeAppKit
import CodexGaugeCore

func quotaDetailsMenuTests() -> [TestCase] {
    [
        quotaMenuGroupsAllWindowsTest(),
        quotaMenuShowsSpendControlDetailsTest(),
        quotaMenuExplainsIncompleteSpendControlTest(),
        quotaMenuKeepsIndependentFailureStatesTest(),
        quotaMenuSelectsConnectionActionTest(),
        quotaMenuAdapterUsesCachedModelTest(),
        quotaMenuDispatchesInjectedActionsTest()
    ]
}

private func quotaMenuShowsSpendControlDetailsTest() -> TestCase {
    TestCase(name: "quota menu shows product spend controls outside quota rows") {
        let input = QuotaDetailsMenuInput(
            productStates: [
                .codex: .value(
                    ProductQuotaValue(
                        capturedAt: Date(timeIntervalSince1970: 1_900_000_000),
                        quotaWindows: [try menuQuota(slot: .primary, used: 17, duration: 300)]
                    ),
                    freshness: .fresh
                ),
                .spark: .value(
                    ProductQuotaValue(
                        capturedAt: Date(timeIntervalSince1970: 1_900_000_000),
                        quotaWindows: [try menuQuota(slot: .primary, used: 9, duration: 300)]
                    ),
                    freshness: .fresh
                )
            ],
            spendControlsByProduct: [
                .codex: .reached,
                .spark: .remaining(percent: 72)
            ],
            codexAvailability: .available
        )

        let sections = menuBuilder().build(input).productSections

        try expect(sections[0].quotaRows == [
            "[5h] · 83% remaining · reset unavailable"
        ], "Expected Codex quota row to remain unchanged")
        try expect(
            sections[0].spendControlRows == ["Spend limit reached"],
            "Expected reached spend control in a separate row"
        )
        try expect(sections[1].quotaRows == [
            "[5h] · 91% remaining · reset unavailable"
        ], "Expected Spark quota row to remain independent")
        try expect(
            sections[1].spendControlRows == ["Spend limit · 72% remaining"],
            "Expected Spark spend control to stay product-specific"
        )
    }
}

private func quotaMenuExplainsIncompleteSpendControlTest() -> TestCase {
    TestCase(name: "quota menu does not invent a missing spend percent") {
        let input = QuotaDetailsMenuInput(
            productStates: [.codex: .unavailable, .spark: .unavailable],
            spendControlsByProduct: [.codex: .notReachedWithoutRemainingPercent],
            codexAvailability: .available
        )

        let sections = menuBuilder().build(input).productSections

        try expect(
            sections[0].spendControlRows
                == ["Spend limit not reached · remaining percentage unavailable"],
            "Expected explicit incomplete spend-control wording"
        )
        try expect(
            sections[1].spendControlRows.isEmpty,
            "Expected a missing sibling spend control to stay absent"
        )
    }
}

private func quotaMenuGroupsAllWindowsTest() -> TestCase {
    TestCase(name: "quota menu groups every product window with absolute dates") {
        let capturedAt = Date(timeIntervalSince1970: 1_900_000_000)
        let codexWindows = [
            try menuQuota(slot: .secondary, used: 41, duration: 10_080),
            try menuQuota(
                slot: .primary,
                used: 17,
                duration: 300,
                reset: 1_900_003_600
            )
        ]
        let sparkWindows = [
            try menuQuota(
                slot: .primary,
                used: 9,
                duration: 300,
                reset: 1_900_007_200
            )
        ]
        let input = QuotaDetailsMenuInput(
            productStates: [
                .codex: .value(
                    ProductQuotaValue(capturedAt: capturedAt, quotaWindows: codexWindows),
                    freshness: .fresh
                ),
                .spark: .value(
                    ProductQuotaValue(capturedAt: capturedAt, quotaWindows: sparkWindows),
                    freshness: .fresh
                )
            ],
            codexAvailability: .available
        )

        let model = menuBuilder().build(input)

        try expect(model.productSections.map(\.product) == [.codex, .spark], "Expected groups")
        try expect(model.productSections[0].quotaRows == [
            "[5h] · 83% remaining · resets D1900003600",
            "[w] · 59% remaining · reset unavailable"
        ], "Expected every sorted Codex window")
        try expect(model.productSections[1].quotaRows == [
            "[5h] · 91% remaining · resets D1900007200"
        ], "Expected every Spark window")
        try expect(
            model.productSections[0].statusRows == ["Last success: D1900000000"],
            "Expected absolute last success"
        )
        try expect(
            model.actionGroups.flatMap { $0 }.map(\.action)
                == [.refresh, .openCodex, .settings, .quit],
            "Expected action order"
        )
        try expect(
            model.actionGroups.flatMap { $0 }.map(\.title)
                == ["Refresh", "Open Codex", "Settings…", "Quit Codex Gauge"],
            "Expected localized action titles"
        )
    }
}

private func quotaMenuKeepsIndependentFailureStatesTest() -> TestCase {
    TestCase(name: "quota menu preserves stale partial and unavailable reasons") {
        let staleValue = ProductQuotaValue(
            capturedAt: Date(timeIntervalSince1970: 1_900_000_100),
            quotaWindows: [try menuQuota(slot: .primary, used: 25, duration: 300)]
        )
        let input = QuotaDetailsMenuInput(
            productStates: [
                .codex: .value(staleValue, freshness: .stale),
                .spark: .unavailable
            ],
            issuesByProduct: [
                .codex: .timeout,
                .spark: .signedOut
            ],
            lastSuccessfulRefreshByProduct: [
                .spark: Date(timeIntervalSince1970: 1_900_000_050)
            ],
            codexAvailability: .available
        )

        let model = menuBuilder().build(input)
        let codex = model.productSections[0]
        let spark = model.productSections[1]

        try expect(codex.quotaRows == [
            "[5h] · 75% remaining · reset unavailable"
        ], "Expected stale cached quota")
        try expect(codex.statusRows == [
            "Last success: D1900000100",
            "Last value · Timed out"
        ], "Expected stale reason")
        try expect(spark.quotaRows.isEmpty, "Expected unavailable product without fake zero")
        try expect(spark.statusRows == [
            "Last success: D1900000050",
            "Sign in to Codex"
        ], "Expected independent unavailable reason")

        let partialInput = QuotaDetailsMenuInput(
            productStates: [.codex: .value(staleValue, freshness: .fresh)],
            issuesByProduct: [.codex: .partialData],
            codexAvailability: .available
        )
        let partial = menuBuilder().build(partialInput).productSections[0]
        try expect(partial.statusRows.last == "Some limits unavailable", "Expected partial state")
    }
}

private func quotaMenuSelectsConnectionActionTest() -> TestCase {
    TestCase(name: "quota menu shows loading and conditional select action") {
        let input = QuotaDetailsMenuInput(
            productStates: [.codex: .loading],
            issuesByProduct: [.spark: .codexNotFound],
            codexAvailability: .needsSelection
        )

        let model = menuBuilder().build(input)

        try expect(model.productSections[0].statusRows == ["Checking connection"], "Expected loading")
        try expect(model.productSections[1].statusRows == ["Codex not found"], "Expected absence")
        try expect(
            model.actionGroups.flatMap { $0 }.map(\.action)
                == [.refresh, .selectCodex, .settings, .quit],
            "Expected select action"
        )
    }
}

private func quotaMenuAdapterUsesCachedModelTest() -> TestCase {
    TestCase(name: "quota menu opens cached content and pauses status rotation") {
        try await MainActor.run {
            let statusPresenter = MenuStatusItemPresenter()
            let scheduler = MenuRotationScheduler()
            let statusController = StatusItemController(
                presenter: statusPresenter,
                scheduler: scheduler
            )
            statusController.setFrames(menuRotationFrames())
            let menuPresenter = RecordingStatusMenuPresenter()
            let formatterCalls = MenuCallRecorder()
            let builder = QuotaDetailsMenuModelBuilder(
                localization: menuLocalization(),
                dateFormatter: QuotaMenuDateFormatter { date in
                    formatterCalls.record("date")
                    return "D\(Int(date.timeIntervalSince1970))"
                }
            )
            let model = builder.build(QuotaDetailsMenuInput(
                productStates: [
                    .codex: .value(
                        ProductQuotaValue(
                            capturedAt: Date(timeIntervalSince1970: 1_900_000_000),
                            quotaWindows: []
                        ),
                        freshness: .fresh
                    )
                ],
                spendControlsByProduct: [.codex: .remaining(percent: 64)],
                codexAvailability: .available
            ))
            let actionCalls = MenuCallRecorder()
            let menuController = StatusMenuController(
                presenter: menuPresenter,
                statusItemController: statusController,
                actions: menuActions(recorder: actionCalls)
            )
            menuController.update(model)
            let formattingCount = formatterCalls.values.count
            guard let menu = menuPresenter.menu else {
                throw TestFailure(description: "Expected attached menu")
            }
            let titlesBeforeOpening = menu.items.map(\.title)
            try expect(
                titlesBeforeOpening.contains("Spend limit · 64% remaining"),
                "Expected the cached AppKit menu to contain the separate spend row"
            )

            menuController.menuWillOpen(menu)
            try expect(scheduler.cancelCount == 1, "Expected menu-open pause")
            menuController.menuDidClose(menu)
            guard let refreshItem = menu.items.first(where: { item in
                item.representedObject as? String == QuotaMenuAction.refresh.rawValue
            }) else {
                throw TestFailure(description: "Expected refresh action item")
            }
            try expect(refreshItem.target === menuController, "Expected controller action target")
            try expect(refreshItem.action != nil, "Expected selector-backed action item")
            menuController.perform(.refresh)

            try expect(scheduler.scheduleCount == 2, "Expected fresh rotation on close")
            try expect(menu.items.map(\.title) == titlesBeforeOpening, "Expected cached menu")
            try expect(formatterCalls.values.count == formattingCount, "Expected no open formatting")
            try expect(statusPresenter.inputOutputCount == 0, "Expected no menu I/O")
            try expect(actionCalls.values == ["refresh"], "Expected wired menu action")
        }
    }
}

private func quotaMenuDispatchesInjectedActionsTest() -> TestCase {
    TestCase(name: "quota menu dispatches every injected action closure") {
        try await MainActor.run {
            let recorder = MenuCallRecorder()
            let actions = menuActions(recorder: recorder)

            QuotaMenuAction.allCases.forEach(actions.perform)

            try expect(
                recorder.values == ["refresh", "open", "select", "settings", "quit"],
                "Expected action closure dispatch"
            )
        }
    }
}

private func menuBuilder() -> QuotaDetailsMenuModelBuilder {
    QuotaDetailsMenuModelBuilder(
        localization: menuLocalization(),
        dateFormatter: QuotaMenuDateFormatter { date in
            "D\(Int(date.timeIntervalSince1970))"
        }
    )
}

private func menuLocalization() -> QuotaMenuLocalization {
    let values = [
        "menu.product.codex": "Codex",
        "menu.product.spark": "Spark",
        "menu.quota.with_reset": "[{duration}] · {remaining}% remaining · resets {reset}",
        "menu.quota.without_reset": "[{duration}] · {remaining}% remaining · reset unavailable",
        "menu.spend_control.reached": "Spend limit reached",
        "menu.spend_control.remaining": "Spend limit · {remaining}% remaining",
        "menu.spend_control.not_reached_without_remaining":
            "Spend limit not reached · remaining percentage unavailable",
        "menu.last_success": "Last success: {date}",
        "menu.status.loading": "Checking connection",
        "menu.status.unavailable": "Usage unavailable",
        "menu.status.partial": "Some limits unavailable",
        "menu.status.refresh_failed": "Refresh failed",
        "menu.status.timeout": "Timed out",
        "menu.status.signed_out": "Sign in to Codex",
        "menu.status.codex_not_found": "Codex not found",
        "menu.status.incompatible_protocol": "Unsupported Codex version",
        "menu.status.unsupported_account": "Unsupported account",
        "menu.status.stale": "Last value · {reason}",
        "menu.action.refresh": "Refresh",
        "menu.action.open_codex": "Open Codex",
        "menu.action.select_codex": "Select Codex…",
        "menu.action.settings": "Settings…",
        "menu.quit": "Quit Codex Gauge"
    ]
    return QuotaMenuLocalization { key in
        values[key] ?? key
    }
}

private func menuQuota(
    slot: QuotaSlot,
    used: Double,
    duration: Int?,
    reset: TimeInterval? = nil
) throws -> QuotaWindow {
    guard let quota = QuotaWindow(
        slot: slot,
        usedPercent: used,
        windowDurationMinutes: duration,
        resetUnixSeconds: reset
    ) else {
        throw TestFailure(description: "Expected synthetic quota")
    }
    return quota
}

private func menuRotationFrames() -> [DisplayFrame] {
    [
        menuFrame(duration: 300, value: .fresh(83)),
        menuFrame(duration: 10_080, value: .fresh(82))
    ]
}

private func menuFrame(duration: Int?, value: DisplayValueState) -> DisplayFrame {
    .single(DisplayQuota(
        identifier: QuotaSelectionID(product: .codex, rawDurationMinutes: duration),
        value: value
    ))
}

@MainActor
private func menuActions(recorder: MenuCallRecorder) -> StatusMenuActions {
    StatusMenuActions(
        refresh: { recorder.record("refresh") },
        openCodex: { recorder.record("open") },
        selectCodex: { recorder.record("select") },
        settings: { recorder.record("settings") },
        quit: { recorder.record("quit") }
    )
}

@MainActor
private final class MenuCallRecorder {
    private(set) var values: [String] = []

    func record(_ value: String) {
        values.append(value)
    }
}

@MainActor
private final class RecordingStatusMenuPresenter: StatusMenuPresenting {
    private(set) var menu: NSMenu?

    func setMenu(_ menu: NSMenu) {
        self.menu = menu
    }
}

@MainActor
private final class MenuStatusItemPresenter: StatusItemPresenting {
    let effectiveAppearance = NSAppearance(named: .aqua)
    private(set) var inputOutputCount = 0

    func setLength(_ length: CGFloat) {
        _ = length
    }

    func present(_ frame: RenderedStatusFrame) {
        _ = frame
    }
}

@MainActor
private final class MenuRotationScheduler: StatusRotationScheduling {
    private(set) var scheduleCount = 0
    private(set) var cancelCount = 0
    private var action: (@MainActor () -> Void)?

    func schedule(
        interval: TimeInterval,
        tolerance: TimeInterval,
        action: @escaping @MainActor () -> Void
    ) {
        _ = interval
        _ = tolerance
        scheduleCount += 1
        self.action = action
    }

    func cancel() {
        cancelCount += 1
        action = nil
    }
}
