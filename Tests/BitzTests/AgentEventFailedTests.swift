import XCTest
import SwiftUI
@testable import BitzCore

@MainActor
final class AgentEventFailedTests: XCTestCase {
    private func makeIsolatedDefaults() -> (UserDefaults, String) {
        let suiteName = "test.bitz.agent.failed.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        return (defaults, suiteName)
    }

    func testAgentEventKindFailed_DecodingFromJSON() throws {
        let json = """
        {
            "id": "A1B2C3D4-E5F6-7A8B-9C0D-1E2F3A4B5C6D",
            "agentID": "claude",
            "agentName": "Claude",
            "kind": "failed",
            "message": "Task execution failed: exit code 1",
            "timestamp": "2026-11-03T14:00:00Z",
            "metadata": {
                "approvalRequestID": "req-123",
                "toolName": "Bash",
                "commandSummary": "git push origin main",
                "owningPID": "12345",
                "bundleID": "com.anthropic.claudefordesktop",
                "workingDir": "/Users/akramkasimi/repo"
            }
        }
        """

        let data = json.data(using: .utf8)!
        let event = try JSONDecoder().decode(AgentEvent.self, from: data)

        XCTAssertEqual(event.kind, .failed)
        XCTAssertEqual(event.agentID, "claude")
        XCTAssertEqual(event.agentName, "Claude")
        XCTAssertEqual(event.message, "Task execution failed: exit code 1")
        XCTAssertEqual(event.approvalRequestID, "req-123")
        XCTAssertEqual(event.toolName, "Bash")
        XCTAssertEqual(event.commandSummary, "git push origin main")
        XCTAssertEqual(event.owningPID, 12345)
        XCTAssertEqual(event.bundleID, "com.anthropic.claudefordesktop")
        XCTAssertEqual(event.workingDir, "/Users/akramkasimi/repo")
    }

    func testAgentEventKindFailed_RoundtripEncoding() throws {
        let original = AgentEvent(
            agentID: "antigravity",
            agentName: "Antigravity",
            kind: .failed,
            message: "Fatal tool error",
            metadata: ["reason": "error"]
        )

        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(AgentEvent.self, from: data)

        XCTAssertEqual(decoded.kind, .failed)
        XCTAssertEqual(decoded.agentID, original.agentID)
        XCTAssertEqual(decoded.agentName, original.agentName)
        XCTAssertEqual(decoded.message, original.message)
    }

    func testAgentMonitorService_HandlesFailedEvent_RemovesActiveAgentAndPresentsPopup() {
        let (defaults, suiteName) = makeIsolatedDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let service = AgentMonitorService(userDefaults: defaults)

        let startEvent = AgentEvent(agentID: "claude", agentName: "Claude", kind: .started)
        service.handleEvent(startEvent)
        XCTAssertTrue(service.activeAgents.contains("claude"))

        let failEvent = AgentEvent(
            agentID: "claude",
            agentName: "Claude",
            kind: .failed,
            message: "Build command timed out"
        )
        service.handleEvent(failEvent)

        XCTAssertFalse(service.activeAgents.contains("claude"), "Failed agent must be removed from activeAgents")
        XCTAssertEqual(service.activePopup?.kind, .failed)
        XCTAssertEqual(service.activePopup?.text, "Build command timed out")
        XCTAssertEqual(service.activePopup?.agentName, "Claude")
        XCTAssertNotNil(service.activePopup?.expiresAt, "Failed popup should have auto-dismiss expiry")
    }

    func testAgentMonitorService_HandlesFailedEvent_DefaultMessage() {
        let (defaults, suiteName) = makeIsolatedDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let service = AgentMonitorService(userDefaults: defaults)

        let failEvent = AgentEvent(
            agentID: "claude",
            agentName: "Claude",
            kind: .failed,
            message: nil
        )
        service.handleEvent(failEvent)

        XCTAssertEqual(service.activePopup?.kind, .failed)
        XCTAssertEqual(service.activePopup?.text, "❌ Claude failed!")
    }

    func testAgentHookInstaller_FailureCommandFormatting() {
        let cmd = AgentHookInstaller.failureCommand(agentID: "claude", agentName: "Claude", message: "Script failed")
        XCTAssertTrue(cmd.contains("'failed'"))
        XCTAssertTrue(cmd.contains("'Script failed'"))
        XCTAssertTrue(cmd.contains("'claude'"))
    }
}
