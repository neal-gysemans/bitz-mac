import Foundation

/// Follows active top-level Claude Code session logs (`~/.claude/projects/<project>/<session>.jsonl`), read-only (C-003),
/// concurrently (#72), and reports turns, loop warnings and usage readings (FR-004, FR-005, FR-008, FR-014).
/// Keeps only byte offsets, token counts, tool names and fingerprints, never line text (NFR-004).
public final class ClaudeCodeTranscriptAdapter: AgentAdapter, @unchecked Sendable {
    public let id = "claude-code-transcript-adapter"
    /// Matches the `AgentDefinition.builtInCatalog` id.
    public let agentID = "claude"
    public let agentName = "Claude"

    /// Newly discovered transcripts modified within this window are attached immediately for concurrent tracking.
    public static let activeAttachWindow: TimeInterval = 300.0
    /// Finished transcripts idle longer than this window are pruned once at least one newer session remains.
    public static let idleRetainWindow: TimeInterval = 1800.0

    public let projectsURL: URL
    public let pollInterval: TimeInterval
    public let maxIdleScanInterval: TimeInterval
    public let activeAttachWindow: TimeInterval
    private let clock: @Sendable () -> Date
    private let lock = NSLock()
    private var eventHandler: (@Sendable (AgentEvent) -> Void)?
    private var pollTask: Task<Void, Never>?

    private struct CachedProjectEntry {
        let projectURL: URL
        var projectModified: Date?
        var sessionModifiedByURL: [URL: Date] = [:]
    }

    private struct Candidate {
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
    }

    private var followedSessions: [String: FollowedSession] = [:]
    private var cachedProjectsDirModified: Date?
    private var cachedProjects: [URL: CachedProjectEntry] = [:]
    private var cachedCandidates: [Candidate] = []
    private var lastCandidateScanTime: Date?
    public private(set) var currentScanInterval: TimeInterval

    private static let interruptMarker = "[Request interrupted"
    private static let usageTokenKeys = ["input_tokens", "cache_creation_input_tokens", "cache_read_input_tokens"]

    public static var defaultProjectsURL: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude/projects")
    }

    public init(
        projectsURL: URL = ClaudeCodeTranscriptAdapter.defaultProjectsURL,
        pollInterval: TimeInterval = 1.5,
        maxIdleScanInterval: TimeInterval = 30.0,
        activeAttachWindow: TimeInterval = ClaudeCodeTranscriptAdapter.activeAttachWindow,
        clock: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.projectsURL = projectsURL
        self.pollInterval = pollInterval
        self.maxIdleScanInterval = max(pollInterval, maxIdleScanInterval)
        self.activeAttachWindow = max(pollInterval, activeAttachWindow)
        self.currentScanInterval = pollInterval
        self.clock = clock
    }

    public func setHandlerForTesting(_ onEvent: @escaping @Sendable (AgentEvent) -> Void) {
        lock.withLock { eventHandler = onEvent }
    }

    /// Attaches to active sessions (priming their turn states, seeding readings), then polls.
    public func start(onEvent: @escaping @Sendable (AgentEvent) -> Void) {
        setHandlerForTesting(onEvent)
        checkForUpdates()
        let nanoseconds = UInt64(pollInterval * 1_000_000_000)
        let task = Task { [weak self] in
            // Task.sleep throws once cancelled, which ends the loop.
            while (try? await Task.sleep(nanoseconds: nanoseconds)) != nil {
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
            cachedProjectsDirModified = nil
            cachedProjects.removeAll()
            cachedCandidates.removeAll()
            lastCandidateScanTime = nil
            currentScanInterval = pollInterval
        }
    }

    /// Top-level session logs only (`<project>/<session>.jsonl`); subagent logs nested deeper are never followed.
    public func sessionCandidates() -> [(url: URL, modified: Date)] {
        lock.withLock {
            refreshCandidates().candidates.map { (url: $0.url, modified: $0.modified) }
        }
    }

    /// Extracts a unique session identifier (`<project>/<session>`) from `.../<project>/<session>.jsonl`.
    public static func sessionID(fromTranscriptURL url: URL) -> String? {
        let stem = url.deletingPathExtension().lastPathComponent
        guard !stem.isEmpty, stem != "/" else { return nil }
        let project = url.deletingLastPathComponent().lastPathComponent
        if !project.isEmpty, project != "/" {
            return "\(project)/\(stem)"
        }
        return stem
    }

    private func refreshCandidates() -> (candidates: [Candidate], changed: Bool) {
        guard let projectsModified = SessionLogTail.modificationDate(projectsURL) else {
            let hadCandidates = !cachedCandidates.isEmpty
            cachedProjectsDirModified = nil
            cachedProjects.removeAll()
            cachedCandidates.removeAll()
            return ([], hadCandidates)
        }

        let fileManager = FileManager.default
        var changed = false

        if cachedProjectsDirModified != projectsModified {
            let projects = (try? fileManager.contentsOfDirectory(at: projectsURL, includingPropertiesForKeys: nil)) ?? []
            var updatedProjects: [URL: CachedProjectEntry] = [:]
            updatedProjects.reserveCapacity(projects.count)
            for project in projects {
                let key = project.standardizedFileURL
                if let existing = cachedProjects[key] {
                    updatedProjects[key] = existing
                } else {
                    changed = true
                    updatedProjects[key] = CachedProjectEntry(projectURL: project)
                }
            }
            if updatedProjects.count != cachedProjects.count {
                changed = true
            }
            cachedProjects = updatedProjects
            cachedProjectsDirModified = projectsModified
        }

        var updatedCandidates: [Candidate] = []

        for (key, var entry) in cachedProjects {
            guard let currentProjMod = SessionLogTail.modificationDate(entry.projectURL) else {
                if !entry.sessionModifiedByURL.isEmpty {
                    changed = true
                    entry.sessionModifiedByURL.removeAll()
                }
                entry.projectModified = nil
                cachedProjects[key] = entry
                continue
            }

            if currentProjMod != entry.projectModified {
                let files = (try? fileManager.contentsOfDirectory(at: entry.projectURL, includingPropertiesForKeys: nil)) ?? []
                let jsonlFiles = files.filter { !$0.hasDirectoryPath && $0.pathExtension == "jsonl" }
                var nextMap: [URL: Date] = [:]
                nextMap.reserveCapacity(jsonlFiles.count)
                for file in jsonlFiles {
                    if let mod = SessionLogTail.modificationDate(file) {
                        if entry.sessionModifiedByURL[file] != mod {
                            changed = true
                        }
                        nextMap[file] = mod
                    }
                }
                if nextMap.count != entry.sessionModifiedByURL.count {
                    changed = true
                }
                entry.sessionModifiedByURL = nextMap
                entry.projectModified = currentProjMod
            } else {
                for (fileURL, prevMod) in entry.sessionModifiedByURL {
                    if let currentMod = SessionLogTail.modificationDate(fileURL) {
                        if currentMod != prevMod {
                            changed = true
                            entry.sessionModifiedByURL[fileURL] = currentMod
                        }
                    } else {
                        changed = true
                        entry.sessionModifiedByURL.removeValue(forKey: fileURL)
                    }
                }
            }
            cachedProjects[key] = entry
            for (fileURL, mod) in entry.sessionModifiedByURL {
                if let sessionID = Self.sessionID(fromTranscriptURL: fileURL) {
                    updatedCandidates.append(Candidate(sessionID: sessionID, url: fileURL, modified: mod))
                }
            }
        }

        updatedCandidates.sort { $0.sessionID < $1.sessionID }
        cachedCandidates = updatedCandidates
        return (updatedCandidates, changed)
    }

    private func shouldScanCandidates(at now: Date) -> Bool {
        guard let lastScan = lastCandidateScanTime else { return true }
        if SessionLogTail.modificationDate(projectsURL) != cachedProjectsDirModified {
            return true
        }
        if cachedProjects.values.contains(where: { SessionLogTail.modificationDate($0.projectURL) != $0.projectModified }) {
            return true
        }
        let elapsed = now.timeIntervalSince(lastScan)
        return elapsed < 0 || elapsed >= currentScanInterval
    }

    /// One poll: attach any newly active top-level sessions, turn appended lines across all followed sessions into events,
    /// and prune long-idle sessions (#72).
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
        let orderedIDs = followedSessions.keys.sorted()
        for sessionID in orderedIDs {
            guard var session = followedSessions[sessionID] else { continue }
            let read = session.tail.readNew()
            guard read.grew || !read.lines.isEmpty else { continue }

            anyGrew = true
            session.lastActivityAt = now
            session.tracker.ingest(read.lines.flatMap(Self.entries(fromLine:)), at: now).forEach(handler)
            // Any appended bytes count as activity, even a partial line (R4).
            if read.grew {
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

    private func attachSession(
        _ candidate: Candidate,
        at now: Date,
        isStaleFallback: Bool,
        handler: @Sendable (AgentEvent) -> Void
    ) {
        var tail = SessionLogTail()
        let seed = tail.attach(to: candidate.url)
        var tracker = AgentSessionTracker(
            agentID: agentID,
            agentName: agentName,
            startsTurnOnPrompt: false,
            sessionID: candidate.sessionID
        )
        // Seed lines silently restore turn state, so a turn already in progress is tracked;
        // the loop streak starts fresh (FR-014, R7).
        tracker.prime(fromSeed: seed.lines.flatMap(Self.entries(fromLine:)))
        if isStaleFallback {
            // Do not mark an old historic unfinished transcript (> activeAttachWindow) as actively running on cold start.
            tracker.markIdle()
        }
        let session = FollowedSession(
            sessionID: candidate.sessionID,
            url: candidate.url,
            tail: tail,
            tracker: tracker,
            lastActivityAt: candidate.modified
        )
        handler(session.tracker.usageEvent(at: now, seed: true))
        followedSessions[candidate.sessionID] = session
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

    /// Maps one Claude Code session-log line to tracker entries; unknown or sidechain lines yield [] (NFR-006).
    public static func entries(fromLine data: Data) -> [SessionLogEntry] {
        guard let line = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              line["isSidechain"] as? Bool != true else { return [] }
        let message = line["message"] as? [String: Any]

        switch line["type"] as? String {
        case "assistant":
            // Claude Code stops the turn on a usage limit; usually a `turn_duration` follows, but not always.
            if line["error"] as? String == "rate_limit" {
                let resetsAt = ((line["quotaLimits"] as? [String: Any])?["resetsAt"] as? Double).map(Date.init(timeIntervalSince1970:))
                return [.rateLimit(resetsAt: resetsAt), .turnEnd(isDone: false)]
            }
            // `<synthetic>` placeholders (interrupts, API errors) carry all-zero usage and are not model output.
            guard let message, message["model"] as? String != "<synthetic>" else { return [] }
            let tokens = (message["usage"] as? [String: Any]).map { usage in
                Self.usageTokenKeys.reduce(0) { $0 + (usage[$1] as? Int ?? 0) }
            }
            let toolCalls: [SessionLogEntry] = (message["content"] as? [[String: Any]] ?? []).compactMap { block in
                guard block["type"] as? String == "tool_use" else { return nil }
                let name = block["name"] as? String ?? ""
                return .toolCall(id: block["id"] as? String, name: name,
                                 fingerprint: AgentSessionTracker.fingerprint(name: name, input: block["input"]))
            }
            let end: [SessionLogEntry] = message["stop_reason"] as? String == "end_turn" ? [.turnEnd(isDone: true)] : []
            return [.assistantOutput(contextTokens: tokens)] + toolCalls + end

        case "user":
            guard line["isMeta"] as? Bool != true, let content = message?["content"] else { return [] }
            let blocks = content as? [[String: Any]] ?? []
            let results: [SessionLogEntry] = blocks
                .filter { $0["type"] as? String == "tool_result" }
                .map { .toolResult(id: $0["tool_use_id"] as? String) }
            // Text is only checked for the interrupt prefix, never kept (NFR-004).
            let texts = (content as? String).map { [$0] }
                ?? blocks.filter { $0["type"] as? String == "text" }.compactMap { $0["text"] as? String }
            if texts.contains(where: { $0.hasPrefix(interruptMarker) }) { return results + [.turnEnd(isDone: false)] }
            return results.isEmpty && !texts.isEmpty ? [.prompt] : results

        case "system":
            switch line["subtype"] as? String {
            case "turn_duration", "stop_hook_summary": return [.turnEnd(isDone: false)]
            case "compact_boundary": return [.compaction]
            default: return []
            }

        default:
            return []
        }
    }
}
