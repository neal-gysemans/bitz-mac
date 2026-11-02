import CryptoKit
import Foundation

/// One parsed session-log line, reduced to what turn, loop and usage tracking need (no line text, NFR-004).
public enum SessionLogEntry: Equatable, Sendable {
    case prompt
    case assistantOutput(contextTokens: Int?)
    case toolCall(id: String?, name: String, fingerprint: String)
    /// `id` nil clears all anonymous pending calls.
    case toolResult(id: String?)
    /// e.g. Antigravity `ask_question`.
    case approvalRequest
    case turnEnd(isDone: Bool)
    case compaction
}

/// Turns parsed session-log entries into `AgentEvent`s: working/done, loop warnings and usage readings (FR-008, FR-014).
/// A value type; adapters wrap it in their own lock.
public struct AgentSessionTracker: Sendable {
    public static let loopThreshold = 4

    public let agentID: String
    public let agentName: String
    /// Antigravity starts a turn on the prompt; Claude Code on the first assistant output (R4).
    public let startsTurnOnPrompt: Bool
    public private(set) var turnActive = false
    public private(set) var latestContextTokens: Int? = nil
    public var pendingTools: Int { pendingIDs.count + anonymousPending }

    private var awaitingFirstOutput = false
    private var pendingIDs: Set<String> = []
    private var anonymousPending = 0
    private var loopFingerprint: String?
    private var loopCount = 0
    private var loopFired = false

    public init(agentID: String, agentName: String, startsTurnOnPrompt: Bool) {
        self.agentID = agentID
        self.agentName = agentName
        self.startsTurnOnPrompt = startsTurnOnPrompt
    }

    public mutating func ingest(_ entries: [SessionLogEntry], at now: Date) -> [AgentEvent] {
        var events: [AgentEvent] = []
        func emit(_ kind: AgentEventKind, _ message: String, _ metadata: [String: String]? = nil) {
            events.append(AgentEvent(agentID: agentID, agentName: agentName, kind: kind, message: message, timestamp: now, metadata: metadata))
        }

        for entry in entries {
            switch entry {
            case .prompt:
                if startsTurnOnPrompt {
                    turnActive = true
                    emit(.working, "\(agentName) is working...")
                } else {
                    awaitingFirstOutput = true
                }
            case .assistantOutput(let tokens):
                latestContextTokens = tokens ?? latestContextTokens
                if awaitingFirstOutput {
                    awaitingFirstOutput = false
                    turnActive = true
                    emit(.working, "\(agentName) is working...")
                }
            case .toolCall(let id, let name, let fingerprint):
                if let id { pendingIDs.insert(id) } else { anonymousPending += 1 }
                if fingerprint == loopFingerprint {
                    loopCount += 1
                } else {
                    loopFingerprint = fingerprint
                    loopCount = 1
                    loopFired = false
                }
                if loopCount >= Self.loopThreshold && !loopFired {
                    loopFired = true
                    emit(.warning, "⚠️ \(agentName) may be stuck in a tool loop (\(name) ×\(loopCount)).",
                         [AgentEvent.MetadataKey.reason: AgentWarningReason.loop.rawValue])
                }
            case .toolResult(let id):
                if let id { pendingIDs.remove(id) } else { anonymousPending = 0 }
            case .approvalRequest:
                emit(.needsApproval, "\(agentName) needs input!")
            case .turnEnd(let isDone):
                // Duplicate end markers (e.g. `end_turn` then `turn_duration`) are no-ops.
                guard turnActive || awaitingFirstOutput else { continue }
                let wasTurnActive = turnActive
                turnActive = false
                awaitingFirstOutput = false
                pendingIDs.removeAll()
                anonymousPending = 0
                if isDone && wasTurnActive { emit(.done, "\(agentName) is done!") }
            case .compaction:
                loopFingerprint = nil
                loopCount = 0
                loopFired = false
            }
        }
        return events
    }

    /// Restores turn state from the startup / session-switch seed without emitting events (FR-014):
    /// a turn already in progress is tracked from now on; the loop streak starts fresh.
    /// Call right after `reset()`.
    public mutating func prime(fromSeed entries: [SessionLogEntry]) {
        // A trailing compaction clears exactly the loop streak (fingerprint, count, fired) and nothing else.
        _ = ingest(entries + [.compaction], at: .distantPast)
        // The seed window can start after the turn's prompt: output since the last turn end still means a turn in progress.
        let sinceLastEnd = entries.reversed().prefix { if case .turnEnd = $0 { return false } else { return true } }
        let hasActivity = sinceLastEnd.contains {
            switch $0 {
            case .assistantOutput, .toolCall: return true
            default: return false
            }
        }
        if hasActivity && !turnActive && !awaitingFirstOutput { turnActive = true }
    }

    public func usageEvent(at now: Date, seed: Bool) -> AgentEvent {
        var metadata = [
            AgentEvent.MetadataKey.pendingTools: String(pendingTools),
            AgentEvent.MetadataKey.turnActive: String(turnActive),
            AgentEvent.MetadataKey.seed: String(seed),
        ]
        if let latestContextTokens { metadata[AgentEvent.MetadataKey.contextTokens] = String(latestContextTokens) }
        return AgentEvent(agentID: agentID, agentName: agentName, kind: .usage, timestamp: now, metadata: metadata)
    }

    /// New session: everything fresh except identity.
    public mutating func reset() {
        self = AgentSessionTracker(agentID: agentID, agentName: agentName, startsTurnOnPrompt: startsTurnOnPrompt)
    }

    /// Tool name + SHA-256 of the input serialized with sorted keys; identical inputs match regardless of key order (R6).
    public static func fingerprint(name: String, input: Any?) -> String {
        // Wrapping in an array lets scalars pass the validity check, which must run first:
        // NSJSONSerialization raises an uncatchable exception on invalid objects.
        let data = input.flatMap { value in
            JSONSerialization.isValidJSONObject([value])
                ? try? JSONSerialization.data(withJSONObject: [value], options: [.sortedKeys])
                : nil
        } ?? Data()
        return name + ":" + SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}
