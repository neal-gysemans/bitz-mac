import XCTest
@testable import BitzCore

final class AgentSignalEdgeCasesTests: XCTestCase {
    private final class Collector: @unchecked Sendable {
        private let lock = NSLock()
        private var events: [AgentEvent] = []
        func append(_ event: AgentEvent) { lock.withLock { events.append(event) } }
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

    private let t0 = Date(timeIntervalSinceReferenceDate: 810_000_000)
    private var root: URL!
    private var projects: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        projects = root.appendingPathComponent("projects")
        try FileManager.default.createDirectory(at: projects, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
        try super.tearDownWithError()
    }

    // MARK: - Helpers

    private func json(_ object: [String: Any]) -> String {
        String(decoding: try! JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]), as: UTF8.self)
    }

    private func claudeAssistant(
        tokens: (Int, Int, Int)? = (1000, 0, 50_000),
        tools: [(id: String, name: String, input: [String: Any])] = [],
        stop: String? = "tool_use"
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
        return json(["type": "assistant", "isSidechain": false, "message": message])
    }

    private func claudePrompt(_ text: String = "do it") -> String {
        json(["type": "user", "isSidechain": false, "message": ["role": "user", "content": text]])
    }

    @discardableResult
    private func makeSession(_ relativePath: String, _ lines: [String] = [], modified: Date? = nil) throws -> URL {
        let url = projects.appendingPathComponent(relativePath)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(lines.map { $0 + "\n" }.joined().utf8).write(to: url)
        if let modified {
            try FileManager.default.setAttributes([.modificationDate: modified], ofItemAtPath: url.path)
        }
        return url
    }

    private func append(_ lines: [String], to url: URL, modified: Date? = nil) throws {
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: Data(lines.map { $0 + "\n" }.joined().utf8))
        if let modified {
            try FileManager.default.setAttributes([.modificationDate: modified], ofItemAtPath: url.path)
        }
    }

    @MainActor
    private func makeIsolatedMonitor(clock: TestClock) -> (AgentMonitorService, UserDefaults, String) {
        let suiteName = "BitzTests.AgentSignalEdgeCases.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        let service = AgentMonitorService(clock: { clock.now }, userDefaults: defaults)
        return (service, defaults, suiteName)
    }

    // MARK: - 1. Concurrent Claude Code sessions (#72)

    func testConcurrentClaudeSessionsIsolateTokensAndSessionIDsAcrossSameStemProjects() throws {
        let clock = TestClock(t0)
        let collector = Collector()
        let adapter = ClaudeCodeTranscriptAdapter(projectsURL: projects, clock: { clock.now })
        adapter.setHandlerForTesting { collector.append($0) }

        // Session A in proj-a uses filename stem `session-1` with 120k context tokens.
        let sessionA = try makeSession("proj-a/session-1.jsonl", [
            claudePrompt(),
            claudeAssistant(tokens: (20_000, 0, 100_000), tools: [("a1", "Bash", ["command": "swift test"])]),
        ], modified: t0.addingTimeInterval(-5))

        adapter.checkForUpdates()
        let initialEvents = collector.drain()
        XCTAssertEqual(initialEvents.count, 1)
        XCTAssertEqual(initialEvents.first?.sessionID, "proj-a/session-1")
        XCTAssertEqual(initialEvents.first?.contextTokens, 120_000)
        XCTAssertEqual(initialEvents.first?.turnActive, true)

        // Session B in proj-b uses the same stem `session-1`, but has only a user prompt (no tokens yet).
        let sessionB = try makeSession("proj-b/session-1.jsonl", [
            claudePrompt("start fresh"),
        ], modified: t0.addingTimeInterval(-1))

        adapter.checkForUpdates()
        let seedB = collector.drain()
        XCTAssertEqual(seedB.map(\.kind), [.usage])
        XCTAssertEqual(seedB.first?.isSeed, true)
        XCTAssertEqual(seedB.first?.sessionID, "proj-b/session-1")
        XCTAssertNil(seedB.first?.contextTokens, "New session without tokens must never inherit Session A's latestContextTokens")
        XCTAssertEqual(seedB.first?.turnActive, false)

        // Append assistant output to Session B and finish Session A on the same poll.
        try append([claudeAssistant(tokens: (15_000, 0, 0), stop: "tool_use")], to: sessionB)
        try append([claudeAssistant(tokens: (21_000, 0, 100_000), stop: "end_turn")], to: sessionA)
        adapter.checkForUpdates()

        let concurrent = collector.drain()
        let doneA = concurrent.filter { $0.sessionID == "proj-a/session-1" && $0.kind == .done }
        let workingB = concurrent.filter { $0.sessionID == "proj-b/session-1" && $0.kind == .working }
        let usageA = concurrent.last { $0.sessionID == "proj-a/session-1" && $0.kind == .usage }
        let usageB = concurrent.last { $0.sessionID == "proj-b/session-1" && $0.kind == .usage }

        XCTAssertEqual(doneA.count, 1, "Session A must emit .done without being swallowed")
        XCTAssertEqual(workingB.count, 1, "Session B must emit .working independently")
        XCTAssertEqual(usageA?.contextTokens, 121_000)
        XCTAssertEqual(usageA?.turnActive, false)
        XCTAssertEqual(usageB?.contextTokens, 15_000)
        XCTAssertEqual(usageB?.turnActive, true)
    }

    func testSamePollFinishAndNewSessionDiscoveryEmitsDoneWithoutSwallowing() throws {
        let clock = TestClock(t0)
        let collector = Collector()
        let adapter = ClaudeCodeTranscriptAdapter(projectsURL: projects, clock: { clock.now })
        adapter.setHandlerForTesting { collector.append($0) }

        let session1 = try makeSession("proj/s1.jsonl", [
            claudePrompt(),
            claudeAssistant(tokens: (1_000, 0, 20_000)),
        ], modified: t0.addingTimeInterval(-10))
        adapter.checkForUpdates()
        _ = collector.drain()

        // On the same poll: s1 finishes its turn AND a brand new s2 in the same project starts and finishes.
        try append([claudeAssistant(tokens: (1_000, 0, 21_000), stop: "end_turn")], to: session1, modified: t0)
        _ = try makeSession("proj/s2.jsonl", [
            claudePrompt(),
            claudeAssistant(tokens: (500, 0, 5_000), stop: "end_turn"),
        ], modified: t0)

        adapter.checkForUpdates()
        let events = collector.drain()

        XCTAssertEqual(events.filter { $0.kind == .done && $0.sessionID == "proj/s1" }.count, 1)
        let s2Seed = events.first { $0.sessionID == "proj/s2" && $0.kind == .usage }
        XCTAssertEqual(s2Seed?.isSeed, true)
        XCTAssertEqual(s2Seed?.contextTokens, 5_500)
        XCTAssertEqual(s2Seed?.turnActive, false)
    }

    @MainActor
    func testConcurrentClaudeSessionsUpdateAgentMonitorCountsIndependently() throws {
        let clock = TestClock(t0)
        let (monitor, defaults, suite) = makeIsolatedMonitor(clock: clock)
        defer { defaults.removePersistentDomain(forName: suite) }

        let collector = Collector()
        let adapter = ClaudeCodeTranscriptAdapter(projectsURL: projects, clock: { clock.now })
        adapter.setHandlerForTesting { collector.append($0) }

        let s1 = try makeSession("proj/s1.jsonl", modified: t0)
        let s2 = try makeSession("proj/s2.jsonl", modified: t0)

        func flush() {
            adapter.checkForUpdates()
            for event in collector.drain() {
                monitor.handleEvent(event)
            }
        }

        flush()
        XCTAssertEqual(monitor.activeAgentCount, 0)

        try append([claudePrompt(), claudeAssistant(tokens: (10_000, 0, 40_000))], to: s1)
        try append([claudePrompt(), claudeAssistant(tokens: (5_000, 0, 10_000))], to: s2)
        flush()
        XCTAssertEqual(monitor.activeAgentCount, 2)
        XCTAssertEqual(monitor.activeSessionCount(for: "claude"), 2)

        // Finishing s1 keeps s2 active.
        try append([claudeAssistant(tokens: (10_000, 0, 41_000), stop: "end_turn")], to: s1)
        flush()
        XCTAssertEqual(monitor.activeAgentCount, 1)
        XCTAssertEqual(monitor.activeSessionCount(for: "claude"), 1)
        XCTAssertTrue(monitor.activeAgents.contains("claude"))

        // Finishing s2 drops active count to 0.
        try append([claudeAssistant(tokens: (5_000, 0, 11_000), stop: "end_turn")], to: s2)
        flush()
        XCTAssertEqual(monitor.activeAgentCount, 0)
        XCTAssertEqual(monitor.activeSessionCount(for: "claude"), 0)
        XCTAssertTrue(monitor.activeAgents.isEmpty)
    }

    func testStaleHistoricClaudeFallbackMarksIdleBeforeEmittingSeed() throws {
        let clock = TestClock(t0)
        let collector = Collector()
        let adapter = ClaudeCodeTranscriptAdapter(projectsURL: projects, clock: { clock.now })
        adapter.setHandlerForTesting { collector.append($0) }

        // Older unfinished session and slightly newer unfinished session, both older than activeAttachWindow (300s).
        _ = try makeSession("proj/older.jsonl", [
            claudePrompt(),
            claudeAssistant(tokens: (1_000, 0, 10_000), tools: [("o1", "Bash", ["command": "sleep 1"])]),
        ], modified: t0.addingTimeInterval(-7200))

        let newestStale = try makeSession("proj/newer-stale.jsonl", [
            claudePrompt(),
            claudeAssistant(tokens: (2_000, 0, 80_000), tools: [("n1", "Bash", ["command": "make"])]),
        ], modified: t0.addingTimeInterval(-3600))

        adapter.checkForUpdates()
        let seeded = collector.drain()

        XCTAssertEqual(seeded.count, 1, "Cold start with no fresh sessions attaches only the single newest fallback")
        XCTAssertEqual(seeded.first?.kind, .usage)
        XCTAssertEqual(seeded.first?.isSeed, true)
        XCTAssertEqual(seeded.first?.sessionID, "proj/newer-stale")
        XCTAssertEqual(seeded.first?.contextTokens, 82_000)
        XCTAssertEqual(seeded.first?.turnActive, false, "Stale historic unfinished transcript must not appear active")
        XCTAssertEqual(seeded.first?.pendingTools, 0)

        // Resuming the fallback session later transitions normally to .working.
        try append([claudePrompt("resume"), claudeAssistant(tokens: (3_000, 0, 82_000))], to: newestStale)
        adapter.checkForUpdates()
        let resumed = collector.drain()
        XCTAssertEqual(resumed.filter { $0.kind != .usage }.map(\.kind), [.working])
        XCTAssertEqual(resumed.last { $0.kind == .usage }?.turnActive, true)
    }

    func testClaudeIdleScanBackoffAndIdleRetainWindowPruning() throws {
        let clock = TestClock(t0)
        let collector = Collector()
        let adapter = ClaudeCodeTranscriptAdapter(
            projectsURL: projects,
            pollInterval: 1.5,
            maxIdleScanInterval: 12.0,
            clock: { clock.now }
        )
        adapter.setHandlerForTesting { collector.append($0) }

        let s1 = try makeSession("proj/s1.jsonl", [
            claudePrompt(),
            claudeAssistant(tokens: (100, 0, 1000), stop: "end_turn"),
        ], modified: t0)
        adapter.checkForUpdates()
        XCTAssertEqual(adapter.currentScanInterval, 1.5)
        _ = collector.drain()

        // Unchanged poll backs off exponentially.
        clock.now = t0.addingTimeInterval(1.5)
        adapter.checkForUpdates()
        XCTAssertEqual(adapter.currentScanInterval, 3.0)

        clock.now = t0.addingTimeInterval(4.5)
        adapter.checkForUpdates()
        XCTAssertEqual(adapter.currentScanInterval, 6.0)

        // Adding a second session in the same project resets backoff and attaches s2.
        let s2Time = t0.addingTimeInterval(5.0)
        let s2 = try makeSession("proj/s2.jsonl", [
            claudePrompt(),
            claudeAssistant(tokens: (200, 0, 2000), stop: "end_turn"),
        ], modified: s2Time)
        clock.now = s2Time
        adapter.checkForUpdates()
        XCTAssertEqual(adapter.currentScanInterval, 1.5)
        XCTAssertEqual(collector.drain().first?.sessionID, "proj/s2")

        // Advance past idleRetainWindow (1800s); s1 (older, turnActive == false) is pruned, while s2 remains.
        clock.now = t0.addingTimeInterval(ClaudeCodeTranscriptAdapter.idleRetainWindow + 10)
        adapter.checkForUpdates()
        _ = collector.drain()

        // Touch s2 -> still tracked.
        try append([claudePrompt(), claudeAssistant(tokens: (300, 0, 3000))], to: s2)
        adapter.checkForUpdates()
        let s2Live = collector.drain()
        XCTAssertEqual(s2Live.filter { $0.kind == .working }.count, 1)

        // Resuming the previously pruned s1 re-attaches it cleanly on the next candidate scan.
        clock.now = clock.now.addingTimeInterval(1.5)
        try append([claudePrompt("resume"), claudeAssistant(tokens: (400, 0, 4000))], to: s1, modified: clock.now)
        adapter.checkForUpdates()
        let s1Reattached = collector.drain()
        XCTAssertEqual(s1Reattached.first?.sessionID, "proj/s1")
        XCTAssertEqual(s1Reattached.first?.isSeed, true)
    }

    // MARK: - 2. Antigravity mid-turn follow-up USER_INPUT (#72)

    func testMidTurnFollowUpPromptDoesNotEmitDuplicateWorkingWhenStartsTurnOnPrompt() {
        var tracker = AgentSessionTracker(
            agentID: "antigravity",
            agentName: "Antigravity",
            startsTurnOnPrompt: true,
            sessionID: "session-1"
        )

        // 1. Initial prompt starts turn and emits one .working event.
        let first = tracker.ingest([.prompt], at: t0)
        XCTAssertEqual(first.map(\.kind), [.working])
        XCTAssertTrue(tracker.turnActive)

        // 2. Mid-turn follow-up prompt while turnActive == true emits nothing.
        let followUp = tracker.ingest([.assistantOutput(contextTokens: 500), .prompt], at: t0.addingTimeInterval(2))
        XCTAssertEqual(followUp, [])
        XCTAssertTrue(tracker.turnActive)

        // 3. Another follow-up prompt in the same batch also emits nothing.
        let batched = tracker.ingest([.prompt, .prompt], at: t0.addingTimeInterval(3))
        XCTAssertEqual(batched, [])
        XCTAssertTrue(tracker.turnActive)

        // 4. Turn ends with .done.
        let done = tracker.ingest([.turnEnd(isDone: true)], at: t0.addingTimeInterval(4))
        XCTAssertEqual(done.map(\.kind), [.done])
        XCTAssertFalse(tracker.turnActive)

        // 5. Next prompt after turn ends emits .working again.
        let nextTurn = tracker.ingest([.prompt], at: t0.addingTimeInterval(5))
        XCTAssertEqual(nextTurn.map(\.kind), [.working])
        XCTAssertTrue(tracker.turnActive)
    }

    func testAntigravityAdapterMidTurnFollowUpUserInputEmitsSingleWorking() throws {
        let brainDir = root.appendingPathComponent("brain")
        let logsDir = brainDir.appendingPathComponent("agy-1/.system_generated/logs")
        try FileManager.default.createDirectory(at: logsDir, withIntermediateDirectories: true)
        let transcript = logsDir.appendingPathComponent("transcript.jsonl")
        try Data().write(to: transcript)

        let collector = Collector()
        let adapter = AntigravityTranscriptAdapter(baseBrainURL: brainDir)
        adapter.setHandlerForTesting { collector.append($0) }
        adapter.checkForUpdates()
        _ = collector.drain()

        // First USER_INPUT -> .working
        try append([
            #"{"step_index":0,"source":"USER_EXPLICIT","type":"USER_INPUT","status":"DONE","content":"first"}"#,
        ], to: transcript)
        adapter.checkForUpdates()
        XCTAssertEqual(collector.drain().filter { $0.kind != .usage }.map(\.kind), [.working])

        // Mid-turn follow-up USER_INPUT while model is still running -> no duplicate .working
        try append([
            #"{"step_index":1,"source":"MODEL","type":"PLANNER_RESPONSE","status":"RUNNING","input_tokens":1000}"#,
            #"{"step_index":2,"source":"USER_EXPLICIT","type":"USER_INPUT","status":"DONE","content":"follow-up"}"#,
        ], to: transcript)
        adapter.checkForUpdates()
        XCTAssertEqual(collector.drain().filter { $0.kind != .usage }, [])

        // Final PLANNER_RESPONSE -> .done
        try append([
            #"{"step_index":3,"source":"MODEL","type":"PLANNER_RESPONSE","status":"DONE","content":"finished"}"#,
        ], to: transcript)
        adapter.checkForUpdates()
        XCTAssertEqual(collector.drain().filter { $0.kind != .usage }.map(\.kind), [.done])
    }

    // MARK: - 3. ProcessAgentAdapter warning-bubble restore isolation (#72)

    @MainActor
    func testProcessPresenceEventsDoNotRestoreWarningBubbleOverApprovalOrClobberOverride() {
        let clock = TestClock(t0)
        let (service, defaults, suite) = makeIsolatedMonitor(clock: clock)
        defer { defaults.removePersistentDomain(forName: suite) }

        let processMetadata = [AgentEvent.MetadataKey.source: "process"]

        for lifecycleKind in [AgentEventKind.working, .done, .failed] {
            service.stopMonitoring()

            // 1. Gemini raises an active warning.
            service.handleEvent(AgentEvent(
                agentID: "gemini",
                agentName: "Gemini",
                kind: .warning,
                message: "Gemini warning",
                timestamp: clock.now,
                metadata: [AgentEvent.MetadataKey.reason: AgentWarningReason.reported.rawValue]
            ))
            XCTAssertEqual(service.activeWarning?.agentID, "gemini")
            XCTAssertEqual(service.activePopup?.kind, .warning)

            // 2. Claude Code session needs approval -> overrides the bubble while Gemini warning stays active.
            service.handleEvent(AgentEvent(
                agentID: "claude",
                agentName: "Claude",
                kind: .needsApproval,
                message: "Approve command?",
                timestamp: clock.now,
                metadata: [AgentEvent.MetadataKey.sessionID: "proj/s1"]
            ))
            XCTAssertEqual(service.activePopup?.kind, .needsApproval)
            XCTAssertEqual(service.activePopup?.text, "Approve command?")
            XCTAssertEqual(service.activeWarning?.agentID, "gemini")

            // 3. ProcessAgentAdapter (source == "process", sharing agentID "claude") emits working/done/failed:
            // must NOT prematurely restore Gemini's warning bubble or clobber approval override state.
            service.handleEvent(AgentEvent(
                agentID: "claude",
                agentName: "Claude",
                kind: lifecycleKind,
                timestamp: clock.now,
                metadata: processMetadata
            ))
            XCTAssertEqual(
                service.activePopup?.kind,
                .needsApproval,
                "Process presence \(lifecycleKind) must not dismiss approval or restore warning"
            )
            XCTAssertEqual(service.activePopup?.text, "Approve command?")
            XCTAssertEqual(service.activeWarning?.agentID, "gemini")

            // 4. Real Claude Code non-presence event still restores Gemini's warning bubble cleanly,
            // proving approval override state remained intact.
            service.handleEvent(AgentEvent(
                agentID: "claude",
                agentName: "Claude",
                kind: lifecycleKind,
                timestamp: clock.now,
                metadata: [AgentEvent.MetadataKey.sessionID: "proj/s1"]
            ))
            XCTAssertEqual(service.activePopup?.kind, .warning)
            XCTAssertEqual(service.activePopup?.text, "Gemini warning")
        }
    }

    // MARK: - 4. Lossy per-key drop-box metadata decoding (#72)

    func testLossyMetadataDecodesValidKeysWhileSkippingNullArraysAndNestedObjects() throws {
        let json = """
        {
            "agentID": "claude",
            "agentName": "Claude",
            "kind": "usage",
            "timestamp": "2026-11-14T12:00:00Z",
            "metadata": {
                "contextTokens": 185000,
                "pendingTools": "2",
                "turnActive": true,
                "ratio": 0.75,
                "wholeDouble": 42000.0,
                "reason": "context",
                "nullValue": null,
                "arrayValue": [1, "two", {"three": 3}],
                "nestedObject": {"inner": "value", "deep": [true]}
            }
        }
        """

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let event = try decoder.decode(AgentEvent.self, from: Data(json.utf8))

        XCTAssertEqual(event.kind, .usage)
        XCTAssertEqual(event.contextTokens, 185_000)
        XCTAssertEqual(event.pendingTools, 2)
        XCTAssertEqual(event.turnActive, true)
        XCTAssertEqual(event.warningReason, .context)
        XCTAssertEqual(event.metadata?["ratio"], "0.75")
        XCTAssertEqual(event.metadata?["wholeDouble"], "42000")
        XCTAssertNil(event.metadata?["nullValue"])
        XCTAssertNil(event.metadata?["arrayValue"])
        XCTAssertNil(event.metadata?["nestedObject"])
        XCTAssertEqual(event.metadata?.count, 6)
    }

    func testLossyMetadataNormalizesAllInvalidOrEmptyOrNonDictionaryToNil() throws {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        let payloads = [
            #"{"agentID":"claude","agentName":"Claude","kind":"usage","timestamp":"2026-11-14T12:00:00Z","metadata":{"a":null,"b":[1],"c":{"d":2}}}"#,
            #"{"agentID":"claude","agentName":"Claude","kind":"usage","timestamp":"2026-11-14T12:00:00Z","metadata":{}}"#,
            #"{"agentID":"claude","agentName":"Claude","kind":"usage","timestamp":"2026-11-14T12:00:00Z","metadata":["not","a","dict"]}"#,
            #"{"agentID":"claude","agentName":"Claude","kind":"usage","timestamp":"2026-11-14T12:00:00Z","metadata":null}"#,
        ]

        for payload in payloads {
            let event = try decoder.decode(AgentEvent.self, from: Data(payload.utf8))
            XCTAssertEqual(event.kind, .usage)
            XCTAssertNil(event.metadata)
        }
    }

    func testDropboxAdapterPreservesSiblingMetadataKeysWhenNullOrNestedPresent() throws {
        let dropboxDir = root.appendingPathComponent("dropbox")
        try FileManager.default.createDirectory(at: dropboxDir, withIntermediateDirectories: true)

        let fixedDate = ISO8601DateFormatter().date(from: "2026-11-14T12:00:05Z")!
        let adapter = DropboxAgentAdapter(directoryURL: dropboxDir, clock: { fixedDate })
        let collector = Collector()
        let payload = """
        {
            "agentID": "claude",
            "agentName": "Claude",
            "kind": "usage",
            "timestamp": "2026-11-14T12:00:00Z",
            "metadata": {
                "contextTokens": 192000,
                "extra": null,
                "debug": {"step": 1, "tags": ["a", "b"]}
            }
        }
        """
        try Data(payload.utf8).write(to: dropboxDir.appendingPathComponent("mixed.json"))
        adapter.start { collector.append($0) }
        defer { adapter.stop() }
        adapter.processPendingFiles()

        let events = collector.drain()
        XCTAssertEqual(events.count, 1)
        XCTAssertEqual(events.first?.contextTokens, 192_000)
        XCTAssertEqual(events.first?.metadata?["contextTokens"], "192000")
        XCTAssertNil(events.first?.metadata?["extra"])
        XCTAssertNil(events.first?.metadata?["debug"])
    }
}
