import Foundation
import SQLite3

/// Agent adapter that monitors Antigravity's active top-level session transcripts (`transcript.jsonl`)
/// in `~/.gemini/antigravity/brain/<id>/.system_generated/logs/` concurrently (#153).
public final class AntigravityTranscriptAdapter: AgentAdapter, @unchecked Sendable {
    public let id: String = "antigravity-transcript-adapter"
    public let agentID: String = "antigravity"
    public let agentName: String = "Antigravity"

    /// Newly discovered transcripts modified within this window are attached immediately for concurrent tracking.
    public static let activeAttachWindow: TimeInterval = 300.0
    /// Finished transcripts idle longer than this window are pruned once at least one newer session remains.
    public static let idleRetainWindow: TimeInterval = 1800.0
    /// Grace window before consulting `conversation_summaries.db` to clear a user-cancelled turn.
    private static let idleCancellationGraceSeconds: TimeInterval = 3.0
    /// Minimum interval between `conversation_summaries.db` cancellation sweeps while another session is streaming.
    private static let idleReconcileMinIntervalSeconds: TimeInterval = 6.0

    public let baseBrainURL: URL
    public let conversationsDirectoryURL: URL?
    public let summariesDatabaseURL: URL
    public let pollInterval: TimeInterval
    public let maxIdleScanInterval: TimeInterval
    public let activeAttachWindow: TimeInterval
    private let clock: @Sendable () -> Date
    private var eventHandler: (@Sendable (AgentEvent) -> Void)?
    private var pollTask: Task<Void, Never>? = nil

    private let lock = NSLock()

    private enum SessionKind {
        case unknown
        case topLevel
        case subagent
    }

    private struct CachedSessionEntry {
        let sessionID: String
        let subdirURL: URL
        let logsDirURL: URL
        let transcriptURL: URL
        var subdirModified: Date?
        var logsDirModified: Date?
        var transcriptModified: Date?
        var sessionKind: SessionKind = .unknown
    }

    private struct DatabaseMarker: Equatable {
        let dbModified: Date?
        let walModified: Date?
    }

    private struct FollowedSession {
        let sessionID: String
        let subdirKey: URL
        let url: URL
        var tail: SessionLogTail
        var tracker: AgentSessionTracker
        var lastActivityAt: Date
        var confirmedTopLevel: Bool
        var isDatabaseAwaitingApproval: Bool = false
        var lastCheckedApprovalMarker: DatabaseMarker? = nil
    }

    private var followedSessions: [String: FollowedSession] = [:]
    private var cachedBrainModified: Date?
    private var cachedSummariesMarker = DatabaseMarker(dbModified: nil, walModified: nil)
    private var lastCheckedIdleSummariesMarker: DatabaseMarker?
    private var lastIdleReconcileTime: Date?
    private var cachedSubdirs: [URL: CachedSessionEntry] = [:]
    private var cachedCandidates: [(sessionID: String, subdirKey: URL, url: URL, modified: Date)] = []
    private var lastCandidateScanTime: Date?
    public private(set) var currentScanInterval: TimeInterval

    public static var defaultBrainURL: URL {
        let home = FileManager.default.homeDirectoryForCurrentUser
        return home.appendingPathComponent(".gemini/antigravity/brain")
    }

    public init(
        baseBrainURL: URL = AntigravityTranscriptAdapter.defaultBrainURL,
        conversationsDirectoryURL: URL? = nil,
        summariesDatabaseURL: URL? = nil,
        pollInterval: TimeInterval = 1.5,
        maxIdleScanInterval: TimeInterval = 30.0,
        activeAttachWindow: TimeInterval = AntigravityTranscriptAdapter.activeAttachWindow,
        clock: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.baseBrainURL = baseBrainURL
        self.conversationsDirectoryURL = conversationsDirectoryURL
            ?? baseBrainURL.deletingLastPathComponent().appendingPathComponent("conversations", isDirectory: true)
        self.summariesDatabaseURL = summariesDatabaseURL
            ?? baseBrainURL.deletingLastPathComponent().appendingPathComponent("conversation_summaries.db", isDirectory: false)
        self.pollInterval = pollInterval
        self.maxIdleScanInterval = max(pollInterval, maxIdleScanInterval)
        self.activeAttachWindow = max(pollInterval, activeAttachWindow)
        self.currentScanInterval = pollInterval
        self.clock = clock
    }

    public func setHandlerForTesting(_ onEvent: @escaping @Sendable (AgentEvent) -> Void) {
        lock.withLock { eventHandler = onEvent }
    }

    public func start(onEvent: @escaping @Sendable (AgentEvent) -> Void) {
        setHandlerForTesting(onEvent)

        // Attach to active transcripts; history primes turn state without emitting popup events (FR-014).
        checkForUpdates()

        let sleepNanoseconds = UInt64(pollInterval * 1_000_000_000)
        let task = Task { [weak self] in
            // Task.sleep throws once cancelled, which ends the loop.
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
            followedSessions.removeAll()
            cachedBrainModified = nil
            cachedSummariesMarker = DatabaseMarker(dbModified: nil, walModified: nil)
            lastCheckedIdleSummariesMarker = nil
            lastIdleReconcileTime = nil
            cachedSubdirs.removeAll()
            cachedCandidates.removeAll()
            lastCandidateScanTime = nil
            currentScanInterval = pollInterval
        }
    }

    /// Top-level `<brain>/<id>/.system_generated/logs/transcript.jsonl` candidates with their modification dates.
    public func sessionCandidates() -> [(url: URL, modified: Date)] {
        lock.withLock {
            refreshCandidates().candidates.map { (url: $0.url, modified: $0.modified) }
        }
    }

    /// Extracts the conversation UUID / directory name from `.../<sessionID>/.system_generated/logs/transcript.jsonl`.
    public static func sessionID(fromTranscriptURL url: URL) -> String? {
        let sessionDir = url
            .deletingLastPathComponent() // logs
            .deletingLastPathComponent() // .system_generated
            .deletingLastPathComponent() // <sessionID>
        let candidate = sessionDir.lastPathComponent
        guard !candidate.isEmpty, candidate != "/" else { return nil }
        return candidate
    }

    /// Classifies a transcript by inspecting its first complete JSONL line once.
    /// Spawned Antigravity subagents always begin at `step_index == 0` with `source == "SYSTEM"` and `type == "SYSTEM_MESSAGE"`.
    private static func classifyTranscript(at url: URL) -> SessionKind {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return .unknown }
        defer { try? handle.close() }

        var buffer = Data()
        let chunkSize = 16 * 1024
        let maxInspectBytes = 64 * 1024
        while buffer.count < maxInspectBytes {
            guard let chunk = try? handle.read(upToCount: chunkSize), !chunk.isEmpty else {
                break
            }
            buffer.append(chunk)
            if buffer.firstIndex(of: 0x0A) != nil {
                break
            }
        }

        guard !buffer.isEmpty else { return .unknown }
        guard let firstNewline = buffer.firstIndex(of: 0x0A) else {
            // Partial first line still being written (unless huge > 64 KB).
            return buffer.count >= maxInspectBytes ? .topLevel : .unknown
        }

        var lineSlice = buffer[..<firstNewline]
        if lineSlice.last == 0x0D {
            lineSlice = lineSlice.dropLast()
        }
        guard let obj = (try? JSONSerialization.jsonObject(with: Data(lineSlice))) as? [String: Any] else {
            return .topLevel
        }
        let stepIndex = obj["step_index"] as? Int
        let source = obj["source"] as? String
        let type = obj["type"] as? String
        if stepIndex == 0 && source == "SYSTEM" && type == "SYSTEM_MESSAGE" {
            return .subagent
        }
        return .topLevel
    }

    private func databaseMarker(for dbURL: URL) -> DatabaseMarker {
        let walURL = URL(fileURLWithPath: dbURL.path + "-wal")
        return DatabaseMarker(
            dbModified: SessionLogTail.modificationDate(dbURL),
            walModified: SessionLogTail.modificationDate(walURL)
        )
    }

    private func currentSummariesMarker() -> DatabaseMarker {
        databaseMarker(for: summariesDatabaseURL)
    }

    /// Incrementally scans `baseBrainURL`, skipping `contentsOfDirectory` when `baseBrainURL`'s mtime is unchanged,
    /// skipping subdirectories without transcripts whose directory mtimes have not changed (#126),
    /// and permanently skipping spawned subagent transcripts (#153).
    private func refreshCandidates() -> (candidates: [(sessionID: String, subdirKey: URL, url: URL, modified: Date)], changed: Bool) {
        guard let brainModified = SessionLogTail.modificationDate(baseBrainURL) else {
            let hadCandidates = !cachedCandidates.isEmpty
            cachedBrainModified = nil
            cachedSubdirs.removeAll()
            cachedCandidates.removeAll()
            return ([], hadCandidates)
        }

        var changed = false

        if cachedBrainModified != brainModified || cachedSubdirs.isEmpty {
            let fileManager = FileManager.default
            guard let subdirs = try? fileManager.contentsOfDirectory(at: baseBrainURL, includingPropertiesForKeys: nil) else {
                let hadCandidates = !cachedCandidates.isEmpty
                cachedBrainModified = nil
                cachedSubdirs.removeAll()
                cachedCandidates.removeAll()
                return ([], hadCandidates)
            }

            var updatedMap: [URL: CachedSessionEntry] = [:]
            updatedMap.reserveCapacity(subdirs.count)
            for subdir in subdirs {
                let key = subdir.standardizedFileURL
                if let existing = cachedSubdirs[key] {
                    updatedMap[key] = existing
                } else {
                    changed = true
                    let logsDir = subdir.appendingPathComponent(".system_generated/logs", isDirectory: true)
                    let transcript = logsDir.appendingPathComponent("transcript.jsonl", isDirectory: false)
                    updatedMap[key] = CachedSessionEntry(
                        sessionID: subdir.lastPathComponent,
                        subdirURL: subdir,
                        logsDirURL: logsDir,
                        transcriptURL: transcript
                    )
                }
            }
            if updatedMap.count != cachedSubdirs.count {
                changed = true
            }
            cachedSubdirs = updatedMap
            cachedBrainModified = brainModified
        }

        var updatedCandidates: [(sessionID: String, subdirKey: URL, url: URL, modified: Date)] = []
        updatedCandidates.reserveCapacity(cachedSubdirs.count)

        for (key, var entry) in cachedSubdirs {
            if entry.sessionKind == .subagent {
                continue
            }

            if entry.transcriptModified == nil {
                if let prevLogsMod = entry.logsDirModified {
                    let currentLogsMod = SessionLogTail.modificationDate(entry.logsDirURL)
                    if currentLogsMod == prevLogsMod {
                        continue
                    }
                    entry.logsDirModified = currentLogsMod
                } else if let prevSubdirMod = entry.subdirModified {
                    let currentSubdirMod = SessionLogTail.modificationDate(entry.subdirURL)
                    if currentSubdirMod == prevSubdirMod {
                        continue
                    }
                    entry.subdirModified = currentSubdirMod
                    entry.logsDirModified = SessionLogTail.modificationDate(entry.logsDirURL)
                    if entry.logsDirModified == nil {
                        cachedSubdirs[key] = entry
                        continue
                    }
                } else {
                    entry.subdirModified = SessionLogTail.modificationDate(entry.subdirURL)
                    entry.logsDirModified = SessionLogTail.modificationDate(entry.logsDirURL)
                    if entry.logsDirModified == nil {
                        cachedSubdirs[key] = entry
                        continue
                    }
                }
            }

            let currentTranscriptMod = SessionLogTail.modificationDate(entry.transcriptURL)
            if currentTranscriptMod != entry.transcriptModified {
                changed = true
                entry.transcriptModified = currentTranscriptMod
            }
            if currentTranscriptMod != nil && entry.sessionKind == .unknown {
                entry.sessionKind = Self.classifyTranscript(at: entry.transcriptURL)
            }
            cachedSubdirs[key] = entry
            if entry.sessionKind != .subagent, let mod = currentTranscriptMod {
                updatedCandidates.append((sessionID: entry.sessionID, subdirKey: key, url: entry.transcriptURL, modified: mod))
            }
        }

        cachedCandidates = updatedCandidates
        return (updatedCandidates, changed)
    }

    private func shouldScanCandidates(at now: Date) -> Bool {
        guard let lastScan = lastCandidateScanTime else { return true }
        if SessionLogTail.modificationDate(baseBrainURL) != cachedBrainModified {
            return true
        }
        let elapsed = now.timeIntervalSince(lastScan)
        if elapsed < 0 || elapsed >= currentScanInterval {
            return true
        }
        // Only use `conversation_summaries.db` mtime to break out of idle backoff early (still respecting base pollInterval).
        if currentScanInterval > pollInterval && elapsed >= pollInterval && currentSummariesMarker() != cachedSummariesMarker {
            return true
        }
        return false
    }

    /// One poll: attach any newly active top-level sessions, ingest appended lines across all followed sessions,
    /// reconcile cancelled turns, and prune long-idle sessions (#153).
    public func checkForUpdates() {
        lock.lock()
        defer { lock.unlock() }

        guard let handler = eventHandler else { return }
        let now = clock()

        let shouldScan = shouldScanCandidates(at: now)
        var scanChanged = false
        var attachedAny = false

        if shouldScan {
            let scan = refreshCandidates()
            lastCandidateScanTime = now
            cachedSummariesMarker = currentSummariesMarker()
            scanChanged = scan.changed

            let unattached = scan.candidates.filter { followedSessions[$0.sessionID] == nil }
            let selection = AgentSessionTracker.selectUnattachedCandidates(
                from: unattached,
                followedIsEmpty: followedSessions.isEmpty,
                activeAttachWindow: activeAttachWindow,
                now: now,
                modified: \.modified
            )
            for candidate in selection.candidates {
                attachSession(candidate, at: now, isStaleFallback: selection.isStaleFallback, handler: handler)
                attachedAny = true
            }
        }

        var anyGrew = false
        var anyApprovalChanged = false
        let orderedIDs = followedSessions.keys.sorted()
        for sessionID in orderedIDs {
            guard var session = followedSessions[sessionID] else { continue }
            let read = session.tail.readNew()
            if read.grew {
                if !session.confirmedTopLevel {
                    let kind = Self.classifyTranscript(at: session.url)
                    if kind == .subagent {
                        cachedSubdirs[session.subdirKey]?.sessionKind = .subagent
                        cachedCandidates.removeAll { $0.sessionID == sessionID }
                        followedSessions.removeValue(forKey: sessionID)
                        continue
                    } else if kind == .topLevel {
                        session.confirmedTopLevel = true
                        cachedSubdirs[session.subdirKey]?.sessionKind = .topLevel
                    }
                }

                anyGrew = true
                session.lastActivityAt = now
                var newEntries = read.lines.flatMap { Self.parseEntries(fromLine: $0, referenceDate: now) }
                if !session.tracker.turnActive,
                   !newEntries.contains(.prompt),
                   newEntries.last != .turnEnd(isDone: true),
                   newEntries.contains(where: { if case .toolCall = $0 { true } else { false } }) {
                    newEntries.insert(.prompt, at: 0)
                }
                let events = session.tracker.ingest(newEntries, at: now)
                for event in events {
                    if event.kind == .working || event.kind == .done {
                        session.isDatabaseAwaitingApproval = false
                    }
                    handler(event)
                }
                handler(session.tracker.usageEvent(at: now, seed: false))
            }

            if session.confirmedTopLevel || cachedSubdirs[session.subdirKey]?.sessionKind != .subagent {
                if checkApprovalStatus(for: &session, at: now, handler: handler) {
                    anyApprovalChanged = true
                }
            }
            followedSessions[sessionID] = session
        }

        let cancelledAny = reconcileIdleSummariesIfNeeded(at: now, handler: handler)

        currentScanInterval = AgentSessionTracker.nextScanInterval(
            current: currentScanInterval,
            base: pollInterval,
            max: maxIdleScanInterval,
            hadActivity: anyGrew || attachedAny || cancelledAny || anyApprovalChanged || (shouldScan && scanChanged),
            didScan: shouldScan
        )

        pruneIdleSessions(at: now)
    }

    private func attachSession(
        _ candidate: (sessionID: String, subdirKey: URL, url: URL, modified: Date),
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
        // History primes turn state silently, so a turn in progress still ends in done (FR-014).
        let seedEntries = seed.lines.flatMap(Self.entries(fromLine:))
        tracker.prime(fromSeed: seedEntries)
        if isStaleFallback {
            // Do not mark an old historic crashed transcript (> activeAttachWindow) as actively running on cold start.
            tracker.markIdle()
        } else if !tracker.turnActive,
                  seedEntries.last != .turnEnd(isDone: true),
                  seedEntries.contains(where: { if case .toolCall = $0 { true } else { false } }) {
            tracker = AgentSessionTracker(
                agentID: agentID,
                agentName: agentName,
                startsTurnOnPrompt: true,
                sessionID: candidate.sessionID
            )
            tracker.prime(fromSeed: [.prompt] + seedEntries)
        }
        let kind = cachedSubdirs[candidate.subdirKey]?.sessionKind ?? .unknown
        var session = FollowedSession(
            sessionID: candidate.sessionID,
            subdirKey: candidate.subdirKey,
            url: candidate.url,
            tail: tail,
            tracker: tracker,
            lastActivityAt: candidate.modified,
            confirmedTopLevel: kind == .topLevel
        )
        handler(session.tracker.usageEvent(at: now, seed: true))
        if !isStaleFallback {
            _ = checkApprovalStatus(for: &session, forceInitialCheck: true, at: now, handler: handler)
        }
        followedSessions[candidate.sessionID] = session
    }

    private func databaseURL(forSessionID sessionID: String) -> URL? {
        guard let conversationsDir = conversationsDirectoryURL else { return nil }
        return conversationsDir.appendingPathComponent("\(sessionID).db", isDirectory: false)
    }

    /// Checks if the session's SQLite database has an active step waiting for user input or approval (status == 9).
    public static func isSessionWaitingForApproval(databaseURL: URL) -> Bool {
        guard FileManager.default.fileExists(atPath: databaseURL.path) else { return false }
        var db: OpaquePointer?
        guard sqlite3_open_v2(databaseURL.path, &db, SQLITE_OPEN_READONLY | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK else {
            return false
        }
        defer { sqlite3_close(db) }
        sqlite3_busy_timeout(db, 20)

        var stmt: OpaquePointer?
        let query = "SELECT 1 FROM steps WHERE status = 9 LIMIT 1;"
        guard sqlite3_prepare_v2(db, query, -1, &stmt, nil) == SQLITE_OK else {
            return false
        }
        defer { sqlite3_finalize(stmt) }

        return sqlite3_step(stmt) == SQLITE_ROW
    }

    @discardableResult
    private func checkApprovalStatus(
        for session: inout FollowedSession,
        forceInitialCheck: Bool = false,
        at now: Date,
        handler: @Sendable (AgentEvent) -> Void
    ) -> Bool {
        guard forceInitialCheck || session.tracker.turnActive || session.isDatabaseAwaitingApproval else {
            return false
        }
        guard let dbURL = databaseURL(forSessionID: session.sessionID) else {
            return false
        }
        let marker = databaseMarker(for: dbURL)
        guard marker.dbModified != nil else {
            return false
        }
        if !forceInitialCheck, session.lastCheckedApprovalMarker == marker {
            return false
        }
        session.lastCheckedApprovalMarker = marker

        let isWaiting = Self.isSessionWaitingForApproval(databaseURL: dbURL)
        let metadata = [AgentEvent.MetadataKey.sessionID: session.sessionID]
        if isWaiting && !session.isDatabaseAwaitingApproval {
            session.isDatabaseAwaitingApproval = true
            session.lastActivityAt = now
            handler(AgentEvent(
                agentID: agentID,
                agentName: agentName,
                kind: .needsApproval,
                message: "\(agentName) needs your approval!",
                timestamp: now,
                metadata: metadata
            ))
            return true
        } else if !isWaiting && session.isDatabaseAwaitingApproval {
            session.isDatabaseAwaitingApproval = false
            session.lastActivityAt = now
            if session.tracker.turnActive {
                handler(AgentEvent(
                    agentID: agentID,
                    agentName: agentName,
                    kind: .working,
                    message: "\(agentName) is working...",
                    timestamp: now,
                    metadata: metadata
                ))
            } else {
                handler(session.tracker.usageEvent(at: now, seed: false))
            }
            return true
        }
        return false
    }

    /// Consults `conversation_summaries.db` (read-only) when a followed session appears `turnActive` but has had no
    /// transcript writes for at least `idleCancellationGraceSeconds`, clearing turns cancelled by the user in Antigravity.
    private func reconcileIdleSummariesIfNeeded(
        at now: Date,
        handler: @Sendable (AgentEvent) -> Void
    ) -> Bool {
        let candidateIDs = followedSessions.values
            .filter {
                $0.tracker.turnActive
                    && !$0.isDatabaseAwaitingApproval
                    && now.timeIntervalSince($0.lastActivityAt) >= Self.idleCancellationGraceSeconds
            }
            .map(\.sessionID)
            .sorted()
        guard !candidateIDs.isEmpty else {
            lastCheckedIdleSummariesMarker = nil
            return false
        }

        let marker = currentSummariesMarker()
        guard marker.dbModified != nil else { return false }
        if lastCheckedIdleSummariesMarker == marker {
            return false
        }
        if let lastReconcile = lastIdleReconcileTime,
           now.timeIntervalSince(lastReconcile) >= 0,
           now.timeIntervalSince(lastReconcile) < Self.idleReconcileMinIntervalSeconds {
            return false
        }
        lastCheckedIdleSummariesMarker = marker
        lastIdleReconcileTime = now

        let statuses = Self.queryRunStatuses(for: candidateIDs, summariesDatabaseURL: summariesDatabaseURL)
        var clearedAny = false
        for sessionID in candidateIDs {
            guard statuses[sessionID] == "CASCADE_RUN_STATUS_IDLE",
                  var session = followedSessions[sessionID],
                  session.tracker.turnActive else {
                continue
            }
            session.tracker.markIdle()
            followedSessions[sessionID] = session
            handler(session.tracker.usageEvent(at: now, seed: false))
            clearedAny = true
        }
        return clearedAny
    }

    /// Queries `status` from `conversation_summaries` for the requested conversation IDs in a single read-only connection.
    public static func queryRunStatuses(
        for sessionIDs: [String],
        summariesDatabaseURL: URL
    ) -> [String: String] {
        guard !sessionIDs.isEmpty,
              FileManager.default.fileExists(atPath: summariesDatabaseURL.path) else {
            return [:]
        }
        var db: OpaquePointer?
        guard sqlite3_open_v2(summariesDatabaseURL.path, &db, SQLITE_OPEN_READONLY | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK else {
            return [:]
        }
        defer { sqlite3_close(db) }
        sqlite3_busy_timeout(db, 20)

        var stmt: OpaquePointer?
        let sql = "SELECT status FROM conversation_summaries WHERE conversation_id = ? LIMIT 1;"
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            return [:]
        }
        defer { sqlite3_finalize(stmt) }

        var result: [String: String] = [:]
        let sqliteTransient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        for sessionID in sessionIDs {
            sqlite3_reset(stmt)
            sqlite3_clear_bindings(stmt)
            _ = sessionID.withCString { cStr in
                sqlite3_bind_text(stmt, 1, cStr, -1, sqliteTransient)
            }
            if sqlite3_step(stmt) == SQLITE_ROW, let cText = sqlite3_column_text(stmt, 0) {
                result[sessionID] = String(cString: cText)
            }
        }
        return result
    }

    private func pruneIdleSessions(at now: Date) {
        let staleIDs = AgentSessionTracker.idleSessionIDsToPrune(
            from: followedSessions,
            retainWindow: Self.idleRetainWindow,
            now: now,
            lastActivityAt: \.lastActivityAt,
            isBusy: { $0.tracker.turnActive || $0.isDatabaseAwaitingApproval }
        )
        for id in staleIDs {
            followedSessions.removeValue(forKey: id)
        }
    }

    /// Maps one Antigravity transcript line to tracker entries; unknown lines yield [.toolResult(id: nil)] only.
    public static func entries(fromLine data: Data) -> [SessionLogEntry] {
        parseEntries(fromLine: data, referenceDate: Date())
    }

    static func parseEntries(fromLine data: Data, referenceDate: Date) -> [SessionLogEntry] {
        guard let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return [] }

        // Tool calls carry no ids, so any later line means the previous calls finished (R5).
        var entries: [SessionLogEntry] = [.toolResult(id: nil)]
        let type = obj["type"] as? String
        let status = obj["status"] as? String
        let toolCalls = obj["tool_calls"] as? [[String: Any]] ?? []

        // Quota / 429 rate-limit detection on error steps only (avoids false positives in prompts or normal stdout).
        let explicitErrorStrings = RateLimitParser.collectErrorStrings(from: obj["error"])
        let isErrorLine = (type == "ERROR_MESSAGE" || type == "ERROR" || status == "ERROR" || !explicitErrorStrings.isEmpty)
        if isErrorLine {
            var errorTexts = explicitErrorStrings
            if type == "ERROR_MESSAGE" || type == "ERROR" || status == "ERROR" {
                errorTexts.append(contentsOf: RateLimitParser.collectErrorStrings(from: obj["content"]))
                errorTexts.append(contentsOf: RateLimitParser.collectErrorStrings(from: obj["message"]))
                errorTexts.append(contentsOf: RateLimitParser.collectErrorStrings(from: obj["details"]))
            }
            var statusCodes: [Int] = []
            for key in ["statusCode", "status_code", "httpStatus", "http_status", "code"] {
                if let code = RateLimitParser.intValue(obj[key]) {
                    statusCodes.append(code)
                }
            }
            if let errorDict = obj["error"] as? [String: Any] {
                for key in ["statusCode", "status_code", "httpStatus", "http_status", "code"] {
                    if let code = RateLimitParser.intValue(errorDict[key]) {
                        statusCodes.append(code)
                    }
                }
            }
            if RateLimitParser.isQuotaError(texts: errorTexts, statusCodes: statusCodes) {
                let lineDate = RateLimitParser.parseTimestamp(obj["created_at"] ?? obj["timestamp"]) ?? referenceDate
                let resetsAt = RateLimitParser.extractResetDate(
                    in: obj,
                    texts: errorTexts,
                    referenceDate: lineDate
                )
                return [.toolResult(id: nil), .rateLimit(resetsAt: resetsAt), .turnEnd(isDone: false)]
            }
        }

        let stepIndex = obj["step_index"] as? Int ?? 0
        if type == "USER_INPUT" || (type == "SYSTEM_MESSAGE" && stepIndex > 0) {
            entries.append(.prompt)
        } else if type == "PLANNER_RESPONSE" {
            // Context = input + cache read (R3).
            let input = obj["input_tokens"] as? Int
            let cacheRead = obj["cache_read_tokens"] as? Int
            entries.append(.assistantOutput(
                contextTokens: input == nil && cacheRead == nil ? nil : (input ?? 0) + (cacheRead ?? 0)
            ))

            let hasAskQuestion = toolCalls.contains { call in
                // Support both flat Antigravity format {"name": "ask_question"}
                // and OpenAI/legacy format {"function": {"name": "ask_question"}}
                if let name = call["name"] as? String, name == "ask_question" {
                    return true
                }
                if let function = call["function"] as? [String: Any],
                   let name = function["name"] as? String,
                   name == "ask_question" {
                    return true
                }
                return false
            }

            if hasAskQuestion {
                entries.append(.approvalRequest)
            }
            for call in toolCalls {
                guard let name = call["name"] as? String else { continue }
                entries.append(.toolCall(
                    id: nil, name: name, fingerprint: AgentSessionTracker.fingerprint(name: name, input: call["args"])
                ))
            }
            if status == "DONE" && toolCalls.isEmpty {
                entries.append(.turnEnd(isDone: true))
            }
        }
        return entries
    }
}
