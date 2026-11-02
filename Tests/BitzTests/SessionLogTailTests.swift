import XCTest
@testable import BitzCore

final class SessionLogTailTests: XCTestCase {
    private var directory: URL!
    private var file: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        file = directory.appendingPathComponent("session.jsonl")
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
        try super.tearDownWithError()
    }

    private func write(_ text: String) throws {
        try Data(text.utf8).write(to: file)
    }

    private func append(_ text: String) throws {
        let handle = try FileHandle(forWritingTo: file)
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: Data(text.utf8))
    }

    private func strings(_ read: SessionLogTail.Read) -> [String] {
        read.lines.map { String(decoding: $0, as: UTF8.self) }
    }

    func testAttachToMissingFileReturnsNothing() {
        var tail = SessionLogTail()

        let read = tail.attach(to: file)

        XCTAssertEqual(read, SessionLogTail.Read(lines: [], grew: false, bytesRead: 0))
        XCTAssertEqual(tail.url, file)
        XCTAssertEqual(tail.readNew(), SessionLogTail.Read(lines: [], grew: false, bytesRead: 0))
    }

    func testAttachSeedsAtMostLastSeedLimitBytesAndDropsPartialFirstLine() throws {
        // 10,000 lines of 33 bytes = 330,000 bytes; the seed window starts inside line 2056.
        func line(_ n: Int) -> String { "line-\(String(format: "%06d", n))-" + String(repeating: "x", count: 20) }
        try write((0..<10_000).map { line($0) + "\n" }.joined())
        var tail = SessionLogTail()

        let read = tail.attach(to: file)

        XCTAssertLessThanOrEqual(read.bytesRead, SessionLogTail.seedLimit)
        XCTAssertLessThanOrEqual(read.lines.reduce(0) { $0 + $1.count }, SessionLogTail.seedLimit)
        XCTAssertEqual(strings(read).first, line(2057))
        XCTAssertEqual(strings(read).last, line(9_999))
        XCTAssertEqual(read.lines.count, 10_000 - 2057)
        XCTAssertFalse(read.grew)
        XCTAssertEqual(tail.readNew().bytesRead, 0)
    }

    func testReadNewReturnsOnlyAppendedCompleteLines() throws {
        try write("{\"a\":1}\n{\"b\":2}\n")
        var tail = SessionLogTail()
        XCTAssertEqual(strings(tail.attach(to: file)), ["{\"a\":1}", "{\"b\":2}"])

        try append("{\"c\":3}\n{\"d\":4}\n")
        let read = tail.readNew()

        XCTAssertEqual(strings(read), ["{\"c\":3}", "{\"d\":4}"])
        XCTAssertTrue(read.grew)
        XCTAssertEqual(read.bytesRead, 16)
    }

    func testNoNewBytesReadsZeroBytesAndNotGrew() throws {
        try write("{\"a\":1}\n")
        var tail = SessionLogTail()
        _ = tail.attach(to: file)

        XCTAssertEqual(tail.readNew(), SessionLogTail.Read(lines: [], grew: false, bytesRead: 0))
        XCTAssertEqual(tail.readNew(), SessionLogTail.Read(lines: [], grew: false, bytesRead: 0))
    }

    func testPartialLineIsCompletedNextReadAndCountsGrowthOnce() throws {
        try write("{\"a\":1}\n")
        var tail = SessionLogTail()
        _ = tail.attach(to: file)

        try append("{\"par")
        XCTAssertEqual(tail.readNew(), SessionLogTail.Read(lines: [], grew: true, bytesRead: 5))
        // Nothing appended: the pending partial line is neither re-read nor counted as growth again.
        XCTAssertEqual(tail.readNew(), SessionLogTail.Read(lines: [], grew: false, bytesRead: 0))

        try append("tial\":1}\n")
        let completed = tail.readNew()
        XCTAssertEqual(strings(completed), ["{\"partial\":1}"])
        XCTAssertTrue(completed.grew)
        XCTAssertEqual(completed.bytesRead, 14)
        XCTAssertEqual(tail.readNew(), SessionLogTail.Read(lines: [], grew: false, bytesRead: 0))
    }

    func testAttachLeavesTrailingPartialLineForNextRead() throws {
        try write("{\"a\":1}\n{\"b\"")
        var tail = SessionLogTail()

        XCTAssertEqual(strings(tail.attach(to: file)), ["{\"a\":1}"])

        try append(":2}\n")
        XCTAssertEqual(strings(tail.readNew()), ["{\"b\":2}"])
    }

    func testBlankAndCRLFLinesHandled() throws {
        try write("{\"a\":1}\r\n\r\n   \n\t\n\n{\"b\":2}\n")
        var tail = SessionLogTail()

        XCTAssertEqual(strings(tail.attach(to: file)), ["{\"a\":1}", "{\"b\":2}"])

        try append("\r\n{\"c\":3}\r\n")
        XCTAssertEqual(strings(tail.readNew()), ["{\"c\":3}"])
    }

    func testTruncationSkipsWithoutReplay() throws {
        try write("{\"a\":1}\n{\"b\":2}\n")
        var tail = SessionLogTail()
        _ = tail.attach(to: file)

        try write("{\"c\":3}\n")
        XCTAssertEqual(tail.readNew(), SessionLogTail.Read(lines: [], grew: false, bytesRead: 0))

        try append("{\"d\":4}\n")
        XCTAssertEqual(strings(tail.readNew()), ["{\"d\":4}"])
    }

    func testFailedStatDoesNotReplayFromStart() throws {
        try write("{\"a\":1}\n")
        var tail = SessionLogTail()
        _ = tail.attach(to: file)

        try FileManager.default.removeItem(at: file)
        XCTAssertEqual(tail.readNew(), SessionLogTail.Read(lines: [], grew: false, bytesRead: 0))

        try write("{\"a\":1}\n{\"b\":2}\n")
        XCTAssertEqual(strings(tail.readNew()), ["{\"b\":2}"], "Position kept: earlier lines are not replayed")
    }

    func testIsCurrentFreshFollowsModificationDate() throws {
        try write("{\"a\":1}\n")
        var tail = SessionLogTail()
        XCTAssertFalse(tail.isCurrentFresh(at: Date()), "No file followed")

        _ = tail.attach(to: file)
        let modified = Date(timeIntervalSince1970: 1_000_000)
        try FileManager.default.setAttributes([.modificationDate: modified], ofItemAtPath: file.path)
        XCTAssertTrue(tail.isCurrentFresh(at: modified + SessionLogTail.idleSwitchDelay))
        XCTAssertFalse(tail.isCurrentFresh(at: modified + SessionLogTail.idleSwitchDelay + 1))

        try FileManager.default.removeItem(at: file)
        XCTAssertFalse(tail.isCurrentFresh(at: modified), "Missing file triggers a rescan")
    }

    func testPickSessionHysteresis() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        let current = URL(fileURLWithPath: "/sessions/current.jsonl")
        let newer = URL(fileURLWithPath: "/sessions/newer.jsonl")

        let active = [(url: current, modified: now - 5), (url: newer, modified: now - 1)]
        XCTAssertEqual(SessionLogTail.pickSession(current: nil, candidates: active, now: now), newer)
        XCTAssertEqual(SessionLogTail.pickSession(current: current, candidates: active, now: now), current)

        let idle = [(url: current, modified: now - 11), (url: newer, modified: now - 1)]
        XCTAssertEqual(SessionLogTail.pickSession(current: current, candidates: idle, now: now), newer)

        let deleted = [(url: newer, modified: now - 30)]
        XCTAssertEqual(SessionLogTail.pickSession(current: current, candidates: deleted, now: now), newer)
        XCTAssertNil(SessionLogTail.pickSession(current: current, candidates: [], now: now))
    }
}
