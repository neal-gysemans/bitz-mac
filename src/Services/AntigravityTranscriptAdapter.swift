import Foundation

/// Agent adapter that monitors Antigravity's active session transcript (`transcript.jsonl`)
/// in `~/.gemini/antigravity/brain/<id>/.system_generated/logs/`.
public final class AntigravityTranscriptAdapter: AgentAdapter, @unchecked Sendable {
    public let id: String = "antigravity-transcript-adapter"
    public let agentID: String = "antigravity"
    public let agentName: String = "Antigravity"

    public let baseBrainURL: URL
    public let pollInterval: TimeInterval
    public let maxIdleScanInterval: TimeInterval
    private let clock: @Sendable () -> Date
    private var eventHandler: (@Sendable (AgentEvent) -> Void)?
    private var pollTask: Task<Void, Never>? = nil

    private var tail = SessionLogTail()
    private var tracker = AgentSessionTracker(agentID: "antigravity", agentName: "Antigravity", startsTurnOnPrompt: true)
    private let lock = NSLock()

    private struct CachedSessionEntry {
        let subdirURL: URL
        let logsDirURL: URL
        let transcriptURL: URL
        var subdirModified: Date?
        var logsDirModified: Date?
        var transcriptModified: Date?
    }

    private var cachedBrainModified: Date?
    private var cachedSubdirs: [URL: CachedSessionEntry] = [:]
    private var cachedCandidates: [(url: URL, modified: Date)] = []
    private var lastCandidateScanTime: Date?
    public private(set) var currentScanInterval: TimeInterval

    public static var defaultBrainURL: URL {
        let home = FileManager.default.homeDirectoryForCurrentUser
        return home.appendingPathComponent(".gemini/antigravity/brain")
    }

    public init(
        baseBrainURL: URL = AntigravityTranscriptAdapter.defaultBrainURL,
        pollInterval: TimeInterval = 1.5,
        maxIdleScanInterval: TimeInterval = 30.0,
        clock: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.baseBrainURL = baseBrainURL
        self.pollInterval = pollInterval
        self.maxIdleScanInterval = max(pollInterval, maxIdleScanInterval)
        self.currentScanInterval = pollInterval
        self.clock = clock
    }

    public func setHandlerForTesting(_ onEvent: @escaping @Sendable (AgentEvent) -> Void) {
        lock.withLock { eventHandler = onEvent }
    }

    public func start(onEvent: @escaping @Sendable (AgentEvent) -> Void) {
        setHandlerForTesting(onEvent)

        // Attach to the active transcript; history primes turn state without emitting events (FR-014).
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
            tail = SessionLogTail()
            tracker.reset()
            cachedBrainModified = nil
            cachedSubdirs.removeAll()
            cachedCandidates.removeAll()
            lastCandidateScanTime = nil
            currentScanInterval = pollInterval
        }
    }

    /// Each `<brain>/<id>/.system_generated/logs/transcript.jsonl` with its modification date.
    public func sessionCandidates() -> [(url: URL, modified: Date)] {
        lock.withLock {
            refreshCandidates().candidates
        }
    }

    /// Incrementally scans `baseBrainURL`, skipping `contentsOfDirectory` when `baseBrainURL`'s mtime is unchanged
    /// and skipping subdirectories without transcripts whose directory mtimes have not changed (#126).
    private func refreshCandidates() -> (candidates: [(url: URL, modified: Date)], changed: Bool) {
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

        var updatedCandidates: [(url: URL, modified: Date)] = []
        updatedCandidates.reserveCapacity(cachedSubdirs.count)

        for (key, var entry) in cachedSubdirs {
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
            cachedSubdirs[key] = entry
            if let mod = currentTranscriptMod {
                updatedCandidates.append((url: entry.transcriptURL, modified: mod))
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
        return elapsed < 0 || elapsed >= currentScanInterval
    }

    /// One poll: follow the active session, emit lifecycle/loop events for new lines, then a `usage` reading.
    public func checkForUpdates() {
        lock.lock()
        defer { lock.unlock() }

        guard let handler = eventHandler else { return }
        let now = clock()

        // While the current transcript is fresh pickSession keeps it, so the directory scan is skipped.
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
                // History primes turn state silently, so a turn in progress still ends in done (FR-014).
                tracker.reset()
                tracker.prime(fromSeed: seed.lines.flatMap(Self.entries(fromLine:)))
                handler(tracker.usageEvent(at: now, seed: true))
                return
            }
        }

        let read = tail.readNew()
        guard read.grew else { return }
        currentScanInterval = pollInterval
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
