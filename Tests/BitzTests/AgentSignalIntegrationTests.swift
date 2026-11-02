import Combine
import XCTest
@testable import BitzCore

/// SC-002: Claude Code session logs replayed through the real `ClaudeCodeTranscriptAdapter` into the real
/// `AgentMonitorService`, asserting the warnings a user would see.
@MainActor
final class AgentSignalIntegrationTests: XCTestCase {
    func testReplayedSessionCrossingThresholdWarnsExactlyOnce() throws {
        let (replay, cleanup) = try makeReplay()
        defer { cleanup() }
        XCTAssertEqual(replay.monitor.signalSettings.contextWindow(for: "claude"), 200_000)

        for tokens in [120_000, 185_000, 190_000] {
            try replay.append(turn(contextTokens: tokens))
        }
        XCTAssertEqual(replay.raised.map(\.reason), [.context], "Crossing 90% warns once; staying above it does not")
        XCTAssertEqual(replay.monitor.latestContext?.tokens, 190_000)

        try replay.append([system("compact_boundary")] + turn(contextTokens: 60_000))
        try replay.append(turn(contextTokens: 182_000))
        XCTAssertEqual(replay.raised.map(\.reason), [.context, .context], "After compaction the next crossing warns again")
    }

    func testReplayedLoopOfFourIdenticalCallsWarnsOnce() throws {
        let (replay, cleanup) = try makeReplay()
        defer { cleanup() }

        try replay.append([userPrompt()])
        for n in 1...5 {
            try replay.append([assistant(tools: [("t\(n)", "Read", ["file_path": "/tmp/a.swift"])]), toolResult("t\(n)")])
            XCTAssertEqual(replay.raised.count, n >= 4 ? 1 : 0, "after identical call \(n)")
        }
        XCTAssertEqual(replay.raised.first?.reason, .loop)
    }

    func testReplayedFinishedTurnNeverStalls() throws {
        let (replay, cleanup) = try makeReplay()
        defer { cleanup() }

        try replay.append([userPrompt(), assistant(tools: [("t1", "Bash", ["command": "make"])])])
        try replay.append([toolResult("t1"), assistant(contextTokens: 52_000, stop: "end_turn")])
        XCTAssertEqual(replay.monitor.latestContext?.tokens, 52_000, "The replayed turn reached the monitor")
        replay.advance(minutes: 10)
        replay.monitor.evaluateStalls()

        XCTAssertEqual(replay.raised, [], "A finished turn is idle, not stuck")
    }

    func testReplayedMidTurnSilenceStalls() throws {
        let (replay, cleanup) = try makeReplay()
        defer { cleanup() }

        try replay.append([userPrompt(), assistant(tools: [("t1", "Bash", ["command": "make"])])])
        try replay.append([toolResult("t1")])
        replay.advance(minutes: 2)
        replay.monitor.evaluateStalls()
        XCTAssertEqual(replay.raised, [], "Not stuck before the 3 min default timeout")

        replay.advance(minutes: 1.5)
        replay.monitor.evaluateStalls()
        replay.monitor.evaluateStalls()
        XCTAssertEqual(replay.raised.map(\.reason), [.stall], "One warning per stall")
    }

    // MARK: - Replay harness

    /// A fresh session log, adapter and monitor sharing one test clock, with isolated defaults; call the cleanup in `defer`.
    private func makeReplay() throws -> (Replay, () -> Void) {
        let suiteName = "AgentSignalIntegrationTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let cleanup = {
            defaults.removePersistentDomain(forName: suiteName)
            try? FileManager.default.removeItem(at: root)
        }
        do {
            return (try Replay(projectsURL: root.appendingPathComponent("projects"), defaults: defaults), cleanup)
        } catch {
            cleanup()
            throw error
        }
    }

    // Fixture lines: synthetic shapes only, no real transcript content.

    private func turn(contextTokens: Int) -> [String] {
        [userPrompt(), assistant(contextTokens: contextTokens, stop: "end_turn")]
    }

    private func assistant(
        contextTokens: Int = 51_000,
        tools: [(id: String, name: String, input: [String: Any])] = [],
        stop: String = "tool_use"
    ) -> String {
        json([
            "type": "assistant",
            "message": [
                "role": "assistant",
                "content": tools.map { ["type": "tool_use", "id": $0.id, "name": $0.name, "input": $0.input] },
                "usage": [
                    "input_tokens": 1_000,
                    "cache_creation_input_tokens": 0,
                    "cache_read_input_tokens": contextTokens - 1_000,
                    "output_tokens": 10,
                ],
                "stop_reason": stop,
            ] as [String: Any],
        ])
    }

    private func userPrompt() -> String {
        json(["type": "user", "message": ["role": "user", "content": "do it"]])
    }

    private func toolResult(_ id: String) -> String {
        json(["type": "user", "message": ["role": "user", "content": [["type": "tool_result", "tool_use_id": id, "content": "ok"]]]])
    }

    private func system(_ subtype: String) -> String {
        json(["type": "system", "subtype": subtype])
    }

    private func json(_ object: [String: Any]) -> String {
        String(decoding: try! JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]), as: UTF8.self)
    }
}

/// One Claude Code session log wired adapter → monitor; the adapter polls only when lines are appended.
@MainActor
private final class Replay {
    final class Clock: @unchecked Sendable {
        private let lock = NSLock()
        private var current = Date(timeIntervalSinceReferenceDate: 800_000_000)
        var now: Date {
            get { lock.withLock { current } }
            set { lock.withLock { current = newValue } }
        }
    }

    /// Collects adapter events, which arrive under the adapter's lock, for in-order hand-off to the monitor.
    final class Collector: @unchecked Sendable {
        private let lock = NSLock()
        private var events: [AgentEvent] = []
        func append(_ event: AgentEvent) { lock.withLock { events.append(event) } }
        func drain() -> [AgentEvent] { lock.withLock { defer { events = [] }; return events } }
    }

    let monitor: AgentMonitorService
    /// Every warning the monitor raised, in order (a replacing warning counts again).
    private(set) var raised: [AgentWarning] = []

    private let clock = Clock()
    private let collector = Collector()
    private let adapter: ClaudeCodeTranscriptAdapter
    private let session: URL
    private var cancellable: AnyCancellable?

    init(projectsURL: URL, defaults: UserDefaults) throws {
        session = projectsURL.appendingPathComponent("proj/session-1.jsonl")
        try FileManager.default.createDirectory(at: session.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data().write(to: session)

        let clock = self.clock
        let collector = self.collector
        adapter = ClaudeCodeTranscriptAdapter(projectsURL: projectsURL, clock: { clock.now })
        adapter.setHandlerForTesting { collector.append($0) }
        monitor = AgentMonitorService(adapters: [], clock: { clock.now }, userDefaults: defaults)
        cancellable = monitor.$activeWarning.compactMap { $0 }.sink { [weak self] in self?.raised.append($0) }
        // The adapter attaches silently on its first poll, so every appended line is observed live.
        poll()
    }

    func append(_ lines: [String]) throws {
        let handle = try FileHandle(forWritingTo: session)
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: Data(lines.map { $0 + "\n" }.joined().utf8))
        poll()
    }

    func advance(minutes: Double) {
        clock.now = clock.now.addingTimeInterval(minutes * 60)
    }

    private func poll() {
        adapter.checkForUpdates()
        // A loop, not `forEach(monitor.handleEvent)`: Swift 6.0 (CI's Xcode 16.2) treats that main-actor method reference as throwing.
        for event in collector.drain() { monitor.handleEvent(event) }
    }
}
