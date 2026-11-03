import Foundation
import Combine

/// Outcome of attempting to submit an approval decision (FR-006, C-003).
public enum ApprovalDispatchResult: Equatable, Sendable {
    case approved
    case rejected
    case tokenNotFound
    case tokenExpired
    case channelWriteFailed(String)
}

/// Decision to dispatch to an approval channel.
public enum ApprovalDecision: String, Codable, Sendable {
    case approve = "approve"
    case reject = "reject"
}

/// Request-scoped token model for pending agent approvals (FR-006, FR-007, C-003).
public struct AgentApprovalRequest: Sendable, Identifiable, Equatable {
    public let id: String
    public let agentID: String
    public let agentName: String
    public let toolName: String?
    public let commandSummary: String?
    public let decisionChannel: String?
    public let owningPID: pid_t?
    public let bundleID: String?
    public let workingDir: String?
    public let createdAt: Date
    public let expiresAt: Date

    public init(
        id: String,
        agentID: String,
        agentName: String,
        toolName: String? = nil,
        commandSummary: String? = nil,
        decisionChannel: String? = nil,
        owningPID: pid_t? = nil,
        bundleID: String? = nil,
        workingDir: String? = nil,
        createdAt: Date = Date(),
        ttlSeconds: TimeInterval = 300
    ) {
        self.id = id
        self.agentID = agentID
        self.agentName = agentName
        self.toolName = toolName
        self.commandSummary = commandSummary
        self.decisionChannel = decisionChannel
        self.owningPID = owningPID
        self.bundleID = bundleID
        self.workingDir = workingDir
        self.createdAt = createdAt
        self.expiresAt = createdAt.addingTimeInterval(ttlSeconds)
    }

    public var isExpired: Bool {
        Date() >= expiresAt
    }

    public var hasApprovalChannel: Bool {
        guard let channel = decisionChannel, !channel.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return false
        }
        return true
    }
}

/// `@MainActor` observable store managing active pending approval tokens, single-use consumption,
/// and automatic TTL expiry sweeps (FR-006, FR-007, C-003).
@MainActor
public final class AgentApprovalStore: ObservableObject {
    /// Active pending approval requests keyed by requestID (FR-007).
    @Published public private(set) var pendingRequests: [String: AgentApprovalRequest] = [:]

    /// The latest active request for the agent currently showing in the popup (if any).
    @Published public private(set) var activeRequest: AgentApprovalRequest? = nil

    /// Invoked whenever a decision is successfully consumed and dispatched.
    public var onDecisionSubmitted: (@MainActor (String, ApprovalDecision) -> Void)? = nil

    private let clock: @Sendable () -> Date
    private let ttl: TimeInterval
    private let channelWriter: @Sendable (String, ApprovalDecision, String) -> Result<Void, Error>

    public init(
        ttl: TimeInterval = 300,
        clock: @escaping @Sendable () -> Date = { Date() },
        channelWriter: @escaping @Sendable (String, ApprovalDecision, String) -> Result<Void, Error> = { channel, decision, requestID in
            AgentApprovalStore.defaultChannelWriter(channel: channel, decision: decision, requestID: requestID)
        }
    ) {
        self.ttl = ttl
        self.clock = clock
        self.channelWriter = channelWriter
    }

    /// Connects to `AgentMonitorService` to register incoming requests and dismiss popups on approval (T016).
    public func bind(agentMonitor: AgentMonitorService) {
        let previousHandler = agentMonitor.onEventHandled
        agentMonitor.onEventHandled = { [weak self] event in
            previousHandler?(event)
            guard let self else { return }
            if event.kind == .needsApproval {
                self.registerRequest(from: event)
            } else if event.kind == .done || event.kind == .failed {
                self.clearRequests(for: event.agentID)
            }
        }

        self.onDecisionSubmitted = { [weak agentMonitor] _, _ in
            agentMonitor?.dismissPopup()
        }
    }

    /// Registers a pending approval request from an `AgentEvent` (T016, T017, FR-007).
    @discardableResult
    public func registerRequest(from event: AgentEvent) -> AgentApprovalRequest? {
        sweepExpired()

        guard event.kind == .needsApproval, let requestID = event.approvalRequestID else { return nil }
        let now = clock()

        let request = AgentApprovalRequest(
            id: requestID,
            agentID: event.agentID,
            agentName: event.agentName,
            toolName: event.toolName,
            commandSummary: event.commandSummary,
            decisionChannel: event.approvalChannel,
            owningPID: event.owningPID.map { pid_t($0) },
            bundleID: event.bundleID,
            workingDir: event.workingDir,
            createdAt: now,
            ttlSeconds: ttl
        )

        pendingRequests[requestID] = request
        activeRequest = request
        return request
    }

    /// Submits a decision (approve or reject) for a pending request (FR-006, C-003).
    /// Single-use: once consumed, the request is removed from `pendingRequests` immediately.
    @discardableResult
    public func submitDecision(_ decision: ApprovalDecision, for requestID: String) -> ApprovalDispatchResult {
        guard let request = pendingRequests[requestID] else {
            return .tokenNotFound
        }

        if clock() >= request.expiresAt {
            pendingRequests.removeValue(forKey: requestID)
            if activeRequest?.id == requestID { activeRequest = nil }
            sweepExpired()
            return .tokenExpired
        }

        sweepExpired()

        // Single-use token invalidation (C-003): remove token BEFORE writing decision
        pendingRequests.removeValue(forKey: requestID)
        if activeRequest?.id == requestID {
            activeRequest = nil
        }

        // Write decision to the channel if present (FR-006, NFR-002: Zero keystroke injection)
        if let channel = request.decisionChannel, !channel.isEmpty {
            let writeResult = channelWriter(channel, decision, requestID)
            switch writeResult {
            case .success:
                onDecisionSubmitted?(requestID, decision)
                return decision == .approve ? .approved : .rejected
            case .failure(let error):
                return .channelWriteFailed(error.localizedDescription)
            }
        }

        onDecisionSubmitted?(requestID, decision)
        return decision == .approve ? .approved : .rejected
    }

    /// Clears any pending requests for an agent when the turn completes or the agent stops.
    public func clearRequests(for agentID: String) {
        pendingRequests = pendingRequests.filter { $0.value.agentID != agentID }
        if activeRequest?.agentID == agentID {
            activeRequest = nil
        }
    }

    /// Clears the active request display without invalidating pending tokens.
    public func clearActiveRequest() {
        activeRequest = nil
    }

    /// Removes all expired requests.
    public func sweepExpired() {
        let now = clock()
        let expiredIDs = pendingRequests.filter { now >= $0.value.expiresAt }.map(\.key)
        for id in expiredIDs {
            pendingRequests.removeValue(forKey: id)
        }
        if let active = activeRequest, now >= active.expiresAt {
            activeRequest = nil
        }
    }

    /// Default file / FIFO response channel writer (FR-006, NFR-002: Zero keystroke injection).
    nonisolated public static func defaultChannelWriter(channel: String, decision: ApprovalDecision, requestID: String) -> Result<Void, Error> {
        let payload: [String: String] = [
            "requestID": requestID,
            "decision": decision.rawValue,
            "timestamp": ISO8601DateFormatter().string(from: Date())
        ]
        do {
            let data = try JSONEncoder().encode(payload)
            let fileURL = URL(fileURLWithPath: channel)
            try data.write(to: fileURL, options: .atomic)
            return .success(())
        } catch {
            return .failure(error)
        }
    }
}
