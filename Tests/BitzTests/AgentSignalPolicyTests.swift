import XCTest
@testable import BitzCore

private final class ClockBox: @unchecked Sendable {
    var now = Date(timeIntervalSince1970: 1_000_000)
    func advance(minutes: Double = 0, seconds: Double = 0) { now += minutes * 60 + seconds }
}

/// Signal policy of `AgentMonitorService`: context / stall / reported warnings, the warning slot and almost-done.
@MainActor
final class AgentSignalPolicyTests: XCTestCase {

    private let names = ["claude": "Claude", "gemini": "Gemini", "antigravity": "Antigravity"]

    private func makeService(_ clock: ClockBox = ClockBox()) -> (AgentMonitorService, UserDefaults, String) {
        let suiteName = "AgentSignalPolicyTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        let service = AgentMonitorService(clock: { clock.now }, userDefaults: defaults)
        return (service, defaults, suiteName)
    }

    private func event(_ id: String, _ kind: AgentEventKind, _ clock: ClockBox, message: String? = nil,
                       metadata: [String: String]? = nil) -> AgentEvent {
        AgentEvent(agentID: id, agentName: names[id] ?? id, kind: kind, message: message,
                   timestamp: clock.now, metadata: metadata)
    }

    private func usage(_ id: String, _ clock: ClockBox, tokens: Int, seed: Bool = false) -> AgentEvent {
        var metadata = [AgentEvent.MetadataKey.contextTokens: String(tokens)]
        if seed { metadata[AgentEvent.MetadataKey.seed] = "true" }
        return event(id, .usage, clock, metadata: metadata)
    }

    private func warning(_ id: String, _ clock: ClockBox, reason: AgentWarningReason? = nil,
                         message: String? = nil) -> AgentEvent {
        event(id, .warning, clock, message: message,
              metadata: reason.map { [AgentEvent.MetadataKey.reason: $0.rawValue] })
    }

    // MARK: - Settings (T007)

    func testSettingsDefaultWhenNothingStored() {
        let (service, defaults, suite) = makeService()
        defer { defaults.removePersistentDomain(forName: suite) }

        XCTAssertEqual(service.signalSettings, .default)
    }

    func testSettingsPersistAndReloadClamped() throws {
        let (service, defaults, suite) = makeService()
        defer { defaults.removePersistentDomain(forName: suite) }

        service.signalSettings.contextThresholdPercent = 120
        service.signalSettings.almostDoneEnabled = false
        XCTAssertEqual(service.signalSettings.contextThresholdPercent, 99)

        let reloaded = AgentMonitorService(userDefaults: defaults)
        XCTAssertEqual(reloaded.signalSettings.contextThresholdPercent, 99)
        XCTAssertFalse(reloaded.signalSettings.almostDoneEnabled)

        // A stored out-of-range blob (e.g. hand-edited) is clamped on load
        var raw = AgentSignalSettings()
        raw.contextThresholdPercent = 120
        raw.stallTimeoutMinutes = 0
        defaults.set(try JSONEncoder().encode(raw), forKey: "Bitz.AgentMonitor.SignalSettings")
        let clamped = AgentMonitorService(userDefaults: defaults)
        XCTAssertEqual(clamped.signalSettings.contextThresholdPercent, 99)
        XCTAssertEqual(clamped.signalSettings.stallTimeoutMinutes, 1)
    }

    // MARK: - Context readings and warning (T008, US1)

    func testContextWarningFiresOnceAndRearms() {
        let clock = ClockBox()
        let (service, defaults, suite) = makeService(clock)
        defer { defaults.removePersistentDomain(forName: suite) }

        service.handleEvent(usage("claude", clock, tokens: 180_000))
        XCTAssertEqual(service.latestContext?.percent, 90)
        XCTAssertEqual(service.activeWarning?.reason, .context)
        XCTAssertEqual(service.activeWarning?.agentID, "claude")
        XCTAssertEqual(service.activeWarning?.text, "⚠️ Claude: context at 90%! Consider /compact soon.")
        XCTAssertEqual(service.activePopup?.kind, .warning)
        XCTAssertNil(service.activePopup?.expiresAt, "Warning bubble persists")
        service.acknowledgeWarning()

        service.handleEvent(usage("claude", clock, tokens: 190_000))
        XCTAssertNil(service.activeWarning, "Still above threshold: no second warning")
        XCTAssertEqual(service.latestContext?.tokens, 190_000)

        service.handleEvent(usage("claude", clock, tokens: 100_000))
        XCTAssertNil(service.activeWarning)
        XCTAssertEqual(service.latestContext?.percent, 50)

        service.handleEvent(usage("claude", clock, tokens: 185_000))
        XCTAssertEqual(service.activeWarning?.text, "⚠️ Claude: context at 92%! Consider /compact soon.")
    }

    func testUsageNeverShowsBubbleOrChangesActiveAgents() {
        let clock = ClockBox()
        let (service, defaults, suite) = makeService(clock)
        defer { defaults.removePersistentDomain(forName: suite) }

        service.handleEvent(usage("antigravity", clock, tokens: 300_000))
        XCTAssertNil(service.activePopup)
        XCTAssertTrue(service.activeAgents.isEmpty)
        XCTAssertEqual(service.latestContext?.compactText, "Antigravity ctx 300k · 30%")

        service.handleEvent(event("gemini", .working, clock))
        service.handleEvent(usage("gemini", clock, tokens: 10_000))
        XCTAssertEqual(service.activePopup?.kind, .working, "usage leaves the current bubble alone")
        XCTAssertEqual(service.activeAgents, ["gemini"])
        XCTAssertEqual(service.latestContext?.agentID, "gemini", "latestContext is the most recently updated reading")
    }

    func testSeedReadingAboveThresholdDoesNotWarnButMarksFired() {
        let clock = ClockBox()
        let (service, defaults, suite) = makeService(clock)
        defer { defaults.removePersistentDomain(forName: suite) }

        service.handleEvent(usage("claude", clock, tokens: 185_000, seed: true))
        XCTAssertEqual(service.latestContext?.percent, 92)
        XCTAssertNil(service.activeWarning)
        XCTAssertNil(service.activePopup)

        service.handleEvent(usage("claude", clock, tokens: 190_000))
        XCTAssertNil(service.activeWarning, "Seed marked the crossing as fired")

        service.handleEvent(usage("claude", clock, tokens: 100_000))
        service.handleEvent(usage("claude", clock, tokens: 185_000))
        XCTAssertEqual(service.activeWarning?.reason, .context)
    }

    func testContextWarningToggleOffSuppressesWarningButKeepsReading() {
        let clock = ClockBox()
        let (service, defaults, suite) = makeService(clock)
        defer { defaults.removePersistentDomain(forName: suite) }

        service.signalSettings.contextWarningEnabled = false
        service.handleEvent(usage("claude", clock, tokens: 190_000))
        XCTAssertNil(service.activeWarning)
        XCTAssertEqual(service.latestContext?.percent, 95)
    }

    func testWindowChangeRecomputesPercent() {
        let clock = ClockBox()
        let (service, defaults, suite) = makeService(clock)
        defer { defaults.removePersistentDomain(forName: suite) }

        service.handleEvent(usage("claude", clock, tokens: 150_000))
        XCTAssertEqual(service.latestContext?.percent, 75)

        service.signalSettings.contextWindowTokens["claude"] = 1_000_000
        XCTAssertEqual(service.latestContext?.windowTokens, 1_000_000)
        XCTAssertEqual(service.latestContext?.percent, 15)

        service.signalSettings.contextWindowTokens["claude"] = 100_000
        XCTAssertEqual(service.latestContext?.percent, 100, "Capped at 100")
        XCTAssertEqual(service.latestContext?.tokens, 150_000)
        XCTAssertNil(service.activeWarning, "Recompute never raises a warning")
    }

    // MARK: - Warning slot (T009, T010, US3)

    func testWorkingAndAlmostDoneDoNotReplaceWarning() {
        let clock = ClockBox()
        let (service, defaults, suite) = makeService(clock)
        defer { defaults.removePersistentDomain(forName: suite) }

        service.handleEvent(warning("claude", clock, message: "Check this"))
        service.handleEvent(event("gemini", .working, clock))
        service.handleEvent(event("claude", .working, clock))
        service.handleEvent(event("claude", .almostDone, clock))

        XCTAssertEqual(service.activeWarning?.agentID, "claude")
        XCTAssertEqual(service.activePopup?.kind, .warning)
        XCTAssertEqual(service.activePopup?.text, "Check this")
        XCTAssertEqual(service.activeAgents, ["claude", "gemini"])
    }

    func testSameAgentDoneClearsWarning() {
        let clock = ClockBox()
        let (service, defaults, suite) = makeService(clock)
        defer { defaults.removePersistentDomain(forName: suite) }

        service.handleEvent(warning("claude", clock))
        service.handleEvent(event("claude", .done, clock))

        XCTAssertNil(service.activeWarning)
        XCTAssertEqual(service.activePopup?.kind, .done)
        XCTAssertEqual(service.activePopup?.expiresAt?.timeIntervalSince(clock.now), 6.0)
    }

    func testSameAgentApprovalClearsWarning() {
        let clock = ClockBox()
        let (service, defaults, suite) = makeService(clock)
        defer { defaults.removePersistentDomain(forName: suite) }

        service.handleEvent(warning("claude", clock))
        service.handleEvent(event("claude", .needsApproval, clock))

        XCTAssertNil(service.activeWarning)
        XCTAssertEqual(service.activePopup?.kind, .needsApproval)
        XCTAssertNil(service.activePopup?.expiresAt)
    }

    func testOtherAgentDoneKeepsWarning() {
        let clock = ClockBox()
        let (service, defaults, suite) = makeService(clock)
        defer { defaults.removePersistentDomain(forName: suite) }

        service.handleEvent(event("gemini", .working, clock))
        service.handleEvent(warning("claude", clock))
        service.handleEvent(event("gemini", .done, clock))

        XCTAssertEqual(service.activeWarning?.agentID, "claude")
        XCTAssertEqual(service.activePopup?.kind, .warning)
        XCTAssertFalse(service.activeAgents.contains("gemini"))
    }

    func testOtherAgentApprovalOverridesThenWarningReturns() {
        let clock = ClockBox()
        let (service, defaults, suite) = makeService(clock)
        defer { defaults.removePersistentDomain(forName: suite) }

        service.handleEvent(warning("claude", clock, message: "Claude warning"))
        service.handleEvent(event("gemini", .needsApproval, clock))
        XCTAssertEqual(service.activePopup?.kind, .needsApproval)
        XCTAssertEqual(service.activeWarning?.agentID, "claude", "Warning stays active under the approval")

        service.handleEvent(event("antigravity", .working, clock))
        XCTAssertEqual(service.activePopup?.kind, .needsApproval, "Only the approving agent supersedes its approval")

        service.handleEvent(event("gemini", .working, clock))
        XCTAssertEqual(service.activePopup?.kind, .warning)
        XCTAssertEqual(service.activePopup?.text, "Claude warning")

        // Same again, superseded by the approving agent's done
        service.handleEvent(event("gemini", .needsApproval, clock))
        service.handleEvent(event("gemini", .done, clock))
        XCTAssertEqual(service.activePopup?.kind, .warning)
        XCTAssertEqual(service.activeWarning?.agentID, "claude")
    }

    func testNewerWarningReplacesOlder() {
        let clock = ClockBox()
        let (service, defaults, suite) = makeService(clock)
        defer { defaults.removePersistentDomain(forName: suite) }

        service.handleEvent(warning("claude", clock, message: "first"))
        service.handleEvent(warning("gemini", clock, reason: .loop, message: "second"))

        XCTAssertEqual(service.activeWarning, AgentWarning(agentID: "gemini", agentName: "Gemini", reason: .loop, text: "second"))
        XCTAssertEqual(service.activePopup?.text, "second")
    }

    func testAcknowledgeClearsWarningAndBubble() {
        let clock = ClockBox()
        let (service, defaults, suite) = makeService(clock)
        defer { defaults.removePersistentDomain(forName: suite) }

        service.handleEvent(warning("claude", clock))
        service.acknowledgeWarning()
        XCTAssertNil(service.activeWarning)
        XCTAssertNil(service.activePopup)

        // Acknowledging under another agent's approval keeps that approval bubble
        service.handleEvent(warning("claude", clock))
        service.handleEvent(event("gemini", .needsApproval, clock))
        service.acknowledgeWarning()
        XCTAssertNil(service.activeWarning)
        XCTAssertEqual(service.activePopup?.kind, .needsApproval)
        service.handleEvent(event("gemini", .working, clock))
        XCTAssertEqual(service.activePopup?.kind, .working, "No stale override after acknowledge")
    }

    func testDismissPopupKeepsWarning() {
        let clock = ClockBox()
        let (service, defaults, suite) = makeService(clock)
        defer { defaults.removePersistentDomain(forName: suite) }

        service.handleEvent(warning("claude", clock))
        service.dismissPopup()
        XCTAssertNil(service.activePopup)
        XCTAssertNotNil(service.activeWarning)
    }

    // MARK: - Almost done and toggles (US4, FR-013)

    func testAlmostDonePopupAndToggle() {
        let clock = ClockBox()
        let (service, defaults, suite) = makeService(clock)
        defer { defaults.removePersistentDomain(forName: suite) }

        service.handleEvent(event("claude", .almostDone, clock))
        XCTAssertEqual(service.activePopup?.kind, .almostDone)
        XCTAssertEqual(service.activePopup?.text, "✨ Claude is almost done!")
        XCTAssertEqual(service.activePopup?.expiresAt?.timeIntervalSince(clock.now), 6.0)
        XCTAssertTrue(service.activeAgents.contains("claude"))

        service.dismissPopup()
        service.signalSettings.almostDoneEnabled = false
        service.handleEvent(event("claude", .almostDone, clock, message: "nearly"))
        XCTAssertNil(service.activePopup)
    }

    func testPopupsDisabledKeepsWarningStateWithoutBubble() {
        let clock = ClockBox()
        let (service, defaults, suite) = makeService(clock)
        defer { defaults.removePersistentDomain(forName: suite) }

        service.popupsEnabled = false
        service.handleEvent(usage("claude", clock, tokens: 190_000))
        XCTAssertEqual(service.activeWarning?.reason, .context)
        XCTAssertEqual(service.latestContext?.percent, 95)
        XCTAssertNil(service.activePopup)

        service.popupsEnabled = true
        XCTAssertEqual(service.activePopup?.kind, .warning)
        XCTAssertEqual(service.activePopup?.text, service.activeWarning?.text)
    }

    func testWarningWaitsBehindAnotherAgentsApproval() {
        let clock = ClockBox()
        let (service, defaults, suite) = makeService(clock)
        defer { defaults.removePersistentDomain(forName: suite) }

        service.handleEvent(event("gemini", .needsApproval, clock))
        service.handleEvent(warning("claude", clock, message: "Claude warning"))

        XCTAssertEqual(service.activePopup?.kind, .needsApproval, "Approval keeps the bubble")
        XCTAssertEqual(service.activeWarning?.agentID, "claude", "Warning is active (amber visor)")

        service.handleEvent(event("gemini", .working, clock))
        XCTAssertEqual(service.activePopup?.text, "Claude warning", "Warning bubble returns once the approval is superseded")
    }

    // MARK: - Stall sweep (T011, US2)

    func testStallFiresOnceAfterTimeout() {
        let clock = ClockBox()
        let (service, defaults, suite) = makeService(clock)
        defer { defaults.removePersistentDomain(forName: suite) }

        service.handleEvent(event("claude", .usage, clock)) // session-log heartbeat: only log-backed sessions stall
        service.handleEvent(event("claude", .working, clock))
        clock.advance(minutes: 2, seconds: 59)
        service.evaluateStalls()
        XCTAssertNil(service.activeWarning)

        clock.advance(seconds: 1)
        service.evaluateStalls()
        XCTAssertEqual(service.activeWarning, AgentWarning(agentID: "claude", agentName: "Claude", reason: .stall,
                                                           text: "⚠️ Claude may be stuck: no output for 3 min."))
        XCTAssertEqual(service.activePopup?.kind, .warning)

        service.acknowledgeWarning()
        clock.advance(minutes: 10)
        service.evaluateStalls()
        XCTAssertNil(service.activeWarning, "One warning per stall")
    }

    func testNoStallWhilePendingToolOrAwaitingApprovalOrAfterDone() {
        let clock = ClockBox()
        let (service, defaults, suite) = makeService(clock)
        defer { defaults.removePersistentDomain(forName: suite) }

        service.handleEvent(event("claude", .usage, clock, metadata: [
            AgentEvent.MetadataKey.turnActive: "true", AgentEvent.MetadataKey.pendingTools: "1"
        ]))
        service.handleEvent(event("gemini", .working, clock))
        service.handleEvent(event("gemini", .needsApproval, clock))
        service.handleEvent(event("antigravity", .working, clock))
        service.handleEvent(event("antigravity", .done, clock))

        clock.advance(minutes: 30)
        service.evaluateStalls()
        XCTAssertNil(service.activeWarning)
    }

    func testStallToggleOffSuppressesStall() {
        let clock = ClockBox()
        let (service, defaults, suite) = makeService(clock)
        defer { defaults.removePersistentDomain(forName: suite) }

        service.signalSettings.stallWarningEnabled = false
        service.handleEvent(event("claude", .working, clock))
        clock.advance(minutes: 5)
        service.evaluateStalls()
        XCTAssertNil(service.activeWarning)
    }

    func testActivityResetsStall() {
        let clock = ClockBox()
        let (service, defaults, suite) = makeService(clock)
        defer { defaults.removePersistentDomain(forName: suite) }

        service.signalSettings.stallTimeoutMinutes = 1
        service.handleEvent(event("claude", .usage, clock)) // session-log heartbeat: only log-backed sessions stall
        service.handleEvent(event("claude", .working, clock))
        clock.advance(minutes: 1)
        service.evaluateStalls()
        XCTAssertEqual(service.activeWarning?.reason, .stall)
        XCTAssertEqual(service.activeWarning?.text, "⚠️ Claude may be stuck: no output for 1 min.")
        service.acknowledgeWarning()

        service.handleEvent(event("claude", .usage, clock)) // heartbeat
        clock.advance(seconds: 59)
        service.evaluateStalls()
        XCTAssertNil(service.activeWarning)

        clock.advance(seconds: 1)
        service.evaluateStalls()
        XCTAssertEqual(service.activeWarning?.reason, .stall, "Activity re-arms the stall warning")
    }

    func testAgentWithoutSessionLogNeverStalls() {
        let clock = ClockBox()
        let (service, defaults, suite) = makeService(clock)
        defer { defaults.removePersistentDomain(forName: suite) }

        // A drop-box-only agent sends no usage heartbeats, so its silence says nothing about a stall.
        service.handleEvent(event("gemini", .working, clock))
        clock.advance(minutes: 30)
        service.evaluateStalls()
        XCTAssertNil(service.activeWarning)
    }

    func testStallSweepTimerRaisesWarning() async throws {
        let clock = ClockBox()
        let suiteName = "AgentSignalPolicyTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let service = AgentMonitorService(clock: { clock.now }, userDefaults: defaults, stallSweepInterval: 0.02)
        service.startMonitoring()
        defer { service.stopMonitoring() }

        service.handleEvent(event("claude", .usage, clock))
        service.handleEvent(event("claude", .working, clock))
        clock.advance(minutes: 3)

        // No manual evaluateStalls(): the sweep started by startMonitoring() must raise it.
        for _ in 0..<100 where service.activeWarning == nil {
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        XCTAssertEqual(service.activeWarning?.reason, .stall)
    }

    // MARK: - Disabled agents (T012, FR-013)

    func testDisablingAgentClearsWarningReadingAndSession() {
        let clock = ClockBox()
        let (service, defaults, suite) = makeService(clock)
        defer { defaults.removePersistentDomain(forName: suite) }

        service.handleEvent(event("claude", .working, clock))
        service.handleEvent(usage("claude", clock, tokens: 190_000))
        XCTAssertNotNil(service.activeWarning)

        service.setAgentEnabled(id: "claude", isEnabled: false)
        XCTAssertNil(service.activeWarning)
        XCTAssertNil(service.latestContext)
        XCTAssertNil(service.activePopup)

        service.setAgentEnabled(id: "claude", isEnabled: true)
        clock.advance(minutes: 5)
        service.evaluateStalls()
        XCTAssertNil(service.activeWarning, "Session (turnActive) was cleared")

        service.handleEvent(usage("claude", clock, tokens: 190_000))
        XCTAssertEqual(service.activeWarning?.reason, .context, "Context crossing state was cleared")
    }

    func testDisablingApprovingAgentRestoresWarningBubble() {
        let clock = ClockBox()
        let (service, defaults, suite) = makeService(clock)
        defer { defaults.removePersistentDomain(forName: suite) }

        service.handleEvent(warning("claude", clock))
        service.handleEvent(event("gemini", .needsApproval, clock))
        service.setAgentEnabled(id: "gemini", isEnabled: false)

        XCTAssertEqual(service.activePopup?.kind, .warning)
        XCTAssertEqual(service.activeWarning?.agentID, "claude")
    }

    // MARK: - Reported and loop warnings (FR-008 toggles)

    func testReportedWarningAlwaysShownAndLoopToggleRespected() {
        let clock = ClockBox()
        let (service, defaults, suite) = makeService(clock)
        defer { defaults.removePersistentDomain(forName: suite) }

        service.signalSettings.loopWarningEnabled = false
        service.signalSettings.contextWarningEnabled = false
        service.signalSettings.stallWarningEnabled = false

        service.handleEvent(warning("claude", clock, reason: .loop, message: "loop"))
        XCTAssertNil(service.activeWarning)

        service.handleEvent(warning("claude", clock))
        XCTAssertEqual(service.activeWarning, AgentWarning(agentID: "claude", agentName: "Claude", reason: .reported,
                                                           text: "⚠️ Claude reported a problem"))

        service.signalSettings.loopWarningEnabled = true
        service.handleEvent(warning("gemini", clock, reason: .loop, message: "loop"))
        XCTAssertEqual(service.activeWarning?.reason, .loop)
    }

    // MARK: - App presence (T044)

    func testProcessPresenceDoneDoesNotClearWarningOrEndTurn() {
        let clock = ClockBox()
        let (service, defaults, suite) = makeService(clock)
        defer { defaults.removePersistentDomain(forName: suite) }

        let presence = [AgentEvent.MetadataKey.source: "process"]
        service.handleEvent(event("claude", .usage, clock)) // session-log heartbeat: only log-backed sessions stall
        service.handleEvent(event("claude", .working, clock))
        service.handleEvent(warning("claude", clock, message: "Claude warning"))
        service.handleEvent(event("claude", .done, clock, metadata: presence))

        XCTAssertEqual(service.activeWarning?.agentID, "claude")
        XCTAssertEqual(service.activePopup?.kind, .warning)
        XCTAssertFalse(service.activeAgents.contains("claude"))

        clock.advance(minutes: 3)
        service.evaluateStalls()
        XCTAssertEqual(service.activeWarning?.reason, .stall, "Turn is still active")

        // Without a warning it is an ordinary done bubble
        service.acknowledgeWarning()
        service.handleEvent(event("claude", .done, clock, metadata: presence))
        XCTAssertEqual(service.activePopup?.kind, .done)
    }

    func testStopMonitoringClearsSignalState() {
        let clock = ClockBox()
        let (service, defaults, suite) = makeService(clock)
        defer { defaults.removePersistentDomain(forName: suite) }

        service.startMonitoring()
        service.handleEvent(event("claude", .working, clock))
        service.handleEvent(usage("claude", clock, tokens: 190_000))
        service.stopMonitoring()

        XCTAssertNil(service.activeWarning)
        XCTAssertNil(service.latestContext)
        clock.advance(minutes: 5)
        service.evaluateStalls()
        XCTAssertNil(service.activeWarning, "Sessions were cleared")
    }
}
