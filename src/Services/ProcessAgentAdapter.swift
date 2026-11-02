import Foundation
import AppKit

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
}

/// Default system provider using NSWorkspace and Darwin proc info.
public struct SystemProcessListingProvider: ProcessListingProviding {
    public init() {}

    public func listRunningProcesses() -> [RunningProcessInfo] {
        let runningApps = NSWorkspace.shared.runningApplications
        return runningApps.compactMap { app in
            guard let name = app.localizedName else { return nil }
            return RunningProcessInfo(
                pid: app.processIdentifier,
                name: name,
                bundleIdentifier: app.bundleIdentifier,
                cpuPercent: 0.0
            )
        }
    }
}

/// Agent adapter that polls running processes and bundle IDs to detect active agents.
public final class ProcessAgentAdapter: AgentAdapter, @unchecked Sendable {
    public let id: String = "process-agent-adapter"

    private let provider: ProcessListingProviding
    private let catalogProvider: @Sendable () -> [AgentDefinition]
    private let pollInterval: TimeInterval
    private let clock: @Sendable () -> Date

    private var eventHandler: (@Sendable (AgentEvent) -> Void)?
    private var timerTask: Task<Void, Never>? = nil

    // State tracking across ticks
    // Key: Agent ID -> (lastSeenDate, isCurrentlyWorking)
    private var trackedAgents: [String: (lastSeen: Date, isWorking: Bool)] = [:]
    private let lock = NSLock()
    /// Tags every event as app presence (see `AgentEvent.isProcessPresence`).
    private static let presenceMetadata = [AgentEvent.MetadataKey.source: "process"]

    public init(
        provider: ProcessListingProviding = SystemProcessListingProvider(),
        catalogProvider: @escaping @Sendable () -> [AgentDefinition] = { AgentDefinition.builtInCatalog },
        pollInterval: TimeInterval = 3.0,
        clock: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.provider = provider
        self.catalogProvider = catalogProvider
        self.pollInterval = pollInterval
        self.clock = clock
    }

    public func start(onEvent: @escaping @Sendable (AgentEvent) -> Void) {
        self.eventHandler = onEvent
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
        eventHandler = nil
        lock.lock()
        trackedAgents.removeAll()
        lock.unlock()
    }

    /// Public method to execute a synchronous tick, ideal for unit testing.
    public func performSampleTick() {
        guard let handler = eventHandler else { return }

        let processes = provider.listRunningProcesses()
        let catalog = catalogProvider().filter { $0.isEnabled }
        let now = clock()

        var currentMatchingAgents: [String: (def: AgentDefinition, isWorking: Bool)] = [:]

        for proc in processes {
            for agentDef in catalog {
                if agentDef.matches(processName: proc.name, bundleIdentifier: proc.bundleIdentifier) {
                    // Working heuristic: if CPU > 1.0% or newly observed
                    let isWorking = proc.cpuPercent > 1.0
                    if let existing = currentMatchingAgents[agentDef.id] {
                        currentMatchingAgents[agentDef.id] = (agentDef, existing.isWorking || isWorking)
                    } else {
                        currentMatchingAgents[agentDef.id] = (agentDef, isWorking)
                    }
                }
            }
        }

        lock.lock()
        defer { lock.unlock() }

        // 1. Detect newly started or working agents
        for (agentID, match) in currentMatchingAgents {
            if let existing = trackedAgents[agentID] {
                // If it wasn't working before and now is working, fire .working
                if !existing.isWorking && match.isWorking {
                    trackedAgents[agentID] = (lastSeen: now, isWorking: true)
                    handler(AgentEvent(
                        agentID: agentID,
                        agentName: match.def.displayName,
                        kind: .working,
                        message: "\(match.def.displayName) is working...",
                        timestamp: now,
                        metadata: Self.presenceMetadata
                    ))
                } else {
                    trackedAgents[agentID] = (lastSeen: now, isWorking: existing.isWorking || match.isWorking)
                }
            } else {
                // Brand new agent detected
                let isWorking = match.isWorking
                trackedAgents[agentID] = (lastSeen: now, isWorking: isWorking)
                handler(AgentEvent(
                    agentID: agentID,
                    agentName: match.def.displayName,
                    kind: isWorking ? .working : .started,
                    message: isWorking ? "\(match.def.displayName) is working..." : "\(match.def.displayName) started",
                    timestamp: now,
                    metadata: Self.presenceMetadata
                ))
            }
        }

        // 2. Detect agents that have exited
        let currentIDs = Set(currentMatchingAgents.keys)
        let removedIDs = trackedAgents.keys.filter { !currentIDs.contains($0) }

        for removedID in removedIDs {
            if let agentDef = catalog.first(where: { $0.id == removedID }) {
                handler(AgentEvent(
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
    }
}
