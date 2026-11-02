import XCTest
@testable import BitzCore

final class MockProcessListingProvider: ProcessListingProviding, @unchecked Sendable {
    var processes: [RunningProcessInfo] = []

    func listRunningProcesses() -> [RunningProcessInfo] {
        return processes
    }
}

final class EventCollector: @unchecked Sendable {
    private var events: [AgentEvent] = []
    private let lock = NSLock()

    func append(_ event: AgentEvent) {
        lock.lock()
        events.append(event)
        lock.unlock()
    }

    var snapshot: [AgentEvent] {
        lock.lock()
        defer { lock.unlock() }
        return events
    }
}

final class ProcessAgentAdapterTests: XCTestCase {

    func testDetectsStartedAndExitedAgent() {
        let mockProvider = MockProcessListingProvider()
        let catalog = [
            AgentDefinition(id: "claude", displayName: "Claude", processNames: ["claude"]),
            AgentDefinition(id: "gemini", displayName: "Gemini", processNames: ["gemini"])
        ]

        let collector = EventCollector()
        let adapter = ProcessAgentAdapter(
            provider: mockProvider,
            catalogProvider: { catalog },
            pollInterval: 1.0
        )

        adapter.start { event in
            collector.append(event)
        }

        // 1. Tick with no agents
        adapter.performSampleTick()
        XCTAssertEqual(collector.snapshot.count, 0)

        // 2. Claude starts (idle)
        mockProvider.processes = [
            RunningProcessInfo(pid: 101, name: "claude", cpuPercent: 0.1)
        ]
        adapter.performSampleTick()
        XCTAssertEqual(collector.snapshot.count, 1)
        XCTAssertEqual(collector.snapshot.first?.agentID, "claude")
        XCTAssertEqual(collector.snapshot.first?.kind, .started)

        // 3. Claude becomes active/working
        mockProvider.processes = [
            RunningProcessInfo(pid: 101, name: "claude", cpuPercent: 12.5)
        ]
        adapter.performSampleTick()
        XCTAssertEqual(collector.snapshot.count, 2)
        XCTAssertEqual(collector.snapshot.last?.kind, .working)

        // 4. Claude terminates
        mockProvider.processes = []
        adapter.performSampleTick()
        XCTAssertEqual(collector.snapshot.count, 3)
        XCTAssertEqual(collector.snapshot.last?.kind, .done)
        XCTAssertEqual(collector.snapshot.last?.message, "Claude finished")
        XCTAssertTrue(collector.snapshot.allSatisfy(\.isProcessPresence), "Every process event is tagged source=process")

        adapter.stop()
    }

    func testMultipleAgentsSimultaneously() {
        let mockProvider = MockProcessListingProvider()
        let catalog = AgentDefinition.builtInCatalog

        let collector = EventCollector()
        let adapter = ProcessAgentAdapter(
            provider: mockProvider,
            catalogProvider: { catalog },
            pollInterval: 1.0
        )

        adapter.start { event in
            collector.append(event)
        }

        // Both Gemini and Antigravity running
        mockProvider.processes = [
            RunningProcessInfo(pid: 201, name: "gemini", cpuPercent: 5.0),
            RunningProcessInfo(pid: 202, name: "antigravity", cpuPercent: 0.2)
        ]
        adapter.performSampleTick()

        XCTAssertEqual(collector.snapshot.count, 2)
        let geminiEvent = collector.snapshot.first(where: { $0.agentID == "gemini" })
        let agyEvent = collector.snapshot.first(where: { $0.agentID == "antigravity" })

        XCTAssertEqual(geminiEvent?.kind, .working)
        XCTAssertEqual(agyEvent?.kind, .started)

        adapter.stop()
    }
}
