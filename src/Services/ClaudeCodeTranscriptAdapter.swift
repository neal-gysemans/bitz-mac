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
    private let clock: @Sendable () -> Date
    private let lock = NSLock()
    private var eventHandler: (@Sendable (AgentEvent) -> Void)?
    private var pollTask: Task<Void, Never>?
    private var tail = SessionLogTail()
    private var tracker = AgentSessionTracker(agentID: "claude", agentName: "Claude", startsTurnOnPrompt: false)

    private static let interruptMarker = "[Request interrupted"

    public static var defaultProjectsURL: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude/projects")
    }

    public init(
        projectsURL: URL = ClaudeCodeTranscriptAdapter.defaultProjectsURL,
        pollInterval: TimeInterval = 1.5,
        clock: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.projectsURL = projectsURL
        self.pollInterval = pollInterval
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
                self.checkForUpdates()
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
        }
    }

    /// Top-level session logs only (`<project>/<session>.jsonl`); subagent logs nested deeper are never followed.
    public func sessionCandidates() -> [(url: URL, modified: Date)] {
        let fileManager = FileManager.default
        let projects = (try? fileManager.contentsOfDirectory(at: projectsURL, includingPropertiesForKeys: nil)) ?? []
        return projects.flatMap { project -> [(url: URL, modified: Date)] in
            let files = (try? fileManager.contentsOfDirectory(at: project, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
            return files.filter { $0.pathExtension == "jsonl" }.compactMap { url in
                (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate).map { (url, $0) }
            }
        }
    }

    /// One poll: follow the right session, then turn appended lines into events.
    public func checkForUpdates() {
        lock.lock()
        defer { lock.unlock() }
        guard let handler = eventHandler else { return }
        let now = clock()

        // While the current log is fresh pickSession keeps it, so the directory scan is skipped.
        if !tail.isCurrentFresh(at: now),
           let chosen = SessionLogTail.pickSession(current: tail.url, candidates: sessionCandidates(), now: now),
           chosen != tail.url {
            let seed = tail.attach(to: chosen)
            // Seed lines silently restore turn state, so a turn already in progress is tracked;
            // the loop streak starts fresh (FR-014, R7). The seed reading always goes out to clear any stale turn.
            tracker.reset()
            tracker.prime(fromSeed: seed.lines.flatMap(Self.entries(fromLine:)))
            handler(tracker.usageEvent(at: now, seed: true))
            return
        }

        let read = tail.readNew()
        guard read.grew || !read.lines.isEmpty else { return }
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
            // `<synthetic>` placeholders (interrupts, API errors) carry all-zero usage and are not model output.
            guard let message, message["model"] as? String != "<synthetic>" else { return [] }
            let tokens = (message["usage"] as? [String: Any]).map { usage in
                ["input_tokens", "cache_creation_input_tokens", "cache_read_input_tokens"].reduce(0) { $0 + (usage[$1] as? Int ?? 0) }
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
