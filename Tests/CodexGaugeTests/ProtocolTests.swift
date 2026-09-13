import CodexGaugeCore
import CodexGaugeProtocol
import Foundation

func protocolTests() -> [TestCase] {
    jsonLineTests() + jsonRPCMessageTests() + responseInterpretationTests()
}

private func jsonLineTests() -> [TestCase] {
    [
        splitAndMultipleJSONLinesTest(),
        unfinishedJSONLineTest(),
        maximumJSONLineTest(),
        oversizedJSONLineTest()
    ]
}

private func jsonRPCMessageTests() -> [TestCase] {
    [
        classifiesJSONRPCMessagesTest(),
        classifiesJSONRPCFailureTest(),
        rejectsMalformedJSONRPCMessageTest()
    ]
}

private func responseInterpretationTests() -> [TestCase] {
    [
        acceptsInitializeResponseTest(),
        classifiesAccountWithoutEmailTest(),
        classifiesUnavailableAccountsTest(),
        decodesMultiBucketRateLimitsTest(),
        prefersMultiBucketRateLimitsTest(),
        decodesLegacyCodexRateLimitsTest(),
        ignoresAdditionalProductBucketsTest(),
        preservesIndependentWindowFailuresTest(),
        decodesSpendControlLimitTest(),
        clampsSpendControlLimitTest(),
        isolatesMalformedSpendControlTest(),
        treatsMissingBucketsAsUnavailableTest(),
        classifiesRateLimitEnvelopeTest(),
        toleratesUnknownRateLimitFieldsTest(),
        propagatesTypedRPCFailureTest()
    ]
}

private func splitAndMultipleJSONLinesTest() -> TestCase {
    TestCase(name: "JSONL framer handles chunks CRLF and blank lines") {
        var framer = JSONLFramer()
        let first = try framer.append(Data("{\"id\":".utf8))
        let second = try framer.append(Data("1}\r\n\n{\"id\":2}\n".utf8))

        try expect(first.isEmpty, "Expected an incomplete line to stay buffered")
        try expect(second == [Data("{\"id\":1}".utf8), Data("{\"id\":2}".utf8)], "Expected normalized lines")
    }
}

private func unfinishedJSONLineTest() -> TestCase {
    TestCase(name: "JSONL framer emits a final line without newline") {
        var framer = JSONLFramer()
        _ = try framer.append(Data("{\"id\":3}\r".utf8))
        let lines = try framer.finish()
        let repeatedFinish = try framer.finish()

        try expect(lines == [Data("{\"id\":3}".utf8)], "Expected the final buffered line")
        try expect(repeatedFinish.isEmpty, "Expected finish to clear the buffer")
    }
}

private func maximumJSONLineTest() -> TestCase {
    TestCase(name: "JSONL framer accepts exactly one MiB") {
        var framer = JSONLFramer()
        var line = Data(repeating: 0x61, count: JSONLFramer.maximumLineBytes)
        line.append(0x0A)
        let lines = try framer.append(line)

        try expect(lines.first?.count == JSONLFramer.maximumLineBytes, "Expected the maximum line")
    }
}

private func oversizedJSONLineTest() -> TestCase {
    TestCase(name: "JSONL framer rejects lines over one MiB") {
        var framer = JSONLFramer()
        let oversized = Data(repeating: 0x61, count: JSONLFramer.maximumLineBytes + 1)

        do {
            _ = try framer.append(oversized)
            throw TestFailure(description: "Expected an oversized-line failure")
        } catch let error as JSONLFramingError {
            try expect(error == .lineTooLong, "Expected a typed line-too-long failure")
        }
    }
}

private func classifiesJSONRPCMessagesTest() -> TestCase {
    TestCase(name: "JSON-RPC decoder classifies response notification and request") {
        let response = try decodeMessage("{\"id\":7,\"result\":{\"ok\":true}}")
        let notification = try decodeMessage("{\"method\":\"account/updated\",\"params\":{}}")
        let request = try decodeMessage("{\"id\":\"server-1\",\"method\":\"future/request\",\"params\":null}")

        try expect(response.isResultResponse(id: .integer(7)), "Expected a result response")
        try expect(notification.isNotification(method: "account/updated"), "Expected a notification")
        try expect(request.isRequest(id: .string("server-1"), method: "future/request"), "Expected a request")
    }
}

private func classifiesJSONRPCFailureTest() -> TestCase {
    TestCase(name: "JSON-RPC decoder keeps only a typed error code") {
        let message = try decodeMessage("{\"id\":8,\"error\":{\"code\":-32601,\"message\":\"synthetic\",\"data\":{\"ignored\":true}}}")

        try expect(message.isFailureResponse(id: .integer(8), code: -32601), "Expected a typed RPC failure")
    }
}

private func rejectsMalformedJSONRPCMessageTest() -> TestCase {
    TestCase(name: "JSON-RPC decoder rejects malformed and ambiguous envelopes") {
        try expectMessageError("not-json", expected: .malformedJSON)
        try expectMessageError("{\"id\":1,\"result\":{},\"error\":{\"code\":1}}", expected: .invalidEnvelope)
        try expectMessageError("{\"params\":{}}", expected: .invalidEnvelope)
    }
}

private func acceptsInitializeResponseTest() -> TestCase {
    TestCase(name: "initialize response accepts unknown result fields") {
        let response = try decodeResponse("{\"id\":1,\"result\":{\"userAgent\":\"synthetic\",\"future\":true}}")
        let acknowledgement = try AppServerResponseInterpreter().initialize(from: response)

        try expect(acknowledgement == InitializeAcknowledgement(), "Expected initialization acknowledgement")
    }
}

private func classifiesAccountWithoutEmailTest() -> TestCase {
    TestCase(name: "account response exposes only a classified status") {
        let response = try decodeResponse("""
        {"id":2,"result":{"account":{"type":"chatgpt","planType":"synthetic","future":true},"requiresOpenaiAuth":true}}
        """)
        let status = try AppServerResponseInterpreter().account(from: response)

        try expect(status == .rateLimitsAvailable, "Expected ChatGPT rate-limit access")
        try expect(String(describing: status) == "rateLimitsAvailable", "Expected only the classified status")
    }
}

private func classifiesUnavailableAccountsTest() -> TestCase {
    TestCase(name: "account response distinguishes signed out and unsupported providers") {
        let signedOut = try interpretAccount("{\"id\":2,\"result\":{\"account\":null,\"requiresOpenaiAuth\":true}}")
        let localProvider = try interpretAccount("{\"id\":2,\"result\":{\"account\":null,\"requiresOpenaiAuth\":false}}")
        let apiKey = try interpretAccount("{\"id\":2,\"result\":{\"account\":{\"type\":\"apiKey\"},\"requiresOpenaiAuth\":true}}")
        let future = try interpretAccount("{\"id\":2,\"result\":{\"account\":{\"type\":\"futureProvider\"},\"requiresOpenaiAuth\":true}}")

        try expect(signedOut == .signedOut, "Expected signed-out status")
        try expect(localProvider == .unsupportedProvider, "Expected unsupported local provider")
        try expect(apiKey == .unsupportedProvider, "Expected unsupported API-key quota")
        try expect(future == .unknownProvider, "Expected forward-compatible unknown provider")
    }
}

private func decodesMultiBucketRateLimitsTest() -> TestCase {
    TestCase(name: "rate-limit response maps only Codex and both slots") {
        let result = try interpretRateLimits(multiBucketFixture())
        let codex = result.rateLimits(for: .codex)

        try expect(codex.state == .available, "Expected available Codex quotas")
        try expect(codex.windows.map(\.slot) == [.primary, .secondary], "Expected both Codex slots")
        try expect(codex.windows.first?.usedPercent == 12.5, "Expected numeric Double decoding")
        try expect(result.rateLimitsByProduct.count == 1, "Expected unknown extra buckets to be ignored")
        try expect(result.snapshot.quotaWindows(for: .codex) == codex.windows, "Expected domain snapshot mapping")
    }
}

private func prefersMultiBucketRateLimitsTest() -> TestCase {
    TestCase(name: "multi-bucket data wins over conflicting legacy data") {
        let json = rateLimitResponse(result: """
        {"rateLimits":{"primary":{"usedPercent":91,"windowDurationMins":300}},"rateLimitsByLimitId":{"codex":{"primary":{"usedPercent":11,"windowDurationMins":300}}}}
        """)
        let result = try interpretRateLimits(json)

        try expect(result.rateLimits(for: .codex).windows.first?.usedPercent == 11, "Expected multi-bucket Codex data")
    }
}

private func decodesLegacyCodexRateLimitsTest() -> TestCase {
    TestCase(name: "legacy top-level data maps to Codex only") {
        let json = rateLimitResponse(result: """
        {"rateLimits":{"primary":{"usedPercent":23,"windowDurationMins":300},"secondary":null}}
        """)
        let result = try interpretRateLimits(json)

        try expect(result.rateLimits(for: .codex).state == .available, "Expected legacy Codex quota")
        try expect(result.rateLimitsByProduct.count == 1, "Expected only the Codex product")
    }
}

private func ignoresAdditionalProductBucketsTest() -> TestCase {
    TestCase(name: "additional product buckets neither alter nor replace Codex") {
        let expected = try interpretRateLimits(rateLimitResponse(result: """
        {"rateLimitsByLimitId":{"codex":{"primary":{"usedPercent":19,"windowDurationMins":300}}}}
        """))
        for extra in ["null", "false", "\"malformed\"", "{}", "{\"primary\":{\"usedPercent\":99}}"] {
            let result = try interpretRateLimits(rateLimitResponse(result: """
            {"rateLimitsByLimitId":{"codex":{"primary":{"usedPercent":19,"windowDurationMins":300}},"codex_bengalfox":\(extra),"future_product":\(extra)}}
            """))
            try expect(result == expected, "Expected unknown buckets to have no effect on Codex")
        }
        let malformed = try interpretRateLimits(rateLimitResponse(result: """
        {"rateLimitsByLimitId":{"codex":"malformed","codex_bengalfox":{"primary":{"usedPercent":19,"windowDurationMins":300}}}}
        """))
        try expect(malformed.rateLimits(for: .codex).state == .malformed, "Expected explicit Codex failure")
        try expect(malformed.responseStatus == .accepted, "Expected an accepted outer envelope")
        try expect(malformed.snapshot.quotaWindows(for: .codex).isEmpty, "Expected no extra product fallback")
    }
}

private func preservesIndependentWindowFailuresTest() -> TestCase {
    TestCase(name: "malformed window preserves its sibling window") {
        let json = rateLimitResponse(result: """
        {"rateLimitsByLimitId":{"codex":{"primary":{"usedPercent":"bad","windowDurationMins":300},"secondary":{"usedPercent":37,"windowDurationMins":10080}}}}
        """)
        let codex = try interpretRateLimits(json).rateLimits(for: .codex)

        try expect(codex.state == .partial, "Expected a partial product result")
        try expect(codex.windows.map(\.slot) == [.secondary], "Expected the valid secondary window")
    }
}

private func decodesSpendControlLimitTest() -> TestCase {
    TestCase(name: "rate-limit decoder preserves minimal spend control") {
        let json = rateLimitResponse(result: """
        {"rateLimitsByLimitId":{"codex":{"primary":{"usedPercent":21},"individualLimit":{"remainingPercent":67.8,"limit":"discarded","used":"discarded","resetsAt":1900000000},"spendControlReached":true,"credits":{"balance":"discarded"}}}}
        """)
        let spendControl = try interpretRateLimits(json)
            .rateLimits(for: .codex)
            .spendControlLimit

        try expect(spendControl?.remainingPercent == 67, "Expected floored remaining spend percent")
        try expect(spendControl?.reached == true, "Expected backend reached state")
        try expect(String(describing: spendControl).contains("discarded") == false, "Expected minimal typed data")
    }
}

private func isolatesMalformedSpendControlTest() -> TestCase {
    TestCase(name: "malformed spend control does not fail quota windows") {
        let json = rateLimitResponse(result: """
        {"rateLimitsByLimitId":{"codex":{"primary":{"usedPercent":22},"secondary":{"usedPercent":"bad"},"individualLimit":{"remainingPercent":"bad"},"spendControlReached":false}}}
        """)
        let result = try interpretRateLimits(json)
        let codex = result.rateLimits(for: .codex)

        try expect(codex.state == .partial, "Expected only the malformed quota to affect state")
        try expect(codex.spendControlLimit?.remainingPercent == nil, "Expected unavailable spend percent")
        try expect(codex.spendControlLimit?.reached == false, "Expected explicit non-reached state")
    }
}

private func clampsSpendControlLimitTest() -> TestCase {
    TestCase(name: "spend control clamps remaining percent bounds") {
        for (rawValue, expected) in [(-4.2, 0), (140.9, 100)] {
            let json = rateLimitResponse(result: """
            {"rateLimitsByLimitId":{"codex":{"individualLimit":{"remainingPercent":\(rawValue)}}}}
            """)
            let spendControl = try interpretRateLimits(json).rateLimits(for: .codex).spendControlLimit

            try expect(spendControl?.remainingPercent == expected, "Expected bounded remaining spend percent")
            try expect(spendControl?.reached == nil, "Expected a missing reached state to stay unknown")
        }
        let noSpend = try interpretRateLimits(rateLimitResponse(result: """
        {"rateLimitsByLimitId":{"codex":{"primary":{"usedPercent":8}}}}
        """))
        try expect(noSpend.rateLimits(for: .codex).spendControlLimit == nil, "Expected absent spend fields to stay nil")
    }
}

private func treatsMissingBucketsAsUnavailableTest() -> TestCase {
    TestCase(name: "missing multi-bucket keys are unavailable without legacy fallback") {
        let json = rateLimitResponse(result: """
        {"rateLimits":{"primary":{"usedPercent":88}},"rateLimitsByLimitId":{}}
        """)
        let result = try interpretRateLimits(json)

        try expect(result.rateLimits(for: .codex).state == .unavailable, "Expected missing Codex bucket")
        try expect(result.rateLimits(for: .codex).windows.isEmpty, "Expected no legacy quota fallback")
    }
}

private func classifiesRateLimitEnvelopeTest() -> TestCase {
    TestCase(name: "rate-limit response distinguishes empty and incompatible envelopes") {
        let empty = try interpretRateLimits(rateLimitResponse(result: "{}"))
        let incompatible = try interpretRateLimits(rateLimitResponse(result: """
        {"rateLimitsByLimitId":"malformed"}
        """))
        let incompatibleLegacy = try interpretRateLimits(rateLimitResponse(result: """
        {"rateLimits":"malformed"}
        """))

        try expect(empty.responseStatus == .accepted, "Expected an accepted empty response")
        try expect(
            incompatible.responseStatus == .incompatible,
            "Expected an incompatible multi-bucket envelope"
        )
        try expect(
            incompatibleLegacy.responseStatus == .incompatible,
            "Expected an incompatible legacy envelope"
        )
    }
}

private func toleratesUnknownRateLimitFieldsTest() -> TestCase {
    TestCase(name: "rate-limit decoder ignores unknown buckets and fields") {
        let json = rateLimitResponse(result: """
        {"future":true,"rateLimitsByLimitId":{"unknown":{"primary":{"usedPercent":99}},"codex":{"limitName":"synthetic","primary":{"usedPercent":-5,"windowDurationMins":null,"resetsAt":1900000000,"future":[1,2]}}}}
        """)
        let codex = try interpretRateLimits(json).rateLimits(for: .codex)

        try expect(codex.windows.count == 1, "Expected the known bucket only")
        try expect(codex.windows.first?.usedPercent == 0, "Expected domain clamping")
        try expect(codex.windows.first?.windowDurationMinutes == nil, "Expected optional duration")
    }
}

private func propagatesTypedRPCFailureTest() -> TestCase {
    TestCase(name: "response interpreter exposes only a typed RPC code") {
        let response = try decodeResponse("{\"id\":2,\"error\":{\"code\":-32601,\"message\":\"synthetic\"}}")

        do {
            _ = try AppServerResponseInterpreter().account(from: response)
            throw TestFailure(description: "Expected an RPC failure")
        } catch let error as AppServerInterpretationError {
            try expect(error == .rpcFailure(code: -32601), "Expected the RPC code only")
        }
    }
}

private func multiBucketFixture() -> String {
    rateLimitResponse(result: """
    {"rateLimitsByLimitId":{"codex":{"primary":{"usedPercent":12.5,"windowDurationMins":300,"resetsAt":1900000000},"secondary":{"usedPercent":34,"windowDurationMins":10080,"resetsAt":1900600000}},"codex_bengalfox":{"primary":{"usedPercent":7,"windowDurationMins":300,"resetsAt":1900000000},"secondary":null}}}
    """)
}

private func rateLimitResponse(result: String) -> String {
    "{\"id\":3,\"result\":\(result)}"
}

private func decodeMessage(_ json: String) throws -> JSONRPCMessage {
    try JSONRPCMessageDecoder().decode(Data(json.utf8))
}

private func decodeResponse(_ json: String) throws -> JSONRPCResponse {
    guard case let .response(response) = try decodeMessage(json) else {
        throw TestFailure(description: "Expected a response envelope")
    }
    return response
}

private func interpretAccount(_ json: String) throws -> AccountStatus {
    let response = try decodeResponse(json)
    return try AppServerResponseInterpreter().account(from: response)
}

private func interpretRateLimits(_ json: String) throws -> RateLimitReadResult {
    let response = try decodeResponse(json)
    let capturedAt = Date(timeIntervalSince1970: 1_899_000_000)
    return try AppServerResponseInterpreter().rateLimits(from: response, capturedAt: capturedAt)
}

private func expectMessageError(
    _ json: String,
    expected: JSONRPCDecodingError
) throws {
    do {
        _ = try decodeMessage(json)
        throw TestFailure(description: "Expected a JSON-RPC decoding failure")
    } catch let error as JSONRPCDecodingError {
        try expect(error == expected, "Unexpected JSON-RPC decoding failure")
    }
}

private extension JSONRPCMessage {
    func isResultResponse(id: JSONRPCIdentifier) -> Bool {
        guard case let .response(response) = self else {
            return false
        }
        guard case .result = response.payload else {
            return false
        }
        return response.id == id
    }

    func isFailureResponse(id: JSONRPCIdentifier, code: Int) -> Bool {
        guard case let .response(response) = self else {
            return false
        }
        guard case let .failure(failure) = response.payload else {
            return false
        }
        return response.id == id && failure.code == code
    }

    func isNotification(method: String) -> Bool {
        guard case let .notification(notification) = self else {
            return false
        }
        return notification.method == method
    }

    func isRequest(id: JSONRPCIdentifier, method: String) -> Bool {
        guard case let .request(request) = self else {
            return false
        }
        return request.id == id && request.method == method
    }
}
