import Darwin
import XCTest
@testable import BitzCore

private final class CPUClockBox: @unchecked Sendable {
    var now = Date(timeIntervalSince1970: 2_000_000)
    func advance(minutes: Double = 0, seconds: Double = 0) {
        now += minutes * 60 + seconds
    }
}

private final class MockCPUProcessProvider: ProcessListingProviding, @unchecked Sendable {
    var processes: [RunningProcessInfo] = []

    func listRunningProcesses() -> [RunningProcessInfo] {
        processes
    }
}

private final class CPUEventCollector: @unchecked Sendable {
    private var events: [AgentEvent] = []
    private let lock = NSLock()

    func append(_ event: AgentEvent) {
        lock.lock()
        events.append(event)
        lock.unlock()
    }

    func drain() -> [AgentEvent] {
        lock.lock()
        defer { lock.unlock() }
        let copy = events
        events.removeAll()
        return copy
    }

    var snapshot: [AgentEvent] {
        lock.lock()
        defer { lock.unlock() }
        return events
    }
}

@MainActor
final class ProcessAgentCPUTests: XCTestCase {

    // MARK: - SystemProcessListingProvider (Darwin libproc + Mach timebase)

    func testSystemProcessListingProviderDiscoversSelfAndSamplesNonZeroCPU() {
        let selfPID = getpid()
        var nameBuf = [CChar](repeating: 0, count: 256)
        var pathBuf = [CChar](repeating: 0, count: Int(MAXPATHLEN) * 4)
        guard let selfName = SystemProcessListingProvider.resolveProcessName(
            pid: selfPID,
            nameBuf: &nameBuf,
            pathBuf: &pathBuf,
            preferFullPathWhenTruncated: true
        ) else {
            XCTFail("Expected process name for current test runner PID \(selfPID)")
            return
        }

        let selfAgent = AgentDefinition(id: "self-runner", displayName: "Self", processNames: [selfName])
        let provider = SystemProcessListingProvider()

        // First observation establishes baseline Mach ticks -> 0.0%
        let firstPass = provider.listRunningProcesses(matchingAgents: [selfAgent])
        let firstSelf = firstPass.first { $0.pid == selfPID }
        XCTAssertNotNil(firstSelf, "Headless test runner process should be discovered by name '\(selfName)'")
        XCTAssertEqual(firstSelf?.cpuPercent ?? -1, 0.0, accuracy: 0.001)
        XCTAssertGreaterThan(provider.lastTaskInfoCallCount, 0)
        XCTAssertEqual(provider.lastTaskInfoCallCount, firstPass.count, "Only matched candidate PIDs should be sampled")

        // Perform a brief single-thread CPU spin (~60ms) so Mach task ticks advance noticeably.
        var sink: UInt64 = 0
        let spinStart = DispatchTime.now().uptimeNanoseconds
        while DispatchTime.now().uptimeNanoseconds - spinStart < 60_000_000 {
            sink &+= 1
            if sink == 0 { break }
        }
        withExtendedLifetime(sink) {}

        // Second observation measures Mach delta task / wall ticks -> realistic single-core %CPU.
        let secondPass = provider.listRunningProcesses(matchingAgents: [selfAgent])
        let secondSelf = secondPass.first { $0.pid == selfPID }
        XCTAssertNotNil(secondSelf)
        XCTAssertGreaterThan(secondSelf?.cpuPercent ?? 0.0, 10.0, "CPU spin should report significant non-zero %CPU")
        XCTAssertLessThan(secondSelf?.cpuPercent ?? 9999.0, 400.0, "Apple Silicon Mach timebase must yield core-% rather than scaled ticks")

        // Empty catalog clears sample cache and makes zero proc_pidinfo calls.
        let emptyPass = provider.listRunningProcesses(matchingAgents: [])
        XCTAssertTrue(emptyPass.isEmpty)
        XCTAssertEqual(provider.lastTaskInfoCallCount, 0)

        // Re-observing after pruning resets baseline to 0.0%.
        let thirdPass = provider.listRunningProcesses(matchingAgents: [selfAgent])
        XCTAssertEqual(thirdPass.first(where: { $0.pid == selfPID })?.cpuPercent ?? -1, 0.0, accuracy: 0.001)
    }

    func testSystemProcessListingProviderZeroArgSkipsTaskInfoForNonCandidates() {
        let selfPID = getpid()
        let provider = SystemProcessListingProvider(catalogProvider: { [] })
        let allProcs = provider.listRunningProcesses()

        XCTAssertTrue(allProcs.contains(where: { $0.pid == selfPID }), "No-arg listing still discovers running processes")
        XCTAssertEqual(provider.lastTaskInfoCallCount, 0, "Zero proc_pidinfo calls when no candidates match")
        XCTAssertTrue(allProcs.allSatisfy { $0.cpuPercent == 0.0 })
    }

    // MARK: - ProcessAgentAdapter Zero-Idle-Wakeup Gating & Aggregation

    func testProcessAgentAdapterEmitsCPUUsageOnlyAtOrAbove50AndOnceOnDrop() {
        let clock = CPUClockBox()
        let mockProvider = MockCPUProcessProvider()
        let catalog = [AgentDefinition(id: "claude", displayName: "Claude", processNames: ["claude"])]
        let collector = CPUEventCollector()
        let adapter = ProcessAgentAdapter(
            provider: mockProvider,
            catalogProvider: { catalog },
            pollInterval: 3.0,
            clock: { clock.now }
        )
        adapter.setHandlerForTesting { collector.append($0) }
        defer { adapter.stop() }

        // 1. Idle startup (0.2%): only .started, zero .usage events
        mockProvider.processes = [RunningProcessInfo(pid: 101, name: "claude", cpuPercent: 0.2)]
        adapter.performSampleTick()
        XCTAssertEqual(collector.drain().map(\.kind), [.started])

        // 2. Repeated low/moderate activity below 50%: .working once, then zero events on idle ticks
        clock.advance(seconds: 3)
        mockProvider.processes = [RunningProcessInfo(pid: 101, name: "claude", cpuPercent: 18.0)]
        adapter.performSampleTick()
        XCTAssertEqual(collector.drain().map(\.kind), [.working])

        clock.advance(seconds: 3)
        mockProvider.processes = [RunningProcessInfo(pid: 101, name: "claude", cpuPercent: 49.9)]
        adapter.performSampleTick()
        XCTAssertTrue(collector.drain().isEmpty, "CPU below 50% must not wake @MainActor")

        // 3. Multiple PIDs summed >= 50% (60% + 55% = 115%) -> emits .usage with source=process and cpuPercent=115
        clock.advance(seconds: 3)
        mockProvider.processes = [
            RunningProcessInfo(pid: 101, name: "claude", cpuPercent: 60.0),
            RunningProcessInfo(pid: 102, name: "claude", cpuPercent: 55.0)
        ]
        adapter.performSampleTick()
        let highEvents = collector.drain()
        XCTAssertEqual(highEvents.count, 1)
        XCTAssertEqual(highEvents.first?.kind, .usage)
        XCTAssertTrue(highEvents.first?.isProcessPresence == true)
        XCTAssertEqual(highEvents.first?.cpuPercent ?? -1, 115.0, accuracy: 0.01)

        // 4. Drops below 50% -> emits ONE final .usage event so AgentMonitorService resets episode
        clock.advance(seconds: 3)
        mockProvider.processes = [RunningProcessInfo(pid: 101, name: "claude", cpuPercent: 12.5)]
        adapter.performSampleTick()
        let dropEvents = collector.drain()
        XCTAssertEqual(dropEvents.count, 1)
        XCTAssertEqual(dropEvents.first?.kind, .usage)
        XCTAssertTrue(dropEvents.first?.isProcessPresence == true)
        XCTAssertEqual(dropEvents.first?.cpuPercent ?? -1, 12.5, accuracy: 0.01)

        // 5. Stays below 50% -> zero wakeups
        clock.advance(seconds: 3)
        mockProvider.processes = [RunningProcessInfo(pid: 101, name: "claude", cpuPercent: 5.0)]
        adapter.performSampleTick()
        XCTAssertTrue(collector.drain().isEmpty)
    }

    func testProcessAgentAdapterBrandNewHighCPUAgentEmitsWorkingAndUsage() {
        let clock = CPUClockBox()
        let mockProvider = MockCPUProcessProvider()
        let catalog = [AgentDefinition(id: "codex", displayName: "Codex / ChatGPT", processNames: ["codex"])]
        let collector = CPUEventCollector()
        let adapter = ProcessAgentAdapter(
            provider: mockProvider,
            catalogProvider: { catalog },
            pollInterval: 3.0,
            clock: { clock.now }
        )
        adapter.setHandlerForTesting { collector.append($0) }
        defer { adapter.stop() }

        mockProvider.processes = [RunningProcessInfo(pid: 555, name: "codex", cpuPercent: 120.0)]
        adapter.performSampleTick()

        let events = collector.drain()
        XCTAssertEqual(events.map(\.kind), [.working, .usage])
        XCTAssertEqual(events.last?.cpuPercent ?? -1, 120.0, accuracy: 0.01)
    }

    // MARK: - AgentMonitorService Sustained Runaway-CPU Warnings

    private func makeService(_ clock: CPUClockBox) -> (AgentMonitorService, UserDefaults, String) {
        let suiteName = "ProcessAgentCPUTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        let service = AgentMonitorService(clock: { clock.now }, userDefaults: defaults)
        return (service, defaults, suiteName)
    }

    private func cpuUsageEvent(_ id: String, _ name: String, _ clock: CPUClockBox, cpuPercent: Double) -> AgentEvent {
        AgentEvent(
            agentID: id,
            agentName: name,
            kind: .usage,
            timestamp: clock.now,
            metadata: [
                AgentEvent.MetadataKey.source: "process",
                AgentEvent.MetadataKey.cpuPercent: String(cpuPercent)
            ]
        )
    }

    func testSustainedRunawayCPUFiresOnceAndRearmsAfterDrop() {
        let clock = CPUClockBox()
        let (service, defaults, suite) = makeService(clock)
        defer { defaults.removePersistentDomain(forName: suite) }

        // Default threshold = 95%, duration = 2 min (120s)
        service.handleEvent(cpuUsageEvent("claude", "Claude", clock, cpuPercent: 110.0))
        XCTAssertNil(service.activeWarning)

        clock.advance(seconds: 60)
        service.handleEvent(cpuUsageEvent("claude", "Claude", clock, cpuPercent: 95.0))
        XCTAssertNil(service.activeWarning)

        clock.advance(seconds: 59)
        service.handleEvent(cpuUsageEvent("claude", "Claude", clock, cpuPercent: 130.0))
        XCTAssertNil(service.activeWarning)

        clock.advance(seconds: 1) // 120s sustained
        service.handleEvent(cpuUsageEvent("claude", "Claude", clock, cpuPercent: 104.6))
        XCTAssertEqual(service.activeWarning?.agentID, "claude")
        XCTAssertEqual(service.activeWarning?.reason, .runawayCPU)
        XCTAssertEqual(
            service.activeWarning?.text,
            "⚠️ Claude is using 105% CPU for 2+ min (possible runaway process)."
        )
        XCTAssertEqual(service.activePopup?.kind, .warning)

        // Acknowledge and continue high CPU -> must not fire a second time during same episode
        service.acknowledgeWarning()
        clock.advance(minutes: 3)
        service.handleEvent(cpuUsageEvent("claude", "Claude", clock, cpuPercent: 180.0))
        XCTAssertNil(service.activeWarning, "Should fire at most once per sustained episode")

        // Drop below threshold -> resets episode
        clock.advance(seconds: 3)
        service.handleEvent(cpuUsageEvent("claude", "Claude", clock, cpuPercent: 94.4))
        XCTAssertNil(service.activeWarning)

        // Sustained again for 2 min -> fires again
        clock.advance(seconds: 3)
        service.handleEvent(cpuUsageEvent("claude", "Claude", clock, cpuPercent: 99.8))
        XCTAssertNil(service.activeWarning)

        clock.advance(minutes: 2)
        service.handleEvent(cpuUsageEvent("claude", "Claude", clock, cpuPercent: 100.0))
        XCTAssertEqual(service.activeWarning?.reason, .runawayCPU)
        XCTAssertEqual(
            service.activeWarning?.text,
            "⚠️ Claude is using 100% CPU for 2+ min (possible runaway process)."
        )
    }

    func testRunawayCPUResetsOnAgentExitDisableToggleOffAndSystemWake() {
        let clock = CPUClockBox()
        let (service, defaults, suite) = makeService(clock)
        defer { defaults.removePersistentDomain(forName: suite) }

        // 1. Agent exit (.done with source=process) resets episode
        service.handleEvent(cpuUsageEvent("claude", "Claude", clock, cpuPercent: 140.0))
        clock.advance(seconds: 90)
        service.handleEvent(AgentEvent(
            agentID: "claude",
            agentName: "Claude",
            kind: .done,
            timestamp: clock.now,
            metadata: [AgentEvent.MetadataKey.source: "process"]
        ))
        clock.advance(seconds: 3)
        service.handleEvent(cpuUsageEvent("claude", "Claude", clock, cpuPercent: 140.0))
        clock.advance(seconds: 90) // only 90s since restart, though 183s since initial start
        service.handleEvent(cpuUsageEvent("claude", "Claude", clock, cpuPercent: 140.0))
        XCTAssertNil(service.activeWarning, "Agent exit must reset runaway episode start time")

        // 2. System wake rebases episode timestamp so sleep time doesn't trigger false alarm
        clock.advance(minutes: 10)
        service.handleSystemWake()
        clock.advance(seconds: 3)
        service.handleEvent(cpuUsageEvent("claude", "Claude", clock, cpuPercent: 140.0))
        XCTAssertNil(service.activeWarning, "Sleep duration must not count toward runaway CPU")

        clock.advance(minutes: 2)
        service.handleEvent(cpuUsageEvent("claude", "Claude", clock, cpuPercent: 140.0))
        XCTAssertEqual(service.activeWarning?.reason, .runawayCPU)

        // 3. Disabling agent clears active runaway warning and episode
        service.setAgentEnabled(id: "claude", isEnabled: false)
        XCTAssertNil(service.activeWarning)
        service.setAgentEnabled(id: "claude", isEnabled: true)

        // 4. Toggle off suppresses runaway warning
        service.signalSettings.runawayCPUWarningEnabled = false
        service.handleEvent(cpuUsageEvent("claude", "Claude", clock, cpuPercent: 200.0))
        clock.advance(minutes: 5)
        service.handleEvent(cpuUsageEvent("claude", "Claude", clock, cpuPercent: 200.0))
        XCTAssertNil(service.activeWarning)
    }

    func testProcessPresenceCPUUsageDoesNotInterfereWithLogStallTimers() {
        let clock = CPUClockBox()
        let (service, defaults, suite) = makeService(clock)
        defer { defaults.removePersistentDomain(forName: suite) }

        // A process-only agent (Cursor) receiving CPU usage events must NOT get tracksLog = true
        service.handleEvent(AgentEvent(
            agentID: "cursor",
            agentName: "Cursor",
            kind: .working,
            timestamp: clock.now,
            metadata: [AgentEvent.MetadataKey.source: "process"]
        ))
        service.handleEvent(cpuUsageEvent("cursor", "Cursor", clock, cpuPercent: 65.0))
        clock.advance(minutes: 10)
        service.evaluateStalls()
        XCTAssertNil(service.activeWarning, "Process CPU .usage events must never enable log-stall timers")

        // A log-backed agent's stall timer must NOT be reset by process CPU .usage events
        service.handleEvent(AgentEvent(agentID: "claude", agentName: "Claude", kind: .usage, timestamp: clock.now))
        service.handleEvent(AgentEvent(agentID: "claude", agentName: "Claude", kind: .working, timestamp: clock.now))

        clock.advance(minutes: 2)
        service.handleEvent(cpuUsageEvent("claude", "Claude", clock, cpuPercent: 60.0))

        clock.advance(minutes: 1) // 3 min total since last real log activity
        service.evaluateStalls()
        XCTAssertEqual(service.activeWarning?.reason, .stall)
    }

    // MARK: - Settings Clamping, Codable Round-Trip, Metadata Accessor & Settings Tab

    func testRunawayCPUSettingsClampingCodableRoundTripAndMetadataAccessor() throws {
        // Metadata accessor validation
        XCTAssertEqual(
            AgentEvent(agentID: "a", agentName: "A", kind: .usage, metadata: [AgentEvent.MetadataKey.cpuPercent: "142.5"]).cpuPercent,
            142.5
        )
        XCTAssertNil(AgentEvent(agentID: "a", agentName: "A", kind: .usage, metadata: [AgentEvent.MetadataKey.cpuPercent: "-1"]).cpuPercent)
        XCTAssertNil(AgentEvent(agentID: "a", agentName: "A", kind: .usage, metadata: [AgentEvent.MetadataKey.cpuPercent: "nan"]).cpuPercent)
        XCTAssertNil(AgentEvent(agentID: "a", agentName: "A", kind: .usage, metadata: [AgentEvent.MetadataKey.cpuPercent: "abc"]).cpuPercent)
        XCTAssertNil(AgentEvent(agentID: "a", agentName: "A", kind: .usage, metadata: [AgentEvent.MetadataKey.cpuPercent: "1e300"]).cpuPercent)
        XCTAssertNil(AgentEvent(agentID: "a", agentName: "A", kind: .usage, metadata: [AgentEvent.MetadataKey.cpuPercent: "100001"]).cpuPercent)

        // Decoded JSON drop-box event with extreme "cpuPercent": 1e300 must neither crash Int() nor fire a runaway warning.
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let dropboxClock = CPUClockBox()
        let (dropboxService, dropboxDefaults, dropboxSuite) = makeService(dropboxClock)
        defer { dropboxDefaults.removePersistentDomain(forName: dropboxSuite) }
        let iso = ISO8601DateFormatter()
        for offsetMinutes in [0.0, 3.0] {
            dropboxClock.advance(minutes: offsetMinutes)
            let json = """
            {"agentID":"claude","agentName":"Claude","kind":"usage","timestamp":"\(iso.string(from: dropboxClock.now))","metadata":{"cpuPercent":1e300}}
            """
            let decodedEvent = try decoder.decode(AgentEvent.self, from: Data(json.utf8))
            XCTAssertNil(decodedEvent.cpuPercent)
            dropboxService.handleEvent(decodedEvent)
        }
        XCTAssertNil(dropboxService.activeWarning)

        // Defaults & isEnabled
        var settings = AgentSignalSettings()
        XCTAssertTrue(settings.runawayCPUWarningEnabled)
        XCTAssertEqual(settings.runawayCPUPercentThreshold, 95)
        XCTAssertEqual(settings.runawayCPUDurationMinutes, 2)
        XCTAssertTrue(settings.isEnabled(.runawayCPU))
        settings.runawayCPUWarningEnabled = false
        XCTAssertFalse(settings.isEnabled(.runawayCPU))

        // Clamping bounds: 50...400%, 1...15 min
        settings.runawayCPUPercentThreshold = 10
        settings.runawayCPUDurationMinutes = 0
        var clamped = settings.clamped()
        XCTAssertEqual(clamped.runawayCPUPercentThreshold, 50)
        XCTAssertEqual(clamped.runawayCPUDurationMinutes, 1)

        settings.runawayCPUPercentThreshold = 999
        settings.runawayCPUDurationMinutes = 60
        clamped = settings.clamped()
        XCTAssertEqual(clamped.runawayCPUPercentThreshold, 400)
        XCTAssertEqual(clamped.runawayCPUDurationMinutes, 15)

        // Backward-compatible partial JSON decode missing runaway fields keeps defaults
        let partial = try JSONDecoder().decode(AgentSignalSettings.self, from: Data(#"{"stallTimeoutMinutes":5}"#.utf8))
        XCTAssertTrue(partial.runawayCPUWarningEnabled)
        XCTAssertEqual(partial.runawayCPUPercentThreshold, 95)
        XCTAssertEqual(partial.runawayCPUDurationMinutes, 2)
        XCTAssertEqual(partial.stallTimeoutMinutes, 5)

        // Full Codable round-trip
        var custom = AgentSignalSettings()
        custom.runawayCPUWarningEnabled = false
        custom.runawayCPUPercentThreshold = 180
        custom.runawayCPUDurationMinutes = 5
        let encoded = try JSONEncoder().encode(custom)
        let decoded = try JSONDecoder().decode(AgentSignalSettings.self, from: encoded)
        XCTAssertEqual(decoded, custom)

        // Settings view renders the Runaway CPU controls
        let suiteName = "ProcessAgentCPUSettingsViewTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let monitor = AgentMonitorService(adapters: [], userDefaults: defaults)
        let tab = AgentsSettingsTabView(agentMonitor: monitor)
        let rendered = String(describing: tab.body)
        XCTAssertTrue(rendered.contains("Runaway CPU Warnings"))
        XCTAssertTrue(rendered.contains("Warn above 95% CPU"))
        XCTAssertTrue(rendered.contains("Sustained for 2 min"))
    }
}
