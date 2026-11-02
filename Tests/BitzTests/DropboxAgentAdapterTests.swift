import XCTest
@testable import BitzCore

final class DropboxEventCollector: @unchecked Sendable {
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

final class DropboxAgentAdapterTests: XCTestCase {
    var tempDir: URL!

    override func setUp() {
        super.setUp()
        tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: tempDir)
        super.tearDown()
    }

    func testProcessesValidEventAndDeletesFile() {
        let fixedDate = ISO8601DateFormatter().date(from: "2026-10-26T14:00:10Z")!
        let adapter = DropboxAgentAdapter(
            directoryURL: tempDir,
            clock: { fixedDate }
        )
        let collector = DropboxEventCollector()

        let json = """
        {
            "id": "E461239C-703A-4EF4-8C88-E3251C86DBD1",
            "agentID": "claude",
            "agentName": "Claude",
            "kind": "needsApproval",
            "message": "Needs permission to edit file",
            "timestamp": "2026-10-26T14:00:00Z"
        }
        """

        let eventFile = tempDir.appendingPathComponent("event1.json")
        try? json.data(using: .utf8)?.write(to: eventFile)

        adapter.start { event in
            collector.append(event)
        }

        adapter.processPendingFiles()

        XCTAssertEqual(collector.snapshot.count, 1)
        XCTAssertEqual(collector.snapshot.first?.agentID, "claude")
        XCTAssertEqual(collector.snapshot.first?.kind, .needsApproval)
        XCTAssertEqual(collector.snapshot.first?.message, "Needs permission to edit file")
        XCTAssertFalse(FileManager.default.fileExists(atPath: eventFile.path), "Processed file must be removed")

        adapter.stop()
    }

    func testDiscardsStaleEvent() {
        let adapter = DropboxAgentAdapter(
            directoryURL: tempDir,
            clock: { ISO8601DateFormatter().date(from: "2026-10-26T14:05:00Z")! }
        )
        let collector = DropboxEventCollector()
        adapter.start { collector.append($0) }

        let staleJson = """
        {
            "agentID": "claude",
            "agentName": "Claude",
            "kind": "done",
            "timestamp": "2026-10-26T14:00:00Z"
        }
        """
        let file = tempDir.appendingPathComponent("stale.json")
        try? staleJson.data(using: .utf8)?.write(to: file)

        adapter.processPendingFiles()
        XCTAssertEqual(collector.snapshot.count, 0, "Stale events over 60s should be dropped")
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path), "Stale file must be removed")
        adapter.stop()
    }

    func testDropsV2EventWithMetadata() {
        let adapter = DropboxAgentAdapter(
            directoryURL: tempDir,
            clock: { ISO8601DateFormatter().date(from: "2026-10-30T11:00:05Z")! }
        )
        let collector = DropboxEventCollector()

        let json = """
        {
            "agentID": "claude",
            "agentName": "Claude",
            "kind": "usage",
            "timestamp": "2026-10-30T11:00:00Z",
            "metadata": { "contextTokens": "1234" }
        }
        """
        try? json.data(using: .utf8)?.write(to: tempDir.appendingPathComponent("v2.json"))

        adapter.start { collector.append($0) }
        adapter.processPendingFiles()
        XCTAssertEqual(collector.snapshot.count, 1)
        XCTAssertEqual(collector.snapshot.first?.kind, .usage)
        XCTAssertEqual(collector.snapshot.first?.contextTokens, 1234)
        adapter.stop()
    }
}
