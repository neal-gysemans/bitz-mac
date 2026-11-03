import AppKit
import Foundation

/// Abstraction over the system clipboard so drops are testable without touching `NSPasteboard.general`.
public protocol PasteboardWriting {
    func writeString(_ string: String)
}

public struct SystemPasteboardWriter: PasteboardWriting {
    public init() {}
    public func writeString(_ string: String) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(string, forType: .string)
    }
}

/// One file hand-off written to the agent inbox.
public struct BitzInboxEntry: Codable, Equatable, Sendable {
    public let id: String
    public let createdAt: String
    public let paths: [String]
    public let filenames: [String]
}

/// Handles files dropped onto Bitz: copies their paths to the clipboard and, when opted in, writes a
/// validated JSON entry (`0600`) into the inbox. Never injects keystrokes or input events.
@MainActor
public final class FileDropInboxService {
    public static var defaultInboxDirectory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Bitz", isDirectory: true)
            .appendingPathComponent("inbox", isDirectory: true)
    }

    public struct Result: Equatable {
        public let paths: [String]
        public let inboxEntryURL: URL?
        public var message: String {
            let suffix = inboxEntryURL != nil ? " (+ inbox)" : ""
            if paths.count == 1 {
                return "📋 Copied path: \((paths[0] as NSString).lastPathComponent)\(suffix)"
            }
            return "📋 Copied \(paths.count) paths\(suffix)"
        }
    }

    public enum DropError: Error, Equatable {
        case noFileURLs
    }

    private let pasteboard: PasteboardWriting
    public let inboxDirectoryURL: URL

    public init(
        pasteboard: PasteboardWriting = SystemPasteboardWriter(),
        inboxDirectoryURL: URL = FileDropInboxService.defaultInboxDirectory
    ) {
        self.pasteboard = pasteboard
        self.inboxDirectoryURL = inboxDirectoryURL
    }

    /// Validates `urls` (file URLs only), copies newline-joined standardized paths and optionally writes the inbox entry.
    @discardableResult
    public func handleDrop(urls: [URL], writeInbox: Bool, now: Date = Date()) throws -> Result {
        let paths = urls
            .filter { $0.isFileURL }
            .map { $0.standardizedFileURL.path }
            .filter { !$0.isEmpty }
        guard !paths.isEmpty else { throw DropError.noFileURLs }

        pasteboard.writeString(paths.joined(separator: "\n"))

        var entryURL: URL?
        if writeInbox {
            entryURL = try writeInboxEntry(paths: paths, now: now)
        }
        return Result(paths: paths, inboxEntryURL: entryURL)
    }

    private func writeInboxEntry(paths: [String], now: Date) throws -> URL {
        let fileManager = FileManager.default
        try fileManager.createDirectory(
            at: inboxDirectoryURL,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        let id = UUID().uuidString
        let entry = BitzInboxEntry(
            id: id,
            createdAt: ISO8601DateFormatter().string(from: now),
            paths: paths,
            filenames: paths.map { ($0 as NSString).lastPathComponent }
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(entry)
        let url = inboxDirectoryURL.appendingPathComponent("\(id).json")
        try data.write(to: url, options: .atomic)
        try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        return url
    }
}
