import SwiftUI
import AppKit

/// Tactical Option B Action Bar HUD for the 3D Cyber-Ship Agent Command Deck.
///
/// Integrates:
/// - Priority-sorted session selector pills with agent icon, status dot, readable session name, and context %
/// - Selected session live details: state badge, metadata (PID / bundle ID), linear context gauge (<70% cyan, 70-89% amber, >=90% crimson), and command/warning summary
/// - 1-click action buttons: APPROVE (when needs approval), GOT IT (when warning), JUMP (app activator), and DIFF (diff viewer)
/// - Empty state ("No Active Agent Sessions · Systems Standby") when no agent sessions are active
public struct TacticalActionBarView: View {
    public let sessions: [AgentSessionSnapshot]
    @Binding public var selectedSessionKey: String?
    public var agentMonitor: AgentMonitorService?
    public var approvalStore: AgentApprovalStore?
    public var appActivator: (any AppActivating)?
    public var diffViewer: (any DiffViewing)?

    // Callbacks for deterministic unit testing and action decoupling
    public var onApprove: ((AgentSessionSnapshot) -> Void)?
    public var onAcknowledgeWarning: ((AgentSessionSnapshot) -> Void)?
    public var onJump: ((AgentSessionSnapshot) -> Void)?
    public var onDiff: ((AgentSessionSnapshot) -> Void)?
    public var onTriggerComms: ((AgentSessionSnapshot) -> Void)?
    public var onToggleTaskLauncher: (() -> Void)?

    public init(
        sessions: [AgentSessionSnapshot],
        selectedSessionKey: Binding<String?>,
        agentMonitor: AgentMonitorService? = nil,
        approvalStore: AgentApprovalStore? = nil,
        appActivator: (any AppActivating)? = nil,
        diffViewer: (any DiffViewing)? = nil,
        onApprove: ((AgentSessionSnapshot) -> Void)? = nil,
        onAcknowledgeWarning: ((AgentSessionSnapshot) -> Void)? = nil,
        onJump: ((AgentSessionSnapshot) -> Void)? = nil,
        onDiff: ((AgentSessionSnapshot) -> Void)? = nil,
        onTriggerComms: ((AgentSessionSnapshot) -> Void)? = nil,
        onToggleTaskLauncher: (() -> Void)? = nil
    ) {
        self.sessions = sessions
        self._selectedSessionKey = selectedSessionKey
        self.agentMonitor = agentMonitor
        self.approvalStore = approvalStore
        self.appActivator = appActivator
        self.diffViewer = diffViewer
        self.onApprove = onApprove
        self.onAcknowledgeWarning = onAcknowledgeWarning
        self.onJump = onJump
        self.onDiff = onDiff
        self.onTriggerComms = onTriggerComms
        self.onToggleTaskLauncher = onToggleTaskLauncher
    }

    // MARK: - Selected Session Resolution

    /// Effective selected session, defaulting smoothly to the first (highest priority) session if unselected.
    public var effectiveSelectedSession: AgentSessionSnapshot? {
        if let key = selectedSessionKey, let match = sessions.first(where: { $0.stateKey == key }) {
            return match
        }
        return sessions.first
    }

    // MARK: - Body

    public var body: some View {
        VStack(spacing: 8) {
            if sessions.isEmpty {
                emptyStateView
            } else {
                sessionSelectorRow
                Divider()
                    .background(Color.white.opacity(0.12))
                sessionDetailAndActionRow
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity)
        .frame(height: 126)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(Color.black.opacity(0.85))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(Color.cyan.opacity(0.3), lineWidth: 1)
        )
        .padding(.horizontal, 16)
        .padding(.bottom, 12)
        .accessibilityIdentifier("TacticalActionBarContainer")
    }

    // MARK: - Subviews

    private var emptyStateView: some View {
        HStack(spacing: 10) {
            Circle()
                .fill(Color.cyan.opacity(0.6))
                .frame(width: 8, height: 8)
            Text("No Active Agent Sessions · Systems Standby")
                .font(.system(size: 12, weight: .medium, design: .monospaced))
                .foregroundStyle(Color.white.opacity(0.7))
            if let onToggleTaskLauncher {
                taskLauncherButton(action: onToggleTaskLauncher)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityIdentifier("TacticalActionBarEmptyState")
    }

    private func taskLauncherButton(action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 4) {
                Image(systemName: "plus.circle.fill")
                    .font(.system(size: 10, weight: .bold))
                Text("TASK")
                    .font(.system(size: 10, weight: .heavy, design: .monospaced))
            }
            .padding(.horizontal, 9)
            .padding(.vertical, 5)
            .background(RoundedRectangle(cornerRadius: 6).fill(Color.cyan.opacity(0.22)))
            .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.cyan.opacity(0.7), lineWidth: 1))
            .foregroundStyle(Color.cyan)
        }
        .buttonStyle(.plain)
        .help("Spawn a Phase 2 CLI Task-Kitten using your existing agent subscription")
        .accessibilityLabel("Spawn Task-Kitten")
        .accessibilityIdentifier("TacticalActionBarNewTaskButton")
    }

    private var sessionSelectorRow: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                if let onToggleTaskLauncher {
                    taskLauncherButton(action: onToggleTaskLauncher)
                }
                ForEach(sessions) { session in
                    let isSelected = (session.stateKey == effectiveSelectedSession?.stateKey)
                    Button {
                        selectedSessionKey = session.stateKey
                    } label: {
                        HStack(spacing: 6) {
                            Image(systemName: Self.agentIcon(for: session.agentID))
                                .font(.system(size: 10, weight: .bold))
                                .foregroundStyle(Color.cyan)

                            Circle()
                                .fill(Color(nsColor: session.lifecycleState.nsColor))
                                .frame(width: 6, height: 6)

                            Text(session.sessionLabel)
                                .font(.system(size: 12, weight: .bold, design: .monospaced))
                                .lineLimit(1)
                                .foregroundStyle(Color.white)

                            if let reading = session.contextReading {
                                Text("\(reading.percent)%")
                                    .font(.system(size: 11, weight: .bold, design: .monospaced))
                                    .foregroundStyle(Self.contextGaugeColor(for: reading.percent))
                            } else {
                                Text("--%")
                                    .font(.system(size: 11, weight: .semibold, design: .monospaced))
                                    .foregroundStyle(Color.white.opacity(0.75))
                            }
                        }
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                        .background(
                            RoundedRectangle(cornerRadius: 6)
                                .fill(isSelected ? Color.cyan.opacity(0.18) : Color.white.opacity(0.06))
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 6)
                                .stroke(isSelected ? Color.cyan : Color.white.opacity(0.15), lineWidth: isSelected ? 1.5 : 1)
                        )
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("SessionSelectorPill_\(session.stateKey)")
                }
            }
        }
        .clipped()
        .frame(maxWidth: .infinity)
        .frame(height: 32)
        .accessibilityIdentifier("TacticalActionBarSessionSelectorRow")
    }

    private var sessionDetailAndActionRow: some View {
        HStack(alignment: .center, spacing: 16) {
            if let session = effectiveSelectedSession {
                // Left & Center: Live Details
                VStack(alignment: .leading, spacing: 4) {
                    // Row 1: Session Label + State Badge + Metadata
                    HStack(spacing: 8) {
                        Text(session.sessionLabel)
                            .font(.system(size: 13, weight: .heavy, design: .monospaced))
                            .foregroundStyle(Color.white)
                            .lineLimit(1)
                            .truncationMode(.tail)

                        // State Badge
                        HStack(spacing: 3) {
                            Image(systemName: Self.statusIcon(for: session.lifecycleState))
                                .font(.system(size: 9, weight: .bold))
                            Text(Self.statusBadgeText(for: session.lifecycleState))
                                .font(.system(size: 9.5, weight: .heavy, design: .monospaced))
                        }
                        .padding(.horizontal, 7)
                        .padding(.vertical, 2.5)
                        .background(
                            Capsule().fill(Color(nsColor: session.lifecycleState.nsColor))
                        )
                        .foregroundStyle(Self.statusBadgeForegroundColor(for: session.lifecycleState))
                        .fixedSize(horizontal: true, vertical: false)
                        .accessibilityIdentifier("TacticalActionBarStateBadge")

                        // Secondary metadata (PID, BundleID)
                        Text(metadataText(for: session))
                            .font(.system(size: 11, weight: .medium, design: .monospaced))
                            .foregroundStyle(Color.white.opacity(0.82))
                            .lineLimit(1)
                            .truncationMode(.tail)
                            .accessibilityIdentifier("TacticalActionBarMetadataRow")
                    }

                    // Row 2: Context Gauge Progress Bar + Token Readout
                    HStack(spacing: 8) {
                        let percent = session.contextReading?.percent ?? 0
                        let tokens = session.contextReading?.tokens ?? 0
                        let window = session.contextReading?.windowTokens ?? 200_000
                        let progress = Self.contextGaugeProgress(tokens: tokens, windowTokens: window)
                        let gaugeColor = Self.contextGaugeColor(for: percent)

                        GeometryReader { geo in
                            ZStack(alignment: .leading) {
                                Capsule()
                                    .fill(Color.white.opacity(0.16))
                                    .frame(height: 5)

                                Capsule()
                                    .fill(gaugeColor)
                                    .frame(width: max(0, min(geo.size.width, geo.size.width * progress)), height: 5)
                            }
                        }
                        .frame(height: 5)
                        .frame(maxWidth: 140)

                        Text(Self.formatContextText(tokens: tokens, windowTokens: window, percent: percent))
                            .font(.system(size: 11, weight: .bold, design: .monospaced))
                            .foregroundStyle(gaugeColor)
                            .lineLimit(1)
                            .truncationMode(.tail)
                    }
                    .accessibilityIdentifier("TacticalActionBarContextGauge")

                    // Row 3: Command / Warning / Tool Summary
                    HStack(spacing: 6) {
                        Image(systemName: "terminal.fill")
                            .font(.system(size: 10))
                            .foregroundStyle(Color.cyan)

                        Text(Self.summaryText(for: session))
                            .font(.system(size: 11, weight: .semibold, design: .monospaced))
                            .lineLimit(1)
                            .truncationMode(.tail)
                            .foregroundStyle(Color.white.opacity(0.95))
                    }
                    .accessibilityIdentifier("TacticalActionBarCommandSummary")
                }
                .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)

                // Right: 1-Click Action Buttons
                HStack(spacing: 8) {
                    // APPROVE button: shown ONLY when an explicit hook response channel exists (R5, FR-006)
                    if Self.shouldShowApproveButton(for: session) {
                        Button {
                            triggerApprove(for: session)
                        } label: {
                            HStack(spacing: 4) {
                                Image(systemName: "checkmark.circle.fill")
                                    .font(.system(size: 10, weight: .bold))
                                Text("APPROVE")
                                    .font(.system(size: 10, weight: .heavy, design: .monospaced))
                            }
                            .padding(.horizontal, 10)
                            .padding(.vertical, 6)
                            .background(Capsule().fill(Color(red: 0.0, green: 0.85, blue: 0.55)))
                            .foregroundStyle(Color.black)
                        }
                        .buttonStyle(.plain)
                        .help("Approve the agent's pending request")
                        .accessibilityLabel("Approve Agent Request")
                        .accessibilityIdentifier("TacticalActionBarApproveButton")
                    }

                    // GOT IT button: visible when warning active or in warning state
                    if Self.shouldShowGotItButton(for: session) {
                        Button {
                            triggerAcknowledgeWarning(for: session)
                        } label: {
                            HStack(spacing: 4) {
                                Image(systemName: "checkmark.shield.fill")
                                    .font(.system(size: 10, weight: .bold))
                                Text("GOT IT")
                                    .font(.system(size: 10, weight: .heavy, design: .monospaced))
                            }
                            .padding(.horizontal, 10)
                            .padding(.vertical, 6)
                            .background(Capsule().fill(Color(red: 0.95, green: 0.65, blue: 0.15)))
                            .foregroundStyle(Color.black)
                        }
                        .buttonStyle(.plain)
                        .help("Acknowledge active agent warning")
                        .accessibilityLabel("Acknowledge Agent Warning")
                        .accessibilityIdentifier("TacticalActionBarGotItButton")
                    }

                    // COMMS button: animate sending a message / handoff to another active agent
                    if sessions.count >= 2 {
                        Button {
                            onTriggerComms?(session)
                        } label: {
                            HStack(spacing: 4) {
                                Image(systemName: "paperplane.fill")
                                    .font(.system(size: 10, weight: .bold))
                                Text("COMMS")
                                    .font(.system(size: 10, weight: .heavy, design: .monospaced))
                            }
                            .padding(.horizontal, 10)
                            .padding(.vertical, 6)
                            .background(Capsule().fill(Color.purple.opacity(0.85)))
                            .foregroundStyle(Color.white)
                        }
                        .buttonStyle(.plain)
                        .help("Send a message / handoff from this agent to a peer agent")
                        .accessibilityLabel("Deliver Inter-Agent Message")
                        .accessibilityIdentifier("TacticalActionBarCommsButton")
                    }

                    // JUMP button: brings owning terminal / IDE process forward
                    Button {
                        triggerJump(for: session)
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: "arrow.up.forward.app.fill")
                                .font(.system(size: 10, weight: .bold))
                            Text("JUMP")
                                .font(.system(size: 10, weight: .heavy, design: .monospaced))
                        }
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background(Capsule().fill(Color(red: 0.12, green: 0.55, blue: 0.95)))
                        .foregroundStyle(Color.white)
                    }
                    .buttonStyle(.plain)
                    .help("Bring the agent's terminal or IDE forward")
                    .accessibilityLabel("Jump to Agent Application")
                    .accessibilityIdentifier("TacticalActionBarJumpButton")

                    // DIFF button: opens git diff for working directory
                    Button {
                        Task { await triggerDiff(for: session) }
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: "doc.text.magnifyingglass")
                                .font(.system(size: 10, weight: .bold))
                            Text("DIFF")
                                .font(.system(size: 10, weight: .heavy, design: .monospaced))
                        }
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background(Capsule().fill(Color.white.opacity(0.12)))
                        .overlay(Capsule().stroke(Color.white.opacity(0.25), lineWidth: 1))
                        .foregroundStyle(Color.white)
                    }
                    .buttonStyle(.plain)
                    .help("Open git diff of working changes")
                    .accessibilityLabel("View Agent Changes Diff")
                    .accessibilityIdentifier("TacticalActionBarDiffButton")
                }
                .fixedSize(horizontal: true, vertical: false)
                .layoutPriority(1)
            }
        }
        .frame(maxWidth: .infinity)
        .frame(height: 58)
        .accessibilityIdentifier("TacticalActionBarDetailRow")
    }

    // MARK: - Button Visibility Rules (R5 & FR-006)

    /// Whether the 1-click APPROVE button should be shown for a session (R5, FR-006).
    /// Shown ONLY when an explicit hook response channel exists (`hasApprovalChannel == true`).
    public static func shouldShowApproveButton(for session: AgentSessionSnapshot) -> Bool {
        session.linkedApprovalRequest?.hasApprovalChannel == true
    }

    /// Whether the GOT IT acknowledgement button should be shown for a session.
    /// Shown when a warning reason is active or the lifecycle state is `.warning`.
    public static func shouldShowGotItButton(for session: AgentSessionSnapshot) -> Bool {
        session.activeWarning != nil || session.lifecycleState == .warning
    }

    // MARK: - Action Trigger Dispatchers (Testable & Decoupled)

    /// Dispatches an approval decision for the given session to `approvalStore` (if a channel exists),
    /// dismisses any active agent popup via `agentMonitor`, and invokes the `onApprove` callback.
    @MainActor
    public func triggerApprove(for session: AgentSessionSnapshot) {
        if let req = session.linkedApprovalRequest, req.hasApprovalChannel {
            approvalStore?.submitDecision(.approve, for: req.id)
        }
        agentMonitor?.dismissPopup()
        onApprove?(session)
    }

    /// Acknowledges an active warning for the given session via `agentMonitor`,
    /// dismisses any active agent popup, and invokes the `onAcknowledgeWarning` callback.
    @MainActor
    public func triggerAcknowledgeWarning(for session: AgentSessionSnapshot) {
        agentMonitor?.acknowledgeWarning(stateKey: session.stateKey)
        agentMonitor?.dismissPopup()
        onAcknowledgeWarning?(session)
    }

    /// Brings the owning application / IDE / terminal for the given session to the foreground
    /// via `appActivator`, and invokes the `onJump` callback.
    @MainActor
    @discardableResult
    public func triggerJump(for session: AgentSessionSnapshot) -> Bool {
        let pid = session.linkedApprovalRequest?.owningPID
        let bundleID = session.linkedApprovalRequest?.bundleID ?? catalogBundleID(for: session.agentID)
        let activator = appActivator ?? WorkspaceAppActivator()
        let result = activator.activateApp(pid: pid, bundleID: bundleID)
        onJump?(session)
        return result
    }

    /// Opens the diff viewer for the session's working directory asynchronously via `diffViewer`,
    /// invokes the `onDiff` callback, and returns the result of the diff operation.
    @MainActor
    @discardableResult
    public func triggerDiff(for session: AgentSessionSnapshot) async -> Bool {
        let dir = session.workingDir ?? session.linkedApprovalRequest?.workingDir
        let viewer = diffViewer ?? SystemDiffViewer()
        let result = await viewer.openDiff(workingDirectory: dir)
        onDiff?(session)
        return result
    }

    // MARK: - Helpers

    private func metadataText(for session: AgentSessionSnapshot) -> String {
        var parts: [String] = []
        parts.append("Agent: \(session.agentID)")
        if let pid = session.linkedApprovalRequest?.owningPID {
            parts.append("PID: \(pid)")
        }
        if let bundle = session.linkedApprovalRequest?.bundleID ?? catalogBundleID(for: session.agentID) {
            parts.append(bundle)
        }
        return parts.joined(separator: " • ")
    }

    private func catalogBundleID(for agentID: String) -> String? {
        agentMonitor?.catalog.first(where: { $0.id == agentID })?.bundleIdentifiers.first
            ?? AgentDefinition.builtInCatalog.first(where: { $0.id == agentID })?.bundleIdentifiers.first
    }

    // MARK: - Static Formatters & Color Mappings (Testable)

    public static func contextGaugeProgress(tokens: Int, windowTokens: Int) -> Double {
        guard windowTokens > 0 else { return 0.0 }
        return min(1.0, max(0.0, Double(tokens) / Double(windowTokens)))
    }

    public static func contextGaugeColor(for percent: Int) -> Color {
        if percent < 70 {
            return Color(red: 0.0, green: 0.85, blue: 1.0) // Cyan (<70%)
        } else if percent < 90 {
            return Color(red: 1.0, green: 0.75, blue: 0.1) // Amber (70-89%)
        } else {
            return Color(red: 1.0, green: 0.25, blue: 0.2) // Crimson (>=90%)
        }
    }

    public static func formatContextText(tokens: Int, windowTokens: Int, percent: Int) -> String {
        let formattedTokens = AgentContextReading.formatTokens(tokens)
        let formattedWindow = AgentContextReading.formatTokens(windowTokens)
        return "\(formattedTokens) / \(formattedWindow) tokens (\(percent)%)"
    }

    public static func statusBadgeText(for state: AgentSessionLifecycleState) -> String {
        switch state {
        case .needsApproval: return "NEEDS APPROVAL"
        case .warning:       return "WARNING"
        case .failed:        return "FAILED"
        case .almostDone:    return "ALMOST DONE"
        case .working:       return "WORKING"
        case .done:          return "DONE"
        case .idle:          return "IDLE"
        }
    }

    public static func statusBadgeForegroundColor(for state: AgentSessionLifecycleState) -> Color {
        switch state {
        case .warning, .failed:
            return Color.white
        case .needsApproval, .almostDone, .working, .done, .idle:
            return Color.black
        }
    }

    public static func statusIcon(for state: AgentSessionLifecycleState) -> String {
        switch state {
        case .needsApproval: return "exclamationmark.triangle.fill"
        case .warning:       return "exclamationmark.circle.fill"
        case .failed:        return "xmark.octagon.fill"
        case .almostDone:    return "bolt.fill"
        case .working:       return "circle.fill"
        case .done:          return "checkmark.circle.fill"
        case .idle:          return "moon.fill"
        }
    }

    public static func agentIcon(for agentID: String) -> String {
        switch agentID.lowercased() {
        case "claude": return "brain"
        case "antigravity": return "atom"
        case "codex": return "bubble.left.and.bubble.right.fill"
        case "cursor": return "cursorarrow.rays"
        case "gemini": return "sparkles"
        case "windsurf": return "wind"
        case "copilot": return "airplane"
        default: return "cpu"
        }
    }

    public static func summaryText(for session: AgentSessionSnapshot) -> String {
        if let req = session.linkedApprovalRequest {
            if let tool = req.toolName, let cmd = req.commandSummary {
                return "\(tool): \(cmd)"
            } else if let cmd = req.commandSummary {
                return cmd
            } else if let tool = req.toolName {
                return "Tool: \(tool)"
            }
        }
        if let warning = session.activeWarning {
            switch warning {
            case .loop: return "Tool loop detected: repetitive calls without progress"
            case .context: return "Context window threshold reached: consider /compact"
            case .stall: return "Agent stalled: no activity detected"
            case .rateLimit: return "Rate limit encountered: waiting for backoff"
            case .runawayCPU: return "Runaway CPU detected: sustained high processor usage"
            case .reported: return "Warning reported by agent"
            }
        }
        if session.pendingTools > 0 {
            return "Executing \(session.pendingTools) pending tool(s)..."
        }
        if let statusMsg = session.statusMessage,
           !statusMsg.isEmpty,
           session.lifecycleState == .done || session.lifecycleState == .failed || session.sessionID?.hasPrefix("kitten-") == true {
            return statusMsg
        }
        switch session.lifecycleState {
        case .needsApproval: return "Awaiting user approval to proceed"
        case .warning: return "Attention required"
        case .failed: return "Session terminated with failure"
        case .almostDone: return "Finalizing output and wraps"
        case .working: return "Agent active · Working on instructions"
        case .done: return "Turn completed successfully"
        case .idle: return "Standing by in MedBay"
        }
    }
}
