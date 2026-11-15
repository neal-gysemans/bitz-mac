import Foundation

/// Reads OpenAI Codex CLI rollout JSONL transcripts (`~/.codex/sessions/YYYY/MM/DD/rollout-*.jsonl`)
/// incrementally using mtime-gated directory scanning, `SessionLogTail`, and exponential idle backoff.
/// Read-only on `~/.codex/sessions`; tracks concurrent active rollout sessions keyed by `sessionID`.
public final class CodexTranscriptAdapter: AgentAdapter, @unchecked Sendable {
    public static let activeAttachWindow: TimeInterval = 300.0
    public static let idleRetainWindow: TimeInterval = 1800.0

    public let id = "codex-transcript"
    public let agentID = "codex"
    public let agentName = "Codex"

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

    private struct CachedFile {
        let url: URL
        var sessionID: String
        var modified: Date?
        var sessionKind: SessionKind = .unknown
    }

    private struct CachedDayDir {
        let url: URL
        var modified: Date?
        var files: [URL: CachedFile] = [:]
    }

    private struct CachedMonthDir {
        let url: URL
        var modified: Date?
        var days: [URL: CachedDayDir] = [:]
    }

    private struct CachedYearDir {
        let url: URL
        var modified: Date?
        var months: [URL: CachedMonthDir] = [:]
    }

    private struct FileCandidate {
        let sessionID: String
        let url: URL
        let modified: Date
    }

    private struct FollowedSession {
        let sessionID: String
        let url: URL
        var tail: SessionLogTail
        var tracker: AgentSessionTracker
        var lastActivityAt: Date
        var confirmedTopLevel: Bool
        var notifiedRateLimitKeys: Set<String> = []
    }

    private var cachedRootModified: Date?
    private var cachedYears: [URL: CachedYearDir] = [:]
    private var cachedRootRollouts: [URL: CachedFile] = [:]
    private var cachedCandidates: [FileCandidate] = []
    private var lastCandidateScanTime: Date?
    private var currentScanInterval: TimeInterval
    private var scanCount = 0
    private var followedSessions: [String: FollowedSession] = [:]

    public static var defaultRootURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".codex/sessions", isDirectory: true)
    }

    public init(
        baseRootURL: URL = CodexTranscriptAdapter.defaultRootURL,
        pollInterval: TimeInterval = 1.5,
        maxIdleScanInterval: TimeInterval = 30.0,
        activeAttachWindow: TimeInterval = CodexTranscriptAdapter.activeAttachWindow,
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
            cachedYears.removeAll()
            cachedRootRollouts.removeAll()
            cachedCandidates.removeAll()
            lastCandidateScanTime = nil
            currentScanInterval = pollInterval
            scanCount = 0
        }
    }

    public func sessionCandidates() -> [(url: URL, modified: Date)] {
        lock.withLock {
            refreshCandidates(at: clock()).candidates.map { (url: $0.url, modified: $0.modified) }
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
            let scan = refreshCandidates(at: now)
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
            let read = session.tail.readNew()
            if read.grew {
                var emittedEvents: [AgentEvent] = []
                var becameSubagent = false
                for line in read.lines {
                    let parsed = Self.parseLine(line, referenceDate: now)
                    if !session.confirmedTopLevel {
                        if parsed.isSubagent {
                            becameSubagent = true
                            break
                        }
                        if parsed.confirmedTopLevel {
                            session.confirmedTopLevel = true
                        }
                    }
                    let lineEntries = filterEntries(parsed, for: &session)
                    if !lineEntries.isEmpty {
                        emittedEvents.append(contentsOf: session.tracker.ingest(lineEntries, at: now))
                    }
                }
                if becameSubagent {
                    followedSessions.removeValue(forKey: sessionID)
                    cachedCandidates.removeAll { $0.sessionID == sessionID }
                    continue
                }
                anyGrew = true
                session.lastActivityAt = now
                for event in emittedEvents {
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

    private func filterEntries(_ parsed: ParsedLine, for session: inout FollowedSession) -> [SessionLogEntry] {
        var out: [SessionLogEntry] = []
        if parsed.isTaskStarted && !session.tracker.turnActive {
            out.append(.toolResult(id: nil))
            out.append(.prompt)
        }
        if let quotaKey = parsed.rateLimitBucketKey {
            if session.notifiedRateLimitKeys.insert(quotaKey).inserted {
                out.append(contentsOf: parsed.entries)
            } else {
                // Suppress repeated heartbeat rate_limit alerts for the exact same exhausted window.
                out.append(contentsOf: parsed.entries.filter {
                    if case .rateLimit = $0 { return false }
                    if case .turnEnd(isDone: false) = $0 { return false }
                    return true
                })
            }
        } else {
            if parsed.clearRateLimitBuckets {
                session.notifiedRateLimitKeys.removeAll()
            }
            out.append(contentsOf: parsed.entries)
        }
        return out
    }

    // MARK: - Directory Discovery & Mtime Caching

    private func shouldScanCandidates(at now: Date) -> Bool {
        guard let lastScan = lastCandidateScanTime else { return true }
        let elapsed = now.timeIntervalSince(lastScan)
        if cachedRootModified == nil {
            return elapsed < 0 || elapsed >= currentScanInterval
        }
        if elapsed < 0 || elapsed >= currentScanInterval {
            return true
        }
        if SessionLogTail.modificationDate(baseRootURL) != cachedRootModified {
            return true
        }
        return false
    }

    private func refreshCandidates(at now: Date) -> (candidates: [FileCandidate], changed: Bool) {
        let currentRootMod = SessionLogTail.modificationDate(baseRootURL)
        guard let currentRootMod else {
            let hadState = cachedRootModified != nil || !cachedYears.isEmpty || !cachedRootRollouts.isEmpty || !cachedCandidates.isEmpty
            cachedRootModified = nil
            cachedYears.removeAll()
            cachedRootRollouts.removeAll()
            cachedCandidates.removeAll()
            return ([], hadState)
        }

        var changed = (currentRootMod != cachedRootModified)
        if cachedRootModified == nil || currentRootMod != cachedRootModified {
            cachedRootModified = currentRootMod
            let children = Self.subitems(at: baseRootURL)
            var nextYears: [URL: CachedYearDir] = [:]
            var nextRootRollouts: [URL: CachedFile] = [:]
            for child in children {
                if child.isDir {
                    if let existing = cachedYears[child.url] {
                        nextYears[child.url] = existing
                    } else {
                        changed = true
                        nextYears[child.url] = CachedYearDir(url: child.url)
                    }
                } else if Self.isRolloutFile(child.url) {
                    if let existing = cachedRootRollouts[child.url] {
                        nextRootRollouts[child.url] = existing
                    } else {
                        changed = true
                        nextRootRollouts[child.url] = CachedFile(
                            url: child.url,
                            sessionID: Self.fallbackSessionID(from: child.url)
                        )
                    }
                }
            }
            if nextYears.count != cachedYears.count || nextRootRollouts.count != cachedRootRollouts.count {
                changed = true
            }
            cachedYears = nextYears
            cachedRootRollouts = nextRootRollouts
        }

        var collected: [FileCandidate] = []

        for fileKey in cachedRootRollouts.keys {
            guard var file = cachedRootRollouts[fileKey] else { continue }
            if updateCachedFile(&file, at: now, checkStat: true, changed: &changed) {
                cachedRootRollouts[fileKey] = file
                if file.sessionKind != .subagent, let mod = file.modified {
                    collected.append(FileCandidate(sessionID: file.sessionID, url: file.url, modified: mod))
                }
            } else {
                cachedRootRollouts.removeValue(forKey: fileKey)
            }
        }

        let sortedYearKeys = cachedYears.keys.sorted { $0.lastPathComponent > $1.lastPathComponent }
        for (yearIdx, yearKey) in sortedYearKeys.enumerated() {
            guard var year = cachedYears[yearKey] else { continue }
            guard let yearMod = SessionLogTail.modificationDate(year.url) else {
                changed = true
                cachedYears.removeValue(forKey: yearKey)
                continue
            }
            if year.modified != yearMod {
                changed = true
                year.modified = yearMod
                let months = Self.subitems(at: year.url).filter(\.isDir)
                var nextMonths: [URL: CachedMonthDir] = [:]
                for month in months {
                    nextMonths[month.url] = year.months[month.url] ?? CachedMonthDir(url: month.url)
                }
                year.months = nextMonths
            }

            let sortedMonthKeys = year.months.keys.sorted { $0.lastPathComponent > $1.lastPathComponent }
            for (monthIdx, monthKey) in sortedMonthKeys.enumerated() {
                guard var month = year.months[monthKey] else { continue }
                guard let monthMod = SessionLogTail.modificationDate(month.url) else {
                    changed = true
                    year.months.removeValue(forKey: monthKey)
                    continue
                }
                if month.modified != monthMod {
                    changed = true
                    month.modified = monthMod
                    let days = Self.subitems(at: month.url).filter(\.isDir)
                    var nextDays: [URL: CachedDayDir] = [:]
                    for day in days {
                        nextDays[day.url] = month.days[day.url] ?? CachedDayDir(url: day.url)
                    }
                    month.days = nextDays
                }

                let sortedDayKeys = month.days.keys.sorted { $0.lastPathComponent > $1.lastPathComponent }
                for (dayIdx, dayKey) in sortedDayKeys.enumerated() {
                    guard var day = month.days[dayKey] else { continue }
                    guard let dayMod = SessionLogTail.modificationDate(day.url) else {
                        changed = true
                        month.days.removeValue(forKey: dayKey)
                        continue
                    }
                    let dirChanged = (day.modified != dayMod)
                    if dirChanged {
                        changed = true
                        day.modified = dayMod
                        let rollouts = Self.subitems(at: day.url).filter { !$0.isDir && Self.isRolloutFile($0.url) }
                        var nextFiles: [URL: CachedFile] = [:]
                        for item in rollouts {
                            nextFiles[item.url] = day.files[item.url] ?? CachedFile(
                                url: item.url,
                                sessionID: Self.fallbackSessionID(from: item.url)
                            )
                        }
                        day.files = nextFiles
                    }

                    // Always check file mtimes in the most recent day folders or recently modified files.
                    let isRecentBucket = (yearIdx == 0 && monthIdx == 0 && dayIdx < 2)
                    for fileKey in day.files.keys {
                        guard var file = day.files[fileKey] else { continue }
                        let wasRecentlyActive = file.modified.map { now.timeIntervalSince($0) <= Self.idleRetainWindow } ?? true
                        let shouldStat = dirChanged || isRecentBucket || wasRecentlyActive || file.modified == nil
                        if updateCachedFile(&file, at: now, checkStat: shouldStat, changed: &changed) {
                            day.files[fileKey] = file
                            if file.sessionKind != .subagent, let mod = file.modified {
                                collected.append(FileCandidate(sessionID: file.sessionID, url: file.url, modified: mod))
                            }
                        } else {
                            day.files.removeValue(forKey: fileKey)
                        }
                    }

                    month.days[dayKey] = day
                }
                year.months[monthKey] = month
            }
            cachedYears[yearKey] = year
        }

        // Deduplicate by sessionID keeping newest modified URL.
        var byID: [String: FileCandidate] = [:]
        for candidate in collected {
            if let existing = byID[candidate.sessionID] {
                if candidate.modified > existing.modified {
                    byID[candidate.sessionID] = candidate
                }
            } else {
                byID[candidate.sessionID] = candidate
            }
        }
        let sorted = byID.values.sorted { $0.sessionID < $1.sessionID }
        cachedCandidates = sorted
        return (sorted, changed)
    }

    private func updateCachedFile(
        _ file: inout CachedFile,
        at now: Date,
        checkStat: Bool,
        changed: inout Bool
    ) -> Bool {
        if checkStat {
            guard let mod = SessionLogTail.modificationDate(file.url) else {
                changed = true
                return false
            }
            if file.modified != mod {
                changed = true
                file.modified = mod
            }
        }
        if file.sessionKind == .unknown {
            let meta = Self.readSessionMeta(at: file.url)
            if let metaID = meta.sessionID {
                file.sessionID = metaID
            }
            file.sessionKind = meta.kind
        }
        return true
    }

    private static func subitems(at directoryURL: URL) -> [(url: URL, isDir: Bool)] {
        let entries = (try? FileManager.default.contentsOfDirectory(
            at: directoryURL,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        )) ?? []
        return entries.map { url in
            let isDir = (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
            return (url.standardizedFileURL, isDir)
        }
    }

    private static func isRolloutFile(_ url: URL) -> Bool {
        let name = url.lastPathComponent
        return name.hasSuffix(".jsonl") && name.hasPrefix("rollout-")
    }

    private static func fallbackSessionID(from url: URL) -> String {
        url.deletingPathExtension().lastPathComponent
    }

    private static func readSessionMeta(at url: URL) -> (sessionID: String?, kind: SessionKind) {
        guard let handle = try? FileHandle(forReadingFrom: url) else {
            return (nil, .unknown)
        }
        defer { try? handle.close() }
        let headData = (try? handle.read(upToCount: 4096)) ?? Data()
        guard !headData.isEmpty else { return (nil, .unknown) }

        let firstLine = headData.firstIndex(of: 0x0A).map { Data(headData[..<$0]) } ?? headData
        guard let obj = (try? JSONSerialization.jsonObject(with: firstLine)) as? [String: Any] else {
            return (nil, .unknown)
        }
        let type = obj["type"] as? String
        guard type == "session_meta" else {
            return (nil, .topLevel)
        }
        let payload = obj["payload"] as? [String: Any] ?? [:]
        let id = payload["id"] as? String
        if let sourceDict = payload["source"] as? [String: Any], sourceDict["subagent"] != nil {
            return (id, .subagent)
        }
        if let sourceStr = payload["source"] as? String, sourceStr.lowercased().contains("subagent") {
            return (id, .subagent)
        }
        return (id, .topLevel)
    }

    // MARK: - Attachment & Pruning

    private func attachSession(
        _ candidate: FileCandidate,
        at now: Date,
        isStaleFallback: Bool,
        handler: @Sendable (AgentEvent) -> Void
    ) {
        var tail = SessionLogTail()
        let seed = tail.attach(to: candidate.url)
        let meta = Self.readSessionMeta(at: candidate.url)
        if meta.kind == .subagent {
            return
        }
        let resolvedSessionID = meta.sessionID ?? candidate.sessionID

        var seedEntries: [SessionLogEntry] = []
        var confirmedTopLevel = (meta.kind == .topLevel)
        var notifiedBuckets: Set<String> = []

        for line in seed.lines {
            let parsed = Self.parseLine(line, referenceDate: now)
            if parsed.isSubagent {
                return
            }
            if parsed.confirmedTopLevel {
                confirmedTopLevel = true
            }
            if let bucket = parsed.rateLimitBucketKey {
                notifiedBuckets.insert(bucket)
            } else if parsed.clearRateLimitBuckets {
                notifiedBuckets.removeAll()
            }
            seedEntries.append(contentsOf: parsed.entries)
        }

        var tracker = AgentSessionTracker(
            agentID: agentID,
            agentName: agentName,
            startsTurnOnPrompt: true,
            sessionID: resolvedSessionID
        )
        tracker.prime(fromSeed: seedEntries)
        if isStaleFallback {
            tracker.markIdle()
        }

        let session = FollowedSession(
            sessionID: resolvedSessionID,
            url: candidate.url,
            tail: tail,
            tracker: tracker,
            lastActivityAt: candidate.modified,
            confirmedTopLevel: confirmedTopLevel,
            notifiedRateLimitKeys: notifiedBuckets
        )
        followedSessions[resolvedSessionID] = session
        handler(session.tracker.usageEvent(at: now, seed: true))
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

    // MARK: - Rollout JSONL Parsing

    struct ParsedLine {
        var entries: [SessionLogEntry] = []
        var isSubagent: Bool = false
        var confirmedTopLevel: Bool = false
        var isTaskStarted: Bool = false
        var rateLimitBucketKey: String?
        var clearRateLimitBuckets: Bool = false
    }

    /// Maps one Codex rollout JSONL line to tracker entries.
    public static func entries(fromLine data: Data, referenceDate: Date = Date()) -> [SessionLogEntry] {
        parseLine(data, referenceDate: referenceDate).entries
    }

    static func parseLine(_ data: Data, referenceDate: Date) -> ParsedLine {
        guard let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let type = obj["type"] as? String else {
            return ParsedLine()
        }

        let lineDate = RateLimitParser.parseTimestamp(obj["timestamp"]) ?? referenceDate
        let payload = (obj["payload"] as? [String: Any]) ?? obj

        switch type {
        case "session_meta":
            if let sourceDict = payload["source"] as? [String: Any], sourceDict["subagent"] != nil {
                return ParsedLine(isSubagent: true)
            }
            if let sourceStr = payload["source"] as? String, sourceStr.lowercased().contains("subagent") {
                return ParsedLine(isSubagent: true)
            }
            return ParsedLine(confirmedTopLevel: true)

        case "compacted":
            return ParsedLine(entries: [.compaction])

        case "error":
            return parseErrorPayload(payload, rawLine: obj, referenceDate: lineDate)

        case "event_msg":
            guard let eventType = payload["type"] as? String else { return ParsedLine() }
            switch eventType {
            case "user_message":
                return ParsedLine(entries: [.toolResult(id: nil), .prompt])

            case "task_started":
                return ParsedLine(isTaskStarted: true)

            case "task_complete":
                return ParsedLine(entries: [.toolResult(id: nil), .turnEnd(isDone: true)])

            case "turn_aborted":
                return ParsedLine(entries: [.toolResult(id: nil), .turnEnd(isDone: false)])

            case "context_compacted":
                return ParsedLine(entries: [.compaction])

            case "agent_message", "agent_reasoning":
                return ParsedLine(entries: [.assistantOutput(contextTokens: nil)])

            case "token_count":
                return parseTokenCount(payload: payload, referenceDate: lineDate)

            case "error":
                return parseErrorPayload(payload, rawLine: obj, referenceDate: lineDate)

            default:
                return ParsedLine()
            }

        case "response_item":
            guard let itemType = payload["type"] as? String else { return ParsedLine() }
            switch itemType {
            case "function_call", "custom_tool_call", "local_shell_call", "web_search_call":
                let callID = (payload["call_id"] as? String) ?? (payload["id"] as? String)
                let name = (payload["name"] as? String) ?? itemType
                let rawInput = payload["arguments"] ?? payload["input"] ?? payload["action"]
                let parsedInput = Self.parseJSONArgumentIfString(rawInput)
                return ParsedLine(entries: [
                    .toolCall(
                        id: callID,
                        name: name,
                        fingerprint: AgentSessionTracker.fingerprint(name: name, input: parsedInput)
                    )
                ])

            case "function_call_output", "custom_tool_call_output":
                let callID = (payload["call_id"] as? String) ?? (payload["id"] as? String)
                return ParsedLine(entries: [.toolResult(id: callID)])

            case "message":
                if (payload["role"] as? String) == "assistant" {
                    return ParsedLine(entries: [.assistantOutput(contextTokens: nil)])
                }
                return ParsedLine()

            default:
                return ParsedLine()
            }

        default:
            return ParsedLine()
        }
    }

    private static func parseTokenCount(payload: [String: Any], referenceDate: Date) -> ParsedLine {
        var entries: [SessionLogEntry] = []

        if let info = payload["info"] as? [String: Any] {
            let lastUsage = info["last_token_usage"] as? [String: Any]
            let totalUsage = info["total_token_usage"] as? [String: Any]
            let usage = lastUsage ?? totalUsage

            if let usage {
                let inputTokens = RateLimitParser.intValue(usage["input_tokens"])
                let totalTokens = RateLimitParser.intValue(usage["total_tokens"])
                if let context = inputTokens ?? totalTokens {
                    entries.append(.assistantOutput(contextTokens: context))
                }
            }
        }

        var exhaustedResetsAt: Date?
        var exhaustedBucketKey: String?
        if let rateLimits = payload["rate_limits"] as? [String: Any] {
            for windowName in ["primary", "secondary"] {
                guard let window = rateLimits[windowName] as? [String: Any],
                      let usedPercent = RateLimitParser.numericValue(window["used_percent"]),
                      usedPercent >= 100.0 else {
                    continue
                }
                let candidateReset = RateLimitParser.extractResetDate(in: window, referenceDate: referenceDate)
                let epochKey = candidateReset.map { Int($0.timeIntervalSince1970) } ?? 0
                exhaustedBucketKey = "\(windowName):\(epochKey)"
                if exhaustedResetsAt == nil || (candidateReset ?? .distantPast) > (exhaustedResetsAt ?? .distantPast) {
                    exhaustedResetsAt = candidateReset
                }
            }
        }

        if let bucketKey = exhaustedBucketKey {
            entries.append(.rateLimit(resetsAt: exhaustedResetsAt))
            entries.append(.turnEnd(isDone: false))
            return ParsedLine(entries: entries, rateLimitBucketKey: bucketKey)
        }

        return ParsedLine(entries: entries, clearRateLimitBuckets: payload["rate_limits"] != nil)
    }

    private static func parseErrorPayload(
        _ payload: [String: Any],
        rawLine: [String: Any],
        referenceDate: Date
    ) -> ParsedLine {
        let errorTexts = RateLimitParser.collectErrorStrings(from: payload["message"])
            + RateLimitParser.collectErrorStrings(from: payload["error"])
            + RateLimitParser.collectErrorStrings(from: payload["codex_error_info"])
            + RateLimitParser.collectErrorStrings(from: payload["details"])

        var statusCodes: [Int] = []
        for dict in [payload, rawLine] {
            for key in ["http_status_code", "statusCode", "status_code", "httpStatus", "code"] {
                if let code = RateLimitParser.intValue(dict[key]) {
                    statusCodes.append(code)
                }
            }
        }

        if RateLimitParser.isQuotaError(texts: errorTexts, statusCodes: statusCodes) {
            let resetsAt = RateLimitParser.extractResetDate(
                in: payload,
                texts: errorTexts,
                referenceDate: referenceDate
            )
            return ParsedLine(entries: [.toolResult(id: nil), .rateLimit(resetsAt: resetsAt), .turnEnd(isDone: false)])
        }

        if (payload["will_retry"] as? Bool) == true {
            return ParsedLine()
        }
        return ParsedLine(entries: [.toolResult(id: nil), .turnEnd(isDone: false)])
    }

    private static func parseJSONArgumentIfString(_ value: Any?) -> Any? {
        guard let str = value as? String,
              let data = str.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) else {
            return value
        }
        return json
    }
}
