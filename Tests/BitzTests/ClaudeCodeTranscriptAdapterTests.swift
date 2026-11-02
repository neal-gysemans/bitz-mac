import XCTest
@testable import BitzCore

final class ClaudeCodeTranscriptAdapterTests: XCTestCase {
    private final class Collector: @unchecked Sendable {
        private let lock = NSLock()
        private var events: [AgentEvent] = []
        func append(_ event: AgentEvent) { lock.withLock { events.append(event) } }
        /// Returns and clears everything collected so far.
        func drain() -> [AgentEvent] { lock.withLock { defer { events = [] }; return events } }
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

    // MARK: - Fixture lines (synthetic shapes only, no real transcript content)

    private func json(_ object: [String: Any]) -> String {
        String(decoding: try! JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]), as: UTF8.self)
    }

    private func assistant(
        tokens: (Int, Int, Int)? = (1000, 0, 50_000),
        tools: [(id: String, name: String, input: [String: Any])] = [],
        stop: String? = "tool_use",
        sidechain: Bool = false
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
        return json(["type": "assistant", "isSidechain": sidechain, "message": message])
    }

    private func userPrompt(_ text: String = "do it") -> String {
        json(["type": "user", "isSidechain": false, "message": ["role": "user", "content": text]])
    }

    private func toolResult(_ id: String) -> String {
        json(["type": "user", "message": ["role": "user", "content": [["type": "tool_result", "tool_use_id": id, "content": "ok"]]]])
    }

    private func system(_ subtype: String) -> String {
        json(["type": "system", "subtype": subtype])
    }

    private func entries(_ line: String) -> [SessionLogEntry] {
        ClaudeCodeTranscriptAdapter.entries(fromLine: Data(line.utf8))
    }

    // MARK: - Fixture files

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

    /// Adapter wired to the temp `projects/` dir, the test clock and the collector; polls only via `checkForUpdates()`.
    private func makeAdapter() -> ClaudeCodeTranscriptAdapter {
        let clock = self.clock!
        let collector = self.collector!
        let adapter = ClaudeCodeTranscriptAdapter(projectsURL: projects, clock: { clock.now })
        adapter.setHandlerForTesting { collector.append($0) }
        return adapter
    }

    private func lifecycle(_ events: [AgentEvent]) -> [AgentEventKind] {
        events.map(\.kind).filter { $0 != .usage }
    }

    private func usage(_ events: [AgentEvent]) -> [AgentEvent] {
        events.filter { $0.kind == .usage }
    }

    // MARK: - Parser

    func testParserMapsAssistantUserAndSystemLines() {
        let input: [String: Any] = ["command": "ls", "cwd": "/tmp"]
        XCTAssertEqual(
            entries(assistant(tokens: (1000, 200, 50_000), tools: [("t1", "Bash", input)], stop: "end_turn")),
            [
                .assistantOutput(contextTokens: 51_200),
                .toolCall(id: "t1", name: "Bash", fingerprint: AgentSessionTracker.fingerprint(name: "Bash", input: input)),
                .turnEnd(isDone: true),
            ]
        )
        XCTAssertEqual(entries(assistant(tokens: nil, stop: nil)), [.assistantOutput(contextTokens: nil)])
        XCTAssertEqual(
            entries(json(["type": "assistant", "message": ["usage": ["input_tokens": 7]]])),
            [.assistantOutput(contextTokens: 7)],
            "missing usage parts count as 0"
        )

        XCTAssertEqual(entries(userPrompt()), [.prompt])
        XCTAssertEqual(entries(json(["type": "user", "message": ["content": [["type": "text", "text": "hi"]]]])), [.prompt])
        XCTAssertEqual(entries(toolResult("t1")), [.toolResult(id: "t1")])
        XCTAssertEqual(entries(userPrompt("[Request interrupted by user]")), [.turnEnd(isDone: false)])
        XCTAssertEqual(
            entries(json(["type": "user", "message": ["content": [
                ["type": "tool_result", "tool_use_id": "t2", "content": "x"],
                ["type": "text", "text": "[Request interrupted by user for tool use]"],
            ]]])),
            [.toolResult(id: "t2"), .turnEnd(isDone: false)]
        )

        XCTAssertEqual(entries(system("turn_duration")), [.turnEnd(isDone: false)])
        XCTAssertEqual(entries(system("stop_hook_summary")), [.turnEnd(isDone: false)])
        XCTAssertEqual(entries(system("compact_boundary")), [.compaction])
    }

    func testParserSkipsSidechainMetaAndUnknownLines() {
        XCTAssertEqual(entries(assistant(sidechain: true)), [])
        XCTAssertEqual(entries(json(["type": "user", "isSidechain": true, "message": ["content": "sub prompt"]])), [])
        XCTAssertEqual(entries(json(["type": "user", "isMeta": true, "message": ["content": "meta"]])), [])
        XCTAssertEqual(entries(system("local_command")), [])
        XCTAssertEqual(entries(json(["type": "attachment"])), [])
        XCTAssertEqual(entries(json(["type": "file-history-snapshot"])), [])
        XCTAssertEqual(entries(json(["type": "assistant", "message": "not a dict"])), [])
        XCTAssertEqual(entries("{}"), [])
        XCTAssertEqual(entries("[1,2]"), [])
        XCTAssertEqual(entries("not json"), [])
        XCTAssertEqual(entries("{\"type\":\"assistant\",\"mess"), [], "fragment of a seeded line")
    }

    func testParserSkipsSyntheticAssistantLines() {
        let synthetic = json(["type": "assistant", "message": [
            "model": "<synthetic>", "role": "assistant", "stop_reason": "stop_sequence",
            "usage": ["input_tokens": 0, "cache_creation_input_tokens": 0, "cache_read_input_tokens": 0],
            "content": [["type": "text", "text": "No response requested."]],
        ] as [String: Any]])
        XCTAssertEqual(entries(synthetic), [], "A placeholder never resets the context reading or starts a turn")
    }

    // MARK: - Adapter

    func testFullTurnEmitsWorkingThenDoneAndUsage() throws {
        let session = try makeSession("proj/session-1.jsonl")
        let adapter = makeAdapter()
        adapter.checkForUpdates()
        let seeded = collector.drain()
        XCTAssertEqual(seeded.map(\.kind), [.usage], "an empty session still seeds one reading")
        XCTAssertEqual(seeded.first?.isSeed, true)
        XCTAssertNil(seeded.first?.contextTokens)

        try append([
            userPrompt(),
            assistant(tokens: (1000, 0, 50_000), tools: [("t1", "Bash", ["command": "make"])]),
        ], to: session)
        adapter.checkForUpdates()
        let first = collector.drain()
        XCTAssertEqual(lifecycle(first), [.working])
        XCTAssertEqual(first.first?.agentID, "claude")
        XCTAssertEqual(usage(first).count, 1)
        XCTAssertEqual(usage(first).last?.contextTokens, 51_000)
        XCTAssertEqual(usage(first).last?.turnActive, true)

        try append([
            toolResult("t1"),
            assistant(tokens: (2000, 100, 60_000), stop: "end_turn"),
            system("turn_duration"),
        ], to: session)
        adapter.checkForUpdates()
        let second = collector.drain()
        XCTAssertEqual(lifecycle(second), [.done])
        XCTAssertEqual(usage(second).count, 1)
        XCTAssertEqual(usage(second).last?.contextTokens, 62_100)
        XCTAssertEqual(usage(second).last?.turnActive, false)
        XCTAssertEqual(usage(second).last?.pendingTools, 0)
        XCTAssertFalse((first + second).contains(where: \.isSeed))

        adapter.checkForUpdates()
        XCTAssertEqual(collector.drain(), [], "no new bytes, no events")
    }

    func testLocalCommandPromptWithoutReplyEmitsNoWorking() throws {
        let session = try makeSession("proj/session-1.jsonl")
        let adapter = makeAdapter()
        adapter.checkForUpdates()
        _ = collector.drain() // seed reading

        try append([userPrompt("/status"), system("local_command")], to: session)
        adapter.checkForUpdates()

        let events = collector.drain()
        XCTAssertEqual(lifecycle(events), [])
        XCTAssertEqual(usage(events).last?.turnActive, false)
    }

    func testInterruptEndsTurnSilently() throws {
        let session = try makeSession("proj/session-1.jsonl")
        let adapter = makeAdapter()
        adapter.checkForUpdates()
        try append([userPrompt(), assistant(tools: [("t1", "Bash", ["command": "sleep 100"])])], to: session)
        adapter.checkForUpdates()
        XCTAssertEqual(lifecycle(collector.drain()), [.working])

        try append([userPrompt("[Request interrupted by user for tool use]")], to: session)
        adapter.checkForUpdates()

        let events = collector.drain()
        XCTAssertEqual(lifecycle(events), [], "interrupt never says done")
        XCTAssertEqual(usage(events).last?.turnActive, false)
        XCTAssertEqual(usage(events).last?.pendingTools, 0)
    }

    func testFourIdenticalToolCallsEmitOneLoopWarning() throws {
        let session = try makeSession("proj/session-1.jsonl")
        let adapter = makeAdapter()
        adapter.checkForUpdates()

        var lines = [userPrompt()]
        for n in 1...5 {
            lines += [assistant(tools: [("t\(n)", "Read", ["file_path": "/tmp/a.swift"])]), toolResult("t\(n)")]
        }
        try append(lines, to: session)
        adapter.checkForUpdates()

        let warnings = collector.drain().filter { $0.kind == .warning }
        XCTAssertEqual(warnings.count, 1)
        XCTAssertEqual(warnings.first?.metadata?[AgentEvent.MetadataKey.reason], "loop")
        XCTAssertEqual(warnings.first?.warningReason, .loop)
    }

    func testPendingToolReportedWhileToolRuns() throws {
        let session = try makeSession("proj/session-1.jsonl")
        let adapter = makeAdapter()
        adapter.checkForUpdates()

        try append([userPrompt(), assistant(tools: [("t1", "Bash", ["command": "swift test"])])], to: session)
        adapter.checkForUpdates()
        let running = usage(collector.drain()).last
        XCTAssertEqual(running?.pendingTools, 1)
        XCTAssertEqual(running?.turnActive, true)

        try append([toolResult("t1")], to: session)
        adapter.checkForUpdates()
        let finished = usage(collector.drain()).last
        XCTAssertEqual(finished?.pendingTools, 0)
        XCTAssertEqual(finished?.turnActive, true)
    }

    func testIgnoresNestedSubagentLogs() throws {
        let topLevel = try makeSession("proj/session-1.jsonl")
        let nested = try makeSession("proj/session-1/subagents/agent-1.jsonl")
        try makeSession("proj/notes.txt")
        try setModified(topLevel, t0.addingTimeInterval(-100))
        try setModified(nested, t0)
        let adapter = makeAdapter()

        XCTAssertEqual(adapter.sessionCandidates().map(\.url.lastPathComponent), ["session-1.jsonl"])

        adapter.checkForUpdates()
        XCTAssertEqual(collector.drain().map(\.kind), [.usage], "seed of the top-level session")
        try append([userPrompt(), assistant(tools: [("s1", "Grep", ["pattern": "x"])])], to: nested)
        try setModified(nested, t0)
        adapter.checkForUpdates()
        XCTAssertEqual(collector.drain(), [], "subagent log is never followed")

        try append([userPrompt(), assistant()], to: topLevel)
        adapter.checkForUpdates()
        XCTAssertEqual(lifecycle(collector.drain()), [.working])
    }

    func testStartupSeedsUsageSilentlyFromTail() throws {
        // Ends mid-turn with a pending tool: the seed primes that turn without emitting working (FR-014).
        let session = try makeSession("proj/session-1.jsonl", [
            userPrompt(),
            assistant(tokens: (1000, 0, 50_000), tools: [("t1", "Bash", ["command": "a"])]),
            toolResult("t1"),
            assistant(tokens: (3000, 0, 90_000), tools: [("t2", "Bash", ["command": "b"])]),
            json(["type": "attachment"]),
        ])
        let clock = self.clock!
        let collector = self.collector!
        let adapter = ClaudeCodeTranscriptAdapter(projectsURL: projects, clock: { clock.now })

        adapter.start { collector.append($0) }
        defer { adapter.stop() }

        let seeded = collector.drain()
        XCTAssertEqual(seeded.map(\.kind), [.usage])
        XCTAssertEqual(seeded.first?.isSeed, true)
        XCTAssertEqual(seeded.first?.contextTokens, 93_000)
        XCTAssertEqual(seeded.first?.turnActive, true)
        XCTAssertEqual(seeded.first?.pendingTools, 1)

        try append([toolResult("t2")], to: session)
        adapter.checkForUpdates()
        let after = collector.drain()
        XCTAssertEqual(lifecycle(after), [], "seed lines are never replayed as events")
        XCTAssertEqual(usage(after).last?.turnActive, true)
        XCTAssertEqual(usage(after).last?.pendingTools, 0)
        XCTAssertEqual(usage(after).last?.isSeed, false)
    }

    func testSwitchesToNewerSessionOnlyAfterIdleDelay() throws {
        let current = try makeSession("proj-a/a.jsonl", [
            userPrompt(),
            assistant(tokens: (1, 0, 1000), tools: [("a1", "Bash", ["command": "x"])]),
        ])
        try setModified(current, t0.addingTimeInterval(-5))
        let adapter = makeAdapter()
        adapter.checkForUpdates()
        let attached = collector.drain()
        XCTAssertEqual(attached.map(\.contextTokens), [1001])
        XCTAssertEqual(attached.first?.turnActive, true)

        let newer = try makeSession("proj-b/b.jsonl", [assistant(tokens: (2, 0, 2000), stop: "end_turn")])
        try setModified(newer, t0.addingTimeInterval(-1))
        adapter.checkForUpdates()
        XCTAssertEqual(collector.drain(), [], "current session was active within the idle delay")

        clock.now = t0.addingTimeInterval(SessionLogTail.idleSwitchDelay + 1)
        adapter.checkForUpdates()
        let switched = collector.drain()
        XCTAssertEqual(switched.map(\.kind), [.usage])
        XCTAssertEqual(switched.first?.isSeed, true)
        XCTAssertEqual(switched.first?.contextTokens, 2002)
        XCTAssertEqual(switched.first?.turnActive, false, "stale turn of the previous session is cleared")
        XCTAssertEqual(switched.first?.pendingTools, 0)
    }

    // MARK: - Attach mid-session (FR-014)

    func testFirstTurnInProgressOnAttachIsTracked() throws {
        let session = try makeSession("proj/session-1.jsonl", [userPrompt()])
        let adapter = makeAdapter()
        adapter.checkForUpdates()

        try append([assistant()], to: session)
        adapter.checkForUpdates()
        try append([assistant(stop: "end_turn")], to: session)
        adapter.checkForUpdates()

        XCTAssertEqual(lifecycle(collector.drain()), [.working, .done])
    }

    func testAttachMidTurnEndsWithSingleDone() throws {
        let session = try makeSession("proj/session-1.jsonl", [
            userPrompt(),
            assistant(tools: [("t1", "Bash", ["command": "make"])]),
        ])
        let adapter = makeAdapter()
        adapter.checkForUpdates()
        let seed = usage(collector.drain()).first
        XCTAssertEqual(seed?.isSeed, true)
        XCTAssertEqual(seed?.turnActive, true)
        XCTAssertEqual(seed?.pendingTools, 1)

        try append([toolResult("t1"), assistant(stop: "end_turn")], to: session)
        adapter.checkForUpdates()

        XCTAssertEqual(lifecycle(collector.drain()), [.done])
    }

    func testSeedUsageEmittedWithoutTokensForFinishedSeed() throws {
        try makeSession("proj/session-1.jsonl", [userPrompt(), assistant(tokens: nil, stop: "end_turn")])
        let adapter = makeAdapter()
        adapter.checkForUpdates()

        let seeded = collector.drain()
        XCTAssertEqual(seeded.map(\.kind), [.usage], "finished seed turn emits no working or done")
        XCTAssertEqual(seeded.first?.isSeed, true)
        XCTAssertNil(seeded.first?.contextTokens)
        XCTAssertEqual(seeded.first?.turnActive, false)
        XCTAssertEqual(seeded.first?.pendingTools, 0)
    }
}
