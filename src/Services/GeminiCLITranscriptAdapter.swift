import Foundation

/// Reads Gemini CLI transcript files (`~/.gemini/tmp/<project_hash>/chats/session-*.jsonl` and legacy `session-*.json`)
/// incrementally using mtime/size gating and exponential idle scan backoff.
/// Read-only on `~/.gemini/tmp`; tracks concurrent active sessions keyed by `sessionID`.
public final class GeminiCLITranscriptAdapter: AgentAdapter, @unchecked Sendable {
    public static let activeAttachWindow: TimeInterval = 300.0
    public static let idleRetainWindow: TimeInterval = 1800.0

    public let id = "gemini-transcript"
    public let agentID = "gemini"
    public let agentName = "Gemini"

    private let baseRootURL: URL
    private let pollInterval: TimeInterval
    private let maxIdleScanInterval: TimeInterval
    private let activeAttachWindow: TimeInterval
    private let clock: @Sendable () -> Date

    private let lock = NSLock()
    private var pollTask: Task<Void, Never>?
    private var eventHandler: (@Sendable (AgentEvent) -> Void)?

    private enum SessionKind: Equatable {
        case unknown
        case topLevel
        case subagent
    }

    private enum FileFormat: Equatable {
        case jsonl
        case jsonSnapshot
    }

    private struct FileCandidate {
        let sessionID: String
        let projectDir: URL
        let url: URL
        let format: FileFormat
        var modified: Date
        var size: UInt64
    }

    private struct CachedProjectDir {
        let projectDir: URL
        let chatsDir: URL
        var chatsModified: Date?
        var files: [URL: CachedChatFile] = [:]
    }

    private struct CachedChatFile {
        let url: URL
        let sessionID: String
        let format: FileFormat
        var modified: Date?
        var size: UInt64
        var sessionKind: SessionKind = .unknown
    }

    private struct MessageDeduplicator {
        private static let maxSetSize = 2_048

        var seenPromptIDs: Set<String> = []
        var emittedContextTokensByMsgID: [String: Int] = [:]
        var seenGeminiMsgIDs: Set<String> = []
        var seenToolCallIDs: Set<String> = []
        var completedToolCallIDs: Set<String> = []
        var awaitingApprovalToolCallIDs: Set<String> = []
        var emittedTurnEndMsgIDs: Set<String> = []
        var handledErrorKeys: Set<Data> = []
        var handledInfoKeys: Set<Data> = []

        mutating func pruneIfOversized() {
            if seenPromptIDs.count > Self.maxSetSize { seenPromptIDs.removeAll(keepingCapacity: true) }
            if emittedContextTokensByMsgID.count > Self.maxSetSize { emittedContextTokensByMsgID.removeAll(keepingCapacity: true) }
            if seenGeminiMsgIDs.count > Self.maxSetSize { seenGeminiMsgIDs.removeAll(keepingCapacity: true) }
            if seenToolCallIDs.count > Self.maxSetSize {
                let inFlightToolIDs = seenToolCallIDs.subtracting(completedToolCallIDs)
                seenToolCallIDs = inFlightToolIDs.count > Self.maxSetSize
                    ? Set(inFlightToolIDs.prefix(Self.maxSetSize))
                    : inFlightToolIDs
            }
            if completedToolCallIDs.count > Self.maxSetSize { completedToolCallIDs.removeAll(keepingCapacity: true) }
            if awaitingApprovalToolCallIDs.count > Self.maxSetSize { awaitingApprovalToolCallIDs.removeAll(keepingCapacity: true) }
            if emittedTurnEndMsgIDs.count > Self.maxSetSize { emittedTurnEndMsgIDs.removeAll(keepingCapacity: true) }
            if handledErrorKeys.count > Self.maxSetSize { handledErrorKeys.removeAll(keepingCapacity: true) }
            if handledInfoKeys.count > Self.maxSetSize { handledInfoKeys.removeAll(keepingCapacity: true) }
        }
    }

    private struct FollowedSession {
        let sessionID: String
        let projectDir: URL
        let url: URL
        let format: FileFormat
        var tail: SessionLogTail
        var lastSnapshotMeta: (size: UInt64, modified: Date)?
        var lastSnapshotMessageCount: Int = 0
        var tracker: AgentSessionTracker
        var deduplicator: MessageDeduplicator
        var lastActivityAt: Date
        var confirmedTopLevel: Bool
    }

    private var cachedRootModified: Date?
    private var cachedProjects: [URL: CachedProjectDir] = [:]
    private var cachedCandidates: [FileCandidate] = []
    private var lastCandidateScanTime: Date?
    private var currentScanInterval: TimeInterval
    private var scanCount = 0
    private var followedSessions: [String: FollowedSession] = [:]

    public static var defaultRootURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".gemini/tmp", isDirectory: true)
    }

    public init(
        baseRootURL: URL = GeminiCLITranscriptAdapter.defaultRootURL,
        pollInterval: TimeInterval = 1.5,
        maxIdleScanInterval: TimeInterval = 30.0,
        activeAttachWindow: TimeInterval = GeminiCLITranscriptAdapter.activeAttachWindow,
        clock: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.baseRootURL = baseRootURL
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
        lock.withLock { followedSessions.keys.sorted() }
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
            followedSessions.removeAll()
            cachedRootModified = nil
            cachedProjects.removeAll()
            cachedCandidates.removeAll()
            lastCandidateScanTime = nil
            currentScanInterval = pollInterval
            scanCount = 0
        }
    }

    public func sessionCandidates() -> [(url: URL, modified: Date)] {
        lock.withLock {
            refreshCandidates().candidates.map { (url: $0.url, modified: $0.modified) }
        }
    }

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
            scanCount += 1
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
        for sessionID in followedSessions.keys.sorted() {
            guard var session = followedSessions[sessionID] else { continue }
            let update = readSessionDelta(&session, at: now)
            if update.becameSubagent {
                followedSessions.removeValue(forKey: sessionID)
                cachedCandidates.removeAll { $0.sessionID == sessionID }
                continue
            }
            if update.grew {
                anyGrew = true
                session.lastActivityAt = now
                let events = session.tracker.ingest(update.entries, at: now)
                for event in events {
                    handler(event)
                }
                handler(session.tracker.usageEvent(at: now, seed: false))
            }
            followedSessions[sessionID] = session
        }

        currentScanInterval = AgentSessionTracker.nextScanInterval(
            current: currentScanInterval,
            base: pollInterval,
            max: maxIdleScanInterval,
            hadActivity: anyGrew || attachedAny || (shouldScan && scanChanged),
            didScan: shouldScan
        )

        pruneIdleSessions(at: now)
    }

    // MARK: - Candidate Discovery & Caching

    private func shouldScanCandidates(at now: Date) -> Bool {
        guard let lastScan = lastCandidateScanTime else { return true }
        let elapsed = now.timeIntervalSince(lastScan)
        // Missing root directory: perform at most one stat per backed-off interval (up to maxIdleScanInterval).
        if cachedRootModified == nil {
            return elapsed < 0 || elapsed >= currentScanInterval
        }
        if elapsed < 0 || elapsed >= currentScanInterval {
            return true
        }
        // Existing root directory: break out of backoff immediately if root itself gained a new project dir.
        if SessionLogTail.modificationDate(baseRootURL) != cachedRootModified {
            return true
        }
        return false
    }

    private func refreshCandidates() -> (candidates: [FileCandidate], changed: Bool) {
        let currentRootMod = SessionLogTail.modificationDate(baseRootURL)
        guard let currentRootMod else {
            let hadState = cachedRootModified != nil || !cachedProjects.isEmpty || !cachedCandidates.isEmpty
            cachedRootModified = nil
            cachedProjects.removeAll()
            cachedCandidates.removeAll()
            return ([], hadState)
        }

        var changed = (currentRootMod != cachedRootModified)
        if cachedRootModified == nil || currentRootMod != cachedRootModified {
            let subdirs = (try? FileManager.default.contentsOfDirectory(
                at: baseRootURL,
                includingPropertiesForKeys: [.isDirectoryKey],
                options: [.skipsHiddenFiles]
            )) ?? []
            var nextProjects: [URL: CachedProjectDir] = [:]
            for url in subdirs {
                let isDir = (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
                guard isDir else { continue }
                let key = url.standardizedFileURL
                if let existing = cachedProjects[key] {
                    nextProjects[key] = existing
                } else {
                    changed = true
                    let chatsDir = key.appendingPathComponent("chats", isDirectory: true)
                    nextProjects[key] = CachedProjectDir(projectDir: key, chatsDir: chatsDir)
                }
            }
            if nextProjects.count != cachedProjects.count {
                changed = true
            }
            cachedProjects = nextProjects
            cachedRootModified = currentRootMod
        }

        var bySessionID: [String: FileCandidate] = [:]
        for projectKey in cachedProjects.keys {
            guard var project = cachedProjects[projectKey] else { continue }
            let chatsMod = SessionLogTail.modificationDate(project.chatsDir)
            if chatsMod == nil {
                if project.chatsModified != nil || !project.files.isEmpty {
                    changed = true
                }
                project.chatsModified = nil
                project.files.removeAll()
                cachedProjects[projectKey] = project
                continue
            }

            if project.chatsModified != chatsMod {
                changed = true
                project.chatsModified = chatsMod
                let entries = (try? FileManager.default.contentsOfDirectory(
                    at: project.chatsDir,
                    includingPropertiesForKeys: [.isRegularFileKey],
                    options: [.skipsHiddenFiles]
                )) ?? []
                var nextFiles: [URL: CachedChatFile] = [:]
                for fileURL in entries {
                    let isRegular = (try? fileURL.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) ?? true
                    guard isRegular,
                          let info = Self.parseChatFilename(fileURL) else {
                        continue
                    }
                    let fileKey = fileURL.standardizedFileURL
                    if let existing = project.files[fileKey] {
                        nextFiles[fileKey] = existing
                    } else {
                        nextFiles[fileKey] = CachedChatFile(
                            url: fileKey,
                            sessionID: info.sessionID,
                            format: info.format,
                            modified: nil,
                            size: 0,
                            sessionKind: .unknown
                        )
                    }
                }
                project.files = nextFiles
            }

            for fileKey in project.files.keys {
                guard var cachedFile = project.files[fileKey] else { continue }
                guard let meta = SessionLogTail.fileMetadata(fileKey) else {
                    changed = true
                    project.files.removeValue(forKey: fileKey)
                    continue
                }
                if cachedFile.modified != meta.modified || cachedFile.size != meta.size {
                    changed = true
                    cachedFile.modified = meta.modified
                    cachedFile.size = meta.size
                    if cachedFile.sessionKind == .unknown {
                        cachedFile.sessionKind = Self.classifyFile(at: fileKey, format: cachedFile.format)
                    }
                } else if cachedFile.sessionKind == .unknown {
                    cachedFile.sessionKind = Self.classifyFile(at: fileKey, format: cachedFile.format)
                }
                project.files[fileKey] = cachedFile

                guard cachedFile.sessionKind != .subagent else { continue }
                let candidate = FileCandidate(
                    sessionID: cachedFile.sessionID,
                    projectDir: projectKey,
                    url: fileKey,
                    format: cachedFile.format,
                    modified: meta.modified,
                    size: meta.size
                )
                if let existing = bySessionID[candidate.sessionID] {
                    // Prefer newer modification date, or .jsonl over .json on ties.
                    if candidate.modified > existing.modified
                        || (candidate.modified == existing.modified && candidate.format == .jsonl && existing.format == .jsonSnapshot) {
                        bySessionID[candidate.sessionID] = candidate
                    }
                } else {
                    bySessionID[candidate.sessionID] = candidate
                }
            }

            cachedProjects[projectKey] = project
        }

        let candidates = bySessionID.values.sorted { $0.sessionID < $1.sessionID }
        cachedCandidates = candidates
        return (candidates, changed)
    }

    private static func parseChatFilename(_ url: URL) -> (sessionID: String, format: FileFormat)? {
        let name = url.lastPathComponent
        guard name.hasPrefix("session-") else { return nil }
        let format: FileFormat
        let stem: String
        if name.hasSuffix(".jsonl") {
            format = .jsonl
            stem = String(name.dropLast(".jsonl".count))
        } else if name.hasSuffix(".json") {
            format = .jsonSnapshot
            stem = String(name.dropLast(".json".count))
        } else {
            return nil
        }
        guard !stem.isEmpty else { return nil }
        return (sessionID: stem, format: format)
    }

    private static func classifyFile(at url: URL, format: FileFormat) -> SessionKind {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return .unknown }
        defer { try? handle.close() }
        // Only the head object / first line contains the session `kind` field.
        let headData = (try? handle.read(upToCount: 4096)) ?? Data()
        guard !headData.isEmpty else { return .unknown }

        switch format {
        case .jsonl:
            let lineData: Data
            if let newline = headData.firstIndex(of: 0x0A) {
                lineData = headData[..<newline]
            } else {
                lineData = headData
            }
            guard let obj = (try? JSONSerialization.jsonObject(with: lineData)) as? [String: Any] else {
                return .unknown
            }
            if let kind = obj["kind"] as? String {
                return kind == "subagent" ? .subagent : .topLevel
            }
            return obj["type"] != nil ? .topLevel : .unknown

        case .jsonSnapshot:
            if let headString = String(data: headData, encoding: .utf8) {
                if headString.contains("\"kind\":\"subagent\"") || headString.contains("\"kind\": \"subagent\"") {
                    return .subagent
                }
                if headString.contains("\"sessionId\"") || headString.contains("\"messages\"") {
                    return .topLevel
                }
            }
            return .topLevel
        }
    }

    // MARK: - Session Attachment & Incremental Reading

    private func attachSession(
        _ candidate: FileCandidate,
        at now: Date,
        isStaleFallback: Bool,
        handler: @Sendable (AgentEvent) -> Void
    ) {
        var tail = SessionLogTail()
        var lastSnapshotMeta: (size: UInt64, modified: Date)?
        var lastSnapshotMessageCount = 0
        var deduplicator = MessageDeduplicator()
        var seedEntries: [SessionLogEntry] = []
        var confirmedTopLevel = false

        switch candidate.format {
        case .jsonl:
            let seed = tail.attach(to: candidate.url)
            let kind = Self.classifyFile(at: candidate.url, format: .jsonl)
            if kind == .subagent {
                return
            }
            confirmedTopLevel = (kind == .topLevel)
            for line in seed.lines {
                if let obj = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any] {
                    if (obj["kind"] as? String) == "subagent" {
                        return
                    }
                    seedEntries.append(contentsOf: Self.entries(
                        fromRecord: obj,
                        deduplicator: &deduplicator,
                        fallbackID: nil,
                        referenceDate: now
                    ))
                }
            }

        case .jsonSnapshot:
            if let meta = SessionLogTail.fileMetadata(candidate.url) {
                lastSnapshotMeta = meta
                if let parsed = Self.parseSnapshotFile(at: candidate.url) {
                    if parsed.isSubagent {
                        return
                    }
                    confirmedTopLevel = true
                    lastSnapshotMessageCount = parsed.messages.count
                    seedEntries = Self.entries(
                        fromMessages: parsed.messages,
                        deduplicator: &deduplicator,
                        referenceDate: now
                    )
                }
            }
        }

        var tracker = AgentSessionTracker(
            agentID: agentID,
            agentName: agentName,
            startsTurnOnPrompt: true,
            sessionID: candidate.sessionID
        )
        tracker.prime(fromSeed: seedEntries)
        if isStaleFallback {
            tracker.markIdle()
        }

        let session = FollowedSession(
            sessionID: candidate.sessionID,
            projectDir: candidate.projectDir,
            url: candidate.url,
            format: candidate.format,
            tail: tail,
            lastSnapshotMeta: lastSnapshotMeta,
            lastSnapshotMessageCount: lastSnapshotMessageCount,
            tracker: tracker,
            deduplicator: deduplicator,
            lastActivityAt: candidate.modified,
            confirmedTopLevel: confirmedTopLevel
        )
        followedSessions[candidate.sessionID] = session
        handler(session.tracker.usageEvent(at: now, seed: true))
    }

    private func readSessionDelta(
        _ session: inout FollowedSession,
        at now: Date
    ) -> (entries: [SessionLogEntry], grew: Bool, becameSubagent: Bool) {
        switch session.format {
        case .jsonl:
            let read = session.tail.readNew()
            guard read.grew else {
                return ([], false, false)
            }
            var entries: [SessionLogEntry] = []
            for line in read.lines {
                guard let obj = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any] else {
                    continue
                }
                if !session.confirmedTopLevel {
                    if (obj["kind"] as? String) == "subagent" {
                        return ([], false, true)
                    }
                    if obj["kind"] != nil || obj["type"] != nil {
                        session.confirmedTopLevel = true
                    }
                }
                entries.append(contentsOf: Self.entries(
                    fromRecord: obj,
                    deduplicator: &session.deduplicator,
                    fallbackID: nil,
                    referenceDate: now
                ))
            }
            return (entries, !entries.isEmpty, false)

        case .jsonSnapshot:
            // Gate snapshot reads strictly on POSIX stat (size, modified).
            guard let meta = SessionLogTail.fileMetadata(session.url) else {
                return ([], false, false)
            }
            if let prev = session.lastSnapshotMeta,
               prev.size == meta.size && prev.modified == meta.modified {
                return ([], false, false)
            }
            session.lastSnapshotMeta = meta
            guard let parsed = Self.parseSnapshotFile(at: session.url) else {
                return ([], false, false)
            }
            if parsed.isSubagent {
                return ([], false, true)
            }
            session.confirmedTopLevel = true
            let startIndex: Int
            if parsed.messages.count < session.lastSnapshotMessageCount {
                let seedEnd = max(0, parsed.messages.count - 1)
                if seedEnd > 0 {
                    let seedEntries = Self.entries(
                        fromMessages: Array(parsed.messages[0..<seedEnd]),
                        startIndex: 0,
                        deduplicator: &session.deduplicator,
                        referenceDate: now
                    )
                    if !seedEntries.isEmpty {
                        session.tracker.prime(fromSeed: seedEntries)
                    }
                }
                startIndex = seedEnd
            } else {
                startIndex = max(0, session.lastSnapshotMessageCount - 1)
            }
            session.lastSnapshotMessageCount = parsed.messages.count
            let entries = Self.entries(
                fromMessages: parsed.messages,
                startIndex: startIndex,
                deduplicator: &session.deduplicator,
                referenceDate: now
            )
            return (entries, !entries.isEmpty, false)
        }
    }

    private func pruneIdleSessions(at now: Date) {
        let staleIDs = AgentSessionTracker.idleSessionIDsToPrune(
            from: followedSessions,
            retainWindow: Self.idleRetainWindow,
            now: now,
            lastActivityAt: \.lastActivityAt,
            isBusy: \.tracker.turnActive
        )
        for id in staleIDs {
            followedSessions.removeValue(forKey: id)
        }
    }

    // MARK: - Gemini Schema Parsing (Static, Testable)

    private static func parseSnapshotFile(at url: URL) -> (isSubagent: Bool, messages: [[String: Any]])? {
        guard let data = try? Data(contentsOf: url),
              let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            return nil
        }
        let isSubagent = (root["kind"] as? String) == "subagent"
        let messages = root["messages"] as? [[String: Any]] ?? []
        return (isSubagent, messages)
    }

    /// Parses a single standalone Gemini JSONL `MessageRecord` line (for unit tests without stateful dedup).
    public static func entries(fromLine data: Data, referenceDate: Date = Date()) -> [SessionLogEntry] {
        guard let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            return []
        }
        var dedup = MessageDeduplicator()
        return entries(fromRecord: obj, deduplicator: &dedup, fallbackID: nil, referenceDate: referenceDate)
    }

    private static func entries(
        fromMessages messages: [[String: Any]],
        startIndex: Int = 0,
        deduplicator: inout MessageDeduplicator,
        referenceDate: Date
    ) -> [SessionLogEntry] {
        var result: [SessionLogEntry] = []
        let clampedStart = min(max(0, startIndex), messages.count)
        for index in clampedStart..<messages.count {
            result.append(contentsOf: entries(
                fromRecord: messages[index],
                deduplicator: &deduplicator,
                fallbackID: "msg#\(index)",
                referenceDate: referenceDate
            ))
        }
        return result
    }

    private static func entries(
        fromRecord obj: [String: Any],
        deduplicator: inout MessageDeduplicator,
        fallbackID: String?,
        referenceDate: Date
    ) -> [SessionLogEntry] {
        if obj["$rewindTo"] != nil {
            deduplicator = MessageDeduplicator()
            return [.toolResult(id: nil), .turnEnd(isDone: false)]
        }
        if obj["$set"] != nil || (obj["sessionId"] != nil && obj["type"] == nil) {
            return []
        }
        guard let type = obj["type"] as? String else { return [] }
        deduplicator.pruneIfOversized()

        let msgID = (obj["id"] as? String) ?? fallbackID
        let lineDate = RateLimitParser.parseTimestamp(obj["timestamp"]) ?? referenceDate

        switch type {
        case "user":
            if let msgID {
                guard deduplicator.seenPromptIDs.insert(msgID).inserted else { return [] }
            }
            return [.toolResult(id: nil), .prompt]

        case "error":
            let errorTexts = RateLimitParser.collectErrorStrings(from: obj["error"])
                + RateLimitParser.collectErrorStrings(from: obj["content"])
                + RateLimitParser.collectErrorStrings(from: obj["message"])
                + RateLimitParser.collectErrorStrings(from: obj["details"])
            let dedupDigest = RateLimitParser.dedupDigest(["error", msgID ?? "anon"] + errorTexts)
            guard deduplicator.handledErrorKeys.insert(dedupDigest).inserted else { return [] }

            var statusCodes: [Int] = []
            for key in ["statusCode", "status_code", "httpStatus", "http_status", "code"] {
                if let code = RateLimitParser.intValue(obj[key]) {
                    statusCodes.append(code)
                }
            }
            if let errDict = obj["error"] as? [String: Any] {
                for key in ["statusCode", "status_code", "httpStatus", "http_status", "code"] {
                    if let code = RateLimitParser.intValue(errDict[key]) {
                        statusCodes.append(code)
                    }
                }
            }

            if RateLimitParser.isQuotaError(texts: errorTexts, statusCodes: statusCodes) {
                let resetsAt = RateLimitParser.extractResetDate(
                    in: obj,
                    texts: errorTexts,
                    referenceDate: lineDate
                )
                return [.toolResult(id: nil), .rateLimit(resetsAt: resetsAt), .turnEnd(isDone: false)]
            }
            return [.toolResult(id: nil), .turnEnd(isDone: false)]

        case "info", "warning":
            let texts = RateLimitParser.collectErrorStrings(from: obj["content"])
                + RateLimitParser.collectErrorStrings(from: obj["message"])
            let dedupDigest = RateLimitParser.dedupDigest([type, msgID ?? "anon"] + texts)
            guard deduplicator.handledInfoKeys.insert(dedupDigest).inserted else { return [] }

            if type == "warning", RateLimitParser.isQuotaError(texts: texts) {
                let resetsAt = RateLimitParser.extractResetDate(in: obj, texts: texts, referenceDate: lineDate)
                return [.toolResult(id: nil), .rateLimit(resetsAt: resetsAt), .turnEnd(isDone: false)]
            }
            let joined = texts.joined(separator: " ").lowercased()
            if joined.contains("compress") || joined.contains("compact") {
                return [.compaction]
            }
            return []

        case "gemini":
            var result: [SessionLogEntry] = []

            let tokensDict = obj["tokens"] as? [String: Any]
            let inputTokens = RateLimitParser.intValue(tokensDict?["input"])
            let totalTokens = RateLimitParser.intValue(tokensDict?["total"])
            let contextTokens: Int? = {
                if let input = inputTokens, input > 0 { return input }
                if let total = totalTokens, total > 0 { return total }
                return inputTokens
            }()

            if let msgID {
                let isFirstAppearance = deduplicator.seenGeminiMsgIDs.insert(msgID).inserted
                if let contextTokens {
                    if deduplicator.emittedContextTokensByMsgID[msgID] != contextTokens {
                        deduplicator.emittedContextTokensByMsgID[msgID] = contextTokens
                        result.append(.assistantOutput(contextTokens: contextTokens))
                    }
                } else if isFirstAppearance {
                    result.append(.assistantOutput(contextTokens: nil))
                }
            } else {
                result.append(.assistantOutput(contextTokens: contextTokens))
            }

            let toolCalls = obj["toolCalls"] as? [[String: Any]] ?? []
            var sawCancelledTool = false
            var hasActiveTools = false

            for (index, call) in toolCalls.enumerated() {
                let callID = (call["id"] as? String) ?? "\(msgID ?? "anon")::tool#\(index)"
                let name = (call["name"] as? String) ?? "tool"
                let status = (call["status"] as? String)?.lowercased() ?? "executing"
                let isTerminal = (status == "success" || status == "error" || status == "cancelled")

                if isTerminal {
                    if !deduplicator.seenToolCallIDs.contains(callID) {
                        deduplicator.seenToolCallIDs.insert(callID)
                        deduplicator.completedToolCallIDs.insert(callID)
                        result.append(.toolCall(
                            id: callID,
                            name: name,
                            fingerprint: AgentSessionTracker.fingerprint(name: name, input: call["args"])
                        ))
                        result.append(.toolResult(id: callID))
                        if status == "cancelled" {
                            sawCancelledTool = true
                        }
                    } else if deduplicator.completedToolCallIDs.insert(callID).inserted {
                        deduplicator.awaitingApprovalToolCallIDs.remove(callID)
                        result.append(.toolResult(id: callID))
                        if status == "cancelled" {
                            sawCancelledTool = true
                        }
                    }
                } else {
                    hasActiveTools = true
                    if deduplicator.seenToolCallIDs.insert(callID).inserted {
                        result.append(.toolCall(
                            id: callID,
                            name: name,
                            fingerprint: AgentSessionTracker.fingerprint(name: name, input: call["args"])
                        ))
                    }
                    if status == "awaiting_approval"
                        && deduplicator.awaitingApprovalToolCallIDs.insert(callID).inserted {
                        result.append(.approvalRequest)
                    }
                }
            }

            if toolCalls.isEmpty {
                let hasContent = Self.hasNonEmptyContent(obj["content"]) || tokensDict != nil
                if hasContent {
                    if let msgID {
                        if deduplicator.emittedTurnEndMsgIDs.insert(msgID).inserted {
                            result.append(.turnEnd(isDone: true))
                        }
                    } else {
                        result.append(.turnEnd(isDone: true))
                    }
                }
            } else if sawCancelledTool && !hasActiveTools {
                result.append(.turnEnd(isDone: false))
            }

            return result

        default:
            return []
        }
    }

    private static func hasNonEmptyContent(_ content: Any?) -> Bool {
        if let str = content as? String {
            return !str.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
        if let parts = content as? [[String: Any]] {
            return !parts.isEmpty
        }
        if let parts = content as? [Any] {
            return !parts.isEmpty
        }
        return false
    }
}
