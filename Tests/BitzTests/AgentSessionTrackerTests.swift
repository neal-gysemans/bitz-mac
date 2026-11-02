import XCTest
@testable import BitzCore

final class AgentSessionTrackerTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_000_000)
    private let bash = SessionLogEntry.toolCall(id: nil, name: "Bash", fingerprint: "Bash:aaa")
    private let read = SessionLogEntry.toolCall(id: nil, name: "Read", fingerprint: "Read:bbb")

    private func claude() -> AgentSessionTracker {
        AgentSessionTracker(agentID: "claude", agentName: "Claude Code", startsTurnOnPrompt: false)
    }

    private func antigravity() -> AgentSessionTracker {
        AgentSessionTracker(agentID: "antigravity", agentName: "Antigravity", startsTurnOnPrompt: true)
    }

    private func call(_ id: String?) -> SessionLogEntry {
        .toolCall(id: id, name: "Bash", fingerprint: "Bash:aaa")
    }

    func testClaudeStyleTurnEmitsWorkingOnFirstOutputThenDone() {
        var tracker = claude()

        XCTAssertEqual(tracker.ingest([.prompt], at: now), [])
        XCTAssertFalse(tracker.turnActive)

        let working = tracker.ingest([.assistantOutput(contextTokens: 1_200)], at: now)
        XCTAssertEqual(working.map(\.kind), [.working])
        XCTAssertEqual(working.first?.message, "Claude Code is working...")
        XCTAssertEqual(working.first?.agentID, "claude")
        XCTAssertEqual(working.first?.agentName, "Claude Code")
        XCTAssertEqual(working.first?.timestamp, now)
        XCTAssertTrue(tracker.turnActive)

        XCTAssertEqual(tracker.ingest([.assistantOutput(contextTokens: 1_300)], at: now), [])

        let done = tracker.ingest([.turnEnd(isDone: true)], at: now)
        XCTAssertEqual(done.map(\.kind), [.done])
        XCTAssertEqual(done.first?.message, "Claude Code is done!")
        XCTAssertFalse(tracker.turnActive)
    }

    func testPromptWithoutOutputNeverStartsTurn() {
        var tracker = claude()

        // Local slash command: prompt, then a silent turn end, no assistant output.
        XCTAssertEqual(tracker.ingest([.prompt, .turnEnd(isDone: false)], at: now), [])
        XCTAssertFalse(tracker.turnActive)
        XCTAssertEqual(tracker.ingest([.assistantOutput(contextTokens: nil)], at: now), [])
        XCTAssertFalse(tracker.turnActive)

        XCTAssertEqual(tracker.ingest([.prompt, .turnEnd(isDone: true)], at: now), [])

        // Interrupted turn: ends silently.
        XCTAssertEqual(tracker.ingest([.prompt, .assistantOutput(contextTokens: nil)], at: now).map(\.kind), [.working])
        XCTAssertEqual(tracker.ingest([.turnEnd(isDone: false)], at: now), [])
        XCTAssertFalse(tracker.turnActive)
    }

    func testAntigravityStyleTurnStartsOnPrompt() {
        var tracker = antigravity()

        let working = tracker.ingest([.prompt], at: now)
        XCTAssertEqual(working.map(\.kind), [.working])
        XCTAssertEqual(working.first?.message, "Antigravity is working...")
        XCTAssertTrue(tracker.turnActive)

        let done = tracker.ingest([.assistantOutput(contextTokens: 5), .turnEnd(isDone: true)], at: now)
        XCTAssertEqual(done.map(\.kind), [.done])
        XCTAssertEqual(done.first?.message, "Antigravity is done!")
    }

    func testApprovalRequestEmitsNeedsApproval() {
        var tracker = antigravity()

        let events = tracker.ingest([.approvalRequest], at: now)

        XCTAssertEqual(events.map(\.kind), [.needsApproval])
        XCTAssertEqual(events.first?.message, "Antigravity needs input!")
    }

    func testLoopWarningFiresOnceAtFourIdenticalCalls() {
        var tracker = claude()

        XCTAssertEqual(tracker.ingest([bash, bash, bash], at: now), [])

        let warning = tracker.ingest([bash], at: now)
        XCTAssertEqual(warning.map(\.kind), [.warning])
        XCTAssertEqual(warning.first?.warningReason, .loop)
        XCTAssertEqual(warning.first?.message, "⚠️ Claude Code may be stuck in a tool loop (Bash ×4).")

        XCTAssertEqual(tracker.ingest([bash], at: now), [])
        XCTAssertEqual(tracker.ingest([bash], at: now), [])
    }

    func testDifferentCallOrCompactionResetsLoop() {
        var tracker = claude()

        XCTAssertEqual(tracker.ingest([bash, bash, bash, read, bash, bash, bash], at: now), [])
        XCTAssertEqual(tracker.ingest([.compaction, bash], at: now), [])
        XCTAssertEqual(tracker.ingest([bash, bash, bash], at: now).map(\.kind), [.warning])

        // A different call re-arms the warning.
        XCTAssertEqual(tracker.ingest([read, bash, bash, bash, bash], at: now).map(\.kind), [.warning])
    }

    func testToolResultsAndTextDoNotBreakStreak() {
        var tracker = claude()
        let rounds: [SessionLogEntry] = (1...4).flatMap { round -> [SessionLogEntry] in
            [call("t\(round)"), .toolResult(id: "t\(round)"), .assistantOutput(contextTokens: nil)]
        }

        XCTAssertEqual(tracker.ingest(rounds, at: now).map(\.kind), [.warning])
    }

    func testPendingToolsTrackIDsAndAnonymous() {
        var tracker = claude()
        _ = tracker.ingest([.prompt, .assistantOutput(contextTokens: nil)], at: now)

        _ = tracker.ingest([call("1"), call("2"), call(nil), call(nil)], at: now)
        XCTAssertEqual(tracker.pendingTools, 4)

        _ = tracker.ingest([.toolResult(id: "1")], at: now)
        XCTAssertEqual(tracker.pendingTools, 3)

        _ = tracker.ingest([.toolResult(id: nil)], at: now)
        XCTAssertEqual(tracker.pendingTools, 1)

        _ = tracker.ingest([.toolResult(id: "unknown")], at: now)
        XCTAssertEqual(tracker.pendingTools, 1)

        _ = tracker.ingest([call("3"), .turnEnd(isDone: true)], at: now)
        XCTAssertEqual(tracker.pendingTools, 0)
    }

    func testUsageEventCarriesMetadata() {
        var tracker = claude()
        _ = tracker.ingest([.prompt, .assistantOutput(contextTokens: 150_000), call("t1"), .assistantOutput(contextTokens: nil)], at: now)

        let usage = tracker.usageEvent(at: now, seed: false)
        XCTAssertEqual(usage.kind, .usage)
        XCTAssertEqual(usage.agentID, "claude")
        XCTAssertEqual(usage.timestamp, now)
        XCTAssertEqual(usage.contextTokens, 150_000)
        XCTAssertEqual(usage.pendingTools, 1)
        XCTAssertEqual(usage.turnActive, true)
        XCTAssertEqual(usage.metadata?[AgentEvent.MetadataKey.seed], "false")
        XCTAssertFalse(usage.isSeed)

        let seed = claude().usageEvent(at: now, seed: true)
        XCTAssertNil(seed.metadata?[AgentEvent.MetadataKey.contextTokens])
        XCTAssertEqual(seed.pendingTools, 0)
        XCTAssertEqual(seed.turnActive, false)
        XCTAssertTrue(seed.isSeed)
    }

    func testFingerprintIgnoresKeyOrderAndDiffersOnValue() throws {
        func json(_ text: String) throws -> Any { try JSONSerialization.jsonObject(with: Data(text.utf8)) }
        let input = try json(#"{"command":"ls","options":{"a":1,"b":[1,2]}}"#)
        let reordered = try json(#"{"options":{"b":[1,2],"a":1},"command":"ls"}"#)
        let changed = try json(#"{"command":"ls -la","options":{"a":1,"b":[1,2]}}"#)

        let fingerprint = AgentSessionTracker.fingerprint(name: "Bash", input: input)
        XCTAssertEqual(fingerprint, AgentSessionTracker.fingerprint(name: "Bash", input: reordered))
        XCTAssertNotEqual(fingerprint, AgentSessionTracker.fingerprint(name: "Bash", input: changed))
        XCTAssertNotEqual(fingerprint, AgentSessionTracker.fingerprint(name: "Read", input: input))
        XCTAssertTrue(fingerprint.hasPrefix("Bash:"))
        XCTAssertEqual(fingerprint.count, "Bash:".count + 64)
        XCTAssertFalse(fingerprint.contains("ls"))

        // nil, scalar and unserializable inputs never crash.
        let empty = AgentSessionTracker.fingerprint(name: "Bash", input: nil)
        XCTAssertEqual(empty, "Bash:e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855")
        XCTAssertEqual(AgentSessionTracker.fingerprint(name: "Bash", input: now), empty)
        XCTAssertNotEqual(AgentSessionTracker.fingerprint(name: "Bash", input: "x"), empty)
    }

    func testResetClearsStateButKeepsIdentity() {
        var tracker = claude()
        _ = tracker.ingest([.prompt, .assistantOutput(contextTokens: 9_000), bash, bash, bash, .prompt], at: now)

        tracker.reset()

        XCTAssertEqual(tracker.agentID, "claude")
        XCTAssertEqual(tracker.agentName, "Claude Code")
        XCTAssertFalse(tracker.startsTurnOnPrompt)
        XCTAssertFalse(tracker.turnActive)
        XCTAssertNil(tracker.latestContextTokens)
        XCTAssertEqual(tracker.pendingTools, 0)
        // Loop streak and awaiting-first-output state are gone too.
        XCTAssertEqual(tracker.ingest([bash, .assistantOutput(contextTokens: nil)], at: now), [])
    }

    func testDuplicateTurnEndEmitsSingleDone() {
        var tracker = claude()

        let events = tracker.ingest([
            .prompt, .assistantOutput(contextTokens: nil),
            .turnEnd(isDone: true), .turnEnd(isDone: false), .turnEnd(isDone: true),
        ], at: now)

        XCTAssertEqual(events.map(\.kind), [.working, .done])
    }

    // MARK: - prime(fromSeed:) (FR-014): prime returns nothing, so seed lines never produce events.

    func testPrimeClaudeSeedAwaitingFirstOutputPicksUpTurn() {
        var tracker = claude()

        tracker.prime(fromSeed: [.turnEnd(isDone: true), .prompt])
        XCTAssertFalse(tracker.turnActive)

        XCTAssertEqual(tracker.ingest([.assistantOutput(contextTokens: nil)], at: now).map(\.kind), [.working])
        XCTAssertEqual(tracker.ingest([.turnEnd(isDone: true)], at: now).map(\.kind), [.done])
    }

    func testPrimeClaudeSeedMidTurnEndsWithSingleDone() {
        var tracker = claude()

        tracker.prime(fromSeed: [.prompt, .assistantOutput(contextTokens: 1_000), call("t1")])
        XCTAssertTrue(tracker.turnActive)
        XCTAssertEqual(tracker.pendingTools, 1)
        XCTAssertEqual(tracker.latestContextTokens, 1_000)

        XCTAssertEqual(tracker.ingest([.toolResult(id: "t1"), .turnEnd(isDone: true)], at: now).map(\.kind), [.done])
    }

    func testPrimeSeedWithoutPromptButOutputSinceLastEndIsActive() {
        // A long turn pushed its prompt out of the 256 KB seed window.
        var tracker = claude()
        tracker.prime(fromSeed: [.assistantOutput(contextTokens: 1_000), call("t1")])
        XCTAssertTrue(tracker.turnActive)
        XCTAssertEqual(tracker.ingest([.toolResult(id: "t1"), .turnEnd(isDone: true)], at: now).map(\.kind), [.done])

        var finished = claude()
        finished.prime(fromSeed: [.assistantOutput(contextTokens: 1_000), .turnEnd(isDone: true)])
        XCTAssertFalse(finished.turnActive)
    }

    func testPrimeAntigravitySeedPromptMarksTurnActive() {
        var tracker = antigravity()

        tracker.prime(fromSeed: [.prompt])
        XCTAssertTrue(tracker.turnActive)

        XCTAssertEqual(tracker.ingest([.turnEnd(isDone: true)], at: now).map(\.kind), [.done])
    }

    func testPrimeSeedEndingWithTurnEndLeavesNoTurn() {
        var tracker = claude()

        tracker.prime(fromSeed: [.prompt, .assistantOutput(contextTokens: 5), call("t1"), call(nil), .turnEnd(isDone: true)])
        XCTAssertFalse(tracker.turnActive)
        XCTAssertEqual(tracker.pendingTools, 0)
        XCTAssertEqual(tracker.latestContextTokens, 5)
        XCTAssertEqual(tracker.ingest([.assistantOutput(contextTokens: nil)], at: now), [])
    }

    func testPrimeClearsLoopStreak() {
        var tracker = claude()

        tracker.prime(fromSeed: [bash, bash, bash])

        XCTAssertEqual(tracker.ingest([bash], at: now), [])
        XCTAssertEqual(tracker.ingest([bash, bash, bash], at: now).map(\.kind), [.warning])
    }

    func testPrimeAfterResetYieldsOnlySeedState() {
        var tracker = claude()
        _ = tracker.ingest([.prompt, .assistantOutput(contextTokens: 9_000), call("old"), bash], at: now)

        tracker.reset()
        tracker.prime(fromSeed: [.prompt])

        XCTAssertFalse(tracker.turnActive)
        XCTAssertEqual(tracker.pendingTools, 0)
        XCTAssertNil(tracker.latestContextTokens)
        XCTAssertEqual(tracker.ingest([.assistantOutput(contextTokens: nil)], at: now).map(\.kind), [.working])
        XCTAssertEqual(tracker.ingest([bash, bash, bash], at: now), [])
    }
}
