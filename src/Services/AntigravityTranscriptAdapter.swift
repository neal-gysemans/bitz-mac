import Foundation

/// Agent adapter that monitors Antigravity's active session transcript (`transcript.jsonl`)
/// in `~/.gemini/antigravity/brain/<id>/.system_generated/logs/`.
public final class AntigravityTranscriptAdapter: AgentAdapter, @unchecked Sendable {
    public let id: String = "antigravity-transcript-adapter"
    public let agentID: String = "antigravity"
    public let agentName: String = "Antigravity"

    public let baseBrainURL: URL
    private let clock: @Sendable () -> Date
    private var eventHandler: (@Sendable (AgentEvent) -> Void)?
    private var pollTask: Task<Void, Never>? = nil

    private var tail = SessionLogTail()
    private var tracker = AgentSessionTracker(agentID: "antigravity", agentName: "Antigravity", startsTurnOnPrompt: true)
    private let lock = NSLock()

    public static var defaultBrainURL: URL {
        let home = FileManager.default.homeDirectoryForCurrentUser
        return home.appendingPathComponent(".gemini/antigravity/brain")
    }

    public init(
        baseBrainURL: URL = AntigravityTranscriptAdapter.defaultBrainURL,
        clock: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.baseBrainURL = baseBrainURL
        self.clock = clock
    }

    public func setHandlerForTesting(_ onEvent: @escaping @Sendable (AgentEvent) -> Void) {
        lock.withLock { eventHandler = onEvent }
    }

    public func start(onEvent: @escaping @Sendable (AgentEvent) -> Void) {
        setHandlerForTesting(onEvent)

        // Attach to the active transcript; history primes turn state without emitting events (FR-014).
        checkForUpdates()

        // Poll for updates every 1.5 seconds
        let task = Task { [weak self] in
            // Task.sleep throws once cancelled, which ends the loop.
            while (try? await Task.sleep(nanoseconds: 1_500_000_000)) != nil {
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

    /// Each `<brain>/<id>/.system_generated/logs/transcript.jsonl` with its modification date.
    public func sessionCandidates() -> [(url: URL, modified: Date)] {
        let fileManager = FileManager.default
        guard let subdirs = try? fileManager.contentsOfDirectory(at: baseBrainURL, includingPropertiesForKeys: nil) else {
            return []
        }
        return subdirs.compactMap { subdir in
            let url = subdir.appendingPathComponent(".system_generated/logs/transcript.jsonl")
            guard let modified = (try? fileManager.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date else {
                return nil
            }
            return (url, modified)
        }
    }

    /// One poll: follow the active session, emit lifecycle/loop events for new lines, then a `usage` reading.
    public func checkForUpdates() {
        lock.lock()
        defer { lock.unlock() }

        guard let handler = eventHandler else { return }
        let now = clock()

        // While the current transcript is fresh pickSession keeps it, so the directory scan is skipped.
        if !tail.isCurrentFresh(at: now),
           let chosen = SessionLogTail.pickSession(current: tail.url, candidates: sessionCandidates(), now: now),
           chosen != tail.url {
            let seed = tail.attach(to: chosen)
            // History primes turn state silently, so a turn in progress still ends in done (FR-014).
            tracker.reset()
            tracker.prime(fromSeed: seed.lines.flatMap(Self.entries(fromLine:)))
            handler(tracker.usageEvent(at: now, seed: true))
            return
        }

        let read = tail.readNew()
        guard read.grew else { return }
        tracker.ingest(read.lines.flatMap(Self.entries(fromLine:)), at: now).forEach(handler)
        handler(tracker.usageEvent(at: now, seed: false))
    }

    /// Maps one Antigravity transcript line to tracker entries; unknown lines yield [.toolResult(id: nil)] only.
    public static func entries(fromLine data: Data) -> [SessionLogEntry] {
        guard let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return [] }

        // Tool calls carry no ids, so any later line means the previous calls finished (R5).
        var entries: [SessionLogEntry] = [.toolResult(id: nil)]
        let type = obj["type"] as? String
        let status = obj["status"] as? String
        let toolCalls = obj["tool_calls"] as? [[String: Any]] ?? []

        if type == "USER_INPUT" {
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
