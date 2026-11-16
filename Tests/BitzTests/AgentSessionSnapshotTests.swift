import XCTest
import SQLite3
@testable import BitzCore

@MainActor
final class AgentSessionSnapshotTests: XCTestCase {

    private final class TestClock: @unchecked Sendable {
        var now = Date(timeIntervalSince1970: 1_700_000_000)
    }

    private func makeIsolatedDefaults() -> (UserDefaults, () -> Void) {
        let suiteName = "AgentSessionSnapshotTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        let cleanup: () -> Void = {
            defaults.removePersistentDomain(forName: suiteName)
        }
        return (defaults, cleanup)
    }

    private func makeTempSummariesDatabase() -> (URL, () -> Void) {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("bitz-test-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        let dbURL = tempDir.appendingPathComponent("conversation_summaries.db")

        var db: OpaquePointer?
        if sqlite3_open(dbURL.path, &db) == SQLITE_OK {
            let sql = """
            CREATE TABLE conversation_summaries (
                conversation_id TEXT PRIMARY KEY,
                title TEXT NOT NULL,
                workspace_uris TEXT NOT NULL,
                status TEXT,
                last_modified_time DATETIME
            );
            INSERT INTO conversation_summaries VALUES ('conv-title-1', 'Build 3D Command Deck', '["file:///Volumes/DevDrive/Code/bitz-mac"]', 'IDLE', datetime('now'));
            INSERT INTO conversation_summaries VALUES ('conv-folder-only', '', '["file:///Users/dev/repos/my-cool-service"]', 'IDLE', datetime('now'));
            INSERT INTO conversation_summaries VALUES ('conv-empty', '', '', 'IDLE', datetime('now'));
            """
            _ = sqlite3_exec(db, sql, nil, nil, nil)
            sqlite3_close(db)
        }

        let cleanup: () -> Void = {
            _ = try? FileManager.default.removeItem(at: tempDir)
        }
        return (dbURL, cleanup)
    }

    // MARK: - 1. Lifecycle State Ordering & Comparable

    func testLifecycleStatePriorityOrderAndComparable() {
        let states: [AgentSessionLifecycleState] = [
            .idle,
            .done,
            .working,
            .almostDone,
            .failed,
            .warning,
            .needsApproval
        ]

        let sorted = states.sorted()
        let expected: [AgentSessionLifecycleState] = [
            .needsApproval,
            .warning,
            .failed,
            .almostDone,
            .working,
            .done,
            .idle
        ]

        XCTAssertEqual(sorted, expected)
        XCTAssertEqual(AgentSessionLifecycleState.needsApproval.priorityOrder, 0)
        XCTAssertEqual(AgentSessionLifecycleState.warning.priorityOrder, 1)
        XCTAssertEqual(AgentSessionLifecycleState.failed.priorityOrder, 2)
        XCTAssertEqual(AgentSessionLifecycleState.almostDone.priorityOrder, 3)
        XCTAssertEqual(AgentSessionLifecycleState.working.priorityOrder, 4)
        XCTAssertEqual(AgentSessionLifecycleState.done.priorityOrder, 5)
        XCTAssertEqual(AgentSessionLifecycleState.idle.priorityOrder, 6)

        XCTAssertTrue(AgentSessionLifecycleState.needsApproval < AgentSessionLifecycleState.warning)
        XCTAssertTrue(AgentSessionLifecycleState.warning < AgentSessionLifecycleState.failed)
        XCTAssertTrue(AgentSessionLifecycleState.failed < AgentSessionLifecycleState.almostDone)
        XCTAssertTrue(AgentSessionLifecycleState.almostDone < AgentSessionLifecycleState.working)
        XCTAssertTrue(AgentSessionLifecycleState.working < AgentSessionLifecycleState.done)
        XCTAssertTrue(AgentSessionLifecycleState.done < AgentSessionLifecycleState.idle)
    }

    // MARK: - 2. Snapshot Model Stability & Identity

    func testAgentSessionSnapshotIdentityAndProperties() {
        let now = Date()
        let reading = AgentContextReading(agentID: "claude", agentName: "Claude", tokens: 150_000, windowTokens: 200_000)
        let approval = AgentApprovalRequest(
            id: "req-1",
            agentID: "claude",
            agentName: "Claude",
            sessionID: "sess-1",
            toolName: "Bash",
            commandSummary: "git status"
        )

        let snapshot = AgentSessionSnapshot(
            stateKey: "claude::sess-1",
            agentID: "claude",
            agentName: "Claude",
            sessionID: "sess-1",
            sessionLabel: "Claude · bitz-mac",
            lifecycleState: .needsApproval,
            activeWarning: .context,
            contextReading: reading,
            pendingTools: 2,
            lastActivity: now,
            linkedApprovalRequest: approval,
            workingDir: "/Volumes/DevDrive/Code/bitz-mac"
        )

        XCTAssertEqual(snapshot.id, "claude::sess-1")
        XCTAssertEqual(snapshot.stateKey, "claude::sess-1")
        XCTAssertEqual(snapshot.agentID, "claude")
        XCTAssertEqual(snapshot.agentName, "Claude")
        XCTAssertEqual(snapshot.sessionID, "sess-1")
        XCTAssertEqual(snapshot.sessionLabel, "Claude · bitz-mac")
        XCTAssertEqual(snapshot.lifecycleState, .needsApproval)
        XCTAssertEqual(snapshot.activeWarning, .context)
        XCTAssertEqual(snapshot.contextReading, reading)
        XCTAssertEqual(snapshot.pendingTools, 2)
        XCTAssertEqual(snapshot.lastActivity, now)
        XCTAssertEqual(snapshot.linkedApprovalRequest?.id, "req-1")
        XCTAssertEqual(snapshot.linkedApprovalRequest?.sessionID, "sess-1")
        XCTAssertEqual(snapshot.workingDir, "/Volumes/DevDrive/Code/bitz-mac")
    }

    // MARK: - 3. Multi-Session Priority Sorting

    func testPrioritySortingAcrossConcurrentSessions() {
        let (defaults, cleanup) = makeIsolatedDefaults()
        defer { cleanup() }

        let clock = TestClock()
        let service = AgentMonitorService(clock: { clock.now }, userDefaults: defaults)

        // Session 1: Claude Code session working
        service.handleEvent(AgentEvent(
            agentID: "claude",
            agentName: "Claude",
            kind: .working,
            timestamp: clock.now,
            metadata: [
                AgentEvent.MetadataKey.sessionID: "claude-session-1",
                AgentEvent.MetadataKey.workingDir: "/Volumes/DevDrive/Code/bitz-mac"
            ]
        ))

        // Session 2: Antigravity session needs approval (highest priority)
        clock.now = clock.now.addingTimeInterval(5)
        service.handleEvent(AgentEvent(
            agentID: "antigravity",
            agentName: "Antigravity",
            kind: .needsApproval,
            timestamp: clock.now,
            metadata: [
                AgentEvent.MetadataKey.sessionID: "conv-1",
                AgentEvent.MetadataKey.approvalRequestID: "req-antigravity-1"
            ]
        ))

        // Session 3: Claude Code session 2 has loop warning
        clock.now = clock.now.addingTimeInterval(5)
        service.handleEvent(AgentEvent(
            agentID: "claude",
            agentName: "Claude",
            kind: .warning,
            timestamp: clock.now,
            metadata: [
                AgentEvent.MetadataKey.sessionID: "claude-session-2",
                AgentEvent.MetadataKey.reason: "loop"
            ]
        ))

        // Session 4: Codex session is done
        clock.now = clock.now.addingTimeInterval(5)
        service.handleEvent(AgentEvent(
            agentID: "codex",
            agentName: "Codex",
            kind: .done,
            timestamp: clock.now,
            metadata: [
                AgentEvent.MetadataKey.sessionID: "codex-session-1"
            ]
        ))

        let snapshots = service.sessionSnapshots
        XCTAssertEqual(snapshots.count, 4)

        // Priority order: needsApproval (0) -> warning (1) -> working (4) -> done (5)
        XCTAssertEqual(snapshots[0].sessionID, "conv-1")
        XCTAssertEqual(snapshots[0].lifecycleState, .needsApproval)

        XCTAssertEqual(snapshots[1].sessionID, "claude-session-2")
        XCTAssertEqual(snapshots[1].lifecycleState, .warning)
        XCTAssertEqual(snapshots[1].activeWarning, .loop)

        XCTAssertEqual(snapshots[2].sessionID, "claude-session-1")
        XCTAssertEqual(snapshots[2].lifecycleState, .working)

        XCTAssertEqual(snapshots[3].sessionID, "codex-session-1")
        XCTAssertEqual(snapshots[3].lifecycleState, .done)
    }

    func testSecondarySortingByLastActivityDescending() {
        let (defaults, cleanup) = makeIsolatedDefaults()
        defer { cleanup() }

        let clock = TestClock()
        let service = AgentMonitorService(clock: { clock.now }, userDefaults: defaults)

        // Session A starts working at t=100
        service.handleEvent(AgentEvent(
            agentID: "claude",
            agentName: "Claude",
            kind: .working,
            timestamp: clock.now,
            metadata: [AgentEvent.MetadataKey.sessionID: "session-older"]
        ))

        // Session B starts working at t=120 (newer)
        clock.now = clock.now.addingTimeInterval(20)
        service.handleEvent(AgentEvent(
            agentID: "claude",
            agentName: "Claude",
            kind: .working,
            timestamp: clock.now,
            metadata: [AgentEvent.MetadataKey.sessionID: "session-newer"]
        ))

        let snapshots = service.sessionSnapshots
        XCTAssertEqual(snapshots.count, 2)
        XCTAssertEqual(snapshots[0].sessionID, "session-newer")
        XCTAssertEqual(snapshots[1].sessionID, "session-older")

        // Touch session-older at t=150
        clock.now = clock.now.addingTimeInterval(30)
        service.handleEvent(AgentEvent(
            agentID: "claude",
            agentName: "Claude",
            kind: .working,
            timestamp: clock.now,
            metadata: [AgentEvent.MetadataKey.sessionID: "session-older"]
        ))

        let updatedSnapshots = service.sessionSnapshots
        XCTAssertEqual(updatedSnapshots[0].sessionID, "session-older")
        XCTAssertEqual(updatedSnapshots[1].sessionID, "session-newer")
    }

    // MARK: - 4. Label Auto-Derivation

    func testLabelDerivationFromWorkingDirectory() {
        let (defaults, cleanup) = makeIsolatedDefaults()
        defer { cleanup() }

        let service = AgentMonitorService(userDefaults: defaults)
        let label = service.deriveSessionLabel(
            agentID: "claude",
            agentName: "Claude",
            sessionID: "uuid-123456",
            workingDir: "/Volumes/DevDrive/Code/bitz-mac",
            fallbackIndex: 1
        )

        XCTAssertEqual(label, "Claude · bitz-mac")
    }

    func testClaudeSlugResolutionGreedyAndFallback() {
        // Test local filesystem greedy match
        let localSlug = "-Volumes-DevDrive-Code-bitz-mac"
        let resolvedLocal = AgentMonitorService.resolveClaudeProjectSlug(localSlug)
        XCTAssertEqual(resolvedLocal, "bitz-mac")

        // Test worktree marker stripping
        let worktreeSlug = "-Volumes-DevDrive-Code-bitz-mac--claude-worktrees-task-alpha"
        let resolvedWorktree = AgentMonitorService.resolveClaudeProjectSlug(worktreeSlug)
        XCTAssertEqual(resolvedWorktree, "bitz-mac")

        // Test non-local mock path with Code marker
        let mockCodeSlug = "-remote-server-home-developer-Code-payment-gateway"
        let resolvedMock = AgentMonitorService.resolveClaudeProjectSlug(mockCodeSlug)
        XCTAssertEqual(resolvedMock, "payment-gateway")

        // Test non-local mock path with projects marker
        let mockProjectsSlug = "-Users-test-projects-frontend-react-ui"
        let resolvedProjects = AgentMonitorService.resolveClaudeProjectSlug(mockProjectsSlug)
        XCTAssertEqual(resolvedProjects, "frontend-react-ui")

        // Test generic simple slug fallback
        let simpleSlug = "custom-agent-task"
        let resolvedSimple = AgentMonitorService.resolveClaudeProjectSlug(simpleSlug)
        XCTAssertEqual(resolvedSimple, "custom-agent-task")
    }

    func testAntigravityConversationSummariesDatabaseExtraction() {
        let (dbURL, cleanupDB) = makeTempSummariesDatabase()
        defer { cleanupDB() }

        let (defaults, cleanupDefaults) = makeIsolatedDefaults()
        defer { cleanupDefaults() }

        let service = AgentMonitorService(userDefaults: defaults, summariesDatabaseURL: dbURL)

        // 1. Title takes precedence
        let labelWithTitle = service.deriveSessionLabel(
            agentID: "antigravity",
            agentName: "Antigravity",
            sessionID: "conv-title-1",
            workingDir: nil,
            fallbackIndex: 1
        )
        XCTAssertEqual(labelWithTitle, "Antigravity · Build 3D Command Deck")

        // 2. Folder from workspace URI extracted when title is empty
        let labelWithFolder = service.deriveSessionLabel(
            agentID: "antigravity",
            agentName: "Antigravity",
            sessionID: "conv-folder-only",
            workingDir: nil,
            fallbackIndex: 2
        )
        XCTAssertEqual(labelWithFolder, "Antigravity · my-cool-service")

        // 3. Fallback to short sessionID when row has empty fields
        let labelEmpty = service.deriveSessionLabel(
            agentID: "antigravity",
            agentName: "Antigravity",
            sessionID: "conv-empty-xyz",
            workingDir: nil,
            fallbackIndex: 3
        )
        XCTAssertEqual(labelEmpty, "Antigravity · conv-e")

        // 4. Fallback index when sessionID is nil
        let labelFallback = service.deriveSessionLabel(
            agentID: "generic",
            agentName: "Aider",
            sessionID: nil,
            workingDir: nil,
            fallbackIndex: 4
        )
        XCTAssertEqual(labelFallback, "Aider · #4")
    }

    // MARK: - 5. Approval Linking & Per-Session Isolation

    func testApprovalLinkingAndPerSessionIsolation() {
        let (defaults, cleanupDefaults) = makeIsolatedDefaults()
        defer { cleanupDefaults() }

        let service = AgentMonitorService(userDefaults: defaults)
        let store = AgentApprovalStore()
        store.bind(agentMonitor: service)

        let now = Date()

        // Session Alpha emits needsApproval
        service.handleEvent(AgentEvent(
            agentID: "claude",
            agentName: "Claude",
            kind: .needsApproval,
            timestamp: now,
            metadata: [
                AgentEvent.MetadataKey.sessionID: "session-alpha",
                AgentEvent.MetadataKey.approvalRequestID: "req-alpha",
                AgentEvent.MetadataKey.toolName: "Bash",
                AgentEvent.MetadataKey.commandSummary: "rm -rf build"
            ]
        ))

        // Session Beta emits needsApproval concurrently
        service.handleEvent(AgentEvent(
            agentID: "claude",
            agentName: "Claude",
            kind: .needsApproval,
            timestamp: now,
            metadata: [
                AgentEvent.MetadataKey.sessionID: "session-beta",
                AgentEvent.MetadataKey.approvalRequestID: "req-beta",
                AgentEvent.MetadataKey.toolName: "Edit",
                AgentEvent.MetadataKey.commandSummary: "edit Package.swift"
            ]
        ))

        // Both sessions should be in needsApproval with linked requests
        let snapshots = service.sessionSnapshots
        XCTAssertEqual(snapshots.count, 2)

        guard let snapAlpha = snapshots.first(where: { $0.sessionID == "session-alpha" }),
              let snapBeta = snapshots.first(where: { $0.sessionID == "session-beta" }) else {
            XCTFail("Missing session snapshots")
            return
        }

        XCTAssertEqual(snapAlpha.lifecycleState, .needsApproval)
        XCTAssertEqual(snapAlpha.linkedApprovalRequest?.id, "req-alpha")
        XCTAssertEqual(snapAlpha.linkedApprovalRequest?.sessionID, "session-alpha")

        XCTAssertEqual(snapBeta.lifecycleState, .needsApproval)
        XCTAssertEqual(snapBeta.linkedApprovalRequest?.id, "req-beta")
        XCTAssertEqual(snapBeta.linkedApprovalRequest?.sessionID, "session-beta")

        // Submit decision for Session Alpha
        let result = store.submitDecision(.approve, for: "req-alpha")
        XCTAssertEqual(result, .approved)

        // Session Alpha's linked request should be cleared, reverting to working
        let afterAlphaSnapshots = service.sessionSnapshots
        let updatedAlpha = afterAlphaSnapshots.first(where: { $0.sessionID == "session-alpha" })
        let updatedBeta = afterAlphaSnapshots.first(where: { $0.sessionID == "session-beta" })

        XCTAssertEqual(updatedAlpha?.lifecycleState, .working)
        XCTAssertNil(updatedAlpha?.linkedApprovalRequest)

        // Session Beta MUST remain in needsApproval with linked request intact!
        XCTAssertEqual(updatedBeta?.lifecycleState, .needsApproval)
        XCTAssertEqual(updatedBeta?.linkedApprovalRequest?.id, "req-beta")
    }

    func testPerSessionClearRequestsInApprovalStore() {
        let store = AgentApprovalStore()

        // Register requests for two sessions of the same agentID
        store.registerRequest(from: AgentEvent(
            agentID: "claude",
            agentName: "Claude",
            kind: .needsApproval,
            metadata: [
                AgentEvent.MetadataKey.sessionID: "session-1",
                AgentEvent.MetadataKey.approvalRequestID: "req-1"
            ]
        ))

        store.registerRequest(from: AgentEvent(
            agentID: "claude",
            agentName: "Claude",
            kind: .needsApproval,
            metadata: [
                AgentEvent.MetadataKey.sessionID: "session-2",
                AgentEvent.MetadataKey.approvalRequestID: "req-2"
            ]
        ))

        XCTAssertEqual(store.pendingRequests.count, 2)

        // Clear only session-1
        store.clearRequests(for: "claude", sessionID: "session-1")

        XCTAssertNil(store.pendingRequests["req-1"])
        XCTAssertNotNil(store.pendingRequests["req-2"])
        XCTAssertEqual(store.pendingRequests["req-2"]?.sessionID, "session-2")

        // Clear all requests for claude
        store.clearRequests(for: "claude", sessionID: nil)
        XCTAssertTrue(store.pendingRequests.isEmpty)
    }

    // MARK: - 6. Warning Lifecycle & Session Targeted Acknowledge

    func testWarningLifecycleAndSessionTargetedAcknowledge() {
        let (defaults, cleanup) = makeIsolatedDefaults()
        defer { cleanup() }

        let service = AgentMonitorService(userDefaults: defaults)

        // Start session 1 working
        service.handleEvent(AgentEvent(
            agentID: "claude",
            agentName: "Claude",
            kind: .working,
            metadata: [AgentEvent.MetadataKey.sessionID: "session-1"]
        ))

        // Raise warning on session 1
        service.handleEvent(AgentEvent(
            agentID: "claude",
            agentName: "Claude",
            kind: .warning,
            metadata: [
                AgentEvent.MetadataKey.sessionID: "session-1",
                AgentEvent.MetadataKey.reason: "loop"
            ]
        ))

        var snap = service.sessionSnapshots.first(where: { $0.sessionID == "session-1" })
        XCTAssertEqual(snap?.lifecycleState, .warning)
        XCTAssertEqual(snap?.activeWarning, .loop)

        // Acknowledge warning specifically for session 1
        service.acknowledgeWarning(stateKey: "claude::session-1")

        snap = service.sessionSnapshots.first(where: { $0.sessionID == "session-1" })
        XCTAssertEqual(snap?.lifecycleState, .working)
        XCTAssertNil(snap?.activeWarning)
    }

    func testStallEvaluationUpdatesSnapshotLifecycle() {
        let (defaults, cleanup) = makeIsolatedDefaults()
        defer { cleanup() }

        let clock = TestClock()
        let service = AgentMonitorService(clock: { clock.now }, userDefaults: defaults)

        // Register session with usage event (tracksLog = true, turnActive = true)
        service.handleEvent(AgentEvent(
            agentID: "claude",
            agentName: "Claude",
            kind: .usage,
            timestamp: clock.now,
            metadata: [
                AgentEvent.MetadataKey.sessionID: "session-stalling",
                AgentEvent.MetadataKey.turnActive: "true",
                AgentEvent.MetadataKey.pendingTools: "0"
            ]
        ))

        var snap = service.sessionSnapshots.first(where: { $0.sessionID == "session-stalling" })
        XCTAssertEqual(snap?.lifecycleState, .working)

        // Advance past stall timeout (default 3 minutes = 180s)
        clock.now = clock.now.addingTimeInterval(200)
        service.evaluateStalls()

        snap = service.sessionSnapshots.first(where: { $0.sessionID == "session-stalling" })
        XCTAssertEqual(snap?.lifecycleState, .warning)
        XCTAssertEqual(snap?.activeWarning, .stall)
    }

    // MARK: - 7. Full Lifecycle Transitions

    func testFullSessionLifecycleTransitions() {
        let (defaults, cleanup) = makeIsolatedDefaults()
        defer { cleanup() }

        let service = AgentMonitorService(userDefaults: defaults)
        let stateKey = "claude::session-lifecycle"

        // 1. started -> working
        service.handleEvent(AgentEvent(
            agentID: "claude",
            agentName: "Claude",
            kind: .started,
            metadata: [AgentEvent.MetadataKey.sessionID: "session-lifecycle"]
        ))
        XCTAssertEqual(service.sessionSnapshots.first(where: { $0.stateKey == stateKey })?.lifecycleState, .working)

        // 2. needsApproval
        service.handleEvent(AgentEvent(
            agentID: "claude",
            agentName: "Claude",
            kind: .needsApproval,
            metadata: [
                AgentEvent.MetadataKey.sessionID: "session-lifecycle",
                AgentEvent.MetadataKey.approvalRequestID: "req-lc"
            ]
        ))
        XCTAssertEqual(service.sessionSnapshots.first(where: { $0.stateKey == stateKey })?.lifecycleState, .needsApproval)

        // 3. working (approval resolved)
        service.handleEvent(AgentEvent(
            agentID: "claude",
            agentName: "Claude",
            kind: .working,
            metadata: [AgentEvent.MetadataKey.sessionID: "session-lifecycle"]
        ))
        XCTAssertEqual(service.sessionSnapshots.first(where: { $0.stateKey == stateKey })?.lifecycleState, .working)

        // 4. almostDone
        service.handleEvent(AgentEvent(
            agentID: "claude",
            agentName: "Claude",
            kind: .almostDone,
            metadata: [AgentEvent.MetadataKey.sessionID: "session-lifecycle"]
        ))
        XCTAssertEqual(service.sessionSnapshots.first(where: { $0.stateKey == stateKey })?.lifecycleState, .almostDone)

        // 5. done
        service.handleEvent(AgentEvent(
            agentID: "claude",
            agentName: "Claude",
            kind: .done,
            metadata: [AgentEvent.MetadataKey.sessionID: "session-lifecycle"]
        ))
        XCTAssertEqual(service.sessionSnapshots.first(where: { $0.stateKey == stateKey })?.lifecycleState, .done)

        // 6. removeSession
        service.removeSession(stateKey: stateKey)
        XCTAssertNil(service.sessionSnapshots.first(where: { $0.stateKey == stateKey }))
    }

    func testProcessPresenceStartedRemainsIdleUntilWorkingSignal() {
        let (defaults, cleanup) = makeIsolatedDefaults()
        defer { cleanup() }

        let service = AgentMonitorService(userDefaults: defaults)
        let stateKey = "gemini::com.google.GeminiMacOS"

        // Passive app launch presence (source=process, 0% CPU) must land in .idle (Sleeping Nests)
        service.handleEvent(AgentEvent(
            agentID: "gemini",
            agentName: "Gemini",
            kind: .started,
            metadata: [
                AgentEvent.MetadataKey.sessionID: "com.google.GeminiMacOS",
                AgentEvent.MetadataKey.source: "process"
            ]
        ))

        let snapIdle = service.sessionSnapshots.first(where: { $0.stateKey == stateKey })
        XCTAssertEqual(snapIdle?.lifecycleState, .idle)

        // When active CPU work begins, it moves to .working (Code Bay)
        service.handleEvent(AgentEvent(
            agentID: "gemini",
            agentName: "Gemini",
            kind: .working,
            metadata: [
                AgentEvent.MetadataKey.sessionID: "com.google.GeminiMacOS",
                AgentEvent.MetadataKey.source: "process"
            ]
        ))

        let snapWorking = service.sessionSnapshots.first(where: { $0.stateKey == stateKey })
        XCTAssertEqual(snapWorking?.lifecycleState, .working)
    }
}
