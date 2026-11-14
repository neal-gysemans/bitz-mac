import Foundation
import AppKit
@preconcurrency import Darwin

/// Information about a running process sampled by the system.
public struct RunningProcessInfo: Sendable, Equatable {
    public let pid: pid_t
    public let name: String
    public let bundleIdentifier: String?
    public let cpuPercent: Double

    public init(pid: pid_t, name: String, bundleIdentifier: String? = nil, cpuPercent: Double = 0.0) {
        self.pid = pid
        self.name = name
        self.bundleIdentifier = bundleIdentifier
        self.cpuPercent = cpuPercent
    }
}

/// Injectable provider abstraction for listing processes and telemetry.
public protocol ProcessListingProviding: Sendable {
    func listRunningProcesses() -> [RunningProcessInfo]
    func listRunningProcesses(matchingAgents catalog: [AgentDefinition]) -> [RunningProcessInfo]
}

extension ProcessListingProviding {
    public func listRunningProcesses(matchingAgents catalog: [AgentDefinition]) -> [RunningProcessInfo] {
        listRunningProcesses()
    }
}

/// Default system provider using NSWorkspace and Darwin libproc/Mach task info.
public final class SystemProcessListingProvider: ProcessListingProviding, @unchecked Sendable {
    private struct CPUSample {
        let taskMachTicks: UInt64
        let wallMachTicks: UInt64
    }

    private struct CandidateMatcher {
        let processNames: Set<String>
        let bundleIDs: Set<String>
        let maxNameLength: Int

        init(catalog: [AgentDefinition]) {
            var names = Set<String>()
            var bundles = Set<String>()
            var maxLen = 0
            for agent in catalog {
                for name in agent.processNames {
                    let lower = name.lowercased()
                    let helper = "\(lower) helper"
                    names.insert(lower)
                    names.insert(helper)
                    maxLen = max(maxLen, helper.utf8.count)
                }
                for bundle in agent.bundleIdentifiers {
                    bundles.insert(bundle.lowercased())
                }
            }
            self.processNames = names
            self.bundleIDs = bundles
            self.maxNameLength = maxLen
        }

        var isEmpty: Bool {
            processNames.isEmpty && bundleIDs.isEmpty
        }

        func matches(name: String, bundleIdentifier: String?) -> Bool {
            if let bundle = bundleIdentifier?.lowercased() {
                if bundle.hasPrefix("com.apple.") {
                    return false
                }
                if bundleIDs.contains(bundle) {
                    return true
                }
            }
            return processNames.contains(name.lowercased())
        }
    }

    private struct CandidateProcess {
        let pid: pid_t
        let name: String
        let bundleIdentifier: String?
        let isMatch: Bool
    }

    private let lock = NSLock()
    private var previousSamples: [pid_t: CPUSample] = [:]
    private var _lastTaskInfoCallCount: Int = 0
    private let catalogProvider: @Sendable () -> [AgentDefinition]

    /// Internal test visibility for verifying `proc_pidinfo` call scoping.
    var lastTaskInfoCallCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return _lastTaskInfoCallCount
    }

    public init(catalogProvider: @escaping @Sendable () -> [AgentDefinition] = { AgentDefinition.builtInCatalog }) {
        self.catalogProvider = catalogProvider
    }

    public func listRunningProcesses() -> [RunningProcessInfo] {
        collectProcesses(matchingAgents: catalogProvider(), includeUnmatched: true)
    }

    public func listRunningProcesses(matchingAgents catalog: [AgentDefinition]) -> [RunningProcessInfo] {
        collectProcesses(matchingAgents: catalog, includeUnmatched: false)
    }

    private func collectProcesses(matchingAgents catalog: [AgentDefinition], includeUnmatched: Bool) -> [RunningProcessInfo] {
        let matcher = CandidateMatcher(catalog: catalog)
        if !includeUnmatched && matcher.isEmpty {
            lock.lock()
            previousSamples.removeAll()
            _lastTaskInfoCallCount = 0
            lock.unlock()
            return []
        }

        let candidates = discoverCandidates(matcher: matcher, includeUnmatched: includeUnmatched)
        let (sampled, taskInfoCalls) = sampleTaskInfo(for: candidates)
        let cpuByPID = computeCPUAndPruneCache(sampled: sampled, taskInfoCalls: taskInfoCalls)

        return candidates.map { candidate in
            RunningProcessInfo(
                pid: candidate.pid,
                name: candidate.name,
                bundleIdentifier: candidate.bundleIdentifier,
                cpuPercent: cpuByPID[candidate.pid] ?? 0.0
            )
        }
    }

    private func discoverCandidates(matcher: CandidateMatcher, includeUnmatched: Bool) -> [CandidateProcess] {
        var candidates: [CandidateProcess] = []
        var seenPIDs = Set<pid_t>()
        var fallbackBundlesByPID: [pid_t: String] = [:]

        for app in NSWorkspace.shared.runningApplications {
            let pid = app.processIdentifier
            guard pid > 0 else { continue }
            let bundleID = app.bundleIdentifier
            if let name = app.localizedName ?? app.executableURL?.lastPathComponent, !name.isEmpty {
                guard seenPIDs.insert(pid).inserted else { continue }
                let isMatch = matcher.matches(name: name, bundleIdentifier: bundleID)
                if isMatch || includeUnmatched {
                    candidates.append(CandidateProcess(pid: pid, name: name, bundleIdentifier: bundleID, isMatch: isMatch))
                }
            } else if let bundleID {
                fallbackBundlesByPID[pid] = bundleID
            }
        }

        appendHeadlessCandidates(
            matcher: matcher,
            includeUnmatched: includeUnmatched,
            fallbackBundlesByPID: fallbackBundlesByPID,
            seenPIDs: &seenPIDs,
            into: &candidates
        )
        return candidates
    }

    private func appendHeadlessCandidates(
        matcher: CandidateMatcher,
        includeUnmatched: Bool,
        fallbackBundlesByPID: [pid_t: String],
        seenPIDs: inout Set<pid_t>,
        into candidates: inout [CandidateProcess]
    ) {
        let estimatedCount = proc_listallpids(nil, 0)
        guard estimatedCount > 0 else { return }

        var capacity = Int(estimatedCount) + 128
        var pids = [pid_t](repeating: 0, count: capacity)
        var actualCount = Int(proc_listallpids(&pids, Int32(capacity * MemoryLayout<pid_t>.stride)))
        if actualCount >= capacity {
            capacity = actualCount + 256
            pids = [pid_t](repeating: 0, count: capacity)
            actualCount = Int(proc_listallpids(&pids, Int32(capacity * MemoryLayout<pid_t>.stride)))
        }

        let count = max(0, min(actualCount, pids.count))
        var nameBuf = [CChar](repeating: 0, count: 256)
        var pathBuf = [CChar](repeating: 0, count: Int(MAXPATHLEN) * 4)

        for i in 0..<count {
            let pid = pids[i]
            guard pid > 0, seenPIDs.insert(pid).inserted else { continue }
            guard let name = Self.resolveProcessName(
                pid: pid,
                nameBuf: &nameBuf,
                pathBuf: &pathBuf,
                preferFullPathWhenTruncated: matcher.maxNameLength >= 31
            ) else {
                continue
            }

            let bundleID = fallbackBundlesByPID[pid]
            let isMatch = matcher.matches(name: name, bundleIdentifier: bundleID)
            if isMatch || includeUnmatched {
                candidates.append(CandidateProcess(pid: pid, name: name, bundleIdentifier: bundleID, isMatch: isMatch))
            }
        }
    }

    private func sampleTaskInfo(for candidates: [CandidateProcess]) -> ([pid_t: CPUSample], Int) {
        var sampled: [pid_t: CPUSample] = [:]
        var taskInfoCalls = 0
        let expectedSize = Int32(MemoryLayout<proc_taskinfo>.stride)

        // Only call proc_pidinfo(PROC_PIDTASKINFO) on PIDs that matched a candidate agent.
        for candidate in candidates where candidate.isMatch {
            var taskInfo = proc_taskinfo()
            let bytesRead = withUnsafeMutablePointer(to: &taskInfo) { ptr in
                proc_pidinfo(candidate.pid, PROC_PIDTASKINFO, 0, ptr, expectedSize)
            }
            let wallMachTicks = mach_absolute_time()
            taskInfoCalls += 1
            if bytesRead == expectedSize {
                // pti_total_user / pti_total_system are Mach absolute time units on Apple Silicon & Intel.
                let taskMachTicks = taskInfo.pti_total_user &+ taskInfo.pti_total_system
                sampled[candidate.pid] = CPUSample(taskMachTicks: taskMachTicks, wallMachTicks: wallMachTicks)
            }
        }
        return (sampled, taskInfoCalls)
    }

    private func computeCPUAndPruneCache(sampled: [pid_t: CPUSample], taskInfoCalls: Int) -> [pid_t: Double] {
        var cpuByPID: [pid_t: Double] = [:]
        cpuByPID.reserveCapacity(sampled.count)
        var nextSamples: [pid_t: CPUSample] = [:]
        nextSamples.reserveCapacity(sampled.count)

        lock.lock()
        for (pid, current) in sampled {
            if let prev = previousSamples[pid],
               current.wallMachTicks > prev.wallMachTicks,
               current.taskMachTicks >= prev.taskMachTicks {
                let deltaTask = current.taskMachTicks - prev.taskMachTicks
                let deltaWall = current.wallMachTicks - prev.wallMachTicks
                cpuByPID[pid] = (Double(deltaTask) / Double(deltaWall)) * 100.0
            } else {
                cpuByPID[pid] = 0.0
            }
            nextSamples[pid] = current
        }
        previousSamples = nextSamples
        _lastTaskInfoCallCount = taskInfoCalls
        lock.unlock()

        return cpuByPID
    }

    static func resolveProcessName(
        pid: pid_t,
        nameBuf: inout [CChar],
        pathBuf: inout [CChar],
        preferFullPathWhenTruncated: Bool = false
    ) -> String? {
        let nameLen = Int(proc_name(pid, &nameBuf, UInt32(nameBuf.count)))
        if nameLen > 0, nameBuf[0] != 0 {
            if preferFullPathWhenTruncated && nameLen >= 31 {
                let pathLen = proc_pidpath(pid, &pathBuf, UInt32(pathBuf.count))
                if pathLen > 0, pathBuf[0] != 0, let fullName = basename(fromCStringBuffer: pathBuf) {
                    return fullName
                }
            }
            return decodeCString(nameBuf)
        }

        let pathLen = proc_pidpath(pid, &pathBuf, UInt32(pathBuf.count))
        if pathLen > 0, pathBuf[0] != 0 {
            return basename(fromCStringBuffer: pathBuf)
        }
        return nil
    }

    private static func decodeCString(_ buffer: [CChar]) -> String {
        let count = buffer.firstIndex(of: 0) ?? buffer.count
        return buffer.withUnsafeBytes { raw in
            String(decoding: raw[0..<count], as: UTF8.self)
        }
    }

    private static func basename(fromCStringBuffer buffer: [CChar]) -> String? {
        guard buffer[0] != 0 else { return nil }
        var end = 0
        var lastSlash = -1
        while end < buffer.count {
            let ch = buffer[end]
            if ch == 0 { break }
            if ch == 47 { // '/'
                lastSlash = end
            }
            end += 1
        }
        let start = lastSlash >= 0 ? lastSlash + 1 : 0
        guard start < end else { return nil }
        return buffer.withUnsafeBytes { raw in
            String(decoding: raw[start..<end], as: UTF8.self)
        }
    }
}

/// Agent adapter that polls running processes and bundle IDs to detect active agents.
public final class ProcessAgentAdapter: AgentAdapter, @unchecked Sendable {
    public let id: String = "process-agent-adapter"

    private let provider: ProcessListingProviding
    private let catalogProvider: @Sendable () -> [AgentDefinition]
    private let excludedAgentIDs: Set<String>
    private let pollInterval: TimeInterval
    private let clock: @Sendable () -> Date

    private var eventHandler: (@Sendable (AgentEvent) -> Void)?
    private var timerTask: Task<Void, Never>? = nil

    private struct TrackedAgentState {
        var lastSeen: Date
        var isWorking: Bool
        var wasHighCPU: Bool
    }

    // State tracking across ticks
    private var trackedAgents: [String: TrackedAgentState] = [:]
    private let lock = NSLock()
    /// Minimum configurable runaway threshold floor (50%); prevents waking @MainActor when agents are idle.
    private static let highCPUFloorPercent: Double = 50.0
    /// Tags every event as app presence (see `AgentEvent.isProcessPresence`).
    private static let presenceMetadata = [AgentEvent.MetadataKey.source: "process"]

    private static func cpuUsageMetadata(cpuPercent: Double) -> [String: String] {
        [
            AgentEvent.MetadataKey.source: "process",
            AgentEvent.MetadataKey.cpuPercent: String(cpuPercent)
        ]
    }

    public init(
        provider: ProcessListingProviding = SystemProcessListingProvider(),
        catalogProvider: @escaping @Sendable () -> [AgentDefinition] = { AgentDefinition.builtInCatalog },
        excludedAgentIDs: Set<String> = [],
        pollInterval: TimeInterval = 3.0,
        clock: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.provider = provider
        self.catalogProvider = catalogProvider
        self.excludedAgentIDs = excludedAgentIDs
        self.pollInterval = pollInterval
        self.clock = clock
    }

    /// Sets the event callback without launching the background polling timer (for deterministic unit tests).
    public func setHandlerForTesting(_ onEvent: @escaping @Sendable (AgentEvent) -> Void) {
        lock.withLock { eventHandler = onEvent }
    }

    public func start(onEvent: @escaping @Sendable (AgentEvent) -> Void) {
        setHandlerForTesting(onEvent)
        self.timerTask?.cancel()

        self.timerTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self = self else { break }
                self.performSampleTick()
                try? await Task.sleep(nanoseconds: UInt64(self.pollInterval * 1_000_000_000))
            }
        }
    }

    public func stop() {
        timerTask?.cancel()
        timerTask = nil
        lock.lock()
        eventHandler = nil
        trackedAgents.removeAll()
        lock.unlock()
    }

    /// Public method to execute a synchronous tick, ideal for unit testing.
    public func performSampleTick() {
        guard let handler = lock.withLock({ eventHandler }) else { return }

        let catalog = catalogProvider().filter { $0.isEnabled && !excludedAgentIDs.contains($0.id) }
        let processes = provider.listRunningProcesses(matchingAgents: catalog)
        let now = clock()

        var currentMatchingAgents: [String: (def: AgentDefinition, isWorking: Bool, cpuPercent: Double)] = [:]

        for proc in processes {
            for agentDef in catalog {
                if agentDef.matches(processName: proc.name, bundleIdentifier: proc.bundleIdentifier) {
                    // Working heuristic: if CPU > 1.0% or newly observed
                    let isWorking = proc.cpuPercent > 1.0
                    if let existing = currentMatchingAgents[agentDef.id] {
                        currentMatchingAgents[agentDef.id] = (
                            agentDef,
                            existing.isWorking || isWorking,
                            existing.cpuPercent + proc.cpuPercent
                        )
                    } else {
                        currentMatchingAgents[agentDef.id] = (agentDef, isWorking, proc.cpuPercent)
                    }
                }
            }
        }

        var pendingEvents: [AgentEvent] = []

        lock.lock()

        // 1. Detect newly started, working, or high-CPU agents
        for (agentID, match) in currentMatchingAgents {
            let isHighCPU = match.cpuPercent >= Self.highCPUFloorPercent
            if let existing = trackedAgents[agentID] {
                // If it wasn't working before and now is working, fire .working
                if !existing.isWorking && match.isWorking {
                    pendingEvents.append(AgentEvent(
                        agentID: agentID,
                        agentName: match.def.displayName,
                        kind: .working,
                        message: "\(match.def.displayName) is working...",
                        timestamp: now,
                        metadata: Self.presenceMetadata
                    ))
                }
                trackedAgents[agentID] = TrackedAgentState(
                    lastSeen: now,
                    isWorking: existing.isWorking || match.isWorking,
                    wasHighCPU: isHighCPU
                )
                if isHighCPU || existing.wasHighCPU {
                    pendingEvents.append(AgentEvent(
                        agentID: agentID,
                        agentName: match.def.displayName,
                        kind: .usage,
                        timestamp: now,
                        metadata: Self.cpuUsageMetadata(cpuPercent: match.cpuPercent)
                    ))
                }
            } else {
                // Brand new agent detected
                let isWorking = match.isWorking
                trackedAgents[agentID] = TrackedAgentState(
                    lastSeen: now,
                    isWorking: isWorking,
                    wasHighCPU: isHighCPU
                )
                pendingEvents.append(AgentEvent(
                    agentID: agentID,
                    agentName: match.def.displayName,
                    kind: isWorking ? .working : .started,
                    message: isWorking ? "\(match.def.displayName) is working..." : "\(match.def.displayName) started",
                    timestamp: now,
                    metadata: Self.presenceMetadata
                ))
                if isHighCPU {
                    pendingEvents.append(AgentEvent(
                        agentID: agentID,
                        agentName: match.def.displayName,
                        kind: .usage,
                        timestamp: now,
                        metadata: Self.cpuUsageMetadata(cpuPercent: match.cpuPercent)
                    ))
                }
            }
        }

        // 2. Detect agents that have exited
        let currentIDs = Set(currentMatchingAgents.keys)
        let removedIDs = trackedAgents.keys.filter { !currentIDs.contains($0) }

        for removedID in removedIDs {
            if let agentDef = catalog.first(where: { $0.id == removedID }) {
                pendingEvents.append(AgentEvent(
                    agentID: removedID,
                    agentName: agentDef.displayName,
                    kind: .done,
                    message: "\(agentDef.displayName) finished",
                    timestamp: now,
                    metadata: Self.presenceMetadata
                ))
            }
            trackedAgents.removeValue(forKey: removedID)
        }

        lock.unlock()

        for event in pendingEvents {
            handler(event)
        }
    }
}
