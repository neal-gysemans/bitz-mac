import XCTest
import SwiftUI
@testable import BitzCore

@MainActor
final class TacticalActionBarTests: XCTestCase {

    private func makeIsolatedDefaults() -> (UserDefaults, () -> Void) {
        let suiteName = "TacticalActionBarTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        let cleanup: () -> Void = {
            defaults.removePersistentDomain(forName: suiteName)
        }
        return (defaults, cleanup)
    }

    private func makeSnapshot(
        stateKey: String,
        agentID: String = "claude",
        agentName: String = "Claude",
        sessionID: String? = nil,
        sessionLabel: String? = nil,
        lifecycleState: AgentSessionLifecycleState,
        activeWarning: AgentWarningReason? = nil,
        contextTokens: Int? = nil,
        windowTokens: Int = 200_000,
        pendingTools: Int = 0,
        lastActivity: Date = Date(),
        linkedApprovalRequest: AgentApprovalRequest? = nil,
        workingDir: String? = nil
    ) -> AgentSessionSnapshot {
        let reading = contextTokens.map {
            AgentContextReading(agentID: agentID, agentName: agentName, tokens: $0, windowTokens: windowTokens)
        }
        return AgentSessionSnapshot(
            stateKey: stateKey,
            agentID: agentID,
            agentName: agentName,
            sessionID: sessionID,
            sessionLabel: sessionLabel ?? "\(agentName) · \(stateKey)",
            lifecycleState: lifecycleState,
            activeWarning: activeWarning,
            contextReading: reading,
            pendingTools: pendingTools,
            lastActivity: lastActivity,
            linkedApprovalRequest: linkedApprovalRequest,
            workingDir: workingDir
        )
    }

    // MARK: - 1. Session Pill Order Preservation & Lifecycle Priority

    func testSessionPillSortingOrder_PriorityPrimary() {
        let states: [AgentSessionLifecycleState] = [
            .needsApproval, .warning, .failed, .almostDone, .working, .done, .idle
        ]
        for idx in 0..<(states.count - 1) {
            XCTAssertTrue(states[idx] < states[idx + 1])
        }

        let now = Date()
        let snapshots = states.enumerated().map { idx, state in
            makeSnapshot(stateKey: "s-\(idx)", lifecycleState: state, lastActivity: now)
        }
        var selectedKey: String? = nil
        let view = TacticalActionBarView(
            sessions: snapshots,
            selectedSessionKey: Binding(get: { selectedKey }, set: { selectedKey = $0 })
        )

        XCTAssertEqual(view.sessions.count, 7)
        XCTAssertEqual(view.sessions.map(\.lifecycleState), states)
    }

    func testSessionPillSortingOrder_LastActivitySecondary() {
        let now = Date()
        let older = makeSnapshot(stateKey: "s-older", lifecycleState: .working, lastActivity: now.addingTimeInterval(-60))
        let newer = makeSnapshot(stateKey: "s-newer", lifecycleState: .working, lastActivity: now)

        var selectedKey: String? = nil
        let view = TacticalActionBarView(
            sessions: [newer, older],
            selectedSessionKey: Binding(get: { selectedKey }, set: { selectedKey = $0 })
        )

        XCTAssertEqual(view.sessions.first?.stateKey, "s-newer")
        XCTAssertEqual(view.sessions.last?.stateKey, "s-older")
    }

    func testSessionPillSortingOrder_StateKeyTertiary() {
        let fixedDate = Date(timeIntervalSince1970: 1_700_000_000)
        let a = makeSnapshot(stateKey: "session-a", lifecycleState: .working, lastActivity: fixedDate)
        let b = makeSnapshot(stateKey: "session-b", lifecycleState: .working, lastActivity: fixedDate)

        var selectedKey: String? = nil
        let view = TacticalActionBarView(
            sessions: [a, b],
            selectedSessionKey: Binding(get: { selectedKey }, set: { selectedKey = $0 })
        )

        XCTAssertEqual(view.sessions.first?.stateKey, "session-a")
        XCTAssertEqual(view.sessions.last?.stateKey, "session-b")
    }

    // MARK: - 2. Effective Selected Session Resolution

    func testEffectiveSelectedSession_DefaultsToHighestPriority() {
        let working = makeSnapshot(stateKey: "s-working", lifecycleState: .working)
        let approval = makeSnapshot(stateKey: "s-approval", lifecycleState: .needsApproval)

        var selectedKey: String? = nil
        let view = TacticalActionBarView(
            sessions: [approval, working],
            selectedSessionKey: Binding(get: { selectedKey }, set: { selectedKey = $0 })
        )

        XCTAssertEqual(view.effectiveSelectedSession?.stateKey, "s-approval")
    }

    func testEffectiveSelectedSession_SelectsMatchingKey() {
        let working = makeSnapshot(stateKey: "s-working", lifecycleState: .working)
        let approval = makeSnapshot(stateKey: "s-approval", lifecycleState: .needsApproval)

        var selectedKey: String? = "s-working"
        let view = TacticalActionBarView(
            sessions: [approval, working],
            selectedSessionKey: Binding(get: { selectedKey }, set: { selectedKey = $0 })
        )

        XCTAssertEqual(view.effectiveSelectedSession?.stateKey, "s-working")
    }

    func testEffectiveSelectedSession_FallbackWhenKeyNotFound() {
        let working = makeSnapshot(stateKey: "s-working", lifecycleState: .working)
        let approval = makeSnapshot(stateKey: "s-approval", lifecycleState: .needsApproval)

        var selectedKey: String? = "non-existent-key"
        let view = TacticalActionBarView(
            sessions: [approval, working],
            selectedSessionKey: Binding(get: { selectedKey }, set: { selectedKey = $0 })
        )

        XCTAssertEqual(view.effectiveSelectedSession?.stateKey, "s-approval")
    }

    // MARK: - 3. Context Gauge Progress, Color Thresholds & Text Formatting

    func testContextGaugeProgress_Calculations() {
        XCTAssertEqual(TacticalActionBarView.contextGaugeProgress(tokens: 0, windowTokens: 200_000), 0.0)
        XCTAssertEqual(TacticalActionBarView.contextGaugeProgress(tokens: 100_000, windowTokens: 200_000), 0.5)
        XCTAssertEqual(TacticalActionBarView.contextGaugeProgress(tokens: 200_000, windowTokens: 200_000), 1.0)
        XCTAssertEqual(TacticalActionBarView.contextGaugeProgress(tokens: 300_000, windowTokens: 200_000), 1.0) // capped
        XCTAssertEqual(TacticalActionBarView.contextGaugeProgress(tokens: 50_000, windowTokens: 0), 0.0) // zero window safe
        XCTAssertEqual(TacticalActionBarView.contextGaugeProgress(tokens: 50_000, windowTokens: -100), 0.0) // negative safe
    }

    func testContextGaugeColor_StrictThresholds() {
        let cyan = Color(red: 0.0, green: 0.85, blue: 1.0)
        let amber = Color(red: 1.0, green: 0.75, blue: 0.1)
        let crimson = Color(red: 1.0, green: 0.25, blue: 0.2)

        // < 70% -> Cyan
        XCTAssertEqual(TacticalActionBarView.contextGaugeColor(for: 0), cyan)
        XCTAssertEqual(TacticalActionBarView.contextGaugeColor(for: 50), cyan)
        XCTAssertEqual(TacticalActionBarView.contextGaugeColor(for: 69), cyan)

        // 70% - 89% -> Amber
        XCTAssertEqual(TacticalActionBarView.contextGaugeColor(for: 70), amber)
        XCTAssertEqual(TacticalActionBarView.contextGaugeColor(for: 74), amber)
        XCTAssertEqual(TacticalActionBarView.contextGaugeColor(for: 89), amber)

        // >= 90% -> Crimson
        XCTAssertEqual(TacticalActionBarView.contextGaugeColor(for: 90), crimson)
        XCTAssertEqual(TacticalActionBarView.contextGaugeColor(for: 95), crimson)
        XCTAssertEqual(TacticalActionBarView.contextGaugeColor(for: 100), crimson)
    }

    func testFormatContextText() {
        let text1 = TacticalActionBarView.formatContextText(tokens: 148_000, windowTokens: 200_000, percent: 74)
        XCTAssertEqual(text1, "148k / 200k tokens (74%)")

        let text2 = TacticalActionBarView.formatContextText(tokens: 500, windowTokens: 200_000, percent: 0)
        XCTAssertEqual(text2, "500 / 200k tokens (0%)")

        let text3 = TacticalActionBarView.formatContextText(tokens: 1_200_000, windowTokens: 2_000_000, percent: 60)
        XCTAssertEqual(text3, "1.2M / 2.0M tokens (60%)")
    }

    // MARK: - 4. Status Badges, Icons & Agent Icons

    func testStatusBadgesAndIcons() {
        for state in AgentSessionLifecycleState.allCases {
            let badgeText = TacticalActionBarView.statusBadgeText(for: state)
            XCTAssertFalse(badgeText.isEmpty)

            let icon = TacticalActionBarView.statusIcon(for: state)
            XCTAssertFalse(icon.isEmpty)

            let _ = Color(nsColor: state.nsColor)
        }

        XCTAssertEqual(TacticalActionBarView.statusBadgeText(for: .needsApproval), "NEEDS APPROVAL")
        XCTAssertEqual(TacticalActionBarView.statusBadgeText(for: .warning), "WARNING")
        XCTAssertEqual(TacticalActionBarView.statusBadgeText(for: .failed), "FAILED")
        XCTAssertEqual(TacticalActionBarView.statusBadgeText(for: .almostDone), "ALMOST DONE")
        XCTAssertEqual(TacticalActionBarView.statusBadgeText(for: .working), "WORKING")
        XCTAssertEqual(TacticalActionBarView.statusBadgeText(for: .done), "DONE")
        XCTAssertEqual(TacticalActionBarView.statusBadgeText(for: .idle), "IDLE")
    }

    func testAgentIcons() {
        XCTAssertEqual(TacticalActionBarView.agentIcon(for: "claude"), "brain")
        XCTAssertEqual(TacticalActionBarView.agentIcon(for: "antigravity"), "atom")
        XCTAssertEqual(TacticalActionBarView.agentIcon(for: "codex"), "bubble.left.and.bubble.right.fill")
        XCTAssertEqual(TacticalActionBarView.agentIcon(for: "cursor"), "cursorarrow.rays")
        XCTAssertEqual(TacticalActionBarView.agentIcon(for: "gemini"), "sparkles")
        XCTAssertEqual(TacticalActionBarView.agentIcon(for: "windsurf"), "wind")
        XCTAssertEqual(TacticalActionBarView.agentIcon(for: "copilot"), "airplane")
        XCTAssertEqual(TacticalActionBarView.agentIcon(for: "unknown"), "cpu")
    }

    // MARK: - 5. Command & Warning Summary Text

    func testSummaryTextDerivations() {
        // 1. Linked approval request with tool and command
        let req1 = AgentApprovalRequest(
            id: "req-1",
            agentID: "claude",
            agentName: "Claude",
            toolName: "Bash",
            commandSummary: "git push origin main"
        )
        let s1 = makeSnapshot(stateKey: "s1", lifecycleState: .needsApproval, linkedApprovalRequest: req1)
        XCTAssertEqual(TacticalActionBarView.summaryText(for: s1), "Bash: git push origin main")

        // 2. Linked approval request with command only
        let req2 = AgentApprovalRequest(
            id: "req-2",
            agentID: "claude",
            agentName: "Claude",
            toolName: nil,
            commandSummary: "cargo test --all"
        )
        let s2 = makeSnapshot(stateKey: "s2", lifecycleState: .needsApproval, linkedApprovalRequest: req2)
        XCTAssertEqual(TacticalActionBarView.summaryText(for: s2), "cargo test --all")

        // 3. Linked approval request with tool only
        let req3 = AgentApprovalRequest(
            id: "req-3",
            agentID: "claude",
            agentName: "Claude",
            toolName: "FileEdit",
            commandSummary: nil
        )
        let s3 = makeSnapshot(stateKey: "s3", lifecycleState: .needsApproval, linkedApprovalRequest: req3)
        XCTAssertEqual(TacticalActionBarView.summaryText(for: s3), "Tool: FileEdit")

        // 4. Warning reasons
        let sLoop = makeSnapshot(stateKey: "s-loop", lifecycleState: .warning, activeWarning: .loop)
        XCTAssertTrue(TacticalActionBarView.summaryText(for: sLoop).contains("loop"))

        let sStall = makeSnapshot(stateKey: "s-stall", lifecycleState: .warning, activeWarning: .stall)
        XCTAssertTrue(TacticalActionBarView.summaryText(for: sStall).contains("stalled"))

        let sContext = makeSnapshot(stateKey: "s-ctx", lifecycleState: .warning, activeWarning: .context)
        XCTAssertTrue(TacticalActionBarView.summaryText(for: sContext).contains("Context"))

        let sRate = makeSnapshot(stateKey: "s-rate", lifecycleState: .warning, activeWarning: .rateLimit)
        XCTAssertTrue(TacticalActionBarView.summaryText(for: sRate).contains("Rate limit"))

        // 5. Pending tools
        let sTools = makeSnapshot(stateKey: "s-tools", lifecycleState: .working, pendingTools: 4)
        XCTAssertEqual(TacticalActionBarView.summaryText(for: sTools), "Executing 4 pending tool(s)...")

        // 6. Generic lifecycle states
        let sWorking = makeSnapshot(stateKey: "s-w", lifecycleState: .working)
        XCTAssertTrue(TacticalActionBarView.summaryText(for: sWorking).contains("Working"))

        let sIdle = makeSnapshot(stateKey: "s-i", lifecycleState: .idle)
        XCTAssertTrue(TacticalActionBarView.summaryText(for: sIdle).contains("MedBay") || TacticalActionBarView.summaryText(for: sIdle).contains("idle"))
    }

    // MARK: - 6. Action Callbacks & Dispatch

    func testButtonVisibility_ApproveGatedOnApprovalChannel() {
        // Case 1: Nil approval request -> false (even if needsApproval)
        let sNilReq = makeSnapshot(stateKey: "s1", lifecycleState: .needsApproval, linkedApprovalRequest: nil)
        XCTAssertFalse(TacticalActionBarView.shouldShowApproveButton(for: sNilReq))

        // Case 2: Approval request without decision channel -> false
        let reqNoChannel = AgentApprovalRequest(
            id: "req-no-chan",
            agentID: "claude",
            agentName: "Claude",
            decisionChannel: nil
        )
        let sNoChan = makeSnapshot(stateKey: "s2", lifecycleState: .needsApproval, linkedApprovalRequest: reqNoChannel)
        XCTAssertFalse(TacticalActionBarView.shouldShowApproveButton(for: sNoChan))

        // Case 3: Approval request with empty/whitespace decision channel -> false
        let reqEmptyChan = AgentApprovalRequest(
            id: "req-empty-chan",
            agentID: "claude",
            agentName: "Claude",
            decisionChannel: "   "
        )
        let sEmptyChan = makeSnapshot(stateKey: "s3", lifecycleState: .needsApproval, linkedApprovalRequest: reqEmptyChan)
        XCTAssertFalse(TacticalActionBarView.shouldShowApproveButton(for: sEmptyChan))

        // Case 4: Approval request with valid decision channel -> true
        let reqValid = AgentApprovalRequest(
            id: "req-valid",
            agentID: "claude",
            agentName: "Claude",
            decisionChannel: "/tmp/claude-hook.sock"
        )
        let sValid = makeSnapshot(stateKey: "s4", lifecycleState: .needsApproval, linkedApprovalRequest: reqValid)
        XCTAssertTrue(TacticalActionBarView.shouldShowApproveButton(for: sValid))
    }

    func testButtonVisibility_GotItGatedOnWarningState() {
        // Case 1: Active warning present -> true
        let sWarnReason = makeSnapshot(stateKey: "s1", lifecycleState: .working, activeWarning: .loop)
        XCTAssertTrue(TacticalActionBarView.shouldShowGotItButton(for: sWarnReason))

        // Case 2: In warning lifecycle state -> true
        let sWarnState = makeSnapshot(stateKey: "s2", lifecycleState: .warning)
        XCTAssertTrue(TacticalActionBarView.shouldShowGotItButton(for: sWarnState))

        // Case 3: Working without warning -> false
        let sNormal = makeSnapshot(stateKey: "s3", lifecycleState: .working)
        XCTAssertFalse(TacticalActionBarView.shouldShowGotItButton(for: sNormal))
    }

    func testActionCallbacks_ApproveDispatchesDecisionAndDismisses() {
        let (defaults, cleanup) = makeIsolatedDefaults()
        defer { cleanup() }

        let decisionsBox = TestBox([(channel: String, decision: ApprovalDecision, requestID: String)]())
        let approvalStore = AgentApprovalStore(
            clock: { Date() },
            channelWriter: { channel, decision, id in
                decisionsBox.value.append((channel, decision, id))
                return .success(())
            }
        )
        let monitor = AgentMonitorService(clock: { Date() }, userDefaults: defaults)
        approvalStore.bind(agentMonitor: monitor)

        let event = AgentEvent(
            agentID: "claude",
            agentName: "Claude",
            kind: .needsApproval,
            metadata: [
                AgentEvent.MetadataKey.sessionID: "s-approve",
                AgentEvent.MetadataKey.approvalRequestID: "req-test-approve",
                AgentEvent.MetadataKey.approvalChannel: "/tmp/fake-chan"
            ]
        )
        let request = approvalStore.registerRequest(from: event)!
        monitor.handleEvent(event)

        // Preconditions: request is pending, active, and monitor has active needsApproval popup
        XCTAssertEqual(approvalStore.activeRequest?.id, "req-test-approve")
        XCTAssertNotNil(approvalStore.pendingRequests["req-test-approve"])
        XCTAssertEqual(monitor.activePopup?.kind, .needsApproval)

        let session = makeSnapshot(
            stateKey: "claude::s-approve",
            lifecycleState: .needsApproval,
            linkedApprovalRequest: request
        )

        var didCallApprove = false
        var passedSession: AgentSessionSnapshot? = nil
        var selectedKey: String? = "claude::s-approve"

        let view = TacticalActionBarView(
            sessions: [session],
            selectedSessionKey: Binding(get: { selectedKey }, set: { selectedKey = $0 }),
            agentMonitor: monitor,
            approvalStore: approvalStore,
            onApprove: { s in
                didCallApprove = true
                passedSession = s
            }
        )

        // Exercise the authentic trigger method
        view.triggerApprove(for: session)

        // Verify callback executed
        XCTAssertTrue(didCallApprove)
        XCTAssertEqual(passedSession?.stateKey, "claude::s-approve")

        // Verify authentic store mutations (token consumed, active request cleared, channel writer invoked, popup dismissed)
        XCTAssertNil(approvalStore.activeRequest, "Approval request must be cleared from approvalStore upon approval")
        XCTAssertNil(approvalStore.pendingRequests["req-test-approve"], "Pending request token must be invalidated upon approval")
        XCTAssertNil(monitor.activePopup, "Monitor popup must be dismissed upon approval")
        XCTAssertEqual(decisionsBox.value.count, 1)
        XCTAssertEqual(decisionsBox.value.first?.decision, .approve)
        XCTAssertEqual(decisionsBox.value.first?.requestID, "req-test-approve")
        XCTAssertEqual(decisionsBox.value.first?.channel, "/tmp/fake-chan")
    }

    func testActionCallbacks_GotItAcknowledgesWarning() {
        let (defaults, cleanup) = makeIsolatedDefaults()
        defer { cleanup() }

        let monitor = AgentMonitorService(clock: { Date() }, userDefaults: defaults)

        // Register session and raise a warning event to create live state on monitor
        monitor.handleEvent(AgentEvent(
            agentID: "claude",
            agentName: "Claude",
            kind: .started,
            metadata: [AgentEvent.MetadataKey.sessionID: "s-warn"]
        ))
        monitor.handleEvent(AgentEvent(
            agentID: "claude",
            agentName: "Claude",
            kind: .warning,
            metadata: [
                AgentEvent.MetadataKey.sessionID: "s-warn",
                AgentEvent.MetadataKey.reason: "loop"
            ]
        ))

        let stateKey = AgentMonitorService.makeStateKey(agentID: "claude", sessionID: "s-warn")
        let snapshot = monitor.sessionSnapshots.first(where: { $0.stateKey == stateKey })!

        // Preconditions: active warning and warning popup are active on monitor
        XCTAssertEqual(monitor.activeWarning?.reason, .loop)
        XCTAssertEqual(monitor.activePopup?.kind, .warning)
        XCTAssertEqual(snapshot.lifecycleState, .warning)
        XCTAssertEqual(snapshot.activeWarning, .loop)

        var didCallAcknowledge = false
        var passedSession: AgentSessionSnapshot? = nil
        var selectedKey: String? = stateKey

        let view = TacticalActionBarView(
            sessions: [snapshot],
            selectedSessionKey: Binding(get: { selectedKey }, set: { selectedKey = $0 }),
            agentMonitor: monitor,
            onAcknowledgeWarning: { s in
                didCallAcknowledge = true
                passedSession = s
            }
        )

        // Exercise the authentic trigger method
        view.triggerAcknowledgeWarning(for: snapshot)

        // Verify callback executed
        XCTAssertTrue(didCallAcknowledge)
        XCTAssertEqual(passedSession?.stateKey, stateKey)

        // Verify authentic monitor mutations (warning cleared on session and service)
        XCTAssertNil(monitor.activeWarning, "Active warning must be cleared after acknowledgment")
        XCTAssertNil(monitor.activePopup, "Warning popup must be dismissed after acknowledgment")

        // Verify session state transitions away from warning
        let updatedSnapshot = monitor.sessionSnapshots.first(where: { $0.stateKey == stateKey })
        XCTAssertNil(updatedSnapshot?.activeWarning, "Session snapshot warning reason must be cleared")
        XCTAssertNotEqual(updatedSnapshot?.lifecycleState, .warning, "Lifecycle state must transition away from warning")
    }

    func testActionCallbacks_JumpActivatesApplication() {
        let mockActivator = MockAppActivator()
        let request = AgentApprovalRequest(
            id: "req-jump",
            agentID: "claude",
            agentName: "Claude",
            owningPID: 12345,
            bundleID: "com.anthropic.claudefordesktop"
        )
        let session = makeSnapshot(
            stateKey: "s-jump",
            lifecycleState: .working,
            linkedApprovalRequest: request
        )

        var didCallJump = false
        var passedSession: AgentSessionSnapshot? = nil
        var selectedKey: String? = "s-jump"

        let view = TacticalActionBarView(
            sessions: [session],
            selectedSessionKey: Binding(get: { selectedKey }, set: { selectedKey = $0 }),
            appActivator: mockActivator,
            onJump: { s in
                didCallJump = true
                passedSession = s
            }
        )

        // Precondition: mock activator has not been invoked yet
        XCTAssertTrue(mockActivator.activatedPIDs.isEmpty)
        XCTAssertTrue(mockActivator.activatedBundleIDs.isEmpty)

        // Exercise the authentic trigger method
        let success = view.triggerJump(for: session)

        // Verify callback and genuine activator side effects
        XCTAssertTrue(success)
        XCTAssertTrue(didCallJump)
        XCTAssertEqual(passedSession?.stateKey, "s-jump")
        XCTAssertEqual(mockActivator.activatedPIDs, [12345], "JUMP action must activate process matching owningPID")
        XCTAssertEqual(mockActivator.activatedBundleIDs, ["com.anthropic.claudefordesktop"], "JUMP action must activate app bundle ID")

        // Fallback test: bundle ID resolved from AgentDefinition catalog when request bundleID is nil
        let fallbackSession = makeSnapshot(
            stateKey: "s-fallback",
            agentID: "claude",
            lifecycleState: .working,
            linkedApprovalRequest: nil
        )
        let fallbackActivator = MockAppActivator()
        let fallbackView = TacticalActionBarView(
            sessions: [fallbackSession],
            selectedSessionKey: Binding.constant("s-fallback"),
            appActivator: fallbackActivator
        )
        fallbackView.triggerJump(for: fallbackSession)
        XCTAssertEqual(fallbackActivator.activatedBundleIDs, ["com.anthropic.claudefordesktop"], "Fallback must resolve bundle ID from AgentDefinition built-in catalog")
    }

    func testActionCallbacks_DiffOpensWorkingDirectory() async {
        let mockDiff = MockDiffViewer()
        let session = makeSnapshot(
            stateKey: "s-diff",
            lifecycleState: .working,
            workingDir: "/Users/dev/my-project"
        )

        var didCallDiff = false
        var passedSession: AgentSessionSnapshot? = nil
        var selectedKey: String? = "s-diff"

        let view = TacticalActionBarView(
            sessions: [session],
            selectedSessionKey: Binding(get: { selectedKey }, set: { selectedKey = $0 }),
            diffViewer: mockDiff,
            onDiff: { s in
                didCallDiff = true
                passedSession = s
            }
        )

        // Precondition: mock diff viewer has not been opened yet
        XCTAssertTrue(mockDiff.openedDirectories.isEmpty)

        // Exercise the authentic trigger method asynchronously
        let success = await view.triggerDiff(for: session)

        // Verify callback and genuine diff viewer side effects
        XCTAssertTrue(success)
        XCTAssertTrue(didCallDiff)
        XCTAssertEqual(passedSession?.stateKey, "s-diff")
        XCTAssertEqual(mockDiff.openedDirectories, ["/Users/dev/my-project"], "DIFF action must open git diff for session working directory")

        // Fallback test: directory resolved from linkedApprovalRequest.workingDir
        let fallbackReq = AgentApprovalRequest(
            id: "req-diff",
            agentID: "claude",
            agentName: "Claude",
            workingDir: "/Users/dev/fallback-repo"
        )
        let fallbackSession = makeSnapshot(
            stateKey: "s-fallback-diff",
            lifecycleState: .working,
            linkedApprovalRequest: fallbackReq,
            workingDir: nil
        )
        let fallbackDiff = MockDiffViewer()
        let fallbackView = TacticalActionBarView(
            sessions: [fallbackSession],
            selectedSessionKey: Binding.constant("s-fallback-diff"),
            diffViewer: fallbackDiff
        )
        await fallbackView.triggerDiff(for: fallbackSession)
        XCTAssertEqual(fallbackDiff.openedDirectories, ["/Users/dev/fallback-repo"], "DIFF action must fall back to linkedApprovalRequest.workingDir")
    }

    // MARK: - 7. Empty State

    func testEmptyState_RendersStandby() {
        var selectedKey: String? = nil
        let view = TacticalActionBarView(
            sessions: [],
            selectedSessionKey: Binding(get: { selectedKey }, set: { selectedKey = $0 })
        )

        XCTAssertTrue(view.sessions.isEmpty)
        XCTAssertNil(view.effectiveSelectedSession)
    }

    // MARK: - 8. Integration into AgentCommandDeckView

    func testAgentCommandDeckView_InitializesWithActionBar() {
        let (defaults, cleanup) = makeIsolatedDefaults()
        defer { cleanup() }

        let monitor = AgentMonitorService(clock: { Date() }, userDefaults: defaults)
        let approvalStore = AgentApprovalStore()
        let activator = MockAppActivator()
        let diffViewer = MockDiffViewer()

        let deckView = AgentCommandDeckView(
            agentMonitor: monitor,
            approvalStore: approvalStore,
            appActivator: activator,
            diffViewer: diffViewer
        )

        XCTAssertEqual(deckView.visibleSessions.count, 0)
        XCTAssertNil(deckView.effectiveSelectedSessionKey)
        XCTAssertFalse(deckView.showsUpgradeBanner)
    }

    // MARK: - 9. Phase 2 CLI Task-Kittens

    func testTaskKittenRunnerLifecycleSpawnsWorkingAndCompletesToDone() async throws {
        let (defaults, cleanup) = makeIsolatedDefaults()
        defer { cleanup() }

        let monitor = AgentMonitorService(clock: { Date() }, userDefaults: defaults)

        let gateContinuation = TestBox<CheckedContinuation<(exitCode: Int32, output: String), Never>?>(nil)
        let recordedCommand = TestBox<(executable: String, arguments: [String], workingDir: String?)?>(nil)

        let runner = TaskKittenRunnerService(agentMonitor: monitor) { executable, arguments, workingDir in
            recordedCommand.value = (executable, arguments, workingDir)
            return await withCheckedContinuation { cont in
                gateContinuation.value = cont
            }
        }

        let sessionID = runner.launchTask(
            title: "PR Review",
            prompt: "Check diff",
            provider: .claude,
            workingDirectory: "/Volumes/DevDrive/Code/bitz-mac"
        )

        XCTAssertTrue(sessionID.hasPrefix("kitten-"))
        XCTAssertTrue(runner.activeSessionIDs.contains(sessionID))

        let stateKey = AgentMonitorService.makeStateKey(agentID: "claude", sessionID: sessionID)
        let workingSnap = try XCTUnwrap(monitor.sessionSnapshots.first(where: { $0.stateKey == stateKey }))
        XCTAssertEqual(workingSnap.sessionLabel, "Claude · 🐾 PR Review")
        XCTAssertEqual(workingSnap.lifecycleState, .working)
        XCTAssertEqual(workingSnap.workingDir, "/Volumes/DevDrive/Code/bitz-mac")
        XCTAssertTrue(TacticalActionBarView.summaryText(for: workingSnap).contains("🐾 PR Review"))

        // Wait briefly for the spawned Task to enter the mock CommandRunner
        for _ in 0..<50 where gateContinuation.value == nil {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertEqual(recordedCommand.value?.executable, "claude")
        XCTAssertEqual(recordedCommand.value?.arguments, ["-p", "Check diff"])
        XCTAssertEqual(recordedCommand.value?.workingDir, "/Volumes/DevDrive/Code/bitz-mac")

        let cont = try XCTUnwrap(gateContinuation.value)
        cont.resume(returning: (0, "All checks look clean\nNo regressions found."))

        for _ in 0..<50 where runner.activeSessionIDs.contains(sessionID) {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertFalse(runner.activeSessionIDs.contains(sessionID))

        let doneSnap = try XCTUnwrap(monitor.sessionSnapshots.first(where: { $0.stateKey == stateKey }))
        XCTAssertEqual(doneSnap.lifecycleState, .done)
        XCTAssertEqual(doneSnap.statusMessage, "🐾 PR Review: All checks look clean No regressions found.")
        XCTAssertEqual(
            TacticalActionBarView.summaryText(for: doneSnap),
            "🐾 PR Review: All checks look clean No regressions found."
        )

        // Verify non-zero exit code transitions Task-Kitten to .failed with exit info
        let failedRunner = TaskKittenRunnerService(agentMonitor: monitor) { _, _, _ in
            (1, "CLI auth expired")
        }
        let failedID = failedRunner.launchTask(
            title: "Git Brief",
            prompt: "Status",
            provider: .codex,
            workingDirectory: "/Volumes/DevDrive/Code/bitz-mac"
        )
        for _ in 0..<50 where failedRunner.activeSessionIDs.contains(failedID) {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        let failedKey = AgentMonitorService.makeStateKey(agentID: "codex", sessionID: failedID)
        let failedSnap = try XCTUnwrap(monitor.sessionSnapshots.first(where: { $0.stateKey == failedKey }))
        XCTAssertEqual(failedSnap.sessionLabel, "Codex · 🐾 Git Brief")
        XCTAssertEqual(failedSnap.lifecycleState, .failed)
        XCTAssertTrue(TacticalActionBarView.summaryText(for: failedSnap).contains("exit 1"))
        XCTAssertTrue(TacticalActionBarView.summaryText(for: failedSnap).contains("CLI auth expired"))
    }
}
