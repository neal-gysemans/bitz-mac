import XCTest
@testable import BitzCore

final class ClaudeCodeMultiSessionTests: XCTestCase {
    private final class Collector: @unchecked Sendable {
        private let lock = NSLock()
        private var events: [AgentEvent] = []

        func append(_ event: AgentEvent) {
            lock.withLock { events.append(event) }
        }

        func drain() -> [AgentEvent] {
            lock.withLock {
                defer { events = [] }
                return events
            }
        }

        func events(forSessionID sessionID: String) -> [AgentEvent] {
            lock.withLock {
                events.filter { $0.sessionID == sessionID }
            }
        }
    }

    private final class TestClock: @unchecked Sendable {
        private let lock = NSLock()
        private var current: Date

        init(_ start: Date) { current = start }

        var now: Date {
            get { lock.withLock { current } }
            set { lock.withLock { current = newValue } }
        }
    }

    private let t0 = Date(timeIntervalSinceReferenceDate: 800_000_000)
    private var root: URL!
    private var projects: URL!
    private var clock: TestClock!
    private var collector: Collector!

    override func setUpWithError() throws {
        try super.setUpWithError()
        root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        projects = root.appendingPathComponent("projects")
        try FileManager.default.createDirectory(at: projects, withIntermediateDirectories: true)
        clock = TestClock(t0)
        collector = Collector()
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
        try super.tearDownWithError()
    }

    // MARK: - Fixture Helpers

    private func json(_ object: [String: Any]) -> String {
        String(decoding: try! JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]), as: UTF8.self)
    }

    private func assistant(
        tokens: (Int, Int, Int)? = (1000, 0, 50_000),
        tools: [(id: String, name: String, input: [String: Any])] = [],
        stop: String? = "tool_use",
        sidechain: Bool = false,
        cwd: String? = nil
    ) -> String {
        var message: [String: Any] = [
            "role": "assistant",
            "content": tools.map { ["type": "tool_use", "id": $0.id, "name": $0.name, "input": $0.input] },
        ]
        if let tokens {
            message["usage"] = [
                "input_tokens": tokens.0,
                "cache_creation_input_tokens": tokens.1,
                "cache_read_input_tokens": tokens.2,
                "output_tokens": 10,
            ]
        }
        if let stop { message["stop_reason"] = stop }
        var line: [String: Any] = ["type": "assistant", "isSidechain": sidechain, "message": message]
        if let cwd { line["cwd"] = cwd }
        return json(line)
    }

    private func userPrompt(_ text: String = "do it", sidechain: Bool = false, cwd: String? = nil) -> String {
        var line: [String: Any] = [
            "type": "user",
            "isSidechain": sidechain,
            "message": ["role": "user", "content": text],
        ]
        if let cwd { line["cwd"] = cwd }
        return json(line)
    }

    private func toolResult(_ id: String, cwd: String? = nil) -> String {
        var line: [String: Any] = [
            "type": "user",
            "message": ["role": "user", "content": [["type": "tool_result", "tool_use_id": id, "content": "ok"]]],
        ]
        if let cwd { line["cwd"] = cwd }
        return json(line)
    }

    @discardableResult
    private func makeSession(_ relativePath: String, _ lines: [String] = []) throws -> URL {
        let url = projects.appendingPathComponent(relativePath)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(lines.map { $0 + "\n" }.joined().utf8).write(to: url)
        return url
    }

    private func append(_ lines: [String], to url: URL) throws {
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: Data(lines.map { $0 + "\n" }.joined().utf8))
    }

    private func setModified(_ url: URL, _ date: Date) throws {
        try FileManager.default.setAttributes([.modificationDate: date], ofItemAtPath: url.path)
    }

    private func makeAdapter(
        activeAttachWindow: TimeInterval = ClaudeCodeTranscriptAdapter.activeAttachWindow,
        idleRetainWindow: TimeInterval = ClaudeCodeTranscriptAdapter.idleRetainWindow
    ) -> ClaudeCodeTranscriptAdapter {
        let clock = self.clock!
        let collector = self.collector!
        let adapter = ClaudeCodeTranscriptAdapter(
            projectsURL: projects,
            activeAttachWindow: activeAttachWindow,
            idleRetainWindow: idleRetainWindow,
            clock: { clock.now }
        )
        adapter.setHandlerForTesting { collector.append($0) }
        return adapter
    }

    // MARK: - Multi-Session Concurrent Tracking Tests

    func testConcurrentTrackingOfTwoSimultaneousSessionsWithDistinctSessionIDs() throws {
        // Setup Session 1 (worktree A) and Session 2 (worktree B)
        let session1URL = try makeSession("proj-worktree-a/session-aaa.jsonl", [
            userPrompt("build feature A", cwd: "/Volumes/DevDrive/Code/bitz-mac"),
        ])
        let session2URL = try makeSession("proj-worktree-b/session-bbb.jsonl", [
            userPrompt("run tests B", cwd: "/Volumes/DevDrive/Code/PhysiqueAtlas"),
        ])
        try setModified(session1URL, t0.addingTimeInterval(-10))
        try setModified(session2URL, t0.addingTimeInterval(-5))

        let adapter = makeAdapter()
        adapter.checkForUpdates()

        let initialEvents = collector.drain()
        XCTAssertEqual(adapter.followedSessionCount, 2)
        XCTAssertTrue(adapter.followedSessionIDs().contains("proj-worktree-a/session-aaa"))
        XCTAssertTrue(adapter.followedSessionIDs().contains("proj-worktree-b/session-bbb"))

        // Verify initial seed usage events carry distinct sessionIDs and auto-derived workingDir
        let session1Seeds = initialEvents.filter { $0.sessionID == "proj-worktree-a/session-aaa" }
        let session2Seeds = initialEvents.filter { $0.sessionID == "proj-worktree-b/session-bbb" }
        XCTAssertFalse(session1Seeds.isEmpty)
        XCTAssertFalse(session2Seeds.isEmpty)
        XCTAssertEqual(session1Seeds.first?.workingDir, "/Volumes/DevDrive/Code/bitz-mac")
        XCTAssertEqual(session2Seeds.first?.workingDir, "/Volumes/DevDrive/Code/PhysiqueAtlas")

        // Progress Session 1 to working with tool calls
        try append([
            assistant(tokens: (1000, 0, 15_000), tools: [("t1", "Edit", ["file": "A.swift"])], stop: "tool_use"),
        ], to: session1URL)

        // Progress Session 2 to working with different tool calls
        try append([
            assistant(tokens: (2000, 0, 25_000), tools: [("t2", "Bash", ["command": "cargo test"])], stop: "tool_use"),
        ], to: session2URL)

        adapter.checkForUpdates()
        let activeEvents = collector.drain()

        let s1Active = activeEvents.filter { $0.sessionID == "proj-worktree-a/session-aaa" }
        let s2Active = activeEvents.filter { $0.sessionID == "proj-worktree-b/session-bbb" }

        // Both sessions emitted .working with their own context tokens
        XCTAssertTrue(s1Active.contains(where: { $0.kind == .working }))
        XCTAssertTrue(s2Active.contains(where: { $0.kind == .working }))
        XCTAssertEqual(s1Active.last?.contextTokens, 16_000)
        XCTAssertEqual(s2Active.last?.contextTokens, 27_000)

        // Complete Session 1 while Session 2 remains in progress
        try append([
            toolResult("t1"),
            assistant(tokens: (1200, 0, 16_000), stop: "end_turn"),
        ], to: session1URL)

        adapter.checkForUpdates()
        let completionEvents = collector.drain()

        let s1Completion = completionEvents.filter { $0.sessionID == "proj-worktree-a/session-aaa" }
        let s2Completion = completionEvents.filter { $0.sessionID == "proj-worktree-b/session-bbb" }

        XCTAssertTrue(s1Completion.contains(where: { $0.kind == .done }), "Session 1 emits .done")
        XCTAssertEqual(s1Completion.last?.turnActive, false)

        // Session 2 is unaffected and still tracked
        XCTAssertEqual(s2Completion.count, 0, "Session 2 has no new events and was not prematurely closed")
        XCTAssertEqual(adapter.followedSessionCount, 2)
    }

    func testThreeParallelSessionsWithDistinctWorktreesAndIndependentContextReadings() throws {
        let s1 = try makeSession("alpha/sess-1.jsonl", [userPrompt()])
        let s2 = try makeSession("beta/sess-2.jsonl", [userPrompt()])
        let s3 = try makeSession("gamma/sess-3.jsonl", [userPrompt()])

        try setModified(s1, t0.addingTimeInterval(-20))
        try setModified(s2, t0.addingTimeInterval(-15))
        try setModified(s3, t0.addingTimeInterval(-10))

        let adapter = makeAdapter()
        adapter.checkForUpdates()
        XCTAssertEqual(adapter.followedSessionCount, 3)
        _ = collector.drain()

        // Give each session distinct context tokens
        try append([assistant(tokens: (500, 0, 10_000))], to: s1)
        try append([assistant(tokens: (800, 0, 45_000))], to: s2)
        try append([assistant(tokens: (1200, 0, 90_000))], to: s3)

        adapter.checkForUpdates()
        let events = collector.drain()

        let s1Events = events.filter { $0.sessionID == "alpha/sess-1" }
        let s2Events = events.filter { $0.sessionID == "beta/sess-2" }
        let s3Events = events.filter { $0.sessionID == "gamma/sess-3" }

        XCTAssertEqual(s1Events.last?.contextTokens, 10_500)
        XCTAssertEqual(s2Events.last?.contextTokens, 45_800)
        XCTAssertEqual(s3Events.last?.contextTokens, 91_200)

        XCTAssertEqual(s1Events.last?.workingDir, "alpha")
        XCTAssertEqual(s2Events.last?.workingDir, "beta")
        XCTAssertEqual(s3Events.last?.workingDir, "gamma")
    }

    // MARK: - Warning & Loop Isolation (No Bleed)

    func testIndependentLoopWarningsWithoutCrossSessionBleed() throws {
        let s1 = try makeSession("proj-a/loop-session.jsonl", [userPrompt()])
        let s2 = try makeSession("proj-b/healthy-session.jsonl", [userPrompt()])
        try setModified(s1, t0.addingTimeInterval(-10))
        try setModified(s2, t0.addingTimeInterval(-5))

        let adapter = makeAdapter()
        adapter.checkForUpdates()
        _ = collector.drain()

        // Session 1 repeats the exact same tool call 4 times to trigger a loop warning
        let repeatedTool = ("t1", "Bash", ["command": "cat foo.txt"])
        try append([
            assistant(tools: [repeatedTool]),
            toolResult("t1"),
            assistant(tools: [repeatedTool]),
            toolResult("t1"),
            assistant(tools: [repeatedTool]),
            toolResult("t1"),
            assistant(tools: [repeatedTool]),
        ], to: s1)

        // Session 2 runs normal distinct tools
        try append([
            assistant(tools: [("tA", "Edit", ["file": "A.swift"])]),
            toolResult("tA"),
            assistant(tools: [("tB", "Edit", ["file": "B.swift"])]),
        ], to: s2)

        adapter.checkForUpdates()
        let events = collector.drain()

        let s1Warnings = events.filter { $0.sessionID == "proj-a/loop-session" && $0.kind == .warning }
        let s2Warnings = events.filter { $0.sessionID == "proj-b/healthy-session" && $0.kind == .warning }

        XCTAssertEqual(s1Warnings.count, 1, "Session 1 must emit a loop warning")
        XCTAssertEqual(s1Warnings.first?.warningReason, .loop)
        XCTAssertEqual(s1Warnings.first?.sessionID, "proj-a/loop-session")

        XCTAssertEqual(s2Warnings.count, 0, "Session 2 must NOT receive or emit a loop warning")
    }

    // MARK: - Attach Windows & Stale Fallback

    func testActiveAttachWindowAttachesFreshTranscriptsAndIgnoresStaleUnlessEmpty() throws {
        // Stale transcript modified 1 hour ago (> 300s activeAttachWindow)
        let staleURL = try makeSession("proj-old/stale.jsonl", [userPrompt()])
        try setModified(staleURL, t0.addingTimeInterval(-3600))

        // Fresh transcript modified 30 seconds ago (<= 300s activeAttachWindow)
        let freshURL1 = try makeSession("proj-new/fresh1.jsonl", [userPrompt()])
        try setModified(freshURL1, t0.addingTimeInterval(-30))

        let adapter = makeAdapter()
        adapter.checkForUpdates()

        XCTAssertEqual(adapter.followedSessionCount, 1, "Only the fresh session attaches")
        XCTAssertTrue(adapter.followedSessionIDs().contains("proj-new/fresh1"))
        XCTAssertFalse(adapter.followedSessionIDs().contains("proj-old/stale"))

        // Add a second fresh session modified 5 seconds ago
        let freshURL2 = try makeSession("proj-new2/fresh2.jsonl", [userPrompt()])
        try setModified(freshURL2, t0.addingTimeInterval(-5))

        adapter.checkForUpdates()
        XCTAssertEqual(adapter.followedSessionCount, 2, "Second fresh session attaches concurrently")
        XCTAssertTrue(adapter.followedSessionIDs().contains("proj-new/fresh1"))
        XCTAssertTrue(adapter.followedSessionIDs().contains("proj-new2/fresh2"))
        XCTAssertFalse(adapter.followedSessionIDs().contains("proj-old/stale"), "Stale session is still ignored")
    }

    func testColdStartWithOnlyStaleTranscriptsAttachesNewestAsFallbackMarkedIdle() throws {
        // Both transcripts are stale (> 300s)
        let olderStale = try makeSession("proj-1/old-stale.jsonl", [
            userPrompt(),
            assistant(tokens: (500, 0, 5000), tools: [("t1", "Bash", ["cmd": "ls"])], stop: "tool_use"),
        ])
        let newerStale = try makeSession("proj-2/new-stale.jsonl", [
            userPrompt(),
            assistant(tokens: (800, 0, 8000), tools: [("t2", "Bash", ["cmd": "pwd"])], stop: "tool_use"),
        ])
        try setModified(olderStale, t0.addingTimeInterval(-7200))
        try setModified(newerStale, t0.addingTimeInterval(-3600))

        let adapter = makeAdapter()
        adapter.checkForUpdates()

        XCTAssertEqual(adapter.followedSessionCount, 1, "Only 1 session attaches as stale fallback")
        XCTAssertTrue(adapter.followedSessionIDs().contains("proj-2/new-stale"), "Newest stale session is chosen")
        XCTAssertFalse(adapter.followedSessionIDs().contains("proj-1/old-stale"))

        let events = collector.drain()
        XCTAssertEqual(events.count, 1)
        XCTAssertEqual(events.first?.isSeed, true)
        XCTAssertEqual(events.first?.turnActive, false, "Fallback transcript is marked idle on cold start")
        XCTAssertEqual(events.first?.pendingTools, 0)
    }

    // MARK: - Idle Retain Window & Pruning

    func testIdleRetainWindowPruningRetainsNewestSessionWhileCleaningInactiveOlderSessions() throws {
        // Three sessions initially active within activeAttachWindow:
        // Session A: finished, inactive turn (t0 - 100)
        // Session B: active turn with pending tool (t0 - 50)
        // Session C: finished, inactive turn, newest (t0 - 10)
        let sA = try makeSession("proj-a/sess-a.jsonl", [userPrompt(), assistant(stop: "end_turn")])
        let sB = try makeSession("proj-b/sess-b.jsonl", [userPrompt(), assistant(tools: [("t1", "Bash", [:])])])
        let sC = try makeSession("proj-c/sess-c.jsonl", [userPrompt(), assistant(stop: "end_turn")])

        try setModified(sA, t0.addingTimeInterval(-100))
        try setModified(sB, t0.addingTimeInterval(-50))
        try setModified(sC, t0.addingTimeInterval(-10))

        let adapter = makeAdapter(activeAttachWindow: 300.0, idleRetainWindow: 1800.0)
        adapter.checkForUpdates()
        XCTAssertEqual(adapter.followedSessionCount, 3, "All 3 sessions attached initially")
        _ = collector.drain()

        // Advance clock by 1850s so Session A and B have elapsed > 1800s since last activity
        clock.now = t0.addingTimeInterval(1850)

        // Session A is idle > 1800s with inactive turn -> pruned.
        // Session B is idle > 1800s but has active turn -> retained.
        // Session C is retained as newest session.
        adapter.checkForUpdates()

        XCTAssertEqual(adapter.followedSessionCount, 2)
        XCTAssertFalse(adapter.followedSessionIDs().contains("proj-a/sess-a"), "Inactive old session A pruned")
        XCTAssertTrue(adapter.followedSessionIDs().contains("proj-b/sess-b"), "Active turn session B retained")
        XCTAssertTrue(adapter.followedSessionIDs().contains("proj-c/sess-c"), "Newest session C retained")
    }

    // MARK: - Subagent Sidechain Exclusion

    func testSubagentSidechainLinesExcludedFromTopLevelTracking() throws {
        let session = try makeSession("proj/sidechain-test.jsonl", [
            userPrompt("top level prompt"),
            assistant(tokens: (100, 0, 1000), tools: [("tTop", "Edit", ["path": "Main.swift"])], stop: "tool_use"),
        ])
        try setModified(session, t0.addingTimeInterval(-10))

        let adapter = makeAdapter()
        adapter.checkForUpdates()
        _ = collector.drain()

        // Append subagent line with isSidechain: true (contains high token usage 99k and subagent tool call)
        try append([
            assistant(
                tokens: (9000, 0, 90_000),
                tools: [("tSub", "Bash", ["command": "subagent helper"])],
                stop: "tool_use",
                sidechain: true
            ),
        ], to: session)

        adapter.checkForUpdates()
        let sidechainEvents = collector.drain()
        let lifecycleEvents = sidechainEvents.filter { $0.kind != .usage }
        XCTAssertEqual(lifecycleEvents.count, 0, "Subagent sidechain lines produce no lifecycle events")
        // Token usage must NOT adopt subagent 99,000 tokens
        XCTAssertEqual(sidechainEvents.last?.contextTokens, 1100)

        // Append regular top-level line
        try append([
            toolResult("tTop"),
            assistant(tokens: (150, 0, 1100), stop: "end_turn", sidechain: false),
        ], to: session)

        adapter.checkForUpdates()
        let topEvents = collector.drain()

        let doneEvents = topEvents.filter { $0.kind == .done }
        XCTAssertEqual(doneEvents.count, 1)
        XCTAssertEqual(topEvents.last?.contextTokens, 1250, "Context tokens reflect top level, ignoring sidechain")
    }

    // MARK: - Stop Lifecycle

    func testStopCleansUpAllFollowedSessionsAndState() throws {
        let s1 = try makeSession("proj-1/s1.jsonl", [userPrompt()])
        let s2 = try makeSession("proj-2/s2.jsonl", [userPrompt()])
        try setModified(s1, t0.addingTimeInterval(-10))
        try setModified(s2, t0.addingTimeInterval(-5))

        let adapter = makeAdapter()
        adapter.checkForUpdates()
        XCTAssertEqual(adapter.followedSessionCount, 2)

        adapter.stop()
        XCTAssertEqual(adapter.followedSessionCount, 0)
        XCTAssertEqual(adapter.followedSessionIDs(), [])
    }
}
