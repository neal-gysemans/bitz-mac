import XCTest
@testable import BitzCore

private final class Collector: @unchecked Sendable {
    var events: [AgentEvent] = []
    let lock = NSLock()
    func append(_ e: AgentEvent) { lock.lock(); events.append(e); lock.unlock() }
    var snapshot: [AgentEvent] { lock.lock(); defer { lock.unlock() }; return events }
    var usages: [AgentEvent] { snapshot.filter { $0.kind == .usage } }
}

final class AntigravityTranscriptAdapterTests: XCTestCase {
    var tempBrainDir: URL!
    var sessionLogsDir: URL!
    var transcriptFile: URL!

    override func setUp() {
        super.setUp()
        tempBrainDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        sessionLogsDir = tempBrainDir.appendingPathComponent("session-1/.system_generated/logs")
        try? FileManager.default.createDirectory(at: sessionLogsDir, withIntermediateDirectories: true)
        transcriptFile = sessionLogsDir.appendingPathComponent("transcript.jsonl")
        FileManager.default.createFile(atPath: transcriptFile.path, contents: Data())
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: tempBrainDir)
        super.tearDown()
    }

    private func append(_ lines: String...) throws {
        let handle = try FileHandle(forWritingTo: transcriptFile)
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: Data(lines.map { $0 + "\n" }.joined().utf8))
    }

    /// Adapter attached to the transcript as it is now, without the background poll task.
    private func attachedAdapter(_ collector: Collector) -> AntigravityTranscriptAdapter {
        let adapter = AntigravityTranscriptAdapter(baseBrainURL: tempBrainDir)
        adapter.setHandlerForTesting { collector.append($0) }
        adapter.checkForUpdates()
        return adapter
    }

    private static let toolCallLine = #"{"step_index":2,"source":"MODEL","type":"PLANNER_RESPONSE","status":"DONE","tool_calls":[{"name":"view_file","args":{"AbsolutePath":"/tmp/a.swift","StartLine":1}}]}"#

    func testDetectsAntigravityTurnEvents() throws {
        let adapter = AntigravityTranscriptAdapter(baseBrainURL: tempBrainDir)

        let collector = Collector()
        adapter.setHandlerForTesting { collector.append($0) }

        // Start adapter (it sets offset to current EOF)
        adapter.start { collector.append($0) }

        let handle = try FileHandle(forWritingTo: transcriptFile)
        defer { try? handle.close() }

        // 1. User Input Line -> .working
        let userLine = "{\"step_index\":1,\"source\":\"USER_EXPLICIT\",\"type\":\"USER_INPUT\",\"status\":\"DONE\",\"content\":\"hello\"}\n"
        handle.seekToEndOfFile()
        handle.write(userLine.data(using: .utf8)!)

        adapter.checkForUpdates()
        var lifecycle = collector.snapshot.filter { $0.kind != .usage }
        XCTAssertEqual(lifecycle.count, 1)
        XCTAssertEqual(lifecycle.first?.kind, .working)
        XCTAssertEqual(lifecycle.first?.agentID, "antigravity")

        // 2. Question / Approval -> .needsApproval (flat format as actually written by Antigravity)
        let questionLine = "{\"step_index\":2,\"source\":\"MODEL\",\"type\":\"PLANNER_RESPONSE\",\"status\":\"DONE\",\"tool_calls\":[{\"name\":\"ask_question\",\"args\":{}}]}\n"
        handle.seekToEndOfFile()
        handle.write(questionLine.data(using: .utf8)!)

        adapter.checkForUpdates()
        lifecycle = collector.snapshot.filter { $0.kind != .usage }
        XCTAssertEqual(lifecycle.count, 2)
        XCTAssertEqual(lifecycle.last?.kind, .needsApproval)

        // 2b. Legacy / nested format support -> .needsApproval
        let legacyQuestionLine = "{\"step_index\":2,\"source\":\"MODEL\",\"type\":\"PLANNER_RESPONSE\",\"status\":\"DONE\",\"tool_calls\":[{\"id\":\"c1\",\"type\":\"function\",\"function\":{\"name\":\"ask_question\",\"arguments\":\"{}\"}}]}\n"
        handle.seekToEndOfFile()
        handle.write(legacyQuestionLine.data(using: .utf8)!)

        adapter.checkForUpdates()
        lifecycle = collector.snapshot.filter { $0.kind != .usage }
        XCTAssertEqual(lifecycle.count, 3)
        XCTAssertEqual(lifecycle.last?.kind, .needsApproval)

        // 3. Final Model Response -> .done
        let doneLine = "{\"step_index\":3,\"source\":\"MODEL\",\"type\":\"PLANNER_RESPONSE\",\"status\":\"DONE\",\"content\":\"Here is the response!\"}\n"
        handle.seekToEndOfFile()
        handle.write(doneLine.data(using: .utf8)!)

        adapter.checkForUpdates()
        lifecycle = collector.snapshot.filter { $0.kind != .usage }
        XCTAssertEqual(lifecycle.count, 4)
        XCTAssertEqual(lifecycle.last?.kind, .done)
        XCTAssertEqual(lifecycle.last?.message, "Antigravity is done!")

        adapter.stop()
    }

    func testReportsContextUsageFromPlannerTokens() throws {
        let collector = Collector()
        let adapter = attachedAdapter(collector)

        try append(#"{"step_index":2,"source":"MODEL","type":"PLANNER_RESPONSE","status":"DONE","input_tokens":1000,"cache_read_tokens":253000,"output_tokens":42}"#)
        adapter.checkForUpdates()

        XCTAssertEqual(collector.usages.last?.contextTokens, 254_000)
        XCTAssertEqual(collector.usages.last?.isSeed, false)
    }

    func testFourIdenticalNameArgsCallsEmitOneLoopWarning() throws {
        let collector = Collector()
        let adapter = attachedAdapter(collector)

        for _ in 1...3 {
            try append(Self.toolCallLine)
            adapter.checkForUpdates()
        }
        XCTAssertTrue(collector.snapshot.filter { $0.kind == .warning }.isEmpty)

        try append(Self.toolCallLine, Self.toolCallLine)
        adapter.checkForUpdates()

        let warnings = collector.snapshot.filter { $0.kind == .warning }
        XCTAssertEqual(warnings.count, 1)
        XCTAssertEqual(warnings.first?.warningReason, .loop)
    }

    func testPendingClearedByNextLine() throws {
        let collector = Collector()
        let adapter = attachedAdapter(collector)

        try append(Self.toolCallLine)
        adapter.checkForUpdates()
        XCTAssertEqual(collector.usages.last?.pendingTools, 1)

        try append(#"{"step_index":3,"source":"SYSTEM","type":"TOOL_OUTPUT","status":"DONE"}"#)
        adapter.checkForUpdates()
        XCTAssertEqual(collector.usages.last?.pendingTools, 0)
    }

    func testStartupSeedIsSilent() throws {
        try append(
            #"{"step_index":1,"source":"USER_EXPLICIT","type":"USER_INPUT","status":"DONE"}"#,
            #"{"step_index":2,"source":"MODEL","type":"PLANNER_RESPONSE","status":"DONE","input_tokens":500,"cache_read_tokens":1500}"#
        )
        let collector = Collector()
        let adapter = AntigravityTranscriptAdapter(baseBrainURL: tempBrainDir)

        adapter.start { collector.append($0) }
        defer { adapter.stop() }

        XCTAssertEqual(collector.snapshot.map(\.kind), [.usage])
        XCTAssertEqual(collector.snapshot.first?.isSeed, true)
        XCTAssertEqual(collector.snapshot.first?.contextTokens, 2000)
    }

    func testAttachMidTurnTracksTurnToDone() throws {
        try append(
            #"{"step_index":1,"source":"USER_EXPLICIT","type":"USER_INPUT","status":"DONE"}"#,
            Self.toolCallLine
        )
        let collector = Collector()
        let adapter = attachedAdapter(collector)

        XCTAssertEqual(collector.snapshot.map(\.kind), [.usage])
        XCTAssertEqual(collector.usages.first?.isSeed, true)
        XCTAssertEqual(collector.usages.first?.turnActive, true)
        XCTAssertEqual(collector.usages.first?.pendingTools, 1)

        try append(#"{"step_index":3,"source":"MODEL","type":"PLANNER_RESPONSE","status":"DONE","content":"Finished."}"#)
        adapter.checkForUpdates()

        XCTAssertEqual(collector.snapshot.filter { $0.kind != .usage }.map(\.kind), [.done])
    }

    func testAttachAfterFinishedTurnSeedsInactiveTurn() throws {
        try append(
            #"{"step_index":1,"source":"USER_EXPLICIT","type":"USER_INPUT","status":"DONE"}"#,
            #"{"step_index":2,"source":"MODEL","type":"PLANNER_RESPONSE","status":"DONE","content":"Finished."}"#
        )
        let collector = Collector()
        let adapter = attachedAdapter(collector)
        adapter.checkForUpdates()

        XCTAssertEqual(collector.snapshot.map(\.kind), [.usage])
        XCTAssertEqual(collector.usages.first?.isSeed, true)
        XCTAssertEqual(collector.usages.first?.turnActive, false)
        XCTAssertNil(collector.usages.first?.contextTokens)
    }

    func testLineParserRules() {
        func entries(_ line: String) -> [SessionLogEntry] {
            AntigravityTranscriptAdapter.entries(fromLine: Data(line.utf8))
        }

        XCTAssertEqual(entries("{not json"), [])
        XCTAssertEqual(entries(#"{"type":"SOMETHING_ELSE"}"#), [.toolResult(id: nil)])
        XCTAssertEqual(entries(#"{"type":"PLANNER_RESPONSE","status":"RUNNING","tool_calls":[{"name":"list_dir"}]}"#), [
            .toolResult(id: nil),
            .assistantOutput(contextTokens: nil),
            .toolCall(id: nil, name: "list_dir", fingerprint: AgentSessionTracker.fingerprint(name: "list_dir", input: nil)),
        ])
    }
}
