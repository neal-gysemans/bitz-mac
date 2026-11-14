import XCTest
@testable import BitzCore

final class MockAgentAdapter: AgentAdapter, @unchecked Sendable {
    let id: String
    private var handler: (@Sendable (AgentEvent) -> Void)?

    init(id: String = "mock-adapter") {
        self.id = id
    }

    func start(onEvent: @escaping @Sendable (AgentEvent) -> Void) {
        self.handler = onEvent
    }

    func stop() {
        self.handler = nil
    }

    func emit(_ event: AgentEvent) {
        handler?(event)
    }
}

@MainActor
final class AgentMonitorServiceTests: XCTestCase {

    override func setUp() {
        super.setUp()
        // Clean up UserDefaults keys used in tests
        UserDefaults.standard.removeObject(forKey: "Bitz.AgentMonitor.CustomAgents")
        UserDefaults.standard.removeObject(forKey: "Bitz.AgentMonitor.PopupsEnabled")
        for def in AgentDefinition.builtInCatalog {
            UserDefaults.standard.removeObject(forKey: "Bitz.AgentMonitor.Disabled." + def.id)
        }
    }

    func testBuiltInCatalogContainsRequiredAgents() {
        let service = AgentMonitorService()
        let catalog = service.catalog

        let expectedIDs = ["claude", "gemini", "antigravity", "codex", "cursor", "windsurf", "copilot", "aider", "goose", "opencode", "amp", "cline"]
        for expected in expectedIDs {
            XCTAssertTrue(catalog.contains(where: { $0.id == expected }), "Catalog should contain \(expected)")
        }
    }

    func testCustomAgentAddAndRemovePersistence() {
        let service = AgentMonitorService()
        XCTAssertEqual(service.catalog.filter { $0.isCustom }.count, 0)

        service.addCustomAgent(displayName: "MyAgent", processNames: ["my-agent-cli"], bundleIdentifiers: ["com.test.myagent"])
        XCTAssertEqual(service.catalog.filter { $0.isCustom }.count, 1)
        guard let custom = service.catalog.first(where: { $0.displayName == "MyAgent" }) else {
            XCTFail("Custom agent was not added")
            return
        }
        XCTAssertTrue(custom.isCustom)
        XCTAssertTrue(custom.matches(processName: "my-agent-cli"))
        XCTAssertTrue(custom.matches(bundleIdentifier: "com.test.myagent"))

        service.removeCustomAgent(id: custom.id)
        XCTAssertEqual(service.catalog.filter { $0.isCustom }.count, 0)
    }

    func testEnableDisableAgent() {
        let service = AgentMonitorService()
        XCTAssertTrue(service.isAgentEnabled(id: "claude"))

        service.setAgentEnabled(id: "claude", isEnabled: false)
        XCTAssertFalse(service.isAgentEnabled(id: "claude"))

        // An event from a disabled agent should be ignored
        let mock = MockAgentAdapter()
        let testService = AgentMonitorService(adapters: [mock])
        testService.setAgentEnabled(id: "claude", isEnabled: false)
        testService.startMonitoring()

        let event = AgentEvent(
            agentID: "claude",
            agentName: "Claude",
            kind: .needsApproval,
            message: "Need permission"
        )
        testService.handleEvent(event)
        XCTAssertNil(testService.activePopup)
        XCTAssertFalse(testService.activeAgents.contains("claude"))
    }

    func testEventStalenessOverSixtySecondsIsDiscarded() {
        let simulatedNow = Date()
        let service = AgentMonitorService(clock: { simulatedNow })

        let staleTimestamp = simulatedNow.addingTimeInterval(-65.0)
        let staleEvent = AgentEvent(
            agentID: "gemini",
            agentName: "Gemini",
            kind: .done,
            timestamp: staleTimestamp
        )

        service.handleEvent(staleEvent)
        XCTAssertNil(service.activePopup, "Stale event older than 60s should be discarded")
    }

    func testNeedsApprovalPopupPersistsIndefinitelyUntilNextEvent() {
        let fixedDate = Date(timeIntervalSince1970: 1000)
        let service = AgentMonitorService(clock: { fixedDate })

        let approvalEvent = AgentEvent(
            agentID: "antigravity",
            agentName: "Antigravity",
            kind: .needsApproval,
            message: "Run bash command?",
            timestamp: fixedDate
        )

        service.handleEvent(approvalEvent)
        XCTAssertNotNil(service.activePopup)
        XCTAssertEqual(service.activePopup?.kind, .needsApproval)
        XCTAssertEqual(service.activePopup?.text, "Run bash command?")
        XCTAssertNil(service.activePopup?.expiresAt, "Approval popup should not expire automatically")
        XCTAssertTrue(service.activeAgents.contains("antigravity"))

        // Next event (done) updates and sets auto-dismiss
        let doneEvent = AgentEvent(
            agentID: "antigravity",
            agentName: "Antigravity",
            kind: .done,
            message: "All done!",
            timestamp: fixedDate
        )
        service.handleEvent(doneEvent)
        XCTAssertEqual(service.activePopup?.kind, .done)
        XCTAssertEqual(service.activePopup?.text, "All done!")
        XCTAssertNotNil(service.activePopup?.expiresAt, "Done popup must have an expiration")
        XCTAssertFalse(service.activeAgents.contains("antigravity"))
    }

    func testDoneEventAutoDismissLifetime() async {
        let fixedDate = Date(timeIntervalSince1970: 2000)
        let service = AgentMonitorService(clock: { fixedDate })

        let doneEvent = AgentEvent(
            agentID: "claude",
            agentName: "Claude",
            kind: .done,
            timestamp: fixedDate
        )
        service.handleEvent(doneEvent)
        guard let popup = service.activePopup else {
            XCTFail("Popup should be present")
            return
        }

        XCTAssertEqual(popup.kind, .done)
        XCTAssertEqual(popup.text, "Claude is done!")
        XCTAssertEqual(popup.expiresAt?.timeIntervalSince(fixedDate), 6.0)
    }

    func testPopupsDisabledOptionSuppressesPopups() {
        let service = AgentMonitorService()
        service.popupsEnabled = false

        let event = AgentEvent(
            agentID: "codex",
            agentName: "Codex",
            kind: .done
        )
        service.handleEvent(event)
        XCTAssertNil(service.activePopup)
    }

    func testAgentDefinitionRejectsAppleSystemProcessesAndPrefixCollisions() {
        let cursorDef = AgentDefinition(
            id: "cursor",
            displayName: "Cursor",
            processNames: ["cursor"],
            bundleIdentifiers: ["com.todesktop.230313mzl4w4u92"]
        )

        // Apple XPC service CursorUIViewService must be rejected
        XCTAssertFalse(cursorDef.matches(
            processName: "CursorUIViewService",
            bundleIdentifier: "com.apple.TextInputUI.xpc.CursorUIViewService"
        ))

        // Even without bundle ID, CursorUIViewService must not match "cursor"
        XCTAssertFalse(cursorDef.matches(processName: "CursorUIViewService"))

        // Prefix collisions on other tools (e.g. Amphetamine vs Amp)
        let ampDef = AgentDefinition(
            id: "amp",
            displayName: "Amp",
            processNames: ["amp"]
        )
        XCTAssertFalse(ampDef.matches(processName: "Amphetamine"))

        // Background launcher (GeminiAppLauncher) vs Gemini
        let geminiDef = AgentDefinition(
            id: "gemini",
            displayName: "Gemini",
            processNames: ["gemini"],
            bundleIdentifiers: ["com.google.GeminiMacOS"]
        )
        XCTAssertFalse(geminiDef.matches(
            processName: "GeminiAppLauncher",
            bundleIdentifier: "com.google.GeminiMacOS.launcher"
        ))
    }

    func testAgentDefinitionMatchesValidAgentNamesAndHelpers() {
        let cursorDef = AgentDefinition(
            id: "cursor",
            displayName: "Cursor",
            processNames: ["cursor"],
            bundleIdentifiers: ["com.todesktop.230313mzl4w4u92"]
        )

        XCTAssertTrue(cursorDef.matches(processName: "Cursor"))
        XCTAssertTrue(cursorDef.matches(processName: "cursor"))
        XCTAssertTrue(cursorDef.matches(processName: "Cursor Helper"))
        XCTAssertTrue(cursorDef.matches(bundleIdentifier: "com.todesktop.230313mzl4w4u92"))

        let antigravityDef = AgentDefinition(
            id: "antigravity",
            displayName: "Antigravity",
            processNames: ["antigravity", "agy"],
            bundleIdentifiers: ["com.google.antigravity"]
        )
        XCTAssertTrue(antigravityDef.matches(processName: "Antigravity"))
        XCTAssertTrue(antigravityDef.matches(processName: "Antigravity Helper"))
        XCTAssertTrue(antigravityDef.matches(processName: "agy"))
        XCTAssertTrue(antigravityDef.matches(bundleIdentifier: "com.google.antigravity"))
    }

    func testMultipleConcurrentAntigravitySessionsIncrementAndDecrementActiveAgentCount() async {
        let suite = "BitzTests.MultiSessionAntigravity.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }

        let now = Date()
        let service = AgentMonitorService(clock: { now }, userDefaults: defaults)

        // 1. Seed attach of an already mid-turn session-a + live .working of session-b + .needsApproval of session-c
        service.handleEvent(AgentEvent(
            agentID: "antigravity",
            agentName: "Antigravity",
            kind: .usage,
            timestamp: now,
            metadata: [
                AgentEvent.MetadataKey.sessionID: "session-a",
                AgentEvent.MetadataKey.turnActive: "true",
                AgentEvent.MetadataKey.seed: "true",
                AgentEvent.MetadataKey.contextTokens: "120000"
            ]
        ))
        XCTAssertEqual(service.activeAgentCount, 1)
        XCTAssertEqual(service.activeSessionCount(for: "antigravity"), 1)
        XCTAssertEqual(service.activeAgents, ["antigravity"])

        service.handleEvent(AgentEvent(
            agentID: "antigravity",
            agentName: "Antigravity",
            kind: .working,
            timestamp: now,
            metadata: [AgentEvent.MetadataKey.sessionID: "session-b"]
        ))
        XCTAssertEqual(service.activeAgentCount, 2)
        XCTAssertEqual(service.activeSessionCount(for: "antigravity"), 2)
        XCTAssertEqual(service.activeAgents, ["antigravity"])

        service.handleEvent(AgentEvent(
            agentID: "antigravity",
            agentName: "Antigravity",
            kind: .needsApproval,
            message: "Approve command?",
            timestamp: now,
            metadata: [AgentEvent.MetadataKey.sessionID: "session-c"]
        ))
        XCTAssertEqual(service.activeAgentCount, 3)
        XCTAssertEqual(service.activeSessionCount(for: "antigravity"), 3)

        // Verify TelemetryDashboardService surfaces 3 AGTS and Antigravity ×3
        let telemetrySettings = TelemetrySettingsStore(userDefaults: defaults)
        let dashboard = TelemetryDashboardService(settingsStore: telemetrySettings, agentMonitor: service)
        await dashboard.performSampleTick()
        XCTAssertEqual(dashboard.snapshot.agents.activeCount, 3)
        XCTAssertEqual(dashboard.snapshot.agents.compactBadge, "3 AGTS · 12%")
        XCTAssertEqual(dashboard.snapshot.agents.agentNames, ["Antigravity ×3"])

        // 2. Finish session-a -> count drops from 3 to 2
        service.handleEvent(AgentEvent(
            agentID: "antigravity",
            agentName: "Antigravity",
            kind: .done,
            timestamp: now,
            metadata: [AgentEvent.MetadataKey.sessionID: "session-a"]
        ))
        XCTAssertEqual(service.activeAgentCount, 2)
        XCTAssertEqual(service.activeSessionCount(for: "antigravity"), 2)
        XCTAssertTrue(service.activeAgents.contains("antigravity"))

        // 3. Cancel session-b silently via usage(turnActive: false) -> count drops from 2 to 1
        service.handleEvent(AgentEvent(
            agentID: "antigravity",
            agentName: "Antigravity",
            kind: .usage,
            timestamp: now,
            metadata: [
                AgentEvent.MetadataKey.sessionID: "session-b",
                AgentEvent.MetadataKey.turnActive: "false"
            ]
        ))
        XCTAssertEqual(service.activeAgentCount, 1)
        XCTAssertEqual(service.activeSessionCount(for: "antigravity"), 1)

        // 4. Finish session-c -> count drops to 0 and activeAgents becomes empty
        service.handleEvent(AgentEvent(
            agentID: "antigravity",
            agentName: "Antigravity",
            kind: .done,
            timestamp: now,
            metadata: [AgentEvent.MetadataKey.sessionID: "session-c"]
        ))
        XCTAssertEqual(service.activeAgentCount, 0)
        XCTAssertEqual(service.activeSessionCount(for: "antigravity"), 0)
        XCTAssertTrue(service.activeAgents.isEmpty)
    }

    func testConcurrentSameAgentSessionsIsolateStallAndWarningState() {
        final class TestClock: @unchecked Sendable {
            var now = Date(timeIntervalSince1970: 1_700_000_000)
        }

        let suite = "BitzTests.MultiSessionStallIsolation.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }

        let clock = TestClock()
        let service = AgentMonitorService(clock: { clock.now }, userDefaults: defaults)

        // session-1 is running a long tool (pendingTools = 1), session-2 has no pending tool (pendingTools = 0)
        service.handleEvent(AgentEvent(
            agentID: "antigravity",
            agentName: "Antigravity",
            kind: .usage,
            timestamp: clock.now,
            metadata: [
                AgentEvent.MetadataKey.sessionID: "session-1",
                AgentEvent.MetadataKey.turnActive: "true",
                AgentEvent.MetadataKey.pendingTools: "1"
            ]
        ))
        service.handleEvent(AgentEvent(
            agentID: "antigravity",
            agentName: "Antigravity",
            kind: .usage,
            timestamp: clock.now,
            metadata: [
                AgentEvent.MetadataKey.sessionID: "session-2",
                AgentEvent.MetadataKey.turnActive: "true",
                AgentEvent.MetadataKey.pendingTools: "0"
            ]
        ))

        clock.now = clock.now.addingTimeInterval(4 * 60)
        service.evaluateStalls()
        XCTAssertEqual(service.activeWarning?.reason, .stall)

        // session-1 finishing does NOT clear session-2's stall warning
        service.handleEvent(AgentEvent(
            agentID: "antigravity",
            agentName: "Antigravity",
            kind: .done,
            timestamp: clock.now,
            metadata: [AgentEvent.MetadataKey.sessionID: "session-1"]
        ))
        XCTAssertEqual(service.activeWarning?.reason, .stall)
        XCTAssertEqual(service.activeAgentCount, 1)

        // session-2 finishing clears session-2's stall warning
        service.handleEvent(AgentEvent(
            agentID: "antigravity",
            agentName: "Antigravity",
            kind: .done,
            timestamp: clock.now,
            metadata: [AgentEvent.MetadataKey.sessionID: "session-2"]
        ))
        XCTAssertNil(service.activeWarning)
        XCTAssertEqual(service.activeAgentCount, 0)
    }
}
