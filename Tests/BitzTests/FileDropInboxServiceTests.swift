import AppKit
import XCTest
@testable import BitzCore

private final class SpyPasteboard: PasteboardWriting {
    var written: [String] = []
    func writeString(_ string: String) { written.append(string) }
}

@MainActor
final class FileDropInboxServiceTests: XCTestCase {
    private func makeTempDir() -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("BitzInboxTests-\(UUID().uuidString)", isDirectory: true)
        return url
    }

    func testSingleFileCopiesPathAndSkipsInboxWhenDisabled() throws {
        let pb = SpyPasteboard()
        let dir = makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let service = FileDropInboxService(pasteboard: pb, inboxDirectoryURL: dir)

        let result = try service.handleDrop(urls: [URL(fileURLWithPath: "/tmp/report.pdf")], writeInbox: false)

        XCTAssertEqual(pb.written, ["/tmp/report.pdf"])
        XCTAssertNil(result.inboxEntryURL)
        XCTAssertFalse(FileManager.default.fileExists(atPath: dir.path))
        XCTAssertEqual(result.message, "📋 Copied path: report.pdf")
    }

    func testMultipleFilesAreNewlineJoined() throws {
        let pb = SpyPasteboard()
        let dir = makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let service = FileDropInboxService(pasteboard: pb, inboxDirectoryURL: dir)

        let result = try service.handleDrop(
            urls: [URL(fileURLWithPath: "/tmp/a.txt"), URL(fileURLWithPath: "/tmp/b.txt")],
            writeInbox: false
        )
        XCTAssertEqual(pb.written, ["/tmp/a.txt\n/tmp/b.txt"])
        XCTAssertEqual(result.message, "📋 Copied 2 paths")
    }

    func testInboxEntryIsValidJSONWith0600Permissions() throws {
        let pb = SpyPasteboard()
        let dir = makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let service = FileDropInboxService(pasteboard: pb, inboxDirectoryURL: dir)

        let result = try service.handleDrop(urls: [URL(fileURLWithPath: "/tmp/spec.md")], writeInbox: true)
        let entryURL = try XCTUnwrap(result.inboxEntryURL)

        let attrs = try FileManager.default.attributesOfItem(atPath: entryURL.path)
        XCTAssertEqual((attrs[.posixPermissions] as? NSNumber)?.intValue, 0o600)
        let dirAttrs = try FileManager.default.attributesOfItem(atPath: dir.path)
        XCTAssertEqual((dirAttrs[.posixPermissions] as? NSNumber)?.intValue, 0o700)

        let entry = try JSONDecoder().decode(BitzInboxEntry.self, from: Data(contentsOf: entryURL))
        XCTAssertEqual(entry.paths, ["/tmp/spec.md"])
        XCTAssertEqual(entry.filenames, ["spec.md"])
        XCTAssertNotNil(ISO8601DateFormatter().date(from: entry.createdAt))
        XCTAssertTrue(result.message.hasSuffix("(+ inbox)"))
    }

    func testNonFileURLsAreRejected() {
        let pb = SpyPasteboard()
        let service = FileDropInboxService(pasteboard: pb, inboxDirectoryURL: makeTempDir())
        XCTAssertThrowsError(try service.handleDrop(urls: [URL(string: "https://example.com/x")!], writeInbox: false)) {
            XCTAssertEqual($0 as? FileDropInboxService.DropError, .noFileURLs)
        }
        XCTAssertTrue(pb.written.isEmpty)
    }

    func testPanelStaysClickThroughAndNonKey() {
        let panel = MascotOverlayPanel()
        XCTAssertTrue(panel.ignoresMouseEvents)
        XCTAssertFalse(panel.canBecomeKey)
        XCTAssertTrue(panel.styleMask.contains(.nonactivatingPanel))
    }
}
