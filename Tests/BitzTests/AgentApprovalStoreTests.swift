import XCTest
import SwiftUI
@testable import BitzCore

final class TestBox<T>: @unchecked Sendable {
    var value: T
    init(_ value: T) { self.value = value }
}

@MainActor
final class AgentApprovalStoreTests: XCTestCase {
    private func makeIsolatedDefaults() -> (UserDefaults, String) {
        let suiteName = "test.bitz.approval.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        return (defaults, suiteName)
    }

    // MARK: - AgentApprovalRequest Model Invariants

    func testAgentApprovalRequest_InitializationAndExpiry() {
        let now = Date()
        let request = AgentApprovalRequest(
            id: "req-001",
            agentID: "claude",
            agentName: "Claude",
            toolName: "Bash",
            commandSummary: "git push origin main",
            decisionChannel: "/tmp/claude-hook.fifo",
            owningPID: 12345,
            bundleID: "com.anthropic.claudefordesktop",
            workingDir: "/Users/dev/repo",
            createdAt: now,
            ttlSeconds: 300
        )

        XCTAssertEqual(request.id, "req-001")
        XCTAssertEqual(request.agentID, "claude")
        XCTAssertEqual(request.agentName, "Claude")
        XCTAssertEqual(request.toolName, "Bash")
        XCTAssertEqual(request.commandSummary, "git push origin main")
        XCTAssertEqual(request.decisionChannel, "/tmp/claude-hook.fifo")
        XCTAssertEqual(request.owningPID, 12345)
        XCTAssertEqual(request.bundleID, "com.anthropic.claudefordesktop")
        XCTAssertEqual(request.workingDir, "/Users/dev/repo")
        XCTAssertEqual(request.expiresAt.timeIntervalSince(now), 300, accuracy: 0.1)
        XCTAssertFalse(request.isExpired)
        XCTAssertTrue(request.hasApprovalChannel)

        let noChannelRequest = AgentApprovalRequest(
            id: "req-002",
            agentID: "claude",
            agentName: "Claude",
            decisionChannel: "   "
        )
        XCTAssertFalse(noChannelRequest.hasApprovalChannel, "Whitespace or empty channel must return false")
    }

    // MARK: - Token Registration & Lifecycle (FR-007, C-003)

    func testAgentApprovalStore_RegisterFromEvent() {
        let store = AgentApprovalStore()

        let event = AgentEvent(
            agentID: "antigravity",
            agentName: "Antigravity",
            kind: .needsApproval,
            message: "Execute test suite?",
            metadata: [
                AgentEvent.MetadataKey.approvalRequestID: "req-abc",
                AgentEvent.MetadataKey.approvalChannel: "/tmp/antigravity.sock",
                AgentEvent.MetadataKey.toolName: "Terminal",
                AgentEvent.MetadataKey.commandSummary: "xcrun swift test",
                AgentEvent.MetadataKey.owningPID: "54321",
                AgentEvent.MetadataKey.bundleID: "com.google.antigravity",
                AgentEvent.MetadataKey.workingDir: "/workspace"
            ]
        )

        let registered = store.registerRequest(from: event)
        XCTAssertNotNil(registered)
        XCTAssertEqual(registered?.id, "req-abc")
        XCTAssertEqual(registered?.toolName, "Terminal")
        XCTAssertEqual(registered?.commandSummary, "xcrun swift test")
        XCTAssertEqual(registered?.owningPID, 54321)
        XCTAssertEqual(registered?.bundleID, "com.google.antigravity")
        XCTAssertEqual(registered?.workingDir, "/workspace")
        XCTAssertEqual(store.activeRequest?.id, "req-abc")
        XCTAssertEqual(store.pendingRequests["req-abc"]?.id, "req-abc")

        // Non-approval events must be ignored by registration
        let workingEvent = AgentEvent(agentID: "antigravity", agentName: "Antigravity", kind: .working)
        let ignored = store.registerRequest(from: workingEvent)
        XCTAssertNil(ignored)
    }

    // MARK: - Single-Use Token Invalidation (C-003, FR-006)

    func testAgentApprovalStore_SingleUseTokenInvalidation_Approve() {
        let decisionsBox = TestBox([(channel: String, decision: ApprovalDecision, requestID: String)]())
        let store = AgentApprovalStore(channelWriter: { channel, decision, requestID in
            decisionsBox.value.append((channel, decision, requestID))
            return .success(())
        })

        let event = AgentEvent(
            agentID: "claude",
            agentName: "Claude",
            kind: .needsApproval,
            metadata: [
                AgentEvent.MetadataKey.approvalRequestID: "token-1",
                AgentEvent.MetadataKey.approvalChannel: "/tmp/hook.pipe"
            ]
        )
        store.registerRequest(from: event)
        XCTAssertNotNil(store.pendingRequests["token-1"])

        // First approval: must succeed
        let firstResult = store.submitDecision(.approve, for: "token-1")
        XCTAssertEqual(firstResult, .approved)
        XCTAssertNil(store.pendingRequests["token-1"], "Token must be invalidated immediately on use (C-003)")
        XCTAssertNil(store.activeRequest)
        XCTAssertEqual(decisionsBox.value.count, 1)
        XCTAssertEqual(decisionsBox.value.first?.decision, .approve)

        // Second attempt to use identical token: must fail with .tokenNotFound
        let secondResult = store.submitDecision(.approve, for: "token-1")
        XCTAssertEqual(secondResult, .tokenNotFound, "Replaying a consumed approval token must be rejected")
    }

    func testAgentApprovalStore_SingleUseTokenInvalidation_Reject() {
        let decisionsBox = TestBox([(channel: String, decision: ApprovalDecision, requestID: String)]())
        let store = AgentApprovalStore(channelWriter: { channel, decision, requestID in
            decisionsBox.value.append((channel, decision, requestID))
            return .success(())
        })

        let event = AgentEvent(
            agentID: "claude",
            agentName: "Claude",
            kind: .needsApproval,
            metadata: [
                AgentEvent.MetadataKey.approvalRequestID: "token-reject",
                AgentEvent.MetadataKey.approvalChannel: "/tmp/hook.pipe"
            ]
        )
        store.registerRequest(from: event)

        let result = store.submitDecision(.reject, for: "token-reject")
        XCTAssertEqual(result, .rejected)
        XCTAssertNil(store.pendingRequests["token-reject"])
        XCTAssertEqual(decisionsBox.value.first?.decision, .reject)
    }

    // MARK: - TTL Expiration Rejection (FR-007)

    func testAgentApprovalStore_TTLExpiryRejection() {
        let nowBox = TestBox(Date())
        let store = AgentApprovalStore(
            ttl: 60,
            clock: { nowBox.value }
        )

        let event = AgentEvent(
            agentID: "claude",
            agentName: "Claude",
            kind: .needsApproval,
            metadata: [AgentEvent.MetadataKey.approvalRequestID: "expiring-token"]
        )
        store.registerRequest(from: event)
        XCTAssertNotNil(store.pendingRequests["expiring-token"])

        // Advance simulated time past TTL
        nowBox.value.addTimeInterval(65)

        let result = store.submitDecision(.approve, for: "expiring-token")
        XCTAssertEqual(result, .tokenExpired, "Expired approval token must be rejected")
        XCTAssertNil(store.pendingRequests["expiring-token"])
        XCTAssertNil(store.activeRequest)
    }

    // MARK: - Zero Keystroke Injection & File Channel Writer (NFR-002, FR-006)

    func testAgentApprovalStore_DefaultFileChannelWriterWritesJSONPayload() throws {
        let tempFile = FileManager.default.temporaryDirectory
            .appendingPathComponent("test_approval_\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: tempFile) }

        let result = AgentApprovalStore.defaultChannelWriter(
            channel: tempFile.path,
            decision: .approve,
            requestID: "req-file-123"
        )

        switch result {
        case .success:
            let data = try Data(contentsOf: tempFile)
            let json = try JSONSerialization.jsonObject(with: data) as? [String: String]
            XCTAssertEqual(json?["requestID"], "req-file-123")
            XCTAssertEqual(json?["decision"], "approve")
            XCTAssertNotNil(json?["timestamp"])
        case .failure(let error):
            XCTFail("Channel writer failed: \(error)")
        }
    }

    // MARK: - Binding & Integration with AgentMonitorService (T016, FR-008)

    func testAgentApprovalStore_BindingToAgentMonitorService() {
        let (defaults, suiteName) = makeIsolatedDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let monitor = AgentMonitorService(userDefaults: defaults)
        let store = AgentApprovalStore()
        store.bind(agentMonitor: monitor)

        let approvalEvent = AgentEvent(
            agentID: "claude",
            agentName: "Claude",
            kind: .needsApproval,
            message: "Approve deployment?",
            metadata: [
                AgentEvent.MetadataKey.approvalRequestID: "req-bind-1",
                AgentEvent.MetadataKey.approvalChannel: "/tmp/bind.sock",
                AgentEvent.MetadataKey.toolName: "deploy"
            ]
        )
        monitor.handleEvent(approvalEvent)

        // Request registered in store and monitor popup displayed
        XCTAssertNotNil(store.activeRequest)
        XCTAssertEqual(store.activeRequest?.id, "req-bind-1")
        XCTAssertEqual(monitor.activePopup?.kind, .needsApproval)

        // Submitting approval decision dismisses the monitor popup
        let decisionResult = store.submitDecision(.approve, for: "req-bind-1")
        XCTAssertEqual(decisionResult, .approved)
        XCTAssertNil(monitor.activePopup, "Monitor popup must be dismissed when approval decision is submitted")
        XCTAssertNil(store.activeRequest)
    }

    func testAgentApprovalStore_ClearOnDoneOrFailed() {
        let (defaults, suiteName) = makeIsolatedDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let monitor = AgentMonitorService(userDefaults: defaults)
        let store = AgentApprovalStore()
        store.bind(agentMonitor: monitor)

        let approvalEvent = AgentEvent(
            agentID: "claude",
            agentName: "Claude",
            kind: .needsApproval,
            metadata: [AgentEvent.MetadataKey.approvalRequestID: "req-clear-1"]
        )
        monitor.handleEvent(approvalEvent)
        XCTAssertNotNil(store.pendingRequests["req-clear-1"])

        // Agent terminates with .failed or .done
        let failEvent = AgentEvent(agentID: "claude", agentName: "Claude", kind: .failed)
        monitor.handleEvent(failEvent)

        XCTAssertNil(store.pendingRequests["req-clear-1"], "Terminated agent's pending approval requests must be cleared")
    }

    // MARK: - AgentApprovalHUDView Gating (T017)

    func testAgentApprovalHUDView_SummaryAndChannelGating() {
        let requestWithChannel = AgentApprovalRequest(
            id: "1",
            agentID: "claude",
            agentName: "Claude",
            toolName: "Bash",
            commandSummary: "cargo test",
            decisionChannel: "/tmp/chan"
        )
        let hudWithChannel = AgentApprovalHUDView(request: requestWithChannel)
        XCTAssertEqual(hudWithChannel.summaryText, "Bash: cargo test")
        XCTAssertTrue(requestWithChannel.hasApprovalChannel)

        let requestWithoutChannel = AgentApprovalRequest(
            id: "2",
            agentID: "claude",
            agentName: "Claude",
            toolName: "Edit",
            commandSummary: "save file",
            decisionChannel: nil
        )
        let hudWithoutChannel = AgentApprovalHUDView(request: requestWithoutChannel)
        XCTAssertEqual(hudWithoutChannel.summaryText, "Edit: save file")
        XCTAssertFalse(requestWithoutChannel.hasApprovalChannel, "Request without channel must gate APPROVE button")
    }

    func testBubblePanelRevertsToClickThroughWhenApprovalPopupDismissedWithPendingRequest() throws {
        let (defaults, suiteName) = makeIsolatedDefaults()
        OverlayFixture.resetAgentMonitorDefaults()
        defer {
            defaults.removePersistentDomain(forName: suiteName)
            OverlayFixture.resetAgentMonitorDefaults()
        }

        let delegate = BitzAppDelegate(
            telemetryProvider: MockTelemetryProvider(),
            scaleStore: AvatarScaleStore(userDefaults: defaults),
            opacityStore: AvatarOpacityStore(userDefaults: defaults),
            positionStore: AvatarPositionStore(userDefaults: defaults),
            displayStore: DisplayPreferenceStore(userDefaults: defaults),
            updateStore: AppUpdateStore(userDefaults: defaults),
            userDefaults: defaults
        )
        delegate.setupOverlayPanel()
        defer { delegate.overlayPanels.forEach { $0.close() } }

        let panel = try XCTUnwrap(delegate.overlayPanel)
        let bubble = panel.speechBubblePanel
        XCTAssertTrue(bubble.ignoresMouseEvents)

        delegate.agentMonitor.handleEvent(AgentEvent(
            agentID: "claude",
            agentName: "Claude",
            kind: .needsApproval,
            message: "Claude needs approval!",
            metadata: [
                AgentEvent.MetadataKey.approvalRequestID: "req-bubble-1",
                AgentEvent.MetadataKey.approvalChannel: "/tmp/req-bubble-1.json"
            ]
        ))
        XCTAssertNotNil(delegate.approvalStore.activeRequest)
        XCTAssertTrue(spinRunLoop(until: { !bubble.ignoresMouseEvents }), "Approval bubble with pending request must accept clicks")

        // Dismiss popup without resolving approvalStore.activeRequest: bubble must revert to click-through.
        delegate.agentMonitor.dismissPopup()
        XCTAssertNotNil(delegate.approvalStore.activeRequest)
        XCTAssertTrue(spinRunLoop(until: { bubble.ignoresMouseEvents }), "Dismissed approval popup must not leave invisible bubble blocking clicks")
    }

    func testDefaultChannelWriterRejectsTraversalAndOutsidePaths() throws {
        let outsidePath = "/var/log/bitz-should-not-write-\(UUID().uuidString).json"
        let outsideResult = AgentApprovalStore.defaultChannelWriter(
            channel: outsidePath,
            decision: .approve,
            requestID: "req-outside"
        )
        if case .success = outsideResult {
            XCTFail("Expected outside path \(outsidePath) to be rejected")
        }

        let traversalResult = AgentApprovalStore.defaultChannelWriter(
            channel: "/tmp/../etc/bitz-traversal-test.json",
            decision: .reject,
            requestID: "req-traversal"
        )
        if case .success = traversalResult {
            XCTFail("Expected traversal path to be rejected")
        }

        let relativeResult = AgentApprovalStore.defaultChannelWriter(
            channel: "relative/approval.json",
            decision: .approve,
            requestID: "req-relative"
        )
        if case .success = relativeResult {
            XCTFail("Expected relative path to be rejected")
        }

        let symlinkURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("bitz-symlink-\(UUID().uuidString).json")
        try FileManager.default.createSymbolicLink(atPath: symlinkURL.path, withDestinationPath: "/etc/hosts")
        defer { try? FileManager.default.removeItem(at: symlinkURL) }

        let symlinkResult = AgentApprovalStore.defaultChannelWriter(
            channel: symlinkURL.path,
            decision: .approve,
            requestID: "req-symlink"
        )
        if case .success = symlinkResult {
            XCTFail("Expected symlink channel path to be rejected")
        }

        let validURL = AgentApprovalStore.defaultApprovalsDirectory
            .appendingPathComponent("bitz-valid-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: validURL) }

        let validResult = AgentApprovalStore.defaultChannelWriter(
            channel: validURL.path,
            decision: .approve,
            requestID: "req-valid"
        )
        if case .failure(let error) = validResult {
            XCTFail("Expected defaultApprovalsDirectory path to succeed, failed with: \(error)")
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: validURL.path))
    }

    func testDefaultChannelWriterDoesNotBlockOnFIFOWithoutReader() throws {
        let approvalsDir = AgentApprovalStore.defaultApprovalsDirectory
        try FileManager.default.createDirectory(at: approvalsDir, withIntermediateDirectories: true)

        let fifoURL = approvalsDir.appendingPathComponent("bitz-fifo-\(UUID().uuidString).pipe")
        XCTAssertEqual(mkfifo(fifoURL.path, 0o600), 0, "mkfifo failed with errno \(errno)")
        defer { try? FileManager.default.removeItem(at: fifoURL) }

        let result = AgentApprovalStore.defaultChannelWriter(
            channel: fifoURL.path,
            decision: .approve,
            requestID: "req-fifo-no-reader"
        )
        switch result {
        case .success:
            XCTFail("Expected non-blocking FIFO write with no reader to fail immediately")
        case .failure(let error):
            XCTAssertEqual((error as? POSIXError)?.code, .ENXIO)
        }
    }

    func testCrossAgentApprovalWithoutRequestIDClearsActiveRequestAndRejectsMismatch() {
        let (defaults, suiteName) = makeIsolatedDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let store = AgentApprovalStore()
        let monitor = AgentMonitorService(adapters: [], userDefaults: defaults)
        store.bind(agentMonitor: monitor)

        monitor.handleEvent(AgentEvent(
            agentID: "claude",
            agentName: "Claude",
            kind: .needsApproval,
            message: "Claude needs approval",
            metadata: [
                AgentEvent.MetadataKey.approvalRequestID: "req-claude-1",
                AgentEvent.MetadataKey.approvalChannel: "/tmp/claude.json"
            ]
        ))
        XCTAssertEqual(store.matchingActiveRequest(for: monitor.activePopup)?.id, "req-claude-1")

        let mismatchedPopup = AgentPopupState(
            text: "Codex needs approval",
            kind: .needsApproval,
            agentName: "Codex",
            expiresAt: nil,
            agentID: "codex",
            approvalRequestID: nil
        )
        XCTAssertNil(store.matchingActiveRequest(for: mismatchedPopup))

        monitor.handleEvent(AgentEvent(
            agentID: "codex",
            agentName: "Codex",
            kind: .needsApproval,
            message: "Codex needs approval"
        ))
        XCTAssertEqual(monitor.activePopup?.agentID, "codex")
        XCTAssertNil(store.activeRequest)
        XCTAssertNil(store.matchingActiveRequest(for: monitor.activePopup))

        let dropboxChannel = DropboxAgentAdapter.defaultDirectoryURL.appendingPathComponent("evil.json").path
        if case .success = AgentApprovalStore.defaultChannelWriter(
            channel: dropboxChannel,
            decision: .approve,
            requestID: "req-dropbox"
        ) {
            XCTFail("Dropbox input directory must not be allowed as an approval channel")
        }
    }
}
