import Foundation

/// Follows the active top-level Claude Code session log (`~/.claude/projects/<project>/<session>.jsonl`), read-only (C-003),
/// and reports turns, loop warnings and usage readings (FR-004, FR-005, FR-008, FR-014).
/// Keeps only byte offsets, token counts, tool names and fingerprints, never line text (NFR-004).
public final class ClaudeCodeTranscriptAdapter: AgentAdapter, @unchecked Sendable {
    public let id = "claude-code-transcript-adapter"
    /// Matches the `AgentDefinition.builtInCatalog` id.
    public let agentID = "claude"
    public let agentName = "Claude"

    public let projectsURL: URL
    private let pollInterval: TimeInterval
    private let maxIdleScanInterval: TimeInterval
    private let clock: @Sendable () -> Date
    private let lock = NSLock()
    private var eventHandler: (@Sendable (AgentEvent) -> Void)?
    private var pollTask: Task<Void, Never>?
    private var tail = SessionLogTail()
    private var tracker = AgentSessionTracker(agentID: "claude", agentName: "Claude", startsTurnOnPrompt: false)

    private struct CachedProjectEntry {
        let projectURL: URL
        var projectModified: Date?
        var sessionModifiedByURL: [URL: Date] = [:]
    }

    private var cachedProjectsDirModified: Date?
    private var cachedProjects: [URL: CachedProjectEntry] = [:]
    private var cachedCandidates: [(url: URL, modified: Date)] = []
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
        clock: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.projectsURL = projectsURL
        self.pollInterval = pollInterval
        self.maxIdleScanInterval = max(pollInterval, maxIdleScanInterval)
        self.currentScanInterval = pollInterval
        self.clock = clock
    }

    public func setHandlerForTesting(_ onEvent: @escaping @Sendable (AgentEvent) -> Void) {
        lock.withLock { eventHandler = onEvent }
    }

    /// Attaches to the current session (priming its turn state, seeding one reading), then polls.
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
            tail = SessionLogTail()
            tracker.reset()
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
            refreshCandidates().candidates
        }
    }

    private func refreshCandidates() -> (candidates: [(url: URL, modified: Date)], changed: Bool) {
        guard let projectsModified = SessionLogTail.modificationDate(projectsURL) else {
            let hadCandidates = !cachedCandidates.isEmpty
            cachedProjectsDirModified = nil
            cachedProjects.removeAll()
            cachedCandidates.removeAll()
            return ([], hadCandidates)
        }

        let fileManager = FileManager.default
        var changed = false

        if cachedProjectsDirModified != projectsModified || cachedProjects.isEmpty {
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

        var updatedCandidates: [(url: URL, modified: Date)] = []

        for (key, var entry) in cachedProjects {
            let currentProjMod = SessionLogTail.modificationDate(entry.projectURL)
            if currentProjMod != entry.projectModified || entry.sessionModifiedByURL.isEmpty {
                let files = (try? fileManager.contentsOfDirectory(at: entry.projectURL, includingPropertiesForKeys: nil)) ?? []
                let jsonlFiles = files.filter { $0.pathExtension == "jsonl" }
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
                updatedCandidates.append((url: fileURL, modified: mod))
            }
        }

        cachedCandidates = updatedCandidates
        return (updatedCandidates, changed)
    }

    private func shouldScanCandidates(at now: Date) -> Bool {
        guard let lastScan = lastCandidateScanTime else { return true }
        if SessionLogTail.modificationDate(projectsURL) != cachedProjectsDirModified {
            return true
        }
        let elapsed = now.timeIntervalSince(lastScan)
        return elapsed < 0 || elapsed >= currentScanInterval
    }

    /// One poll: follow the right session, then turn appended lines into events.
    public func checkForUpdates() {
        lock.lock()
        defer { lock.unlock() }
        guard let handler = eventHandler else { return }
        let now = clock()

        // While the current log is fresh pickSession keeps it, so the directory scan is skipped.
        if !tail.isCurrentFresh(at: now) {
            let candidates: [(url: URL, modified: Date)]
            if shouldScanCandidates(at: now) {
                let scan = refreshCandidates()
                lastCandidateScanTime = now
                candidates = scan.candidates
                if scan.changed {
                    currentScanInterval = pollInterval
                } else {
                    currentScanInterval = min(currentScanInterval * 2.0, maxIdleScanInterval)
                }
            } else {
                candidates = cachedCandidates
            }

            if let chosen = SessionLogTail.pickSession(current: tail.url, candidates: candidates, now: now),
               chosen != tail.url {
                currentScanInterval = pollInterval
                let seed = tail.attach(to: chosen)
                // Seed lines silently restore turn state, so a turn already in progress is tracked;
                // the loop streak starts fresh (FR-014, R7). The seed reading always goes out to clear any stale turn.
                tracker.reset()
                tracker.prime(fromSeed: seed.lines.flatMap(Self.entries(fromLine:)))
                handler(tracker.usageEvent(at: now, seed: true))
                return
            }
        }

        let read = tail.readNew()
        guard read.grew || !read.lines.isEmpty else { return }
        currentScanInterval = pollInterval
        tracker.ingest(read.lines.flatMap(Self.entries(fromLine:)), at: now).forEach(handler)
        // Any appended bytes count as activity, even a partial line (R4).
        if read.grew { handler(tracker.usageEvent(at: now, seed: false)) }
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
