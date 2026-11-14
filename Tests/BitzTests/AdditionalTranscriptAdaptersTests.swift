import XCTest
import SQLite3
@testable import BitzCore

final class AdditionalTranscriptAdaptersTests: XCTestCase {
    private final class TestClock: @unchecked Sendable {
        private let lock = NSLock()
        private var current: Date

        init(_ initial: Date = Date(timeIntervalSince1970: 1_794_668_000)) {
            self.current = initial
        }

        func now() -> Date {
            lock.withLock { current }
        }

        func advance(by seconds: TimeInterval) {
            lock.withLock { current = current.addingTimeInterval(seconds) }
        }
    }

    private final class EventCollector: @unchecked Sendable {
        private let lock = NSLock()
        private var recorded: [AgentEvent] = []

        func append(_ event: AgentEvent) {
            lock.withLock { recorded.append(event) }
        }

        var events: [AgentEvent] {
            lock.withLock { recorded }
        }
    }

    private func makeTempDir(prefix: String) throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(prefix)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func jsonLine(_ obj: [String: Any]) throws -> Data {
        var data = try JSONSerialization.data(withJSONObject: obj)
        data.append(0x0A)
        return data
    }

    private func appendJSONLine(_ obj: [String: Any], to url: URL) throws {
        let line = try jsonLine(obj)
        if !FileManager.default.fileExists(atPath: url.path) {
            try line.write(to: url)
            return
        }
        let handle = try FileHandle(forUpdating: url)
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: line)
    }

    private func setModifiedDate(_ date: Date, for url: URL) throws {
        try FileManager.default.setAttributes([.modificationDate: date], ofItemAtPath: url.path)
    }

    private func expectedRateLimitMessage(agentName: String, resetsAt: Date?) -> String {
        let resets = resetsAt.map { " · resets \($0.formatted(.dateTime.weekday().hour().minute()))" } ?? ""
        return "⚠️ \(agentName) hit its usage limit\(resets)."
    }

    // MARK: - 1. Signal Settings & Monitor Service Integration

    func testSignalSettingsDefaultsAndUpgradeDecodeMerge() throws {
        let settings = AgentSignalSettings.default
        XCTAssertEqual(settings.contextWindow(for: "claude"), 200_000)
        XCTAssertEqual(settings.contextWindow(for: "antigravity"), 1_000_000)
        XCTAssertEqual(settings.contextWindow(for: "gemini"), 1_000_000)
        XCTAssertEqual(settings.contextWindow(for: "codex"), 200_000)
        XCTAssertEqual(settings.contextWindow(for: "cursor"), 200_000)

        // Legacy persisted blob from before Issue #162 only saved claude & antigravity keys.
        let legacyJSON = """
        {
            "almostDoneEnabled": true,
            "contextWarningEnabled": true,
            "loopWarningEnabled": true,
            "stallWarningEnabled": true,
            "rateLimitWarningEnabled": true,
            "contextThresholdPercent": 85,
            "stallTimeoutMinutes": 4,
            "contextWindowTokens": {
                "claude": 150000,
                "antigravity": 1000000
            }
        }
        """.data(using: .utf8)!

        let decoded = try JSONDecoder().decode(AgentSignalSettings.self, from: legacyJSON)
        XCTAssertEqual(decoded.contextWindow(for: "claude"), 150_000)
        XCTAssertEqual(decoded.contextWindow(for: "antigravity"), 1_000_000)
        XCTAssertEqual(decoded.contextWindow(for: "gemini"), 1_000_000)
        XCTAssertEqual(decoded.contextWindow(for: "codex"), 200_000)
        XCTAssertEqual(decoded.contextWindow(for: "cursor"), 200_000)
    }

    @MainActor
    func testMonitorServiceComputesContextPercentagesAndRateLimitWarningsForNewAgents() {
        let suite = "AdditionalTranscriptAdaptersTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }

        let service = AgentMonitorService(adapters: [], userDefaults: defaults)
        let now = Date()

        service.handleEvent(AgentEvent(
            agentID: "gemini",
            agentName: "Gemini",
            kind: .usage,
            message: "Gemini active",
            timestamp: now,
            metadata: [
                AgentEvent.MetadataKey.sessionID: "gem-1",
                AgentEvent.MetadataKey.contextTokens: "500000",
                AgentEvent.MetadataKey.turnActive: "true",
            ]
        ))
        XCTAssertEqual(service.latestContext?.agentID, "gemini")
        XCTAssertEqual(service.latestContext?.percent, 50)

        service.handleEvent(AgentEvent(
            agentID: "codex",
            agentName: "Codex",
            kind: .usage,
            message: "Codex active",
            timestamp: now,
            metadata: [
                AgentEvent.MetadataKey.sessionID: "codex-1",
                AgentEvent.MetadataKey.contextTokens: "100000",
                AgentEvent.MetadataKey.turnActive: "true",
            ]
        ))
        XCTAssertEqual(service.latestContext?.agentID, "codex")
        XCTAssertEqual(service.latestContext?.percent, 50)

        service.handleEvent(AgentEvent(
            agentID: "cursor",
            agentName: "Cursor",
            kind: .usage,
            message: "Cursor active",
            timestamp: now,
            metadata: [
                AgentEvent.MetadataKey.sessionID: "cur-1",
                AgentEvent.MetadataKey.contextTokens: "160000",
                AgentEvent.MetadataKey.turnActive: "true",
            ]
        ))
        XCTAssertEqual(service.latestContext?.agentID, "cursor")
        XCTAssertEqual(service.latestContext?.percent, 80)

        let resetsAt = now.addingTimeInterval(600)
        let expectedText = expectedRateLimitMessage(agentName: "Cursor", resetsAt: resetsAt)
        service.handleEvent(AgentEvent(
            agentID: "cursor",
            agentName: "Cursor",
            kind: .warning,
            message: expectedText,
            timestamp: now,
            metadata: [
                AgentEvent.MetadataKey.sessionID: "cur-1",
                AgentEvent.MetadataKey.reason: AgentWarningReason.rateLimit.rawValue,
            ]
        ))

        XCTAssertEqual(service.activeWarning?.reason, .rateLimit)
        XCTAssertEqual(service.activeWarning?.agentID, "cursor")
        XCTAssertEqual(service.activeWarning?.text, expectedText)
    }

    // MARK: - 2. Antigravity 429 / Quota Warnings

    func testAntigravityEntriesParsesQuotaErrorsAndIgnoresNormalPromptMentions() throws {
        let line1 = try JSONSerialization.data(withJSONObject: [
            "step_index": 179,
            "source": "SYSTEM",
            "type": "ERROR_MESSAGE",
            "status": "DONE",
            "created_at": "2026-11-14T10:00:00Z",
            "error": "Model API failed: HTTP 429 RESOURCE_EXHAUSTED, retryDelay: \"45.5s\"",
        ])
        let entries1 = AntigravityTranscriptAdapter.entries(fromLine: line1)
        let iso = ISO8601DateFormatter()
        let baseDate = iso.date(from: "2026-11-14T10:00:00Z")!
        XCTAssertEqual(entries1.count, 3)
        XCTAssertEqual(entries1[0], .toolResult(id: nil))
        if case let .rateLimit(resetsAt) = entries1[1] {
            XCTAssertNotNil(resetsAt)
            XCTAssertEqual(resetsAt!.timeIntervalSince1970, baseDate.addingTimeInterval(45.5).timeIntervalSince1970, accuracy: 0.01)
        } else {
            XCTFail("Expected .rateLimit, got \(entries1)")
        }
        XCTAssertEqual(entries1[2], .turnEnd(isDone: false))

        let line2 = try JSONSerialization.data(withJSONObject: [
            "type": "PLANNER_RESPONSE",
            "status": "ERROR",
            "error": [
                "code": 429,
                "status": "RESOURCE_EXHAUSTED",
                "resets_at": "2026-11-14T12:30:00Z",
            ],
        ])
        let entries2 = AntigravityTranscriptAdapter.entries(fromLine: line2)
        if case let .rateLimit(resetsAt) = entries2.dropFirst().first {
            XCTAssertEqual(resetsAt, iso.date(from: "2026-11-14T12:30:00Z"))
        } else {
            XCTFail("Expected structured resets_at .rateLimit")
        }

        let line3 = try JSONSerialization.data(withJSONObject: [
            "type": "ERROR_MESSAGE",
            "status": "ERROR",
            "message": "Rate limit exceeded without retry header",
        ])
        let entries3 = AntigravityTranscriptAdapter.entries(fromLine: line3)
        XCTAssertEqual(entries3, [.toolResult(id: nil), .rateLimit(resetsAt: nil), .turnEnd(isDone: false)])

        // User prompt mentioning "429" / "rate limit" MUST NOT fire .rateLimit.
        let userLine = try JSONSerialization.data(withJSONObject: [
            "type": "USER_INPUT",
            "content": "Please handle HTTP 429 RESOURCE_EXHAUSTED and rate limit errors",
        ])
        XCTAssertEqual(AntigravityTranscriptAdapter.entries(fromLine: userLine), [.toolResult(id: nil), .prompt])
    }

    func testAntigravitySeedPrimeNeverFiresRateLimitAndLiveAppendFiresWarning() throws {
        // 1. Direct tracker invariant check: prime(fromSeed:) never returns or exposes warnings.
        var tracker = AgentSessionTracker(agentID: "antigravity", agentName: "Antigravity", startsTurnOnPrompt: true, sessionID: "ag-seed")
        tracker.prime(fromSeed: [
            .prompt,
            .rateLimit(resetsAt: Date(timeIntervalSince1970: 1_800_000_000)),
            .turnEnd(isDone: false),
        ])
        XCTAssertFalse(tracker.turnActive)

        // 2. End-to-end adapter test: historic 429 in seed stays silent; newly appended 429 raises warning.
        let root = try makeTempDir(prefix: "ag-429")
        defer { try? FileManager.default.removeItem(at: root) }

        let sessionDir = root.appendingPathComponent("conv-1/.system_generated/logs", isDirectory: true)
        try FileManager.default.createDirectory(at: sessionDir, withIntermediateDirectories: true)
        let logURL = sessionDir.appendingPathComponent("transcript.jsonl")

        let clock = TestClock()
        try appendJSONLine([
            "type": "USER_INPUT",
            "content": "Start",
        ], to: logURL)
        try appendJSONLine([
            "type": "ERROR_MESSAGE",
            "status": "DONE",
            "error": "429 RESOURCE_EXHAUSTED",
        ], to: logURL)
        try setModifiedDate(clock.now(), for: logURL)

        let collector = EventCollector()
        let adapter = AntigravityTranscriptAdapter(baseBrainURL: root, clock: { clock.now() })
        adapter.setHandlerForTesting { collector.append($0) }
        adapter.checkForUpdates()

        // Seed attach MUST NOT emit any .warning event!
        XCTAssertFalse(collector.events.contains { $0.kind == .warning })

        // Now append a live prompt + live 429 error.
        clock.advance(by: 2.0)
        try appendJSONLine(["type": "USER_INPUT", "content": "Try again"], to: logURL)
        try appendJSONLine([
            "type": "ERROR_MESSAGE",
            "status": "DONE",
            "created_at": "2026-11-14T15:00:00Z",
            "error": "Quota exhausted (429): resets in 2h 15m",
        ], to: logURL)
        adapter.checkForUpdates()

        let warnings = collector.events.filter { $0.kind == .warning }
        XCTAssertEqual(warnings.count, 1)
        let iso = ISO8601DateFormatter()
        let expectedReset = iso.date(from: "2026-11-14T15:00:00Z")!.addingTimeInterval(2 * 3600 + 15 * 60)
        XCTAssertEqual(warnings.first?.metadata?[AgentEvent.MetadataKey.reason], AgentWarningReason.rateLimit.rawValue)
        XCTAssertEqual(warnings.first?.metadata?[AgentEvent.MetadataKey.sessionID], "conv-1")
        XCTAssertEqual(
            warnings.first?.message,
            expectedRateLimitMessage(agentName: "Antigravity", resetsAt: expectedReset)
        )
    }

    // MARK: - 3. Gemini CLI Transcript Adapter

    func testGeminiJSONLContextToolDedupLoopApprovalAndDone() throws {
        let root = try makeTempDir(prefix: "gemini-jsonl")
        defer { try? FileManager.default.removeItem(at: root) }

        let chatsDir = root.appendingPathComponent("projhash1/chats", isDirectory: true)
        try FileManager.default.createDirectory(at: chatsDir, withIntermediateDirectories: true)
        let sessionURL = chatsDir.appendingPathComponent("session-2026-11-14T10-00-abc123.jsonl")

        let clock = TestClock()
        try appendJSONLine([
            "sessionId": "abc123-full",
            "projectHash": "projhash1",
            "kind": "main",
            "startTime": "2026-11-14T10:00:00Z",
        ], to: sessionURL)
        try appendJSONLine([
            "id": "u1",
            "type": "user",
            "content": "Initial",
        ], to: sessionURL)
        try setModifiedDate(clock.now(), for: sessionURL)

        let collector = EventCollector()
        let adapter = GeminiCLITranscriptAdapter(baseRootURL: root, clock: { clock.now() })
        adapter.setHandlerForTesting { collector.append($0) }
        adapter.checkForUpdates()
        XCTAssertEqual(collector.events.count, 1)
        XCTAssertEqual(collector.events.first?.kind, .usage)

        // Append live user prompt, then re-push the SAME Gemini message ID across tool status transitions.
        clock.advance(by: 2.0)
        try appendJSONLine(["id": "u2", "type": "user", "content": "Run tool"], to: sessionURL)
        try appendJSONLine([
            "id": "g1",
            "type": "gemini",
            "content": "",
            "toolCalls": [["id": "call-1", "name": "run_shell_command", "args": ["command": "ls"], "status": "validating"]],
        ], to: sessionURL)
        try appendJSONLine([
            "id": "g1",
            "type": "gemini",
            "content": "",
            "toolCalls": [["id": "call-1", "name": "run_shell_command", "args": ["command": "ls"], "status": "awaiting_approval"]],
        ], to: sessionURL)
        try appendJSONLine([
            "id": "g1",
            "type": "gemini",
            "content": "",
            "toolCalls": [["id": "call-1", "name": "run_shell_command", "args": ["command": "ls"], "status": "success"]],
        ], to: sessionURL)
        try appendJSONLine([
            "id": "g1",
            "type": "gemini",
            "content": "",
            "toolCalls": [["id": "call-1", "name": "run_shell_command", "args": ["command": "ls"], "status": "success"]],
            "tokens": ["input": 120_000, "output": 500, "cached": 50_000, "total": 120_500],
        ], to: sessionURL)
        adapter.checkForUpdates()

        // Same toolCallId re-pushed 4 times MUST NOT emit a loop warning, and awaiting_approval emits .needsApproval.
        XCTAssertFalse(collector.events.contains { $0.kind == .warning })
        XCTAssertTrue(collector.events.contains { $0.kind == .needsApproval })
        XCTAssertTrue(collector.events.contains {
            $0.kind == .usage && $0.metadata?[AgentEvent.MetadataKey.contextTokens] == "120000"
        })

        // Append 4 distinct repeated identical tool calls -> triggers .loop warning!
        clock.advance(by: 2.0)
        try appendJSONLine([
            "id": "g2",
            "type": "gemini",
            "content": "",
            "toolCalls": [
                ["id": "c1", "name": "read_file", "args": ["path": "a.swift"], "status": "success"],
                ["id": "c2", "name": "read_file", "args": ["path": "a.swift"], "status": "success"],
                ["id": "c3", "name": "read_file", "args": ["path": "a.swift"], "status": "success"],
                ["id": "c4", "name": "read_file", "args": ["path": "a.swift"], "status": "success"],
            ],
        ], to: sessionURL)
        adapter.checkForUpdates()
        XCTAssertTrue(collector.events.contains {
            $0.kind == .warning && $0.metadata?[AgentEvent.MetadataKey.reason] == AgentWarningReason.loop.rawValue
        })

        // Final gemini summary message with no toolCalls + final token count -> emits .done + updated context tokens.
        clock.advance(by: 2.0)
        try appendJSONLine([
            "id": "g3",
            "type": "gemini",
            "content": "All done!",
            "tokens": ["input": 350_000, "output": 200, "total": 350_200],
        ], to: sessionURL)
        adapter.checkForUpdates()

        XCTAssertTrue(collector.events.contains { $0.kind == .done })
        XCTAssertEqual(
            collector.events.last { $0.kind == .usage }?.metadata?[AgentEvent.MetadataKey.contextTokens],
            "350000"
        )
    }

    func testGeminiLegacySnapshotJSONGatedOnFileMetadata() throws {
        let root = try makeTempDir(prefix: "gemini-legacy")
        defer { try? FileManager.default.removeItem(at: root) }

        let chatsDir = root.appendingPathComponent("projlegacy/chats", isDirectory: true)
        try FileManager.default.createDirectory(at: chatsDir, withIntermediateDirectories: true)
        let snapshotURL = chatsDir.appendingPathComponent("session-2026-11-14T11-00-leg1.json")

        let clock = TestClock()
        let initialSnapshot: [String: Any] = [
            "sessionId": "leg1",
            "kind": "main",
            "messages": [
                ["id": "m1", "type": "user", "content": "Hello"],
            ],
        ]
        try JSONSerialization.data(withJSONObject: initialSnapshot).write(to: snapshotURL)
        try setModifiedDate(clock.now(), for: snapshotURL)

        let collector = EventCollector()
        let adapter = GeminiCLITranscriptAdapter(baseRootURL: root, clock: { clock.now() })
        adapter.setHandlerForTesting { collector.append($0) }
        adapter.checkForUpdates()
        let baselineCount = collector.events.count

        // Unchanged file on subsequent polls emits zero duplicate events.
        clock.advance(by: 2.0)
        adapter.checkForUpdates()
        XCTAssertEqual(collector.events.count, baselineCount)

        // Rewrite full JSON file adding a Gemini reply with tokens.
        clock.advance(by: 2.0)
        let updatedSnapshot: [String: Any] = [
            "sessionId": "leg1",
            "kind": "main",
            "messages": [
                ["id": "m1", "type": "user", "content": "Hello"],
                ["id": "m2", "type": "gemini", "content": "Done!", "tokens": ["input": 250_000, "total": 250_100]],
            ],
        ]
        try JSONSerialization.data(withJSONObject: updatedSnapshot).write(to: snapshotURL)
        try setModifiedDate(clock.now(), for: snapshotURL)
        adapter.checkForUpdates()

        XCTAssertTrue(collector.events.contains { $0.kind == .done })
        XCTAssertEqual(
            collector.events.last { $0.kind == .usage }?.metadata?[AgentEvent.MetadataKey.contextTokens],
            "250000"
        )
    }

    func testGeminiRateLimitWithAndWithoutResetTimeSeedSilenceSubagentsAndBackoff() throws {
        let container = try makeTempDir(prefix: "gemini-rl")
        defer { try? FileManager.default.removeItem(at: container) }
        let root = container.appendingPathComponent("missing-gemini-tmp", isDirectory: true)

        let clock = TestClock()
        let adapter = GeminiCLITranscriptAdapter(baseRootURL: root, clock: { clock.now() })
        let collector = EventCollector()
        adapter.setHandlerForTesting { collector.append($0) }

        // Missing root dir: scan backoff 1.5 -> 3 -> 6 -> 12 -> 24 -> 30s with <= 1 scan per interval.
        adapter.checkForUpdates() // scan #1, interval -> 3.0
        XCTAssertEqual(adapter.scanCountForTesting, 1)
        XCTAssertEqual(adapter.scanIntervalForTesting, 3.0, accuracy: 0.001)

        clock.advance(by: 1.5)
        adapter.checkForUpdates() // skipped (< 3.0s)
        XCTAssertEqual(adapter.scanCountForTesting, 1)

        clock.advance(by: 1.5)
        adapter.checkForUpdates() // scan #2, interval -> 6.0
        XCTAssertEqual(adapter.scanCountForTesting, 2)
        XCTAssertEqual(adapter.scanIntervalForTesting, 6.0, accuracy: 0.001)

        clock.advance(by: 6.0)
        adapter.checkForUpdates() // scan #3 -> 12.0
        clock.advance(by: 12.0)
        adapter.checkForUpdates() // scan #4 -> 24.0
        clock.advance(by: 24.0)
        adapter.checkForUpdates() // scan #5 -> 30.0 (clamped)
        XCTAssertEqual(adapter.scanIntervalForTesting, 30.0, accuracy: 0.001)

        clock.advance(by: 10.0)
        adapter.checkForUpdates() // skipped while backed off inside 30s window
        XCTAssertEqual(adapter.scanCountForTesting, 5)

        // Now populate 2 concurrent main sessions + 1 subagent file + 1 nested subagent dir.
        let chatsDir = root.appendingPathComponent("proj/chats", isDirectory: true)
        let nestedSubDir = chatsDir.appendingPathComponent("s1", isDirectory: true)
        try FileManager.default.createDirectory(at: nestedSubDir, withIntermediateDirectories: true)

        let s1 = chatsDir.appendingPathComponent("session-2026-11-14T12-00-s1.jsonl")
        let s2 = chatsDir.appendingPathComponent("session-2026-11-14T12-01-s2.jsonl")
        let subTop = chatsDir.appendingPathComponent("session-2026-11-14T12-02-sub.jsonl")
        let subNested = nestedSubDir.appendingPathComponent("session-nested.jsonl")

        // Seed s1 with an old 429 error -> MUST stay silent on seed attach.
        try appendJSONLine(["sessionId": "s1", "kind": "main"], to: s1)
        try appendJSONLine(["id": "e0", "type": "error", "content": "HTTP 429 RESOURCE_EXHAUSTED"], to: s1)
        try appendJSONLine(["sessionId": "s2", "kind": "main"], to: s2)
        try appendJSONLine(["id": "u2", "type": "user", "content": "Work"], to: s2)
        try appendJSONLine(["sessionId": "sub", "kind": "subagent"], to: subTop)
        try appendJSONLine(["id": "su1", "type": "user", "content": "Subagent task"], to: subTop)
        try appendJSONLine(["id": "sn1", "type": "user", "content": "Nested subagent"], to: subNested)

        clock.advance(by: 25.0)
        try setModifiedDate(clock.now(), for: s1)
        try setModifiedDate(clock.now(), for: s2)
        try setModifiedDate(clock.now(), for: subTop)
        try setModifiedDate(clock.now(), for: subNested)
        adapter.checkForUpdates()

        XCTAssertEqual(adapter.activeSessionIDsForTesting, [
            "session-2026-11-14T12-00-s1",
            "session-2026-11-14T12-01-s2",
        ])
        XCTAssertFalse(collector.events.contains { $0.kind == .warning })

        // Live 429 WITH duration reset on s1 + live 429 WITHOUT reset on s2.
        clock.advance(by: 2.0)
        try appendJSONLine([
            "id": "e1",
            "type": "error",
            "timestamp": "2026-11-14T12:05:00Z",
            "content": "Error 429 RESOURCE_EXHAUSTED: quota will reset in 1h 30m",
        ], to: s1)
        try appendJSONLine([
            "id": "e2",
            "type": "error",
            "content": "Too many requests (429)",
        ], to: s2)
        adapter.checkForUpdates()

        let warnings = collector.events.filter { $0.kind == .warning }
        XCTAssertEqual(warnings.count, 2)
        let w1 = warnings.first { $0.metadata?[AgentEvent.MetadataKey.sessionID] == "session-2026-11-14T12-00-s1" }
        let w2 = warnings.first { $0.metadata?[AgentEvent.MetadataKey.sessionID] == "session-2026-11-14T12-01-s2" }

        let iso = ISO8601DateFormatter()
        let expectedReset1 = iso.date(from: "2026-11-14T12:05:00Z")!.addingTimeInterval(5400)
        XCTAssertEqual(w1?.metadata?[AgentEvent.MetadataKey.reason], AgentWarningReason.rateLimit.rawValue)
        XCTAssertEqual(w1?.message, expectedRateLimitMessage(agentName: "Gemini", resetsAt: expectedReset1))
        XCTAssertEqual(w2?.metadata?[AgentEvent.MetadataKey.reason], AgentWarningReason.rateLimit.rawValue)
        XCTAssertEqual(w2?.message, expectedRateLimitMessage(agentName: "Gemini", resetsAt: nil))
    }

    // MARK: - 4. OpenAI Codex CLI Transcript Adapter

    func testCodexRolloutContextToolLoopAndDone() throws {
        let root = try makeTempDir(prefix: "codex-main")
        defer { try? FileManager.default.removeItem(at: root) }

        let dayDir = root.appendingPathComponent("2026/11/14", isDirectory: true)
        try FileManager.default.createDirectory(at: dayDir, withIntermediateDirectories: true)
        let rolloutURL = dayDir.appendingPathComponent("rollout-2026-11-14-uuid1.jsonl")

        let clock = TestClock()
        try appendJSONLine([
            "timestamp": "2026-11-14T10:00:00Z",
            "type": "session_meta",
            "payload": ["id": "codex-uuid-1", "originator": "codex_cli_rs", "source": "cli"],
        ], to: rolloutURL)
        try setModifiedDate(clock.now(), for: rolloutURL)

        let collector = EventCollector()
        let adapter = CodexTranscriptAdapter(baseRootURL: root, clock: { clock.now() })
        adapter.setHandlerForTesting { collector.append($0) }
        adapter.checkForUpdates()
        XCTAssertEqual(adapter.activeSessionIDsForTesting, ["codex-uuid-1"])

        // Live turn: prompt -> token_count (< 100% rate limit must NOT warn) -> 4x repeated tool loop -> task_complete.
        clock.advance(by: 2.0)
        try appendJSONLine([
            "type": "event_msg",
            "payload": ["type": "user_message", "message": "Inspect repo"],
        ], to: rolloutURL)
        try appendJSONLine([
            "type": "event_msg",
            "payload": ["type": "task_started", "turn_id": "t1"],
        ], to: rolloutURL)
        try appendJSONLine([
            "type": "event_msg",
            "payload": [
                "type": "token_count",
                "info": [
                    "last_token_usage": ["input_tokens": 90_000, "cached_input_tokens": 20_000, "output_tokens": 400],
                    "total_token_usage": ["input_tokens": 250_000],
                ],
                "rate_limits": [
                    "primary": ["used_percent": 35.0, "resets_at": 1_794_700_000],
                ],
            ],
        ], to: rolloutURL)
        // Loop 4 calls with equivalent JSON object key reordering in arguments string.
        for idx in 1...4 {
            let args = idx.isMultiple(of: 2) ? #"{"b":2,"a":1}"# : #"{"a":1,"b":2}"#
            try appendJSONLine([
                "type": "response_item",
                "payload": ["type": "function_call", "name": "shell", "arguments": args, "call_id": "call_\(idx)"],
            ], to: rolloutURL)
            try appendJSONLine([
                "type": "response_item",
                "payload": ["type": "function_call_output", "call_id": "call_\(idx)", "output": "ok"],
            ], to: rolloutURL)
        }
        try appendJSONLine([
            "type": "event_msg",
            "payload": ["type": "task_complete", "turn_id": "t1"],
        ], to: rolloutURL)
        adapter.checkForUpdates()

        // Single prompt + suppressed duplicate task_started -> only 1 .working event.
        XCTAssertEqual(collector.events.filter { $0.kind == .working }.count, 1)
        XCTAssertEqual(
            collector.events.last { $0.kind == .usage }?.metadata?[AgentEvent.MetadataKey.contextTokens],
            "90000"
        )
        let warnings = collector.events.filter { $0.kind == .warning }
        XCTAssertEqual(warnings.count, 1)
        XCTAssertEqual(warnings.first?.metadata?[AgentEvent.MetadataKey.reason], AgentWarningReason.loop.rawValue)
        XCTAssertTrue(collector.events.contains { $0.kind == .done })
    }

    func testCodexRateLimitsExhaustedError429SeedSilenceSubagentsConcurrentAndBackoff() throws {
        let container = try makeTempDir(prefix: "codex-rl")
        defer { try? FileManager.default.removeItem(at: container) }
        let root = container.appendingPathComponent("missing-codex-sessions", isDirectory: true)

        let clock = TestClock()
        let adapter = CodexTranscriptAdapter(baseRootURL: root, clock: { clock.now() })
        let collector = EventCollector()
        adapter.setHandlerForTesting { collector.append($0) }

        // Backoff when ~/.codex/sessions does not exist.
        adapter.checkForUpdates() // scan 1 -> 3s
        XCTAssertEqual(adapter.scanCountForTesting, 1)
        XCTAssertEqual(adapter.scanIntervalForTesting, 3.0, accuracy: 0.001)
        clock.advance(by: 2.0)
        adapter.checkForUpdates()
        XCTAssertEqual(adapter.scanCountForTesting, 1)
        clock.advance(by: 1.0)
        adapter.checkForUpdates() // scan 2 -> 6s
        clock.advance(by: 6.0)
        adapter.checkForUpdates() // scan 3 -> 12s
        clock.advance(by: 12.0)
        adapter.checkForUpdates() // scan 4 -> 24s
        clock.advance(by: 24.0)
        adapter.checkForUpdates() // scan 5 -> 30s
        XCTAssertEqual(adapter.scanIntervalForTesting, 30.0, accuracy: 0.001)

        // Create two concurrent sessions in different date directories + one subagent rollout.
        let day1 = root.appendingPathComponent("2026/11/13", isDirectory: true)
        let day2 = root.appendingPathComponent("2026/11/14", isDirectory: true)
        try FileManager.default.createDirectory(at: day1, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: day2, withIntermediateDirectories: true)

        let r1 = day1.appendingPathComponent("rollout-1.jsonl")
        let r2 = day2.appendingPathComponent("rollout-2.jsonl")
        let rSub = day2.appendingPathComponent("rollout-sub.jsonl")

        // Seed r1 with old 100% rate limit -> prime stays silent!
        try appendJSONLine(["type": "session_meta", "payload": ["id": "c1", "source": "cli"]], to: r1)
        try appendJSONLine([
            "type": "event_msg",
            "payload": [
                "type": "token_count",
                "rate_limits": ["primary": ["used_percent": 100.0, "resets_at": 1_794_600_000]],
            ],
        ], to: r1)
        try appendJSONLine(["type": "session_meta", "payload": ["id": "c2", "source": "vscode"]], to: r2)
        try appendJSONLine([
            "type": "session_meta",
            "payload": ["id": "csub", "source": ["subagent": ["parent_thread_id": "c1"]]],
        ], to: rSub)
        try setModifiedDate(clock.now(), for: r1)
        try setModifiedDate(clock.now(), for: r2)
        try setModifiedDate(clock.now(), for: rSub)

        clock.advance(by: 30.0)
        adapter.checkForUpdates()
        XCTAssertEqual(adapter.activeSessionIDsForTesting, ["c1", "c2"])
        XCTAssertFalse(collector.events.contains { $0.kind == .warning })

        // Live 100% primary exhaustion with new resets_at + duplicate heartbeat + 429 error on r2.
        clock.advance(by: 2.0)
        let expectedReset = Date(timeIntervalSince1970: 1_794_750_000)
        try appendJSONLine([
            "type": "event_msg",
            "payload": [
                "type": "token_count",
                "rate_limits": ["primary": ["used_percent": 100.0, "resets_at": 1_794_750_000]],
            ],
        ], to: r1)
        try appendJSONLine([
            "type": "event_msg",
            "payload": [
                "type": "token_count",
                "rate_limits": ["primary": ["used_percent": 100.0, "resets_at": 1_794_750_000]],
            ],
        ], to: r1)
        try appendJSONLine([
            "type": "event_msg",
            "payload": ["type": "error", "message": "HTTP 429 Too Many Requests"],
        ], to: r2)
        adapter.checkForUpdates()

        let warnings = collector.events.filter { $0.kind == .warning }
        XCTAssertEqual(warnings.count, 2)
        let w1 = warnings.first { $0.metadata?[AgentEvent.MetadataKey.sessionID] == "c1" }
        let w2 = warnings.first { $0.metadata?[AgentEvent.MetadataKey.sessionID] == "c2" }
        XCTAssertEqual(w1?.metadata?[AgentEvent.MetadataKey.reason], AgentWarningReason.rateLimit.rawValue)
        XCTAssertEqual(w1?.message, expectedRateLimitMessage(agentName: "Codex", resetsAt: expectedReset))
        XCTAssertEqual(w2?.metadata?[AgentEvent.MetadataKey.reason], AgentWarningReason.rateLimit.rawValue)
        XCTAssertEqual(w2?.message, expectedRateLimitMessage(agentName: "Codex", resetsAt: nil))
    }

    // MARK: - 5. Cursor SQLite (`state.vscdb`) + JSONL (`agent-transcripts`)

    private func createCursorSQLiteDB(at dbURL: URL) throws {
        try FileManager.default.createDirectory(at: dbURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        var db: OpaquePointer?
        XCTAssertEqual(sqlite3_open(dbURL.path, &db), SQLITE_OK)
        defer { sqlite3_close(db) }
        let sql = """
        CREATE TABLE IF NOT EXISTS cursorDiskKV (key TEXT PRIMARY KEY, value TEXT);
        CREATE TABLE IF NOT EXISTS ItemTable (key TEXT PRIMARY KEY, value TEXT);
        """
        XCTAssertEqual(sqlite3_exec(db, sql, nil, nil, nil), SQLITE_OK)
    }

    private func upsertCursorKV(_ key: String, json: [String: Any], table: String = "cursorDiskKV", dbURL: URL) throws {
        var db: OpaquePointer?
        XCTAssertEqual(sqlite3_open(dbURL.path, &db), SQLITE_OK)
        defer { sqlite3_close(db) }
        let data = try JSONSerialization.data(withJSONObject: json)
        let str = String(data: data, encoding: .utf8)!
        var stmt: OpaquePointer?
        let sql = "INSERT OR REPLACE INTO \(table) (key, value) VALUES (?, ?);"
        XCTAssertEqual(sqlite3_prepare_v2(db, sql, -1, &stmt, nil), SQLITE_OK)
        defer { sqlite3_finalize(stmt) }
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        key.withCString { _ = sqlite3_bind_text(stmt, 1, $0, -1, transient) }
        str.withCString { _ = sqlite3_bind_text(stmt, 2, $0, -1, transient) }
        XCTAssertEqual(sqlite3_step(stmt), SQLITE_DONE)
    }

    func testCursorSQLiteComposerContextToolApprovalQuotaAndSeedSilence() throws {
        let dir = try makeTempDir(prefix: "cursor-db")
        defer { try? FileManager.default.removeItem(at: dir) }

        let dbURL = dir.appendingPathComponent("globalStorage/state.vscdb")
        let missingProjectsURL = dir.appendingPathComponent("missing-projects", isDirectory: true)
        try createCursorSQLiteDB(at: dbURL)

        let clock = TestClock()
        let nowMs = Int(clock.now().timeIntervalSince1970 * 1000)

        // Seed comp-1 with an old quota error + completed turn (must stay silent on seed), plus skipped subagent & draft.
        try upsertCursorKV("composerData:comp-1", json: [
            "composerId": "comp-1",
            "status": "completed",
            "contextTokensUsed": 40_000,
            "lastUpdatedAt": nowMs,
            "fullConversationHeadersOnly": [
                ["bubbleId": "b0", "type": 1],
                ["bubbleId": "b1", "type": 2],
            ],
        ], dbURL: dbURL)
        try upsertCursorKV("bubbleId:comp-1:b1", json: [
            "bubbleId": "b1",
            "type": 2,
            "errorDetails": ["error": "ERROR_PRO_USER_USAGE_LIMIT", "message": "Usage limit reached (429)"],
        ], dbURL: dbURL)
        try upsertCursorKV("composerData:sub-1", json: [
            "composerId": "sub-1",
            "isSubagent": true,
            "status": "generating",
            "lastUpdatedAt": nowMs,
        ], dbURL: dbURL)
        try upsertCursorKV("composerData:empty-state-draft", json: [
            "composerId": "empty-state-draft",
            "isDraft": true,
            "lastUpdatedAt": nowMs,
        ], dbURL: dbURL)
        try upsertCursorKV("composer.composerHeaders", json: [
            "allComposers": [
                ["composerId": "comp-1", "lastUpdatedAt": nowMs],
                ["composerId": "sub-1", "isSubagent": true, "lastUpdatedAt": nowMs],
            ],
        ], table: "ItemTable", dbURL: dbURL)
        try setModifiedDate(clock.now(), for: dbURL)

        let collector = EventCollector()
        let adapter = CursorTranscriptAdapter(
            globalStorageDBURL: dbURL,
            projectsURL: missingProjectsURL,
            clock: { clock.now() }
        )
        adapter.setHandlerForTesting { collector.append($0) }
        adapter.checkForUpdates()

        XCTAssertEqual(adapter.activeSessionIDsForTesting, ["comp-1"])
        XCTAssertFalse(collector.events.contains { $0.kind == .warning })
        XCTAssertEqual(
            collector.events.last { $0.kind == .usage }?.metadata?[AgentEvent.MetadataKey.contextTokens],
            "40000"
        )

        // Update comp-1 to actively generating with approval-gated tool.
        clock.advance(by: 2.0)
        let t1Ms = Int(clock.now().timeIntervalSince1970 * 1000)
        try upsertCursorKV("composerData:comp-1", json: [
            "composerId": "comp-1",
            "status": "generating",
            "contextTokensUsed": 95_000,
            "generatingBubbleIds": ["b3"],
            "lastUpdatedAt": t1Ms,
            "fullConversationHeadersOnly": [
                ["bubbleId": "b0", "type": 1],
                ["bubbleId": "b1", "type": 2],
                ["bubbleId": "b2", "type": 1],
                ["bubbleId": "b3", "type": 2],
            ],
        ], dbURL: dbURL)
        try upsertCursorKV("bubbleId:comp-1:b3", json: [
            "bubbleId": "b3",
            "type": 2,
            "toolFormerData": [
                "toolCallId": "tc-1",
                "name": "run_terminal_cmd",
                "rawArgs": #"{"command":"npm test"}"#,
                "status": "waiting_for_approval",
            ],
        ], dbURL: dbURL)
        try upsertCursorKV("composer.composerHeaders", json: [
            "allComposers": [["composerId": "comp-1", "lastUpdatedAt": t1Ms]],
        ], table: "ItemTable", dbURL: dbURL)
        try setModifiedDate(clock.now(), for: dbURL)
        adapter.checkForUpdates()

        XCTAssertTrue(collector.events.contains { $0.kind == .needsApproval })
        XCTAssertEqual(
            collector.events.last { $0.kind == .usage }?.metadata?[AgentEvent.MetadataKey.contextTokens],
            "95000"
        )

        // Complete tool tc-1 and complete turn.
        clock.advance(by: 2.0)
        let t2Ms = Int(clock.now().timeIntervalSince1970 * 1000)
        try upsertCursorKV("bubbleId:comp-1:b3", json: [
            "bubbleId": "b3",
            "type": 2,
            "toolFormerData": [
                "toolCallId": "tc-1",
                "name": "run_terminal_cmd",
                "rawArgs": #"{"command":"npm test"}"#,
                "status": "completed",
                "result": "ok",
            ],
        ], dbURL: dbURL)
        try upsertCursorKV("composerData:comp-1", json: [
            "composerId": "comp-1",
            "status": "completed",
            "contextTokensUsed": 110_000,
            "generatingBubbleIds": [],
            "lastUpdatedAt": t2Ms,
            "fullConversationHeadersOnly": [
                ["bubbleId": "b0", "type": 1],
                ["bubbleId": "b1", "type": 2],
                ["bubbleId": "b2", "type": 1],
                ["bubbleId": "b3", "type": 2],
            ],
        ], dbURL: dbURL)
        try setModifiedDate(clock.now(), for: dbURL)
        adapter.checkForUpdates()

        XCTAssertTrue(collector.events.contains { $0.kind == .done })

        // Now trigger a live 429 quota error with retry duration.
        clock.advance(by: 2.0)
        let t3Ms = Int(clock.now().timeIntervalSince1970 * 1000)
        try upsertCursorKV("bubbleId:comp-1:b4", json: [
            "bubbleId": "b4",
            "type": 2,
            "createdAt": "2026-11-14T16:00:00Z",
            "errorDetails": [
                "error": "ERROR_RESOURCE_EXHAUSTED",
                "message": "Rate limit exceeded (429). Try again in 15 minutes.",
            ],
        ], dbURL: dbURL)
        try upsertCursorKV("composerData:comp-1", json: [
            "composerId": "comp-1",
            "status": "aborted",
            "lastUpdatedAt": t3Ms,
            "fullConversationHeadersOnly": [
                ["bubbleId": "b0", "type": 1],
                ["bubbleId": "b1", "type": 2],
                ["bubbleId": "b2", "type": 1],
                ["bubbleId": "b3", "type": 2],
                ["bubbleId": "b4", "type": 2],
            ],
        ], dbURL: dbURL)
        try setModifiedDate(clock.now(), for: dbURL)
        adapter.checkForUpdates()

        let rateWarnings = collector.events.filter {
            $0.kind == .warning && $0.metadata?[AgentEvent.MetadataKey.reason] == AgentWarningReason.rateLimit.rawValue
        }
        XCTAssertEqual(rateWarnings.count, 1)
        let iso = ISO8601DateFormatter()
        let expectedReset = iso.date(from: "2026-11-14T16:00:00Z")!.addingTimeInterval(900)
        XCTAssertEqual(rateWarnings.first?.message, expectedRateLimitMessage(agentName: "Cursor", resetsAt: expectedReset))
    }

    func testCursorJSONLConcurrentSessionsToolLoop429AndMissingDirBackoff() throws {
        let dir = try makeTempDir(prefix: "cursor-jsonl")
        defer { try? FileManager.default.removeItem(at: dir) }

        let missingDBURL = dir.appendingPathComponent("missing/state.vscdb")
        let projectsURL = dir.appendingPathComponent("projects", isDirectory: true)

        let clock = TestClock()
        let adapter = CursorTranscriptAdapter(
            globalStorageDBURL: missingDBURL,
            projectsURL: projectsURL,
            clock: { clock.now() }
        )
        let collector = EventCollector()
        adapter.setHandlerForTesting { collector.append($0) }

        // Backoff when both DB and projects dirs are missing.
        adapter.checkForUpdates() // scan 1 -> 3s
        XCTAssertEqual(adapter.scanCountForTesting, 1)
        XCTAssertEqual(adapter.scanIntervalForTesting, 3.0, accuracy: 0.001)
        clock.advance(by: 1.5)
        adapter.checkForUpdates()
        XCTAssertEqual(adapter.scanCountForTesting, 1)
        clock.advance(by: 1.5)
        adapter.checkForUpdates() // scan 2 -> 6s
        clock.advance(by: 6.0)
        adapter.checkForUpdates() // scan 3 -> 12s
        clock.advance(by: 12.0)
        adapter.checkForUpdates() // scan 4 -> 24s
        clock.advance(by: 24.0)
        adapter.checkForUpdates() // scan 5 -> 30s
        XCTAssertEqual(adapter.scanIntervalForTesting, 30.0, accuracy: 0.001)

        // Create flat session + nested session + ignored subagents/ file.
        let transcriptsDir = projectsURL.appendingPathComponent("projA/agent-transcripts", isDirectory: true)
        let nestedDir = transcriptsDir.appendingPathComponent("cur-nested", isDirectory: true)
        let subagentsDir = transcriptsDir.appendingPathComponent("subagents", isDirectory: true)
        try FileManager.default.createDirectory(at: nestedDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: subagentsDir, withIntermediateDirectories: true)

        let flatURL = transcriptsDir.appendingPathComponent("cur-flat.jsonl")
        let nestedURL = nestedDir.appendingPathComponent("cur-nested.jsonl")
        let subURL = subagentsDir.appendingPathComponent("sub.jsonl")

        try appendJSONLine(["role": "user", "message": ["content": [["type": "text", "text": "Hi"]]]], to: flatURL)
        try appendJSONLine(["role": "user", "message": ["content": [["type": "text", "text": "Nested"]]]], to: nestedURL)
        try appendJSONLine(["role": "user", "message": ["content": [["type": "text", "text": "Sub"]]]], to: subURL)
        try setModifiedDate(clock.now(), for: flatURL)
        try setModifiedDate(clock.now(), for: nestedURL)
        try setModifiedDate(clock.now(), for: subURL)

        clock.advance(by: 30.0)
        adapter.checkForUpdates()
        XCTAssertEqual(adapter.activeSessionIDsForTesting, ["cur-flat", "cur-nested"])

        // cur-flat: context usage + 4x tool loop + done.
        clock.advance(by: 2.0)
        for idx in 1...4 {
            try appendJSONLine([
                "role": "assistant",
                "message": [
                    "usage": ["input_tokens": 50_000, "cache_read_input_tokens": 30_000],
                    "content": [["type": "tool_use", "id": "tu_\(idx)", "name": "grep", "input": ["pattern": "foo"]]],
                ],
            ], to: flatURL)
            try appendJSONLine([
                "role": "user",
                "message": ["content": [["type": "tool_result", "tool_use_id": "tu_\(idx)", "content": "match"]]],
            ], to: flatURL)
        }
        try appendJSONLine([
            "role": "assistant",
            "message": [
                "usage": ["input_tokens": 60_000, "cache_read_input_tokens": 30_000],
                "stop_reason": "end_turn",
                "content": [["type": "text", "text": "Completed"]],
            ],
        ], to: flatURL)

        // cur-nested: live 429 without reset time.
        try appendJSONLine([
            "type": "error",
            "statusCode": 429,
            "error": "Rate limit reached",
        ], to: nestedURL)

        adapter.checkForUpdates()

        let events = collector.events
        let lastFlatUsage = events.last { event in
            event.kind == .usage && event.metadata?[AgentEvent.MetadataKey.sessionID] == "cur-flat"
        }
        XCTAssertEqual(lastFlatUsage?.metadata?[AgentEvent.MetadataKey.contextTokens], "90000")

        let flatDone = events.contains { event in
            event.kind == .done && event.metadata?[AgentEvent.MetadataKey.sessionID] == "cur-flat"
        }
        XCTAssertTrue(flatDone)

        let flatLoop = events.contains { event in
            event.kind == .warning
                && event.metadata?[AgentEvent.MetadataKey.sessionID] == "cur-flat"
                && event.metadata?[AgentEvent.MetadataKey.reason] == AgentWarningReason.loop.rawValue
        }
        XCTAssertTrue(flatLoop)

        let nested429 = events.first { event in
            event.kind == .warning
                && event.metadata?[AgentEvent.MetadataKey.sessionID] == "cur-nested"
                && event.metadata?[AgentEvent.MetadataKey.reason] == AgentWarningReason.rateLimit.rawValue
        }
        XCTAssertNotNil(nested429)
        XCTAssertEqual(nested429?.message, expectedRateLimitMessage(agentName: "Cursor", resetsAt: nil))
    }
}
