import XCTest
@testable import BitzCore

final class AgentModelsTests: XCTestCase {

    private func decodeEvent(_ json: String) throws -> AgentEvent {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(AgentEvent.self, from: Data(json.utf8))
    }

    private func event(metadata: String) throws -> AgentEvent {
        try decodeEvent("""
        {"agentID":"claude","agentName":"Claude","kind":"usage","timestamp":"2026-10-30T11:00:00Z","metadata":\(metadata)}
        """)
    }

    // MARK: - AgentEvent decoding (FR-003)

    func testOldPayloadDecodesUnchanged() throws {
        // Exact shape written by AgentHookInstaller.claudeSettingsSnippet()
        let event = try decodeEvent("""
        {"id":"6f1c2b7e-0d3a-4c8e-9a51-2b7f0c9d1e23","agentID":"claude","agentName":"Claude","kind":"done","message":"Claude is done!","timestamp":"2026-10-30T11:00:00Z"}
        """)

        XCTAssertEqual(event.id, UUID(uuidString: "6f1c2b7e-0d3a-4c8e-9a51-2b7f0c9d1e23"))
        XCTAssertEqual(event.agentID, "claude")
        XCTAssertEqual(event.agentName, "Claude")
        XCTAssertEqual(event.kind, .done)
        XCTAssertEqual(event.message, "Claude is done!")
        XCTAssertEqual(event.timestamp, ISO8601DateFormatter().date(from: "2026-10-30T11:00:00Z"))
        XCTAssertNil(event.metadata)
    }

    func testNewKindsDecode() throws {
        for kind in ["almostDone", "warning", "usage"] {
            let event = try decodeEvent("""
            {"agentID":"claude","agentName":"Claude","kind":"\(kind)","timestamp":"2026-10-30T11:00:00Z"}
            """)
            XCTAssertEqual(event.kind.rawValue, kind)
        }
    }

    func testMetadataDecodesStringsNumbersAndBools() throws {
        let event = try event(metadata: #"{"contextTokens":185000,"pendingTools":"2","turnActive":true,"reason":"context","ratio":0.5}"#)

        XCTAssertEqual(event.metadata?["contextTokens"], "185000")
        XCTAssertEqual(event.metadata?["ratio"], "0.5")
        XCTAssertEqual(event.contextTokens, 185_000)
        XCTAssertEqual(event.pendingTools, 2)
        XCTAssertEqual(event.turnActive, true)
        XCTAssertEqual(event.warningReason, .context)
    }

    func testMalformedMetadataIsIgnoredNotFatal() throws {
        let event = try event(metadata: #"{"x":[1,2]}"#)
        XCTAssertEqual(event.kind, .usage)
        XCTAssertNil(event.metadata)
    }

    func testInvalidNumbersReturnNil() throws {
        XCTAssertNil(try event(metadata: #"{"contextTokens":"abc"}"#).contextTokens)
        XCTAssertNil(try event(metadata: #"{"contextTokens":"-5","pendingTools":-1}"#).contextTokens)
        XCTAssertNil(try event(metadata: #"{"pendingTools":-1}"#).pendingTools)
        XCTAssertNil(try event(metadata: #"{"turnActive":"maybe"}"#).turnActive)
    }

    func testUnknownReasonFallsBackToReported() throws {
        XCTAssertEqual(try event(metadata: #"{"reason":"cosmic-rays"}"#).warningReason, .reported)
        XCTAssertEqual(AgentEvent(agentID: "a", agentName: "A", kind: .warning).warningReason, .reported)
    }

    func testProcessPresenceFlagFromSourceMetadata() throws {
        XCTAssertTrue(try event(metadata: #"{"source":"process"}"#).isProcessPresence)
        XCTAssertFalse(try event(metadata: #"{"source":"hook"}"#).isProcessPresence)
        XCTAssertFalse(AgentEvent(agentID: "a", agentName: "A", kind: .done).isProcessPresence)
    }

    func testSeedFlag() throws {
        XCTAssertTrue(try event(metadata: #"{"seed":"true"}"#).isSeed)
        XCTAssertFalse(try event(metadata: #"{"seed":false}"#).isSeed)
    }

    func testMetadataRoundTripsThroughEncoding() throws {
        let original = AgentEvent(
            agentID: "claude",
            agentName: "Claude",
            kind: .warning,
            message: "⚠️ loop",
            timestamp: Date(timeIntervalSince1970: 1_800_000_000),
            metadata: [AgentEvent.MetadataKey.reason: "loop"]
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let decoded = try decoder.decode(AgentEvent.self, from: encoder.encode(original))
        XCTAssertEqual(decoded, original)
    }

    // MARK: - Value types

    func testContextPercentDoesNotOverflowOnHugeTokenCounts() {
        // Drop-box metadata comes from user scripts; `tokens * 100` in Int would trap.
        let reading = AgentContextReading(agentID: "claude", agentName: "Claude", tokens: Int.max, windowTokens: 200_000)
        XCTAssertEqual(reading.percent, 100)
    }

    func testContextReadingPercentAndText() {
        let reading = AgentContextReading(agentID: "claude", agentName: "Claude", tokens: 148_000, windowTokens: 200_000)
        XCTAssertEqual(reading.percent, 74)
        XCTAssertEqual(reading.compactText, "Claude ctx 148k · 74%")

        XCTAssertEqual(AgentContextReading(agentID: "c", agentName: "C", tokens: 943_000, windowTokens: 200_000).percent, 100)
        XCTAssertEqual(AgentContextReading(agentID: "c", agentName: "C", tokens: 10, windowTokens: 0).percent, 0)

        XCTAssertEqual(AgentContextReading.formatTokens(950), "950")
        XCTAssertEqual(AgentContextReading.formatTokens(185_000), "185k")
        XCTAssertEqual(AgentContextReading.formatTokens(1_200_000), "1.2M")
    }

    func testSignalSettingsDefaults() {
        let settings = AgentSignalSettings()
        XCTAssertEqual(settings, .default)
        XCTAssertTrue(settings.almostDoneEnabled)
        XCTAssertTrue(settings.contextWarningEnabled)
        XCTAssertTrue(settings.loopWarningEnabled)
        XCTAssertTrue(settings.stallWarningEnabled)
        XCTAssertEqual(settings.contextThresholdPercent, 90)
        XCTAssertEqual(settings.stallTimeoutMinutes, 3)
        XCTAssertEqual(settings.contextWindow(for: "claude"), 200_000)
        XCTAssertEqual(settings.contextWindow(for: "antigravity"), 1_000_000)
        XCTAssertEqual(settings.contextWindow(for: "unknown"), AgentSignalSettings.defaultContextWindow)
    }

    func testSignalSettingsClamp() {
        var settings = AgentSignalSettings()
        settings.contextThresholdPercent = 120
        settings.stallTimeoutMinutes = 0
        settings.contextWindowTokens["broken"] = 0
        var clamped = settings.clamped()
        XCTAssertEqual(clamped.contextThresholdPercent, 99)
        XCTAssertEqual(clamped.stallTimeoutMinutes, 1)
        XCTAssertNil(clamped.contextWindowTokens["broken"])

        settings.contextThresholdPercent = 10
        settings.stallTimeoutMinutes = 99
        clamped = settings.clamped()
        XCTAssertEqual(clamped.contextThresholdPercent, 50)
        XCTAssertEqual(clamped.stallTimeoutMinutes, 30)
    }

    func testSignalSettingsPartialDecodeKeepsDefaults() throws {
        let settings = try JSONDecoder().decode(AgentSignalSettings.self, from: Data(#"{"loopWarningEnabled":false}"#.utf8))
        var expected = AgentSignalSettings()
        expected.loopWarningEnabled = false
        XCTAssertEqual(settings, expected)
    }

    func testSignalSettingsWarningToggles() {
        var settings = AgentSignalSettings()
        settings.contextWarningEnabled = false
        settings.loopWarningEnabled = false
        settings.stallWarningEnabled = false
        XCTAssertFalse(settings.isEnabled(.context))
        XCTAssertFalse(settings.isEnabled(.loop))
        XCTAssertFalse(settings.isEnabled(.stall))
        XCTAssertTrue(settings.isEnabled(.reported), "Reported warnings have no toggle")
    }
}
