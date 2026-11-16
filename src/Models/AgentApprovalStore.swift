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
    public let sessionID: String?
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
        sessionID: String? = nil,
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
        self.sessionID = sessionID
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
        agentMonitor.onEventHandled = { [weak self, weak agentMonitor] event in
            previousHandler?(event)
            guard let self else { return }
            if event.kind == .needsApproval {
                let req = self.registerRequest(from: event)
                if let req {
                    let stateKey = AgentMonitorService.makeStateKey(agentID: event.agentID, sessionID: event.sessionID)
                    agentMonitor?.setLinkedApprovalRequest(req, for: stateKey)
                }
            } else if event.kind == .done || event.kind == .failed {
                self.clearRequests(for: event.agentID, sessionID: event.sessionID)
            }
        }

        self.onDecisionSubmitted = { [weak agentMonitor] requestID, _ in
            agentMonitor?.dismissPopup()
            agentMonitor?.clearLinkedApprovalRequest(requestID: requestID)
        }
    }

    /// Registers a pending approval request from an `AgentEvent` (T016, T017, FR-007).
    @discardableResult
    public func registerRequest(from event: AgentEvent) -> AgentApprovalRequest? {
        sweepExpired()

        guard event.kind == .needsApproval else { return nil }
        guard let requestID = event.approvalRequestID else {
            activeRequest = nil
            return nil
        }
        let now = clock()

        let request = AgentApprovalRequest(
            id: requestID,
            agentID: event.agentID,
            agentName: event.agentName,
            sessionID: event.sessionID,
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
    public func clearRequests(for agentID: String, sessionID: String? = nil) {
        pendingRequests = pendingRequests.filter { !($0.value.agentID == agentID && (sessionID == nil || $0.value.sessionID == sessionID)) }
        if activeRequest?.agentID == agentID && (sessionID == nil || activeRequest?.sessionID == sessionID) {
            activeRequest = nil
        }
    }

    /// Clears the active request display without invalidating pending tokens.
    public func clearActiveRequest() {
        activeRequest = nil
    }

    /// Returns the active approval request only when it matches the currently displayed `.needsApproval` popup.
    public func matchingActiveRequest(for popup: AgentPopupState?) -> AgentApprovalRequest? {
        guard let popup, popup.kind == .needsApproval, let request = activeRequest else { return nil }
        if let popupRequestID = popup.approvalRequestID {
            return request.id == popupRequestID ? request : nil
        }
        if popup.agentID != nil {
            return nil
        }
        return request.agentName == popup.agentName ? request : nil
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

    public enum ApprovalChannelError: LocalizedError, Sendable {
        case unsafeChannelPath(String)

        public var errorDescription: String? {
            switch self {
            case .unsafeChannelPath(let path):
                return "Refused to write approval response outside allowed directories: \(path)"
            }
        }
    }

    nonisolated public static var defaultApprovalsDirectory: URL {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return appSupport.appendingPathComponent("Bitz/agent-approvals", isDirectory: true)
    }

    nonisolated private static func validatedChannelURL(for channel: String) throws -> URL {
        let trimmed = channel.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.hasPrefix("/") else {
            throw ApprovalChannelError.unsafeChannelPath(channel)
        }
        let rawURL = URL(fileURLWithPath: trimmed)
        guard !rawURL.pathComponents.contains("..") else {
            throw ApprovalChannelError.unsafeChannelPath(channel)
        }
        let resolvedParent = rawURL.deletingLastPathComponent().resolvingSymlinksInPath().standardizedFileURL
        let fileURL = resolvedParent.appendingPathComponent(rawURL.lastPathComponent)
        let candidatePath = fileURL.path

        let allowedRoots = [
            defaultApprovalsDirectory,
            FileManager.default.temporaryDirectory,
            URL(fileURLWithPath: "/private/tmp", isDirectory: true)
        ].map { $0.resolvingSymlinksInPath().standardizedFileURL.path }

        let isAllowed = allowedRoots.contains { root in
            candidatePath == root || candidatePath.hasPrefix(root.hasSuffix("/") ? root : root + "/")
        }
        guard isAllowed else {
            throw ApprovalChannelError.unsafeChannelPath(channel)
        }

        if let attrs = try? FileManager.default.attributesOfItem(atPath: candidatePath),
           let fileType = attrs[.type] as? FileAttributeType,
           (fileType == .typeSymbolicLink || fileType == .typeDirectory) {
            throw ApprovalChannelError.unsafeChannelPath(channel)
        }

        return fileURL
    }

    /// Default file / FIFO response channel writer (FR-006, NFR-002: Zero keystroke injection).
    nonisolated public static func defaultChannelWriter(channel: String, decision: ApprovalDecision, requestID: String) -> Result<Void, Error> {
        let payload: [String: String] = [
            "requestID": requestID,
            "decision": decision.rawValue,
            "timestamp": ISO8601DateFormatter().string(from: Date())
        ]
        do {
            let fileURL = try validatedChannelURL(for: channel)
            let parentDir = fileURL.deletingLastPathComponent()
            if !FileManager.default.fileExists(atPath: parentDir.path) {
                try FileManager.default.createDirectory(
                    at: parentDir,
                    withIntermediateDirectories: true,
                    attributes: [.posixPermissions: 0o700]
                )
            }
            let data = try JSONEncoder().encode(payload)
            var st = stat()
            let isFIFO = lstat(fileURL.path, &st) == 0 && (st.st_mode & mode_t(S_IFMT)) == mode_t(S_IFIFO)
            if isFIFO {
                // O_NONBLOCK avoids hanging @MainActor if the reader process already exited; O_NOFOLLOW closes TOCTOU symlink swaps; F_SETNOSIGPIPE prevents SIGPIPE termination.
                let fd = open(fileURL.path, O_WRONLY | O_NONBLOCK | O_NOFOLLOW)
                guard fd >= 0 else {
                    throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
                }
                defer { close(fd) }
                _ = fcntl(fd, F_SETNOSIGPIPE, 1)
                try data.withUnsafeBytes { rawBuffer in
                    guard let baseAddress = rawBuffer.baseAddress else { return }
                    var offset = 0
                    while offset < rawBuffer.count {
                        let written = write(fd, baseAddress.advanced(by: offset), rawBuffer.count - offset)
                        if written < 0 {
                            if errno == EINTR { continue }
                            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
                        }
                        if written == 0 {
                            throw POSIXError(.EIO)
                        }
                        offset += written
                    }
                }
            } else {
                try data.write(to: fileURL, options: .atomic)
                try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fileURL.path)
            }
            return .success(())
        } catch {
            return .failure(error)
        }
    }
}
