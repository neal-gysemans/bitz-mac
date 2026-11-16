import SQLite3
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

    func testIdleScanBacksOffWhenUnchangedAndResetsOnNewSessionOrGrowth() throws {
        final class TestClock: @unchecked Sendable {
            var now: Date
            init(_ now: Date) { self.now = now }
        }

        let t0 = Date(timeIntervalSince1970: 1_700_000_000)
        try FileManager.default.setAttributes([.modificationDate: t0.addingTimeInterval(-60)], ofItemAtPath: transcriptFile.path)

        let clock = TestClock(t0)
        let collector = Collector()
        let adapter = AntigravityTranscriptAdapter(
            baseBrainURL: tempBrainDir,
            pollInterval: 1.5,
            maxIdleScanInterval: 12.0,
            clock: { clock.now }
        )
        adapter.setHandlerForTesting { collector.append($0) }

        // First poll discovers session-1 (changed == true -> interval stays at base 1.5s)
        adapter.checkForUpdates()
        XCTAssertEqual(adapter.currentScanInterval, 1.5)
        XCTAssertEqual(collector.usages.count, 1)

        // Advance clock by 1.5s with no filesystem changes -> backs off to 3.0s
        clock.now = t0.addingTimeInterval(1.5)
        adapter.checkForUpdates()
        XCTAssertEqual(adapter.currentScanInterval, 3.0)

        // Poll within the 3.0s backoff window (at +3.0s total, only 1.5s since last scan) -> skipped, interval stays 3.0s
        clock.now = t0.addingTimeInterval(3.0)
        adapter.checkForUpdates()
        XCTAssertEqual(adapter.currentScanInterval, 3.0)

        // Poll at +4.5s total (3.0s since last scan) with no changes -> backs off to 6.0s
        clock.now = t0.addingTimeInterval(4.5)
        adapter.checkForUpdates()
        XCTAssertEqual(adapter.currentScanInterval, 6.0)

        // Poll at +10.5s total (6.0s since last scan) with no changes -> backs off to max 12.0s
        clock.now = t0.addingTimeInterval(10.5)
        adapter.checkForUpdates()
        XCTAssertEqual(adapter.currentScanInterval, 12.0)

        // Creating a brand-new session updates baseBrainURL mtime, bypassing the 12s backoff immediately!
        let session2Logs = tempBrainDir.appendingPathComponent("session-2/.system_generated/logs")
        try FileManager.default.createDirectory(at: session2Logs, withIntermediateDirectories: true)
        let transcript2 = session2Logs.appendingPathComponent("transcript.jsonl")
        let s2Line = #"{"step_index":1,"source":"MODEL","type":"PLANNER_RESPONSE","status":"DONE","input_tokens":3000,"cache_read_tokens":500}"# + "\n"
        try Data(s2Line.utf8).write(to: transcript2)
        try FileManager.default.setAttributes([.modificationDate: clock.now], ofItemAtPath: transcript2.path)

        clock.now = t0.addingTimeInterval(11.0) // Only 0.5s after last scan (well inside 12s backoff)
        adapter.checkForUpdates()
        XCTAssertEqual(adapter.currentScanInterval, 1.5, "New session directory resets scan interval to base pollInterval")
        XCTAssertEqual(collector.usages.last?.contextTokens, 3500)
    }

    func testIncrementalScanHandlesEmptySubdirectoriesThenLateTranscriptCreation() throws {
        let emptySubdir = tempBrainDir.appendingPathComponent("empty-session")
        try FileManager.default.createDirectory(at: emptySubdir, withIntermediateDirectories: true)

        let adapter = AntigravityTranscriptAdapter(baseBrainURL: tempBrainDir)
        XCTAssertEqual(adapter.sessionCandidates().count, 1)

        // Repeat scan with unchanged emptySubdir mtime still returns 1 candidate
        XCTAssertEqual(adapter.sessionCandidates().count, 1)

        // Later, .system_generated/logs/transcript.jsonl is created inside empty-session
        let lateLogsDir = emptySubdir.appendingPathComponent(".system_generated/logs")
        try FileManager.default.createDirectory(at: lateLogsDir, withIntermediateDirectories: true)
        let lateTranscript = lateLogsDir.appendingPathComponent("transcript.jsonl")
        try Data().write(to: lateTranscript)

        XCTAssertEqual(adapter.sessionCandidates().count, 2)
    }

    func testExtractsSessionIDFromTranscriptURL() {
        let url = URL(fileURLWithPath: "/Users/user/.gemini/antigravity/brain/session-uuid-123/.system_generated/logs/transcript.jsonl")
        XCTAssertEqual(AntigravityTranscriptAdapter.sessionID(fromTranscriptURL: url), "session-uuid-123")
    }

    func testDetectsToolPermissionApprovalFromDatabaseAndTransitionsBackToWorking() throws {
        let sessionID = "approval-session-456"
        let sessionDir = tempBrainDir.appendingPathComponent(sessionID)
        let logsDir = sessionDir.appendingPathComponent(".system_generated/logs")
        try FileManager.default.createDirectory(at: logsDir, withIntermediateDirectories: true)
        let transcriptURL = logsDir.appendingPathComponent("transcript.jsonl")
        try Data().write(to: transcriptURL)

        let conversationsDir = tempBrainDir.appendingPathComponent("conversations")
        try FileManager.default.createDirectory(at: conversationsDir, withIntermediateDirectories: true)
        let dbURL = conversationsDir.appendingPathComponent("\(sessionID).db")

        // Set up SQLite steps table in the session database
        var db: OpaquePointer?
        guard sqlite3_open(dbURL.path, &db) == SQLITE_OK else {
            XCTFail("Failed to create test SQLite database")
            return
        }
        sqlite3_exec(db, "CREATE TABLE steps (idx INTEGER PRIMARY KEY, step_type INTEGER, status INTEGER);", nil, nil, nil)
        sqlite3_close(db)

        let adapter = AntigravityTranscriptAdapter(
            baseBrainURL: tempBrainDir,
            conversationsDirectoryURL: conversationsDir
        )
        let collector = Collector()
        adapter.setHandlerForTesting { collector.append($0) }
        adapter.checkForUpdates()

        let handle = try FileHandle(forWritingTo: transcriptURL)
        defer { try? handle.close() }

        // 1. User Input -> .working
        let userLine = "{\"step_index\":1,\"source\":\"USER_EXPLICIT\",\"type\":\"USER_INPUT\",\"status\":\"DONE\",\"content\":\"run inspection\"}\n"
        handle.seekToEndOfFile()
        handle.write(Data(userLine.utf8))
        adapter.checkForUpdates()

        var lifecycle = collector.snapshot.filter { $0.kind != .usage }
        XCTAssertEqual(lifecycle.count, 1)
        XCTAssertEqual(lifecycle.last?.kind, .working)

        // 2. Model outputs tool call for run_command
        let commandLine = "{\"step_index\":2,\"source\":\"MODEL\",\"type\":\"PLANNER_RESPONSE\",\"status\":\"DONE\",\"tool_calls\":[{\"name\":\"run_command\",\"args\":{\"CommandLine\":\"ls -la\"}}]}\n"
        handle.seekToEndOfFile()
        handle.write(Data(commandLine.utf8))
        adapter.checkForUpdates()

        // Still 1 lifecycle event because run_command is not ask_question and status is not yet 9
        lifecycle = collector.snapshot.filter { $0.kind != .usage }
        XCTAssertEqual(lifecycle.count, 1)

        // 3. Antigravity pauses execution and prompts user for permission (status == 9)
        var writeDB: OpaquePointer?
        sqlite3_open(dbURL.path, &writeDB)
        sqlite3_exec(writeDB, "INSERT INTO steps VALUES (2, 132, 9);", nil, nil, nil)
        sqlite3_close(writeDB)

        adapter.checkForUpdates()

        // Adapter must detect status == 9 and emit .needsApproval
        lifecycle = collector.snapshot.filter { $0.kind != .usage }
        XCTAssertEqual(lifecycle.count, 2)
        XCTAssertEqual(lifecycle.last?.kind, .needsApproval)
        XCTAssertEqual(lifecycle.last?.message, "Antigravity needs your approval!")

        // Repeated check does not emit duplicate .needsApproval
        adapter.checkForUpdates()
        lifecycle = collector.snapshot.filter { $0.kind != .usage }
        XCTAssertEqual(lifecycle.count, 2)

        // 4. User selects an option / approves (status becomes 3)
        sqlite3_open(dbURL.path, &writeDB)
        sqlite3_exec(writeDB, "UPDATE steps SET status = 3 WHERE idx = 2;", nil, nil, nil)
        sqlite3_close(writeDB)

        adapter.checkForUpdates()

        // Adapter detects status cleared from 9 and emits .working
        lifecycle = collector.snapshot.filter { $0.kind != .usage }
        XCTAssertEqual(lifecycle.count, 3)
        XCTAssertEqual(lifecycle.last?.kind, .working)
        XCTAssertEqual(lifecycle.last?.message, "Antigravity is working...")

        // 5. Command finishes and model completes turn
        let doneLine = "{\"step_index\":3,\"source\":\"MODEL\",\"type\":\"PLANNER_RESPONSE\",\"status\":\"DONE\",\"content\":\"all done\"}\n"
        handle.seekToEndOfFile()
        handle.write(Data(doneLine.utf8))
        adapter.checkForUpdates()

        lifecycle = collector.snapshot.filter { $0.kind != .usage }
        XCTAssertEqual(lifecycle.count, 4)
        XCTAssertEqual(lifecycle.last?.kind, .done)
        XCTAssertEqual(lifecycle.last?.message, "Antigravity is done!")
    }

    func testConcurrentTopLevelSessionsTrackedIndependentlyWithDistinctSessionIDs() throws {
        let session2Logs = tempBrainDir.appendingPathComponent("session-2/.system_generated/logs")
        try FileManager.default.createDirectory(at: session2Logs, withIntermediateDirectories: true)
        let transcript2 = session2Logs.appendingPathComponent("transcript.jsonl")
        FileManager.default.createFile(atPath: transcript2.path, contents: Data())

        let collector = Collector()
        let adapter = attachedAdapter(collector)

        // Both session-1 and session-2 seeded on attach
        XCTAssertEqual(Set(collector.usages.compactMap(\.sessionID)), ["session-1", "session-2"])

        // Start turns concurrently in both conversations
        let userInput = #"{"step_index":0,"source":"USER_EXPLICIT","type":"USER_INPUT","status":"DONE","content":"go"}"# + "\n"
        let h1 = try FileHandle(forWritingTo: transcriptFile)
        defer { try? h1.close() }
        try h1.seekToEnd()
        try h1.write(contentsOf: Data(userInput.utf8))

        let h2 = try FileHandle(forWritingTo: transcript2)
        defer { try? h2.close() }
        try h2.seekToEnd()
        try h2.write(contentsOf: Data(userInput.utf8))

        adapter.checkForUpdates()

        let workingEvents = collector.snapshot.filter { $0.kind == .working }
        XCTAssertEqual(workingEvents.count, 2)
        XCTAssertEqual(Set(workingEvents.compactMap(\.sessionID)), ["session-1", "session-2"])

        // Finish session-1 only; session-2 remains mid-turn
        let doneLine = #"{"step_index":1,"source":"MODEL","type":"PLANNER_RESPONSE","status":"DONE","content":"done 1"}"# + "\n"
        try h1.seekToEnd()
        try h1.write(contentsOf: Data(doneLine.utf8))

        adapter.checkForUpdates()

        let doneEventsAfterS1 = collector.snapshot.filter { $0.kind == .done }
        XCTAssertEqual(doneEventsAfterS1.count, 1)
        XCTAssertEqual(doneEventsAfterS1.first?.sessionID, "session-1")

        // Finish session-2 next
        try h2.seekToEnd()
        try h2.write(contentsOf: Data(doneLine.utf8))

        adapter.checkForUpdates()

        let doneEventsAfterS2 = collector.snapshot.filter { $0.kind == .done }
        XCTAssertEqual(doneEventsAfterS2.count, 2)
        XCTAssertEqual(Set(doneEventsAfterS2.compactMap(\.sessionID)), ["session-1", "session-2"])
    }

    func testSpawnedSubagentTranscriptsAreSkipped() throws {
        // 1. Pre-populated subagent transcript (step_index 0 SYSTEM_MESSAGE)
        let sub1Logs = tempBrainDir.appendingPathComponent("subagent-1/.system_generated/logs")
        try FileManager.default.createDirectory(at: sub1Logs, withIntermediateDirectories: true)
        let sub1Transcript = sub1Logs.appendingPathComponent("transcript.jsonl")
        let subHeader = #"{"step_index":0,"source":"SYSTEM","type":"SYSTEM_MESSAGE","status":"DONE","content":"task"}"# + "\n"
        try Data(subHeader.utf8).write(to: sub1Transcript)

        // 2. Empty subagent file attached at 0 bytes, then receives SYSTEM_MESSAGE at step 0
        let sub2Logs = tempBrainDir.appendingPathComponent("subagent-2/.system_generated/logs")
        try FileManager.default.createDirectory(at: sub2Logs, withIntermediateDirectories: true)
        let sub2Transcript = sub2Logs.appendingPathComponent("transcript.jsonl")
        FileManager.default.createFile(atPath: sub2Transcript.path, contents: Data())

        let collector = Collector()
        let adapter = attachedAdapter(collector)

        // subagent-1 is immediately excluded from candidates
        let initialCandidateSessionIDs = Set(adapter.sessionCandidates().compactMap { AntigravityTranscriptAdapter.sessionID(fromTranscriptURL: $0.url) })
        XCTAssertFalse(initialCandidateSessionIDs.contains("subagent-1"))
        XCTAssertTrue(initialCandidateSessionIDs.contains("session-1"))

        // Write subagent-2's initial SYSTEM_MESSAGE + a PLANNER_RESPONSE
        let hSub2 = try FileHandle(forWritingTo: sub2Transcript)
        defer { try? hSub2.close() }
        try hSub2.seekToEnd()
        let subTurn = subHeader + #"{"step_index":1,"source":"MODEL","type":"PLANNER_RESPONSE","status":"DONE","input_tokens":9999}"# + "\n"
        try hSub2.write(contentsOf: Data(subTurn.utf8))

        adapter.checkForUpdates()

        // Neither subagent emits live events or remains in candidates
        XCTAssertFalse(collector.snapshot.contains { $0.sessionID == "subagent-1" })
        XCTAssertFalse(collector.snapshot.contains { $0.sessionID == "subagent-2" && !$0.isSeed })
        let finalCandidateSessionIDs = Set(adapter.sessionCandidates().compactMap { AntigravityTranscriptAdapter.sessionID(fromTranscriptURL: $0.url) })
        XCTAssertEqual(finalCandidateSessionIDs, ["session-1"])
    }

    func testCancelledTurnReconciledViaConversationSummariesDatabase() throws {
        final class TestClock: @unchecked Sendable {
            var now: Date
            init(_ now: Date) { self.now = now }
        }

        let dbURL = tempBrainDir.deletingLastPathComponent().appendingPathComponent("summaries-\(UUID().uuidString).db")
        defer { try? FileManager.default.removeItem(at: dbURL) }

        var db: OpaquePointer?
        XCTAssertEqual(sqlite3_open(dbURL.path, &db), SQLITE_OK)
        XCTAssertEqual(sqlite3_exec(
            db,
            "CREATE TABLE conversation_summaries (conversation_id TEXT PRIMARY KEY, status TEXT NOT NULL);",
            nil, nil, nil
        ), SQLITE_OK)
        XCTAssertEqual(sqlite3_exec(
            db,
            "INSERT INTO conversation_summaries (conversation_id, status) VALUES ('session-1', 'CASCADE_RUN_STATUS_RUNNING');",
            nil, nil, nil
        ), SQLITE_OK)
        sqlite3_close(db)

        let t0 = Date()
        let clock = TestClock(t0)
        let collector = Collector()
        let adapter = AntigravityTranscriptAdapter(
            baseBrainURL: tempBrainDir,
            summariesDatabaseURL: dbURL,
            clock: { clock.now }
        )
        adapter.setHandlerForTesting { collector.append($0) }
        adapter.checkForUpdates()

        try append(#"{"step_index":0,"source":"USER_EXPLICIT","type":"USER_INPUT","status":"DONE","content":"run"}"#)
        adapter.checkForUpdates()
        XCTAssertEqual(collector.usages.last?.turnActive, true)

        // Simulate user clicking Stop in Antigravity IDE (summary flips to IDLE without appending PLANNER_RESPONSE)
        var db2: OpaquePointer?
        XCTAssertEqual(sqlite3_open(dbURL.path, &db2), SQLITE_OK)
        XCTAssertEqual(sqlite3_exec(
            db2,
            "UPDATE conversation_summaries SET status = 'CASCADE_RUN_STATUS_IDLE' WHERE conversation_id = 'session-1';",
            nil, nil, nil
        ), SQLITE_OK)
        sqlite3_close(db2)
        try FileManager.default.setAttributes([.modificationDate: t0.addingTimeInterval(4.0)], ofItemAtPath: dbURL.path)

        clock.now = t0.addingTimeInterval(4.0)
        adapter.checkForUpdates()

        XCTAssertEqual(collector.usages.last?.sessionID, "session-1")
        XCTAssertEqual(collector.usages.last?.turnActive, false)
        XCTAssertFalse(collector.snapshot.contains { $0.kind == .done }, "Cancelled turn clears silently without fake done popup")
    }

    func testStaleHistoricMidTurnFallbackSeedsContextWithoutMarkingTurnActive() throws {
        try append(
            #"{"step_index":0,"source":"USER_EXPLICIT","type":"USER_INPUT","status":"DONE"}"#,
            #"{"step_index":1,"source":"MODEL","type":"PLANNER_RESPONSE","status":"DONE","input_tokens":4000,"cache_read_tokens":6000,"tool_calls":[{"name":"run_command"}]}"#
        )
        let t0 = Date()
        // Mark transcript 2 hours old (> activeAttachWindow)
        try FileManager.default.setAttributes([.modificationDate: t0.addingTimeInterval(-7200)], ofItemAtPath: transcriptFile.path)

        let collector = Collector()
        let adapter = AntigravityTranscriptAdapter(baseBrainURL: tempBrainDir, clock: { t0 })
        adapter.setHandlerForTesting { collector.append($0) }
        adapter.checkForUpdates()

        XCTAssertEqual(collector.usages.count, 1)
        XCTAssertEqual(collector.usages.first?.isSeed, true)
        XCTAssertEqual(collector.usages.first?.contextTokens, 10_000)
        XCTAssertEqual(collector.usages.first?.turnActive, false, "Stale historic unfinished transcript must not report an active running turn on launch")
    }

    func testConcurrentSessionsIsolateDatabaseApprovalAndPreserveAskQuestion() throws {
        let session2Logs = tempBrainDir.appendingPathComponent("session-2/.system_generated/logs")
        try FileManager.default.createDirectory(at: session2Logs, withIntermediateDirectories: true)
        let transcript2 = session2Logs.appendingPathComponent("transcript.jsonl")
        FileManager.default.createFile(atPath: transcript2.path, contents: Data())

        let conversationsDir = tempBrainDir.appendingPathComponent("conversations")
        try FileManager.default.createDirectory(at: conversationsDir, withIntermediateDirectories: true)
        let db1URL = conversationsDir.appendingPathComponent("session-1.db")
        let db2URL = conversationsDir.appendingPathComponent("session-2.db")

        for url in [db1URL, db2URL] {
            var db: OpaquePointer?
            XCTAssertEqual(sqlite3_open(url.path, &db), SQLITE_OK)
            XCTAssertEqual(sqlite3_exec(db, "CREATE TABLE steps (idx INTEGER PRIMARY KEY, step_type INTEGER, status INTEGER);", nil, nil, nil), SQLITE_OK)
            sqlite3_close(db)
        }

        let adapter = AntigravityTranscriptAdapter(
            baseBrainURL: tempBrainDir,
            conversationsDirectoryURL: conversationsDir
        )
        let collector = Collector()
        adapter.setHandlerForTesting { collector.append($0) }
        adapter.checkForUpdates()

        let userInput = #"{"step_index":0,"source":"USER_EXPLICIT","type":"USER_INPUT","status":"DONE","content":"go"}"# + "\n"
        let h1 = try FileHandle(forWritingTo: transcriptFile)
        defer { try? h1.close() }
        try h1.seekToEnd()
        try h1.write(contentsOf: Data(userInput.utf8))

        let h2 = try FileHandle(forWritingTo: transcript2)
        defer { try? h2.close() }
        try h2.seekToEnd()
        try h2.write(contentsOf: Data(userInput.utf8))

        adapter.checkForUpdates()

        // session-1 enters DB step approval (status == 9)
        var db1: OpaquePointer?
        XCTAssertEqual(sqlite3_open(db1URL.path, &db1), SQLITE_OK)
        XCTAssertEqual(sqlite3_exec(db1, "INSERT INTO steps VALUES (1, 132, 9);", nil, nil, nil), SQLITE_OK)
        sqlite3_close(db1)

        // session-2 asks a question via transcript while its DB step status is 3 (not 9)
        let askLine = #"{"step_index":1,"source":"MODEL","type":"PLANNER_RESPONSE","status":"DONE","tool_calls":[{"name":"ask_question","args":{"questions":[]}}]}"# + "\n"
        try h2.seekToEnd()
        try h2.write(contentsOf: Data(askLine.utf8))

        var db2: OpaquePointer?
        XCTAssertEqual(sqlite3_open(db2URL.path, &db2), SQLITE_OK)
        XCTAssertEqual(sqlite3_exec(db2, "INSERT INTO steps VALUES (1, 100, 3);", nil, nil, nil), SQLITE_OK)
        sqlite3_close(db2)

        adapter.checkForUpdates()

        let approvalEvents = collector.snapshot.filter { $0.kind == .needsApproval }
        XCTAssertEqual(approvalEvents.count, 2)
        XCTAssertEqual(approvalEvents.first(where: { $0.sessionID == "session-1" })?.message, "Antigravity needs your approval!")
        XCTAssertEqual(approvalEvents.first(where: { $0.sessionID == "session-2" })?.message, "Antigravity needs input!")

        // Subsequent poll must NOT emit spurious .working for session-2 (ask_question remains pending)
        let workingCountBeforeApprove = collector.snapshot.filter { $0.kind == .working }.count
        adapter.checkForUpdates()
        XCTAssertEqual(collector.snapshot.filter { $0.kind == .working }.count, workingCountBeforeApprove)

        // Approving session-1 (status -> 3) transitions ONLY session-1 back to .working
        XCTAssertEqual(sqlite3_open(db1URL.path, &db1), SQLITE_OK)
        XCTAssertEqual(sqlite3_exec(db1, "UPDATE steps SET status = 3 WHERE idx = 1;", nil, nil, nil), SQLITE_OK)
        sqlite3_close(db1)

        adapter.checkForUpdates()

        let workingEventsAfterApprove = collector.snapshot.filter { $0.kind == .working }
        XCTAssertEqual(workingEventsAfterApprove.count, workingCountBeforeApprove + 1)
        XCTAssertEqual(workingEventsAfterApprove.last?.sessionID, "session-1")
    }

    func testMidConversationSystemMessageWakesTurnToWorking() throws {
        try append(
            #"{"step_index":0,"source":"USER_EXPLICIT","type":"USER_INPUT","status":"DONE","content":"start"}"#,
            #"{"step_index":1,"source":"MODEL","type":"PLANNER_RESPONSE","status":"DONE","content":"waiting on background command"}"#
        )

        let collector = Collector()
        let adapter = attachedAdapter(collector)

        // Initially idle after finished PLANNER_RESPONSE
        XCTAssertEqual(collector.usages.last?.turnActive, false)

        // Antigravity wakes the agent with a mid-conversation SYSTEM_MESSAGE (step_index > 0)
        try append(#"{"step_index":2,"source":"SYSTEM","type":"SYSTEM_MESSAGE","status":"DONE","content":"Background task finished"}"#)
        adapter.checkForUpdates()

        XCTAssertEqual(collector.usages.last?.turnActive, true)
        XCTAssertTrue(collector.snapshot.contains { $0.kind == .working && $0.sessionID == "session-1" })
    }
}
