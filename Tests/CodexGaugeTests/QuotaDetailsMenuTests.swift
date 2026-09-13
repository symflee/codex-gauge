import AppKit
import CodexGaugeAppKit
import CodexGaugeCore
import CodexGaugeSettings

func quotaDetailsMenuTests() -> [TestCase] {
    [
        quotaMenuExplicitLanguageFactoryTest(),
        quotaMenuLocalizedDateLocaleTest(),
        quotaMenuGroupsAllWindowsTest(),
        quotaMenuExpiresValuesWithToolbarValidityPolicyTest(),
        quotaMenuShowsSpendControlDetailsTest(),
        quotaMenuExplainsIncompleteSpendControlTest(),
        quotaMenuKeepsIndependentFailureStatesTest(),
        quotaMenuSelectsConnectionActionTest(),
        quotaMenuReflectsApplicationUpdateAvailabilityTest(),
        quotaMenuAdapterUsesCachedModelTest(),
        quotaMenuCachesIndependentRowsTest(),
        quotaMenuPreservesNativeRowIdentityTest(),
        quotaMenuDefersClosedUpdatesTest(),
        quotaMenuDispatchesInjectedActionsTest()
    ]
}

private func quotaMenuDefersClosedUpdatesTest() -> TestCase {
    TestCase(name: "quota native menu defers one thousand closed providers and reuses open rows") {
        try await MainActor.run {
            let presenter = RecordingStatusMenuPresenter()
            let controller = StatusMenuController(
                presenter: presenter,
                actions: menuActions(recorder: MenuCallRecorder())
            )
            // Exercise the production protocol witness, not only the controller API.
            let runtime: any ApplicationMenuRuntime = StatusMenuRuntimeAdapter(controller: controller)
            let calls = MenuCallRecorder()
            let builder = QuotaDetailsMenuModelBuilder(
                localization: menuLocalization(),
                dateFormatter: QuotaMenuDateFormatter { date in
                    calls.record("date")
                    return "D\(Int(date.timeIntervalSince1970))"
                }
            )
            var cache = QuotaDetailsMenuModelCache()
            let captured = Date(timeIntervalSince1970: 1_900_000_000)
            let quota = try menuQuota(slot: .primary, used: 17, duration: 300,
                                      reset: captured.addingTimeInterval(3_600).timeIntervalSince1970)
            func input(_ index: Int, includeQuota: Bool = true) -> QuotaDetailsMenuInput {
                QuotaDetailsMenuInput(
                    productStates: [.codex: .value(ProductQuotaValue(
                        capturedAt: captured, quotaWindows: includeQuota ? [quota] : []
                    ), freshness: .fresh)],
                    lastSuccessfulRefreshByProduct: [.codex: captured.addingTimeInterval(Double(index))],
                    codexAvailability: .available, currentDate: captured
                )
            }
            var providerCalls: [Int] = []
            weak var previousCapture: MenuDeferredCapture?
            for index in 0..<1_000 {
                let capture = MenuDeferredCapture(index: index)
                runtime.updateDeferred {
                    providerCalls.append(capture.index)
                    return cache.build(input(capture.index), using: builder)
                }
                try expect(previousCapture == nil, "Expected obsolete provider captures released immediately")
                previousCapture = capture
            }
            guard let menu = presenter.menu else { throw TestFailure(description: "Expected attached menu") }
            try expect(providerCalls.isEmpty && calls.values.isEmpty, "Expected no closed model building or date formatting")
            try expect(menu.items.isEmpty, "Expected no native rows before first request")
            try expect(previousCapture != nil, "Expected only the latest provider retained")

            controller.menuNeedsUpdate(menu)
            try expect(providerCalls == [999], "Expected exactly the latest provider at first request")
            try expect(previousCapture == nil, "Expected provider capture released after materialization")
            let items = menu.items
            try expect(items.count > 2, "Expected product, quota, and success rows")
            try expect(items[2].title == "Last success: D1900000999", "Expected latest cached publication")
            let formatCount = calls.values.count
            controller.menuWillOpen(menu)
            controller.menuDidClose(menu)
            controller.menuNeedsUpdate(menu)
            controller.menuWillOpen(menu)
            try expect(providerCalls == [999] && calls.values.count == formatCount, "Expected unchanged reopening without rebuilding")
            try expect(zip(items, menu.items).allSatisfy { pair in pair.0 === pair.1 }, "Expected unchanged native items")

            runtime.updateDeferred {
                providerCalls.append(1_000)
                return cache.build(input(1_000), using: builder)
            }
            try expect(providerCalls == [999, 1_000], "Expected immediate incremental update while tracking")
            try expect(items[2].title == "Last success: D1900001000", "Expected changed status row in place")
            try expect(calls.values.count == formatCount + 1, "Expected only the changed success date formatted")
            try expect(zip(items, menu.items).allSatisfy { pair in pair.0 === pair.1 }, "Expected no native row replacement for a value change")

            controller.menuDidClose(menu)
            runtime.updateDeferred {
                providerCalls.append(1_001)
                return cache.build(input(1_001, includeQuota: false), using: builder)
            }
            try expect(providerCalls == [999, 1_000], "Expected updates deferred again after close")
            try expect(menu.items[1] === items[1], "Expected closed native rows left intact")
            controller.menuNeedsUpdate(menu)
            try expect(providerCalls == [999, 1_000, 1_001], "Expected one latest model on reopening")
            try expect(menu.items[1] === items[2], "Expected status identity after preceding quota removal")
            try expect(menu.items.last === items.last, "Expected stable action identity across deferred structural change")
            try expect(items[1].menu == nil, "Expected obsolete native quota row detached")
        }
    }
}

private final class MenuDeferredCapture {
    let index: Int
    init(index: Int) { self.index = index }
}

private func quotaMenuCachesIndependentRowsTest() -> TestCase {
    TestCase(name: "quota menu caches semantic rows and still expires exact boundaries") {
        try await MainActor.run {
            let calls = MenuCallRecorder()
            let builder = QuotaDetailsMenuModelBuilder(
                localization: menuLocalization(),
                dateFormatter: QuotaMenuDateFormatter { date in
                    calls.record("date")
                    return "D\(Int(date.timeIntervalSince1970))"
                }
            )
            var cache = QuotaDetailsMenuModelCache()
            let captured = Date(timeIntervalSince1970: 1_900_000_000)
            let reset = captured.addingTimeInterval(3_600)
            let quota = try menuQuota(slot: .primary, used: 17, duration: 300,
                                      reset: reset.timeIntervalSince1970)
            func input(success: Date, now: Date) -> QuotaDetailsMenuInput {
                QuotaDetailsMenuInput(
                    productStates: [.codex: .value(ProductQuotaValue(
                        capturedAt: success, quotaWindows: [quota]
                    ), freshness: .fresh)],
                    codexAvailability: .available, currentDate: now
                )
            }
            let original = cache.build(input(success: captured, now: captured), using: builder)
            let initialCalls = calls.values.count
            for index in 1...100 {
                let repeated = cache.build(input(success: captured, now: captured.addingTimeInterval(Double(index))), using: builder)
                try expect(repeated == original, "Expected wall clock movement without expiry to reuse the model")
            }
            try expect(calls.values.count == initialCalls, "Expected no repeated formatting")
            let later = captured.addingTimeInterval(180)
            let changed = cache.build(input(success: later, now: later), using: builder)
            try expect(calls.values.count == initialCalls + 1, "Expected only last-success date formatting")
            try expect(changed.productSections[0].quotaRows == original.productSections[0].quotaRows, "Expected retained quota rows")
            let expired = cache.build(input(success: later, now: reset), using: builder)
            try expect(expired.productSections[0].quotaRows[0].contains("refresh required"), "Expected exact reset expiry")
            try expect(expired.productSections[0].quotaRowIDs == original.productSections[0].quotaRowIDs, "Expected stable quota identity at expiry")
            let backwards = cache.build(input(success: later, now: reset.addingTimeInterval(-1)), using: builder)
            try expect(backwards.productSections[0].quotaRows == original.productSections[0].quotaRows, "Expected backward clock changes to reevaluate validity")
            let relocalized = cache.build(input(success: later, now: later), using: .bundled(language: .korean))
            try expect(relocalized.actionGroups[0][0].title != original.actionGroups[0][0].title, "Expected a changed builder to invalidate localized text")
        }
    }
}

private func quotaMenuPreservesNativeRowIdentityTest() -> TestCase {
    TestCase(name: "quota menu mutates changed rows and preserves unrelated native items") {
        try await MainActor.run {
            let presenter = RecordingStatusMenuPresenter()
            let controller = StatusMenuController(
                presenter: presenter,
                actions: menuActions(recorder: MenuCallRecorder())
            )
            func model(success: String, includeQuota: Bool, available: Bool) -> QuotaDetailsMenuModel {
                QuotaDetailsMenuModel(productSections: [QuotaMenuProductSection(
                    product: .codex, title: "Codex",
                    quotaRows: includeQuota ? ["83%"] : [], spendControlRows: [],
                    statusRows: [success], quotaRowIDs: includeQuota ? ["primary"] : [],
                    statusRowIDs: ["last-success"]
                )], actionGroups: [[QuotaMenuActionItem(action: .refresh, title: "Refresh"),
                                     QuotaMenuActionItem(action: .checkForUpdates, title: "Update", isEnabled: available)]])
            }
            let initial = model(success: "first", includeQuota: true, available: false)
            controller.update(initial)
            guard let menu = presenter.menu else { throw TestFailure(description: "Expected native menu") }
            let items = menu.items
            controller.update(initial)
            try expect(zip(items, menu.items).allSatisfy { pair in pair.0 === pair.1 }, "Expected identical publication to retain every native item")
            controller.update(model(success: "later", includeQuota: true, available: true))
            try expect(zip(items, menu.items).allSatisfy { pair in pair.0 === pair.1 }, "Expected only row properties to change")
            try expect(items[2].title == "later", "Expected updated success title on the same item")
            try expect(items.last?.isEnabled == true, "Expected updated action availability")
            controller.update(model(success: "later", includeQuota: false, available: true))
            try expect(menu.items[1] === items[2], "Expected last-success identity to survive removal before it")
            try expect(menu.items.last === items.last, "Expected stable action identity across structural changes")
            try expect(items[1].menu == nil, "Expected obsolete quota row removed")
        }
    }
}

private func quotaMenuExplicitLanguageFactoryTest() -> TestCase {
    TestCase(name: "quota menu factory resolves an explicit application language") {
        let input = QuotaDetailsMenuInput(
            productStates: [.codex: .loading],
            codexAvailability: .needsSelection,
            currentDate: Date(timeIntervalSince1970: 1_900_000_000)
        )

        let korean = QuotaDetailsMenuModelBuilder
            .bundled(language: .korean)
            .build(input)
        let english = QuotaDetailsMenuModelBuilder
            .bundled(language: .english)
            .build(input)

        try expect(
            korean.productSections[0].statusRows == ["연결 확인 중"],
            "Expected Korean menu content"
        )
        try expect(
            korean.actionGroups.flatMap { $0 }.map(\.title)
                == [
                    "새로 고침", "Codex 선택…",
                    "현재 버전: v? (최신 확인 불가)", "설정…",
                    "Codex Gauge 종료"
                ],
            "Expected Korean menu actions"
        )
        try expect(
            english.productSections[0].statusRows == ["Checking connection"],
            "Expected English menu content"
        )
        try expect(
            english.actionGroups.flatMap { $0 }.map(\.title)
                == [
                    "Refresh", "Select Codex…",
                    "Current version: v? (latest unavailable)", "Settings…",
                    "Quit Codex Gauge"
                ],
            "Expected English menu actions"
        )
    }
}

private func quotaMenuLocalizedDateLocaleTest() -> TestCase {
    TestCase(name: "quota menu dates follow the selected application language locale") {
        guard let timeZone = TimeZone(secondsFromGMT: 0) else {
            throw TestFailure(description: "Expected a GMT time zone")
        }
        let date = Date(timeIntervalSince1970: 1_900_003_600)
        let korean = QuotaMenuDateFormatter.localized(
            language: .korean,
            timeZone: timeZone
        ).string(from: date)
        let english = QuotaMenuDateFormatter.localized(
            language: .english,
            timeZone: timeZone
        ).string(from: date)

        try expect(korean != english, "Expected language-specific date formatting")
        try expect(containsHangul(korean), "Expected a Korean-localized date")
        try expect(!containsHangul(english), "Expected an English-localized date")
    }
}

private func containsHangul(_ value: String) -> Bool {
    value.unicodeScalars.contains { scalar in
        (0xAC00...0xD7A3).contains(Int(scalar.value))
    }
}

private func quotaMenuExpiresValuesWithToolbarValidityPolicyTest() -> TestCase {
    TestCase(name: "quota menu and toolbar expire values at the same exact boundaries") {
        let currentDate = Date(timeIntervalSince1970: 1_900_100_000)
        let expiredAtReset = try menuQuota(
            slot: .primary,
            used: 17,
            duration: 300,
            reset: currentDate.timeIntervalSince1970
        )
        let validWindow = try menuQuota(
            slot: .secondary,
            used: 41,
            duration: 10_080,
            reset: currentDate.timeIntervalSince1970 + 3_600
        )
        let freshValue = ProductQuotaValue(
            capturedAt: currentDate,
            quotaWindows: [expiredAtReset, validWindow]
        )
        let freshInput = QuotaDetailsMenuInput(
            productStates: [.codex: .value(freshValue, freshness: .fresh)],
            spendControlsByProduct: [.codex: .remaining(percent: 64)],
            lastSuccessfulRefreshByProduct: [.codex: currentDate],
            codexAvailability: .available,
            currentDate: currentDate
        )

        let freshSection = menuBuilder().build(freshInput).productSections[0]
        let freshFrame = DisplayFrameBuilder().makeFrames(
            preference: DisplayPreference(
                quotaSelection: .manual(
                    QuotaSelectionID(product: .codex, rawDurationMinutes: 300)
                )
            ),
            productStates: freshInput.productStates,
            now: currentDate
        )[0]

        try expect(freshSection.quotaRows == [
            "[5h] · — · resets D1900100000 · refresh required",
            "[w] · 59% remaining · resets D1900103600"
        ], "Expected only the reset-boundary window to lose its percentage")
        try expect(
            freshSection.spendControlRows == ["Spend limit · 64% remaining"],
            "Expected spend-control details to survive quota expiry"
        )
        try expect(
            freshSection.statusRows == ["Last success: D1900100000"],
            "Expected fresh last-success details to survive quota expiry"
        )
        try expect(
            singleMenuDisplayValue(freshFrame) == .unavailable,
            "Expected toolbar and menu to agree at the reset boundary"
        )

        let capturedAt = currentDate.addingTimeInterval(-86_400)
        let ageExpiredWindow = try menuQuota(
            slot: .primary,
            used: 25,
            duration: 300
        )
        let staleValue = ProductQuotaValue(
            capturedAt: capturedAt,
            quotaWindows: [ageExpiredWindow]
        )
        let staleInput = QuotaDetailsMenuInput(
            productStates: [.codex: .value(staleValue, freshness: .stale)],
            spendControlsByProduct: [.codex: .reached],
            issuesByProduct: [.codex: .timeout],
            lastSuccessfulRefreshByProduct: [.codex: capturedAt],
            codexAvailability: .needsSelection,
            currentDate: currentDate
        )

        let staleModel = menuBuilder().build(staleInput)
        let staleSection = staleModel.productSections[0]
        let staleFrame = DisplayFrameBuilder().makeFrames(
            preference: DisplayPreference(
                quotaSelection: .automatic
            ),
            productStates: staleInput.productStates,
            now: currentDate
        )[0]

        try expect(staleSection.quotaRows == [
            "[5h] · — · refresh required"
        ], "Expected the exact 24-hour boundary to hide a stale percentage")
        try expect(
            staleSection.spendControlRows == ["Spend limit reached"],
            "Expected spend-control state to remain independent"
        )
        try expect(staleSection.statusRows == [
            "Last success: D1900013600",
            "Last value · Timed out"
        ], "Expected stale reason and last-success action context to remain")
        try expect(
            singleMenuDisplayValue(staleFrame) == .unavailable,
            "Expected toolbar and menu to agree at the age boundary"
        )
        try expect(
            staleModel.actionGroups.flatMap { $0 }.map(\.action)
                == [.refresh, .selectCodex, .checkForUpdates, .settings, .quit],
            "Expected refresh and recovery actions to remain available"
        )
    }
}

private func quotaMenuReflectsApplicationUpdateAvailabilityTest() -> TestCase {
    TestCase(name: "quota menu shows current and latest versions after the launch probe") {
        let input = QuotaDetailsMenuInput(
            productStates: [.codex: .loading],
            codexAvailability: .available,
            currentDate: Date(timeIntervalSince1970: 1_900_000_000)
        )
        let korean = QuotaDetailsMenuModelBuilder.bundled(language: .korean)
        let english = QuotaDetailsMenuModelBuilder.bundled(language: .english)
        let checking = korean.build(
            input,
            applicationUpdateState: ApplicationUpdateState(
                currentVersion: "1.2.0",
                status: .checking
            )
        )
        let current = korean.build(
            input,
            applicationUpdateState: ApplicationUpdateState(
                currentVersion: "1.2.0",
                status: .current(latestVersion: "1.2.0")
            )
        )
        let availableState = ApplicationUpdateState(
            currentVersion: "1.2.0",
            status: .updateAvailable(latestVersion: "1.3.0")
        )
        let available = korean.build(
            input,
            applicationUpdateState: availableState
        )
        let availableEnglish = english.build(
            input,
            applicationUpdateState: availableState
        )

        try expect(
            updateAction(in: checking)?.title
                == "현재 버전: v1.2.0 (최신 확인 중…)",
            "Expected launch-checking title"
        )
        try expect(
            updateAction(in: current)?.title
                == "현재 버전: v1.2.0 (최신 v1.2.0)",
            "Expected current version title"
        )
        try expect(
            updateAction(in: available)?.title
                == "현재 버전: v1.2.0 (최신 v1.3.0)",
            "Expected Korean available version title"
        )
        try expect(
            updateAction(in: availableEnglish)?.title
                == "Current version: v1.2.0 (latest v1.3.0)",
            "Expected English available version title"
        )
        try expect(updateAction(in: checking)?.isEnabled == false, "Expected disabled probe")
        try expect(updateAction(in: current)?.isEnabled == false, "Expected disabled current")
        try expect(updateAction(in: available)?.isEnabled == true, "Expected enabled update")
        try expect(
            available.actionGroups.map { $0.map(\.action) } == [
                [.refresh, .openCodex],
                [.checkForUpdates, .settings],
                [.quit]
            ],
            "Expected update and settings in their own action group"
        )
    }
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
                )
            ],
            spendControlsByProduct: [
                .codex: .reached
            ],
            codexAvailability: .available,
            currentDate: Date(timeIntervalSince1970: 1_900_000_000)
        )

        let sections = menuBuilder().build(input).productSections

        try expect(sections[0].quotaRows == [
            "[5h] · 83% remaining · reset unavailable"
        ], "Expected Codex quota row to remain unchanged")
        try expect(
            sections[0].spendControlRows == ["Spend limit reached"],
            "Expected reached spend control in a separate row"
        )
    }
}

private func quotaMenuExplainsIncompleteSpendControlTest() -> TestCase {
    TestCase(name: "quota menu does not invent a missing spend percent") {
        let input = QuotaDetailsMenuInput(
            productStates: [.codex: .unavailable],
            spendControlsByProduct: [.codex: .notReachedWithoutRemainingPercent],
            codexAvailability: .available,
            currentDate: Date(timeIntervalSince1970: 1_900_000_000)
        )

        let sections = menuBuilder().build(input).productSections

        try expect(
            sections[0].spendControlRows
                == ["Spend limit not reached · remaining percentage unavailable"],
            "Expected explicit incomplete spend-control wording"
        )
        try expect(sections.count == 1, "Expected only the Codex section")
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
        let input = QuotaDetailsMenuInput(
            productStates: [
                .codex: .value(
                    ProductQuotaValue(capturedAt: capturedAt, quotaWindows: codexWindows),
                    freshness: .fresh
                )
            ],
            codexAvailability: .available,
            currentDate: capturedAt
        )

        let model = menuBuilder().build(input)

        try expect(model.productSections.map(\.product) == [.codex], "Expected groups")
        try expect(model.productSections[0].quotaRows == [
            "[5h] · 83% remaining · resets D1900003600",
            "[w] · 59% remaining · reset unavailable"
        ], "Expected every sorted Codex window")
        try expect(
            model.productSections[0].statusRows == ["Last success: D1900000000"],
            "Expected absolute last success"
        )
        try expect(
            model.actionGroups.flatMap { $0 }.map(\.action)
                == [.refresh, .openCodex, .checkForUpdates, .settings, .quit],
            "Expected action order"
        )
        try expect(
            model.actionGroups.flatMap { $0 }.map(\.title)
                == [
                    "Refresh", "Open Codex",
                    "Current version: v? (latest unavailable)", "Settings…",
                    "Quit Codex Gauge"
                ],
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
                .codex: .value(staleValue, freshness: .stale)
            ],
            issuesByProduct: [
                .codex: .timeout
            ],
            lastSuccessfulRefreshByProduct: [:],
            codexAvailability: .available,
            currentDate: Date(timeIntervalSince1970: 1_900_000_100)
        )

        let model = menuBuilder().build(input)
        let codex = model.productSections[0]

        try expect(codex.quotaRows == [
            "[5h] · 75% remaining · reset unavailable"
        ], "Expected stale cached quota")
        try expect(codex.statusRows == [
            "Last success: D1900000100",
            "Last value · Timed out"
        ], "Expected stale reason")
        let unavailable = menuBuilder().build(QuotaDetailsMenuInput(
            productStates: [.codex: .unavailable],
            issuesByProduct: [.codex: .signedOut],
            lastSuccessfulRefreshByProduct: [.codex: Date(timeIntervalSince1970: 1_900_000_050)],
            codexAvailability: .available,
            currentDate: Date(timeIntervalSince1970: 1_900_000_100)
        )).productSections[0]
        try expect(unavailable.quotaRows.isEmpty, "Expected unavailable quota without fake zero")
        try expect(unavailable.statusRows == [
            "Last success: D1900000050", "Sign in to Codex"
        ], "Expected unavailable recovery reason")

        let partialInput = QuotaDetailsMenuInput(
            productStates: [.codex: .value(staleValue, freshness: .fresh)],
            issuesByProduct: [.codex: .partialData],
            codexAvailability: .available,
            currentDate: Date(timeIntervalSince1970: 1_900_000_100)
        )
        let partial = menuBuilder().build(partialInput).productSections[0]
        try expect(partial.statusRows.last == "Some limits unavailable", "Expected partial state")
    }
}

private func quotaMenuSelectsConnectionActionTest() -> TestCase {
    TestCase(name: "quota menu shows loading and conditional select action") {
        let input = QuotaDetailsMenuInput(
            productStates: [.codex: .loading],
            issuesByProduct: [:],
            codexAvailability: .needsSelection,
            currentDate: Date(timeIntervalSince1970: 1_900_000_000)
        )

        let model = menuBuilder().build(input)

        try expect(model.productSections[0].statusRows == ["Checking connection"], "Expected loading")
        try expect(model.productSections.count == 1, "Expected only Codex details")
        try expect(
            model.actionGroups.flatMap { $0 }.map(\.action)
                == [.refresh, .selectCodex, .checkForUpdates, .settings, .quit],
            "Expected select action"
        )
    }
}

private func quotaMenuAdapterUsesCachedModelTest() -> TestCase {
    TestCase(name: "quota menu opens cached content without rerendering the status") {
        try await MainActor.run {
            let statusPresenter = MenuStatusItemPresenter()
            let statusController = StatusItemController(
                presenter: statusPresenter
            )
            statusController.setFrames(menuSelectedFrames())
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
                codexAvailability: .available,
                currentDate: Date(timeIntervalSince1970: 1_900_000_000)
            ))
            let actionCalls = MenuCallRecorder()
            let menuController = StatusMenuController(
                presenter: menuPresenter,
                actions: menuActions(recorder: actionCalls)
            )
            menuController.update(model)
            let statusPresentationCount = statusPresenter.presentationCount
            let formattingCount = formatterCalls.values.count
            guard let menu = menuPresenter.menu else {
                throw TestFailure(description: "Expected attached menu")
            }
            let titlesBeforeOpening = menu.items.map(\.title)
            try expect(
                titlesBeforeOpening.contains("Spend limit · 64% remaining"),
                "Expected the cached AppKit menu to contain the separate spend row"
            )
            guard let updateItem = menu.items.first(where: { item in
                item.representedObject as? String
                    == QuotaMenuAction.checkForUpdates.rawValue
            }) else {
                throw TestFailure(description: "Expected update action item")
            }
            try expect(!updateItem.isEnabled, "Expected unavailable updater action disabled")

            menuController.menuWillOpen(menu)
            menuController.menuDidClose(menu)
            try expect(statusPresenter.presentationCount == statusPresentationCount, "Expected menu open and close not to present status again")
            guard let refreshItem = menu.items.first(where: { item in
                item.representedObject as? String == QuotaMenuAction.refresh.rawValue
            }) else {
                throw TestFailure(description: "Expected refresh action item")
            }
            try expect(refreshItem.target === menuController, "Expected controller action target")
            try expect(refreshItem.action != nil, "Expected selector-backed action item")
            menuController.perform(.refresh)

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
                recorder.values == [
                    "refresh", "open", "select", "update", "settings", "quit"
                ],
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
                "menu.quota.with_reset": "[{duration}] · {remaining}% remaining · resets {reset}",
        "menu.quota.without_reset": "[{duration}] · {remaining}% remaining · reset unavailable",
        "menu.quota.expired_with_reset":
            "[{duration}] · — · resets {reset} · refresh required",
        "menu.quota.expired_without_reset": "[{duration}] · — · refresh required",
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
        "menu.update.checking": "Current version: v{current} (checking latest…)",
        "menu.update.versions": "Current version: v{current} (latest v{latest})",
        "menu.update.failed": "Current version: v{current} (latest check failed)",
        "menu.update.unavailable": "Current version: v{current} (latest unavailable)",
        "menu.action.settings": "Settings…",
        "menu.quit": "Quit Codex Gauge"
    ]
    return QuotaMenuLocalization { key in
        values[key] ?? key
    }
}

private func updateAction(
    in model: QuotaDetailsMenuModel
) -> QuotaMenuActionItem? {
    model.actionGroups.flatMap { $0 }.first { $0.action == .checkForUpdates }
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

private func menuSelectedFrames() -> [DisplayFrame] {
    [
        menuFrame(duration: 300, value: .fresh(83))
    ]
}

private func menuFrame(duration: Int?, value: DisplayValueState) -> DisplayFrame {
    .single(DisplayQuota(
        identifier: QuotaSelectionID(product: .codex, rawDurationMinutes: duration),
        value: value
    ))
}

private func singleMenuDisplayValue(_ frame: DisplayFrame) -> DisplayValueState? {
    guard case .single(let quota) = frame else {
        return nil
    }
    return quota.value
}

@MainActor
private func menuActions(recorder: MenuCallRecorder) -> StatusMenuActions {
    StatusMenuActions(
        refresh: { recorder.record("refresh") },
        openCodex: { recorder.record("open") },
        selectCodex: { recorder.record("select") },
        checkForUpdates: { recorder.record("update") },
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
    private(set) var presentationCount = 0

    func setLength(_ length: CGFloat) {
        _ = length
    }

    func present(_ frame: RenderedStatusFrame) {
        _ = frame
        presentationCount += 1
    }
}
