import Foundation
import SQLite3

/// Reads Cursor Composer/Agent sessions from two read-only sources:
/// 1. `~/Library/Application Support/Cursor/User/globalStorage/state.vscdb` (read-only SQLite, gated on DB + WAL mtime/size), and
/// 2. `~/.cursor/projects/*/agent-transcripts/*.jsonl` (append-only JSONL via `SessionLogTail`, skipping `subagents/`).
/// Uses exponential idle backoff (`1.5s -> 30.0s`) and supports concurrent sessions keyed by `sessionID`.
public final class CursorTranscriptAdapter: AgentAdapter, @unchecked Sendable {
    public static let activeAttachWindow: TimeInterval = 300.0
    public static let idleRetainWindow: TimeInterval = 1800.0

    public let id = "cursor-transcript"
    public let agentID = "cursor"
    public let agentName = "Cursor"

    private let globalStorageDBURL: URL
    private let projectsURL: URL
    private let pollInterval: TimeInterval
    private let maxIdleScanInterval: TimeInterval
    private let activeAttachWindow: TimeInterval
    private let clock: @Sendable () -> Date

    private let lock = NSLock()
    private var pollTask: Task<Void, Never>?
    private var eventHandler: (@Sendable (AgentEvent) -> Void)?

    // MARK: - SQLite State

    private struct DatabaseMarker: Equatable {
        let dbModified: Date?
        let dbSize: UInt64
        let walModified: Date?
        let walSize: UInt64
    }

    private struct SQLiteToolState: Equatable {
        var status: String
        var awaitingApprovalEmitted: Bool
        var completedEmitted: Bool
    }

    private struct SQLiteSessionState {
        let sessionID: String
        var tracker: AgentSessionTracker
        var lastActivityAt: Date
        var lastComposerUpdatedAt: Date?
        var wasGenerating: Bool
        var lastEmittedContextTokens: Int?
        var seenHumanBubbles: Set<String> = []
        var seenAIBubbles: Set<String> = []
        var pendingToolBubbleIDs: Set<String> = []
        var toolStates: [String: SQLiteToolState] = [:]
        var handledErrorKeys: Set<Data> = []
        var lastBubbleSignatureByID: [String: Int] = [:]
    }

    // MARK: - JSONL State

    private struct CachedJSONLFile {
        let url: URL
        let sessionID: String
        var modified: Date?
    }

    private struct CachedNestedDir {
        var modified: Date?
    }

    private struct CachedTranscriptsDir {
        let projectDir: URL
        let transcriptsDir: URL
        var modified: Date?
        var nestedSessionDirs: [URL: CachedNestedDir] = [:]
        var files: [URL: CachedJSONLFile] = [:]
    }

    private struct FollowedJSONLSession {
        let sessionID: String
        let url: URL
        var tail: SessionLogTail
        var tracker: AgentSessionTracker
        var lastActivityAt: Date
    }

    private var lastSQLiteMarker = DatabaseMarker(dbModified: nil, dbSize: 0, walModified: nil, walSize: 0)
    private var sqliteSessions: [String: SQLiteSessionState] = [:]
    private var hasSeededSQLite = false

    private var cachedProjectsModified: Date?
    private var cachedProjects: [URL: CachedTranscriptsDir] = [:]
    private var followedJSONLSessions: [String: FollowedJSONLSession] = [:]

    private var lastCandidateScanTime: Date?
    private var currentScanInterval: TimeInterval
    private var scanCount = 0

    public static var defaultGlobalStorageDBURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Cursor/User/globalStorage/state.vscdb", isDirectory: false)
    }

    public static var defaultProjectsURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".cursor/projects", isDirectory: true)
    }

    public init(
        globalStorageDBURL: URL = CursorTranscriptAdapter.defaultGlobalStorageDBURL,
        projectsURL: URL = CursorTranscriptAdapter.defaultProjectsURL,
        pollInterval: TimeInterval = 1.5,
        maxIdleScanInterval: TimeInterval = 30.0,
        activeAttachWindow: TimeInterval = CursorTranscriptAdapter.activeAttachWindow,
        clock: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.globalStorageDBURL = globalStorageDBURL
        self.projectsURL = projectsURL
        self.pollInterval = pollInterval
        self.maxIdleScanInterval = max(pollInterval, maxIdleScanInterval)
        self.activeAttachWindow = max(pollInterval, activeAttachWindow)
        self.currentScanInterval = pollInterval
        self.clock = clock
    }

    public var scanIntervalForTesting: TimeInterval {
        lock.withLock { currentScanInterval }
    }

    public var scanCountForTesting: Int {
        lock.withLock { scanCount }
    }

    public var activeSessionIDsForTesting: [String] {
        lock.withLock {
            Array(Set(sqliteSessions.keys).union(followedJSONLSessions.keys)).sorted()
        }
    }

    public func setHandlerForTesting(_ onEvent: @escaping @Sendable (AgentEvent) -> Void) {
        lock.withLock { eventHandler = onEvent }
    }

    public func start(onEvent: @escaping @Sendable (AgentEvent) -> Void) {
        setHandlerForTesting(onEvent)
        checkForUpdates()

        let sleepNanoseconds = UInt64(pollInterval * 1_000_000_000)
        let task = Task { [weak self] in
            while (try? await Task.sleep(nanoseconds: sleepNanoseconds)) != nil {
                guard let self else { return }
                autoreleasepool {
                    self.checkForUpdates()
                }
            }
        }
        lock.withLock {
            pollTask?.cancel()
            pollTask = task
        }
    }

    public func stop() {
        lock.withLock {
            pollTask?.cancel()
            pollTask = nil
            eventHandler = nil
            sqliteSessions.removeAll()
            followedJSONLSessions.removeAll()
            lastSQLiteMarker = DatabaseMarker(dbModified: nil, dbSize: 0, walModified: nil, walSize: 0)
            hasSeededSQLite = false
            cachedProjectsModified = nil
            cachedProjects.removeAll()
            lastCandidateScanTime = nil
            currentScanInterval = pollInterval
            scanCount = 0
        }
    }

    public func checkForUpdates() {
        lock.lock()
        defer { lock.unlock() }

        guard let handler = eventHandler else { return }
        let now = clock()

        let shouldScan = shouldScanSources(at: now)
        var anyActivity = false

        if shouldScan {
            lastCandidateScanTime = now
            scanCount += 1

            if pollSQLite(at: now, handler: handler) {
                anyActivity = true
            }

            if scanAndAttachJSONL(at: now, handler: handler) {
                anyActivity = true
            }
        }

        // Tail already-followed JSONL sessions every tick just like Claude / Antigravity adapters.
        for sessionID in followedJSONLSessions.keys.sorted() {
            guard var session = followedJSONLSessions[sessionID] else { continue }
            let read = session.tail.readNew()
            if read.grew {
                anyActivity = true
                session.lastActivityAt = now
                let entries = read.lines.flatMap { Self.entries(fromLine: $0, referenceDate: now) }
                let events = session.tracker.ingest(entries, at: now)
                for event in events {
                    handler(event)
                }
                handler(session.tracker.usageEvent(at: now, seed: false))
                followedJSONLSessions[sessionID] = session
            }
        }

        if anyActivity {
            currentScanInterval = pollInterval
        } else if shouldScan {
            currentScanInterval = min(currentScanInterval * 2.0, maxIdleScanInterval)
        }

        pruneIdleSessions(at: now)
    }

    private func shouldScanSources(at now: Date) -> Bool {
        guard let lastScan = lastCandidateScanTime else { return true }
        let elapsed = now.timeIntervalSince(lastScan)
        if elapsed < 0 || elapsed >= currentScanInterval {
            return true
        }
        // Only check source modification markers before backoff expires when at least one source exists.
        if lastSQLiteMarker.dbModified != nil && currentSQLiteMarker() != lastSQLiteMarker {
            return true
        }
        if cachedProjectsModified != nil && SessionLogTail.modificationDate(projectsURL) != cachedProjectsModified {
            return true
        }
        return false
    }

    // MARK: - SQLite Composer Storage (`state.vscdb`)

    private func currentSQLiteMarker() -> DatabaseMarker {
        let dbMeta = SessionLogTail.fileMetadata(globalStorageDBURL)
        let walURL = URL(fileURLWithPath: globalStorageDBURL.path + "-wal")
        let walMeta = SessionLogTail.fileMetadata(walURL)
        return DatabaseMarker(
            dbModified: dbMeta?.modified,
            dbSize: dbMeta?.size ?? 0,
            walModified: walMeta?.modified,
            walSize: walMeta?.size ?? 0
        )
    }

    private func pollSQLite(at now: Date, handler: @Sendable (AgentEvent) -> Void) -> Bool {
        let marker = currentSQLiteMarker()
        guard marker.dbModified != nil else {
            lastSQLiteMarker = marker
            return false
        }
        guard marker != lastSQLiteMarker else {
            return false
        }
        lastSQLiteMarker = marker

        var rawDB: OpaquePointer?
        defer {
            if let rawDB {
                sqlite3_close(rawDB)
            }
        }
        guard sqlite3_open_v2(
            globalStorageDBURL.path,
            &rawDB,
            SQLITE_OPEN_READONLY | SQLITE_OPEN_FULLMUTEX,
            nil
        ) == SQLITE_OK, let db = rawDB else {
            return false
        }
        sqlite3_busy_timeout(db, 20)

        guard Self.tableExists("cursorDiskKV", in: db) else {
            return false
        }

        let headers = Self.readComposerHeaders(in: db)
        let composerObjects: [(id: String, json: [String: Any])]
        if let headers, !headers.isEmpty {
            // Query only recently updated non-subagent composers plus any currently followed SQLite sessions.
            let candidateIDs = Self.selectCandidateComposerIDs(
                fromHeaders: headers,
                followedIDs: Set(sqliteSessions.keys),
                activeWindow: activeAttachWindow,
                now: now
            )
            composerObjects = Self.readComposerData(forIDs: candidateIDs, in: db)
        } else {
            composerObjects = Self.readAllComposerData(in: db)
        }

        let isColdStart = !hasSeededSQLite
        hasSeededSQLite = true

        // Choose which composers to follow when cold starting without fresh composers.
        let validComposers = composerObjects.filter { !Self.isSubagentOrDraft($0.json) }
        if isColdStart && sqliteSessions.isEmpty {
            let fresh = validComposers.filter { item in
                guard let ts = Self.composerUpdatedDate(item.json, fallback: marker.walModified ?? marker.dbModified) else {
                    return false
                }
                return now.timeIntervalSince(ts) <= activeAttachWindow
            }
            let toAttach: [(id: String, json: [String: Any])]
            let staleFallback: Bool
            if !fresh.isEmpty {
                toAttach = fresh
                staleFallback = false
            } else if let newest = validComposers.max(by: {
                (Self.composerUpdatedDate($0.json, fallback: nil) ?? .distantPast)
                    < (Self.composerUpdatedDate($1.json, fallback: nil) ?? .distantPast)
            }) {
                toAttach = [newest]
                staleFallback = true
            } else {
                toAttach = []
                staleFallback = false
            }

            var changed = false
            for item in toAttach {
                attachSQLiteComposer(
                    id: item.id,
                    composer: item.json,
                    markerDate: marker.walModified ?? marker.dbModified ?? now,
                    at: now,
                    db: db,
                    isStaleFallback: staleFallback,
                    handler: handler
                )
                changed = true
            }
            return changed
        }

        var anyChanged = false
        for item in validComposers {
            let updatedAt = Self.composerUpdatedDate(item.json, fallback: nil)
            let isGenerating = Self.isComposerGenerating(item.json)
            if var existing = sqliteSessions[item.id] {
                if updateSQLiteComposer(
                    &existing,
                    composer: item.json,
                    markerDate: marker.walModified ?? marker.dbModified ?? now,
                    at: now,
                    db: db,
                    handler: handler
                ) {
                    anyChanged = true
                }
                sqliteSessions[item.id] = existing
            } else {
                let isFresh = isGenerating || (updatedAt.map { now.timeIntervalSince($0) <= activeAttachWindow } ?? false)
                if isFresh {
                    attachSQLiteComposer(
                        id: item.id,
                        composer: item.json,
                        markerDate: marker.walModified ?? marker.dbModified ?? now,
                        at: now,
                        db: db,
                        isStaleFallback: false,
                        handler: handler
                    )
                    anyChanged = true
                }
            }
        }
        return anyChanged
    }

    private func attachSQLiteComposer(
        id composerID: String,
        composer: [String: Any],
        markerDate: Date,
        at now: Date,
        db: OpaquePointer,
        isStaleFallback: Bool,
        handler: @Sendable (AgentEvent) -> Void
    ) {
        var state = SQLiteSessionState(
            sessionID: composerID,
            tracker: AgentSessionTracker(
                agentID: agentID,
                agentName: agentName,
                startsTurnOnPrompt: true,
                sessionID: composerID
            ),
            lastActivityAt: Self.composerUpdatedDate(composer, fallback: markerDate) ?? markerDate,
            lastComposerUpdatedAt: Self.composerUpdatedDate(composer, fallback: nil),
            wasGenerating: Self.isComposerGenerating(composer),
            lastEmittedContextTokens: nil
        )

        let seedEntries = extractSQLiteDeltaEntries(
            for: &state,
            composer: composer,
            at: now,
            db: db,
            isSeed: true
        )
        state.tracker.prime(fromSeed: seedEntries)
        if isStaleFallback || !state.wasGenerating {
            let status = (composer["status"] as? String)?.lowercased() ?? "none"
            if isStaleFallback || status == "completed" || status == "aborted" || status == "cancelled" || status == "none" {
                state.tracker.markIdle()
            }
        }
        sqliteSessions[composerID] = state
        handler(state.tracker.usageEvent(at: now, seed: true))
    }

    private func updateSQLiteComposer(
        _ state: inout SQLiteSessionState,
        composer: [String: Any],
        markerDate: Date,
        at now: Date,
        db: OpaquePointer,
        handler: @Sendable (AgentEvent) -> Void
    ) -> Bool {
        let entries = extractSQLiteDeltaEntries(
            for: &state,
            composer: composer,
            at: now,
            db: db,
            isSeed: false
        )
        guard !entries.isEmpty else {
            return false
        }

        state.lastActivityAt = now
        let events = state.tracker.ingest(entries, at: now)
        for event in events {
            handler(event)
        }
        handler(state.tracker.usageEvent(at: now, seed: false))
        return true
    }

    private func extractSQLiteDeltaEntries(
        for state: inout SQLiteSessionState,
        composer: [String: Any],
        at now: Date,
        db: OpaquePointer,
        isSeed: Bool
    ) -> [SessionLogEntry] {
        var entries: [SessionLogEntry] = []

        let bubbleRefs = Self.bubbleHeaders(from: composer)
        let generatingIDs = Set(composer["generatingBubbleIds"] as? [String] ?? [])
        let composerContext = Self.composerContextTokens(from: composer)

        // Only inspect bubbles we haven't finalized yet (tailing recent ones + any currently generating).
        let candidateBubbles = bubbleRefs.enumerated().filter { index, ref in
            let isTail = index >= max(0, bubbleRefs.count - 4)
            return !state.seenHumanBubbles.contains(ref.id)
                && (
                    !state.seenAIBubbles.contains(ref.id)
                        || generatingIDs.contains(ref.id)
                        || state.pendingToolBubbleIDs.contains(ref.id)
                        || isTail
                )
        }

        var latestBubbleInputTokens: Int?
        var sawTurnAbortOrQuota = false
        var sawNewPromptOrNonToolAI = false

        for (_, ref) in candidateBubbles {
            if ref.type == 1 {
                if state.seenHumanBubbles.insert(ref.id).inserted {
                    sawNewPromptOrNonToolAI = true
                    entries.append(.toolResult(id: nil))
                    entries.append(.prompt)
                }
                continue
            }

            let rowKey = "bubbleId:\(state.sessionID):\(ref.id)"
            guard let bubble = Self.readKVJSON(forKey: rowKey, in: db) else {
                continue
            }

            let bubbleSig = Self.bubbleSignature(bubble)
            let isFirstBubbleRead = state.lastBubbleSignatureByID[ref.id] == nil
            if state.lastBubbleSignatureByID[ref.id] == bubbleSig {
                continue
            }
            state.lastBubbleSignatureByID[ref.id] = bubbleSig

            let bubbleType = RateLimitParser.intValue(bubble["type"]) ?? ref.type
            if bubbleType == 1 {
                if state.seenHumanBubbles.insert(ref.id).inserted {
                    sawNewPromptOrNonToolAI = true
                    entries.append(.toolResult(id: nil))
                    entries.append(.prompt)
                }
                continue
            }

            _ = state.seenAIBubbles.insert(ref.id)
            let lineDate = RateLimitParser.parseTimestamp(bubble["createdAt"]) ?? now

            // 1. Bubble error / quota checks.
            let errorTexts = RateLimitParser.collectErrorStrings(from: bubble["errorDetails"])
                + RateLimitParser.collectErrorStrings(from: bubble["clientVisibleErrorMessage"])
                + RateLimitParser.collectErrorStrings(from: bubble["actualErrorMessage"])
            if !errorTexts.isEmpty {
                let errDigest = RateLimitParser.dedupDigest([ref.id] + errorTexts)
                if state.handledErrorKeys.insert(errDigest).inserted {
                    var codes: [Int] = []
                    if let details = bubble["errorDetails"] as? [String: Any] {
                        for key in ["code", "statusCode", "httpStatus"] {
                            if let code = RateLimitParser.intValue(details[key]) {
                                codes.append(code)
                            }
                        }
                    }
                    if RateLimitParser.isQuotaError(texts: errorTexts, statusCodes: codes) {
                        let resetsAt = RateLimitParser.extractResetDate(
                            in: bubble,
                            texts: errorTexts,
                            referenceDate: lineDate
                        )
                        entries.append(.toolResult(id: nil))
                        entries.append(.rateLimit(resetsAt: resetsAt))
                        entries.append(.turnEnd(isDone: false))
                        sawTurnAbortOrQuota = true
                        continue
                    }
                }
            }

            // 2. Bubble token usage.
            if let tokenCount = bubble["tokenCount"] as? [String: Any],
               let inputTokens = RateLimitParser.intValue(tokenCount["inputTokens"]),
               inputTokens > 0 {
                latestBubbleInputTokens = inputTokens
            }

            // 3. Tool calls via toolFormerData.
            if let tool = bubble["toolFormerData"] as? [String: Any] {
                let callID = (tool["toolCallId"] as? String) ?? ref.id
                let name = (tool["name"] as? String) ?? "tool"
                let status = (tool["status"] as? String)?.lowercased() ?? "loading"
                let isTerminal = (
                    status == "completed" || status == "success" || status == "error"
                        || status == "cancelled" || status == "rejected" || status == "failed"
                        || (tool["result"] != nil && status != "running" && status != "loading" && status != "pending")
                )
                let isWaitingApproval = (
                    status == "waiting_for_approval" || status == "awaiting_approval"
                        || status == "requires_approval" || status == "pending_approval"
                )

                var toolState = state.toolStates[callID]
                if toolState == nil {
                    let parsedArgs = Self.parseJSONIfString(tool["rawArgs"] ?? tool["params"])
                    entries.append(.toolCall(
                        id: callID,
                        name: name,
                        fingerprint: AgentSessionTracker.fingerprint(name: name, input: parsedArgs)
                    ))
                    toolState = SQLiteToolState(
                        status: status,
                        awaitingApprovalEmitted: false,
                        completedEmitted: false
                    )
                }
                if var ts = toolState {
                    ts.status = status
                    if isWaitingApproval && !ts.awaitingApprovalEmitted {
                        ts.awaitingApprovalEmitted = true
                        entries.append(.approvalRequest)
                    }
                    if isTerminal && !ts.completedEmitted {
                        ts.completedEmitted = true
                        state.pendingToolBubbleIDs.remove(ref.id)
                        entries.append(.toolResult(id: callID))
                    } else if !isTerminal {
                        state.pendingToolBubbleIDs.insert(ref.id)
                    }
                    state.toolStates[callID] = ts
                }
            } else if isFirstBubbleRead {
                sawNewPromptOrNonToolAI = true
                entries.append(.assistantOutput(contextTokens: nil))
            }
        }

        // Apply latest context token count (composerData takes precedence when populated).
        let effectiveContextTokens = composerContext ?? latestBubbleInputTokens
        if let tokens = effectiveContextTokens, tokens > 0, state.lastEmittedContextTokens != tokens {
            state.lastEmittedContextTokens = tokens
            entries.append(.assistantOutput(contextTokens: tokens))
        }

        let isGeneratingNow = Self.isComposerGenerating(composer)
        let composerStatus = (composer["status"] as? String)?.lowercased() ?? "none"
        let hasPendingTools = state.toolStates.values.contains { !$0.completedEmitted }

        if !isSeed {
            if isGeneratingNow && !state.wasGenerating && !state.tracker.turnActive {
                entries.append(.prompt)
            } else if !isGeneratingNow && !hasPendingTools && !sawTurnAbortOrQuota
                        && (state.wasGenerating || (sawNewPromptOrNonToolAI && composerStatus == "completed")) {
                if composerStatus == "aborted" || composerStatus == "cancelled" {
                    entries.append(.toolResult(id: nil))
                    entries.append(.turnEnd(isDone: false))
                } else {
                    entries.append(.toolResult(id: nil))
                    entries.append(.turnEnd(isDone: true))
                }
            }
        }
        state.wasGenerating = isGeneratingNow

        return entries
    }

    // MARK: - SQLite Query Helpers

    private static func tableExists(_ tableName: String, in db: OpaquePointer) -> Bool {
        var stmt: OpaquePointer?
        let sql = "SELECT 1 FROM sqlite_master WHERE type = 'table' AND name = ? LIMIT 1;"
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return false }
        defer { sqlite3_finalize(stmt) }
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        tableName.withCString { _ = sqlite3_bind_text(stmt, 1, $0, -1, transient) }
        return sqlite3_step(stmt) == SQLITE_ROW
    }

    private static func columnData(at index: Int32, in stmt: OpaquePointer) -> Data? {
        let type = sqlite3_column_type(stmt, index)
        switch type {
        case SQLITE_TEXT:
            guard let text = sqlite3_column_text(stmt, index) else { return nil }
            let byteCount = Int(sqlite3_column_bytes(stmt, index))
            return Data(bytes: text, count: byteCount)
        case SQLITE_BLOB:
            guard let blob = sqlite3_column_blob(stmt, index) else { return nil }
            let byteCount = Int(sqlite3_column_bytes(stmt, index))
            return Data(bytes: blob, count: byteCount)
        default:
            return nil
        }
    }

    private static func readComposerHeaders(in db: OpaquePointer) -> [[String: Any]]? {
        guard tableExists("ItemTable", in: db) else { return nil }
        var rawStmt: OpaquePointer?
        let sql = "SELECT value FROM ItemTable WHERE key = 'composer.composerHeaders' LIMIT 1;"
        guard sqlite3_prepare_v2(db, sql, -1, &rawStmt, nil) == SQLITE_OK, let stmt = rawStmt else { return nil }
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_step(stmt) == SQLITE_ROW,
              let data = columnData(at: 0, in: stmt),
              let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            return nil
        }
        return json["allComposers"] as? [[String: Any]]
    }

    private static func selectCandidateComposerIDs(
        fromHeaders headers: [[String: Any]],
        followedIDs: Set<String>,
        activeWindow: TimeInterval,
        now: Date
    ) -> [String] {
        var ids = followedIDs
        var newestID: String?
        var newestDate = Date.distantPast

        for header in headers {
            guard let composerID = header["composerId"] as? String,
                  composerID != "empty-state-draft",
                  !isSubagentOrDraft(header) else {
                continue
            }
            let updatedAt = composerUpdatedDate(header, fallback: nil) ?? .distantPast
            if updatedAt > newestDate {
                newestDate = updatedAt
                newestID = composerID
            }
            if now.timeIntervalSince(updatedAt) <= activeWindow {
                ids.insert(composerID)
            }
        }
        if ids.isEmpty, let newestID {
            ids.insert(newestID)
        }
        return ids.sorted()
    }

    private static func readComposerData(forIDs composerIDs: [String], in db: OpaquePointer) -> [(id: String, json: [String: Any])] {
        var result: [(id: String, json: [String: Any])] = []
        for composerID in composerIDs {
            let key = "composerData:\(composerID)"
            if let json = readKVJSON(forKey: key, in: db) {
                result.append((id: composerID, json: json))
            }
        }
        return result
    }

    private static func readAllComposerData(in db: OpaquePointer) -> [(id: String, json: [String: Any])] {
        var rawStmt: OpaquePointer?
        let sql = "SELECT key, value FROM cursorDiskKV WHERE key LIKE 'composerData:%' AND key != 'composerData:empty-state-draft';"
        guard sqlite3_prepare_v2(db, sql, -1, &rawStmt, nil) == SQLITE_OK, let stmt = rawStmt else { return [] }
        defer { sqlite3_finalize(stmt) }

        var result: [(id: String, json: [String: Any])] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            guard let keyC = sqlite3_column_text(stmt, 0),
                  let data = columnData(at: 1, in: stmt),
                  let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
                continue
            }
            let fullKey = String(cString: keyC)
            let composerID = String(fullKey.dropFirst("composerData:".count))
            if !composerID.isEmpty {
                result.append((id: composerID, json: json))
            }
        }
        return result
    }

    private static func readKVJSON(forKey key: String, in db: OpaquePointer) -> [String: Any]? {
        var rawStmt: OpaquePointer?
        let sql = "SELECT value FROM cursorDiskKV WHERE key = ? LIMIT 1;"
        guard sqlite3_prepare_v2(db, sql, -1, &rawStmt, nil) == SQLITE_OK, let stmt = rawStmt else { return nil }
        defer { sqlite3_finalize(stmt) }
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        key.withCString { _ = sqlite3_bind_text(stmt, 1, $0, -1, transient) }
        guard sqlite3_step(stmt) == SQLITE_ROW,
              let data = columnData(at: 0, in: stmt),
              let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            return nil
        }
        return json
    }

    private static func isSubagentOrDraft(_ composer: [String: Any]) -> Bool {
        if (composer["isDraft"] as? Bool) == true { return true }
        if (composer["isSubagent"] as? Bool) == true { return true }
        if let isSubInt = RateLimitParser.intValue(composer["isSubagent"]), isSubInt != 0 { return true }
        if composer["subagentInfo"] != nil && !(composer["subagentInfo"] is NSNull) { return true }
        return false
    }

    private static func composerUpdatedDate(_ composer: [String: Any], fallback: Date?) -> Date? {
        RateLimitParser.parseTimestamp(composer["lastUpdatedAt"])
            ?? RateLimitParser.parseTimestamp(composer["createdAt"])
            ?? RateLimitParser.parseTimestamp(composer["recency"])
            ?? fallback
    }

    private static func isComposerGenerating(_ composer: [String: Any]) -> Bool {
        if let status = (composer["status"] as? String)?.lowercased(), status == "generating" {
            return true
        }
        if let generating = composer["generatingBubbleIds"] as? [Any], !generating.isEmpty {
            return true
        }
        return false
    }

    private static func composerContextTokens(from composer: [String: Any]) -> Int? {
        if let used = RateLimitParser.intValue(composer["contextTokensUsed"]), used > 0 {
            return used
        }
        if let percent = RateLimitParser.numericValue(composer["contextUsagePercent"]),
           let limit = RateLimitParser.numericValue(composer["contextTokenLimit"]),
           percent > 0, limit > 0 {
            return Int((percent / 100.0) * limit)
        }
        return nil
    }

    private static func bubbleHeaders(from composer: [String: Any]) -> [(id: String, type: Int)] {
        guard let headers = composer["fullConversationHeadersOnly"] as? [[String: Any]] else {
            return []
        }
        return headers.compactMap { header in
            guard let id = header["bubbleId"] as? String else { return nil }
            let type = RateLimitParser.intValue(header["type"]) ?? 2
            return (id: id, type: type)
        }
    }

    private static func bubbleSignature(_ bubble: [String: Any]) -> Int {
        var hasher = Hasher()
        if let tool = bubble["toolFormerData"] as? [String: Any] {
            hasher.combine(tool["status"] as? String)
            hasher.combine(tool["name"] as? String)
            hasher.combine(tool["result"] != nil)
        }
        if let tokens = bubble["tokenCount"] as? [String: Any] {
            hasher.combine(RateLimitParser.intValue(tokens["inputTokens"]))
            hasher.combine(RateLimitParser.intValue(tokens["outputTokens"]))
        }
        hasher.combine(bubble["clientVisibleErrorMessage"] as? String)
        hasher.combine(bubble["actualErrorMessage"] as? String)
        hasher.combine((bubble["errorDetails"] as? [String: Any])?["message"] as? String)
        return hasher.finalize()
    }

    private static func parseJSONIfString(_ value: Any?) -> Any? {
        guard let str = value as? String,
              let data = str.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) else {
            return value
        }
        return json
    }

    // MARK: - Cursor Agent JSONL Transcripts (`~/.cursor/projects/*/agent-transcripts`)

    private func scanAndAttachJSONL(at now: Date, handler: @Sendable (AgentEvent) -> Void) -> Bool {
        let currentRootMod = SessionLogTail.modificationDate(projectsURL)
        guard let currentRootMod else {
            let hadState = cachedProjectsModified != nil || !cachedProjects.isEmpty
            cachedProjectsModified = nil
            cachedProjects.removeAll()
            return hadState
        }

        var changed = (currentRootMod != cachedProjectsModified)
        if cachedProjectsModified == nil || currentRootMod != cachedProjectsModified {
            cachedProjectsModified = currentRootMod
            let projectDirs = Self.subdirectories(at: projectsURL)
            var nextProjects: [URL: CachedTranscriptsDir] = [:]
            for dir in projectDirs {
                if let existing = cachedProjects[dir] {
                    nextProjects[dir] = existing
                } else {
                    changed = true
                    let transcriptsDir = dir.appendingPathComponent("agent-transcripts", isDirectory: true)
                    nextProjects[dir] = CachedTranscriptsDir(projectDir: dir, transcriptsDir: transcriptsDir)
                }
            }
            if nextProjects.count != cachedProjects.count {
                changed = true
            }
            cachedProjects = nextProjects
        }

        var candidates: [(sessionID: String, url: URL, modified: Date)] = []

        for projectKey in cachedProjects.keys {
            guard var project = cachedProjects[projectKey] else { continue }
            guard let dirMod = SessionLogTail.modificationDate(project.transcriptsDir) else {
                if project.modified != nil || !project.files.isEmpty {
                    changed = true
                }
                project.modified = nil
                project.nestedSessionDirs.removeAll()
                project.files.removeAll()
                cachedProjects[projectKey] = project
                continue
            }

            if project.modified != dirMod {
                changed = true
                project.modified = dirMod
                let entries = (try? FileManager.default.contentsOfDirectory(
                    at: project.transcriptsDir,
                    includingPropertiesForKeys: [.isDirectoryKey, .isRegularFileKey],
                    options: [.skipsHiddenFiles]
                )) ?? []
                var nextFiles: [URL: CachedJSONLFile] = [:]
                var nextDirs: [URL: CachedNestedDir] = [:]

                for item in entries {
                    let itemURL = item.standardizedFileURL
                    let values = try? itemURL.resourceValues(forKeys: [.isDirectoryKey, .isRegularFileKey])
                    if values?.isDirectory == true {
                        if itemURL.lastPathComponent == "subagents" { continue }
                        nextDirs[itemURL] = project.nestedSessionDirs[itemURL] ?? CachedNestedDir(modified: nil)
                    } else if values?.isRegularFile != false && itemURL.pathExtension == "jsonl" {
                        let sessionID = itemURL.deletingPathExtension().lastPathComponent
                        nextFiles[itemURL] = project.files[itemURL] ?? CachedJSONLFile(url: itemURL, sessionID: sessionID)
                    }
                }
                project.nestedSessionDirs = nextDirs
                // Preserve nested JSONL entries found below.
                for (url, file) in project.files where url.deletingLastPathComponent() != project.transcriptsDir {
                    if nextDirs[url.deletingLastPathComponent()] != nil {
                        nextFiles[url] = file
                    }
                }
                project.files = nextFiles
            }

            for dirURL in project.nestedSessionDirs.keys {
                let nestedMod = SessionLogTail.modificationDate(dirURL)
                if project.nestedSessionDirs[dirURL]?.modified != nestedMod {
                    changed = true
                    project.nestedSessionDirs[dirURL] = CachedNestedDir(modified: nestedMod)
                    if nestedMod != nil {
                        let nestedFiles = (try? FileManager.default.contentsOfDirectory(
                            at: dirURL,
                            includingPropertiesForKeys: [.isRegularFileKey],
                            options: [.skipsHiddenFiles]
                        )) ?? []
                        for item in nestedFiles {
                            let fileURL = item.standardizedFileURL
                            let isRegular = (try? fileURL.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) ?? true
                            if isRegular && fileURL.pathExtension == "jsonl" {
                                let sessionID = dirURL.lastPathComponent
                                project.files[fileURL] = project.files[fileURL] ?? CachedJSONLFile(
                                    url: fileURL,
                                    sessionID: sessionID
                                )
                            }
                        }
                    }
                }
            }

            for fileKey in project.files.keys {
                guard var cachedFile = project.files[fileKey] else { continue }
                guard let mod = SessionLogTail.modificationDate(fileKey) else {
                    changed = true
                    project.files.removeValue(forKey: fileKey)
                    continue
                }
                if cachedFile.modified != mod {
                    changed = true
                    cachedFile.modified = mod
                }
                project.files[fileKey] = cachedFile
                candidates.append((sessionID: cachedFile.sessionID, url: fileKey, modified: mod))
            }

            cachedProjects[projectKey] = project
        }

        let unattached = candidates.filter { followedJSONLSessions[$0.sessionID] == nil }
        let freshUnattached = unattached
            .filter { now.timeIntervalSince($0.modified) <= activeAttachWindow }
            .sorted { $0.modified < $1.modified }

        var attachedAny = false
        if !freshUnattached.isEmpty {
            for candidate in freshUnattached {
                attachJSONLSession(candidate, at: now, isStaleFallback: false, handler: handler)
                attachedAny = true
            }
        } else if followedJSONLSessions.isEmpty && sqliteSessions.isEmpty,
                  let newest = unattached.max(by: { $0.modified < $1.modified }) {
            attachJSONLSession(newest, at: now, isStaleFallback: true, handler: handler)
            attachedAny = true
        }

        return changed || attachedAny
    }

    private func attachJSONLSession(
        _ candidate: (sessionID: String, url: URL, modified: Date),
        at now: Date,
        isStaleFallback: Bool,
        handler: @Sendable (AgentEvent) -> Void
    ) {
        var tail = SessionLogTail()
        let seed = tail.attach(to: candidate.url)
        var tracker = AgentSessionTracker(
            agentID: agentID,
            agentName: agentName,
            startsTurnOnPrompt: true,
            sessionID: candidate.sessionID
        )
        tracker.prime(fromSeed: seed.lines.flatMap { Self.entries(fromLine: $0, referenceDate: now) })
        if isStaleFallback {
            tracker.markIdle()
        }
        let session = FollowedJSONLSession(
            sessionID: candidate.sessionID,
            url: candidate.url,
            tail: tail,
            tracker: tracker,
            lastActivityAt: candidate.modified
        )
        followedJSONLSessions[candidate.sessionID] = session
        handler(session.tracker.usageEvent(at: now, seed: true))
    }

    private static func subdirectories(at url: URL) -> [URL] {
        let entries = (try? FileManager.default.contentsOfDirectory(
            at: url,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        )) ?? []
        return entries.compactMap { item in
            let isDir = (try? item.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
            return isDir ? item.standardizedFileURL : nil
        }
    }

    private func pruneIdleSessions(at now: Date) {
        let total = sqliteSessions.count + followedJSONLSessions.count
        guard total > 1 else { return }

        var allRecency: [(key: String, isSQLite: Bool, date: Date, turnActive: Bool)] = []
        for s in sqliteSessions.values {
            allRecency.append((s.sessionID, true, s.lastActivityAt, s.tracker.turnActive))
        }
        for s in followedJSONLSessions.values {
            allRecency.append((s.sessionID, false, s.lastActivityAt, s.tracker.turnActive))
        }
        let sorted = allRecency.sorted { $0.date > $1.date }
        guard let newest = sorted.first else { return }

        for item in sorted {
            if item.key == newest.key && item.isSQLite == newest.isSQLite { continue }
            if !item.turnActive && now.timeIntervalSince(item.date) > Self.idleRetainWindow {
                if item.isSQLite {
                    sqliteSessions.removeValue(forKey: item.key)
                } else {
                    followedJSONLSessions.removeValue(forKey: item.key)
                }
            }
        }
    }

    // MARK: - JSONL Line Parser

    /// Parses one Cursor agent-transcript JSONL line into `SessionLogEntry` actions.
    public static func entries(fromLine data: Data, referenceDate: Date = Date()) -> [SessionLogEntry] {
        guard let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            return []
        }

        let lineDate = RateLimitParser.parseTimestamp(obj["timestamp"] ?? obj["createdAt"]) ?? referenceDate
        let type = obj["type"] as? String
        let status = (obj["status"] as? String)?.lowercased()
        let message = obj["message"] as? [String: Any]

        // Error / 429 lines.
        let explicitErrorTexts = RateLimitParser.collectErrorStrings(from: obj["error"])
            + RateLimitParser.collectErrorStrings(from: obj["errorDetails"])
            + RateLimitParser.collectErrorStrings(from: message?["error"])
        if type == "error" || status == "error" || !explicitErrorTexts.isEmpty {
            var errorTexts = explicitErrorTexts
            if type == "error" || status == "error" {
                errorTexts.append(contentsOf: RateLimitParser.collectErrorStrings(from: obj["content"]))
                errorTexts.append(contentsOf: RateLimitParser.collectErrorStrings(from: obj["message"]))
            }
            var codes: [Int] = []
            for key in ["statusCode", "status_code", "httpStatus", "code"] {
                if let code = RateLimitParser.intValue(obj[key]) {
                    codes.append(code)
                }
            }
            if RateLimitParser.isQuotaError(texts: errorTexts, statusCodes: codes) {
                let resetsAt = RateLimitParser.extractResetDate(in: obj, texts: errorTexts, referenceDate: lineDate)
                return [.toolResult(id: nil), .rateLimit(resetsAt: resetsAt), .turnEnd(isDone: false)]
            }
            if type == "error" || status == "error" {
                return [.toolResult(id: nil), .turnEnd(isDone: false)]
            }
        }

        let role = (obj["role"] as? String) ?? (message?["role"] as? String)
        let contentBlocks = ((message?["content"] ?? obj["content"]) as? [[String: Any]]) ?? []

        if role == "user" {
            let toolResults = contentBlocks.compactMap { block -> SessionLogEntry? in
                guard (block["type"] as? String) == "tool_result" else { return nil }
                return .toolResult(id: block["tool_use_id"] as? String)
            }
            if !toolResults.isEmpty {
                return toolResults
            }
            return [.toolResult(id: nil), .prompt]
        }

        if role == "tool" {
            let callID = obj["tool_call_id"] as? String
            return [.toolResult(id: callID)]
        }

        if role == "assistant" {
            let usage = (message?["usage"] as? [String: Any]) ?? (obj["usage"] as? [String: Any])
            let contextTokens = Self.jsonlContextTokens(from: usage, fallbackObj: obj)

            var entries: [SessionLogEntry] = [.assistantOutput(contextTokens: contextTokens)]
            var hasToolUse = false
            var hasTextBlock = false

            for block in contentBlocks {
                let blockType = block["type"] as? String
                if blockType == "tool_use" {
                    hasToolUse = true
                    let name = (block["name"] as? String) ?? "tool"
                    let callID = block["id"] as? String
                    entries.append(.toolCall(
                        id: callID,
                        name: name,
                        fingerprint: AgentSessionTracker.fingerprint(name: name, input: block["input"])
                    ))
                    let lowerName = name.lowercased()
                    if lowerName == "askuserquestion" || lowerName == "ask_question" {
                        entries.append(.approvalRequest)
                    }
                } else if blockType == "text" {
                    if let text = block["text"] as? String, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        hasTextBlock = true
                    }
                }
            }

            if contentBlocks.isEmpty,
               let textContent = (message?["content"] as? String) ?? (obj["content"] as? String),
               !textContent.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                hasTextBlock = true
            }

            let stopReason = (message?["stop_reason"] as? String) ?? (obj["stop_reason"] as? String)
            if let stopReason {
                if (stopReason == "end_turn" || stopReason == "stop") && !hasToolUse {
                    entries.append(.turnEnd(isDone: true))
                }
            } else if hasTextBlock && !hasToolUse {
                entries.append(.turnEnd(isDone: true))
            }

            return entries
        }

        return []
    }

    private static func jsonlContextTokens(from usage: [String: Any]?, fallbackObj: [String: Any]) -> Int? {
        if let direct = RateLimitParser.intValue(fallbackObj["contextTokens"] ?? fallbackObj["context_tokens"]) {
            return direct
        }
        guard let usage else { return nil }
        let input = RateLimitParser.intValue(usage["input_tokens"] ?? usage["inputTokens"])
        let cacheRead = RateLimitParser.intValue(usage["cache_read_input_tokens"] ?? usage["cacheReadTokens"]) ?? 0
        let cacheCreate = RateLimitParser.intValue(usage["cache_creation_input_tokens"] ?? usage["cacheCreationTokens"]) ?? 0
        guard let input else { return nil }
        return input + cacheRead + cacheCreate
    }
}
