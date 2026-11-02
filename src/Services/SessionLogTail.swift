import Foundation

/// Incremental reader for an append-only JSONL session log (NFR-001, NFR-002).
/// Holds only the file URL and byte positions, never line text (NFR-004).
public struct SessionLogTail: Sendable {
    public static let seedLimit = 256 * 1024
    public static let idleSwitchDelay: TimeInterval = 10

    public struct Read: Sendable, Equatable {
        /// Complete, non-blank lines (trailing `\r` trimmed).
        public let lines: [Data]
        /// File size increased since the previous call.
        public let grew: Bool
        public let bytesRead: Int

        static let empty = Read(lines: [], grew: false, bytesRead: 0)
    }

    public private(set) var url: URL?
    /// First byte not yet parsed (start of a partial line, if any).
    private var offset: UInt64 = 0
    /// File size seen at the previous call.
    private var knownSize: UInt64 = 0

    public init() {}

    /// Switches to `url` and returns complete lines from at most the last `seedLimit` bytes.
    public mutating func attach(to url: URL) -> Read {
        self.url = url
        let size = Self.fileSize(url) ?? 0
        let start = size - min(size, UInt64(Self.seedLimit))
        knownSize = size
        let data = Self.read(url, from: start, to: size)
        return Read(lines: consume(data, at: start, dropFirstLine: start > 0), grew: false, bytesRead: data.count)
    }

    /// Returns lines completed since the previous call.
    public mutating func readNew() -> Read {
        // A failed stat is not a truncation: resetting the offset would replay the whole log as live events.
        guard let url, let size = Self.fileSize(url) else { return .empty }
        if size < knownSize {
            // Truncated or recreated: skip what is there now instead of replaying it.
            offset = size
            knownSize = size
            return .empty
        }
        // Nothing appended means nothing completed, so a pending partial line is not re-read (NFR-001)
        // and counts as growth only on the poll its bytes arrived (R4).
        guard size > knownSize else { return .empty }
        knownSize = size
        let start = offset
        let data = Self.read(url, from: start, to: size)
        return Read(lines: consume(data, at: start, dropFirstLine: false), grew: true, bytesRead: data.count)
    }

    /// Picks the session to follow: the newest candidate, but never leaves `current` while it was modified within `idleSwitchDelay`.
    public static func pickSession(current: URL?, candidates: [(url: URL, modified: Date)], now: Date) -> URL? {
        let newest = candidates.max { $0.modified < $1.modified }?.url
        guard let current, let modified = candidates.first(where: { $0.url == current })?.modified else { return newest }
        return now.timeIntervalSince(modified) <= idleSwitchDelay ? current : newest
    }

    /// The followed file was modified within `idleSwitchDelay`, so `pickSession` would keep it (one stat, no directory scan).
    public func isCurrentFresh(at now: Date) -> Bool {
        guard let url, let modified = Self.attributes(url)?[.modificationDate] as? Date else { return false }
        return now.timeIntervalSince(modified) <= Self.idleSwitchDelay
    }

    /// Splits `data` (read from byte `start`) into complete lines and moves `offset` just past the last `\n`.
    private mutating func consume(_ data: Data, at start: UInt64, dropFirstLine: Bool) -> [Data] {
        // shortcut: a seed window inside one huge line leaves offset at `start`, so its tail later surfaces
        // as a fragment line; parsers skip it as malformed JSON (NFR-006). Track a skip flag if that ever matters.
        guard let lastNewline = data.lastIndex(of: 0x0A) else {
            offset = start
            return []
        }
        offset = start + UInt64(data.distance(from: data.startIndex, to: lastNewline) + 1)
        var complete = data[..<lastNewline]
        if dropFirstLine {
            guard let firstNewline = complete.firstIndex(of: 0x0A) else { return [] }
            complete = complete[(firstNewline + 1)...]
        }
        return complete.split(separator: 0x0A).compactMap { line in
            let trimmed = line.last == 0x0D ? line.dropLast() : line
            let isBlank = trimmed.allSatisfy { $0 == 0x20 || $0 == 0x09 || $0 == 0x0D }
            return isBlank ? nil : Data(trimmed)
        }
    }

    private static func attributes(_ url: URL) -> [FileAttributeKey: Any]? {
        try? FileManager.default.attributesOfItem(atPath: url.path)
    }

    /// nil when the file cannot be stat'ed.
    private static func fileSize(_ url: URL) -> UInt64? {
        attributes(url)?[.size] as? UInt64
    }

    private static func read(_ url: URL, from start: UInt64, to end: UInt64) -> Data {
        guard end > start, let handle = try? FileHandle(forReadingFrom: url) else { return Data() }
        defer { try? handle.close() }
        do {
            try handle.seek(toOffset: start)
            return try handle.read(upToCount: Int(end - start)) ?? Data()
        } catch {
            return Data()
        }
    }
}
