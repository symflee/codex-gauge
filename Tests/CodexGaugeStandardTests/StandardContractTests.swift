import CodexGaugeCore
import CodexGaugeProtocol
import CodexGaugeSettings
import Testing

@Test("Quota values keep valid remaining-percent boundaries")
func quotaRemainingPercentBoundaries() throws {
    let unused = try makeQuota(usedPercent: -4)
    let fractional = try makeQuota(usedPercent: 99.9)
    let exhausted = try makeQuota(usedPercent: 100)
    let overused = try makeQuota(usedPercent: 140)

    #expect(unused.remainingPercent == 100)
    #expect(fractional.remainingPercent == 1)
    #expect(exhausted.remainingPercent == 0)
    #expect(overused.remainingPercent == 0)
}

@Test("Duration badges preserve server duration without monthly inference")
func durationBadgeContract() {
    #expect(DurationBadge(windowDurationMinutes: 300).label == "5h")
    #expect(DurationBadge(windowDurationMinutes: 10_080).label == "w")
    #expect(DurationBadge(windowDurationMinutes: 43_200).label == "30d")
    #expect(DurationBadge(windowDurationMinutes: 90).label == "?")
    #expect(DurationBadge(windowDurationMinutes: nil).label == "?")
}

@Test("Automatic selection follows preferred duration order")
func automaticQuotaSelectionContract() throws {
    let hourly = try makeQuota(usedPercent: 10, duration: 60)
    let weekly = try makeQuota(usedPercent: 20, duration: 10_080)
    let fiveHour = try makeQuota(usedPercent: 30, duration: 300)
    let selector = QuotaSelector()

    #expect(selector.automaticQuota(from: [hourly, weekly, fiveHour]) == fiveHour)
    #expect(selector.automaticQuota(from: [hourly, weekly]) == weekly)
    #expect(selector.automaticQuota(from: [hourly]) == hourly)
}

@Test("Protocol decoding tolerates unknown fields and isolates malformed windows")
func tolerantRateLimitDecodingContract() throws {
    let result = try interpretRateLimits(
        .object([
            "future": .boolean(true),
            "rateLimitsByLimitId": .object([
                "codex": .object([
                    "future": .string("ignored"),
                    "primary": .object([
                        "usedPercent": .integer(17),
                        "windowDurationMins": .integer(300),
                        "future": .array([.integer(1), .integer(2)])
                    ]),
                    "secondary": .object([
                        "usedPercent": .string("malformed")
                    ])
                ]),
                "future_limit": .object([
                    "primary": .object(["usedPercent": .integer(99)])
                ])
            ])
        ])
    )
    let codex = result.rateLimits(for: .codex)

    #expect(result.responseStatus == .accepted)
    #expect(codex.state == .partial)
    #expect(codex.windows.count == 1)
    #expect(codex.windows.first?.slot == .primary)
    #expect(codex.windows.first?.remainingPercent == 83)
    #expect(result.rateLimits(for: .spark).state == .unavailable)
}

@Test("Protocol decoding keeps the legacy Codex fallback product-scoped")
func legacyRateLimitFallbackContract() throws {
    let result = try interpretRateLimits(
        .object([
            "rateLimits": .object([
                "primary": .object([
                    "usedPercent": .integer(41),
                    "windowDurationMins": .integer(10_080)
                ])
            ])
        ])
    )
    let codex = result.rateLimits(for: .codex)

    #expect(codex.state == .available)
    #expect(codex.windows.first?.remainingPercent == 59)
    #expect(result.rateLimits(for: .spark).state == .unavailable)
}

@Test("Preferences remove hidden-product selections and recover empty manual state")
func preferenceNormalizationContract() {
    let codexIdentifier = QuotaSelectionID(
        product: .codex,
        rawDurationMinutes: 300
    )
    let sparkIdentifier = QuotaSelectionID(
        product: .spark,
        rawDurationMinutes: 10_080
    )
    let normalized = AppPreferences(
        displayPreference: DisplayPreference(
            productMode: .codex,
            quotaSelection: .manual([codexIdentifier, sparkIdentifier])
        )
    )
    let recovered = AppPreferences(
        displayPreference: DisplayPreference(
            productMode: .codex,
            quotaSelection: .manual([sparkIdentifier])
        )
    )

    #expect(
        normalized.displayPreference.quotaSelection == .manual([codexIdentifier])
    )
    #expect(recovered.displayPreference.quotaSelection == .automatic)
}

private func makeQuota(
    usedPercent: Double,
    duration: Int? = nil,
    slot: QuotaSlot = .primary
) throws -> QuotaWindow {
    try #require(
        QuotaWindow(
            slot: slot,
            usedPercent: usedPercent,
            windowDurationMinutes: duration
        )
    )
}

private func interpretRateLimits(
    _ result: JSONValue
) throws -> RateLimitReadResult {
    let response = JSONRPCResponse(
        id: .integer(1),
        payload: .result(result)
    )
    return try AppServerResponseInterpreter().rateLimits(
        from: response,
        capturedAt: .distantFuture
    )
}
