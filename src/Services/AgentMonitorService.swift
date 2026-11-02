import Foundation
import Combine

/// Protocol for agent detection adapters (ProcessAdapter, DropboxAdapter, LogWatcherAdapter).
public protocol AgentAdapter: AnyObject, Sendable {
    var id: String { get }
    func start(onEvent: @escaping @Sendable (AgentEvent) -> Void)
    func stop()
}

/// Central manager orchestrating agent adapters, catalog definitions, and popup state.
@MainActor
public final class AgentMonitorService: ObservableObject {
    @Published public private(set) var activePopup: AgentPopupState? = nil
    @Published public private(set) var activeAgents: Set<String> = []
    @Published public private(set) var catalog: [AgentDefinition] = []
    @Published public var popupsEnabled: Bool {
        didSet {
            userDefaults.set(popupsEnabled, forKey: Self.popupsEnabledKey)
            if !popupsEnabled {
                activePopup = nil
            } else if activeWarning != nil {
                presentWarningBubble()
            }
        }
    }
    /// Single warning slot (FR-010); drives the warning visor and the warning bubble.
    @Published public private(set) var activeWarning: AgentWarning? = nil
    /// Most recently updated context reading (gauge).
    @Published public private(set) var latestContext: AgentContextReading? = nil
    @Published public var signalSettings: AgentSignalSettings {
        didSet {
            let clamped = signalSettings.clamped()
            if clamped != signalSettings { signalSettings = clamped }
            if let data = try? JSONEncoder().encode(signalSettings) {
                userDefaults.set(data, forKey: Self.signalSettingsKey)
            }
            recomputeContextReadings()
        }
    }

    private var adapters: [AgentAdapter] = []
    private let clock: @Sendable () -> Date
    private let userDefaults: UserDefaults
    private var dismissTask: Task<Void, Never>? = nil
    private var stallTask: Task<Void, Never>? = nil

    /// Per-agent stall and context-crossing inputs (data-model.md, "Per-agent session").
    private struct SessionState {
        var turnActive = false
        var awaitingApproval = false
        var pendingTools = 0
        var lastActivity: Date
        var stallFired = false
        var contextFired = false
        /// Sends `usage` heartbeats (a session-log adapter); only these can stall (FR-009).
        var tracksLog = false
    }
    private var sessions: [String: SessionState] = [:]
    private var contextReadings: [String: AgentContextReading] = [:]
    /// Agent whose approval bubble currently covers the warning bubble.
    private var approvalOverrideAgentID: String? = nil
    /// Agent whose approval popup was shown last; valid while `activePopup` is that approval.
    private var approvalPopupAgentID: String? = nil
    private let stallSweepInterval: TimeInterval

    private static let customAgentsKey = "Bitz.AgentMonitor.CustomAgents"
    private static let agentDisabledPrefix = "Bitz.AgentMonitor.Disabled."
    private static let popupsEnabledKey = "Bitz.AgentMonitor.PopupsEnabled"
    private static let signalSettingsKey = "Bitz.AgentMonitor.SignalSettings"

    public init(
        adapters: [AgentAdapter] = [],
        clock: @escaping @Sendable () -> Date = { Date() },
        userDefaults: UserDefaults = .standard,
        stallSweepInterval: TimeInterval = 5
    ) {
        self.adapters = adapters
        self.clock = clock
        self.userDefaults = userDefaults
        self.stallSweepInterval = stallSweepInterval
        self.popupsEnabled = userDefaults.object(forKey: Self.popupsEnabledKey) as? Bool ?? true
        self.signalSettings = userDefaults.data(forKey: Self.signalSettingsKey)
            .flatMap { try? JSONDecoder().decode(AgentSignalSettings.self, from: $0) }?
            .clamped() ?? .default
        loadCatalog()
    }

    /// Loads built-in and user-custom agent definitions.
    public func loadCatalog() {
        var merged: [AgentDefinition] = []
        for builtIn in AgentDefinition.builtInCatalog {
            let disabled = userDefaults.bool(forKey: Self.agentDisabledPrefix + builtIn.id)
            var def = builtIn
            def.isEnabled = !disabled
            merged.append(def)
        }

        if let data = userDefaults.data(forKey: Self.customAgentsKey),
           let custom = try? JSONDecoder().decode([AgentDefinition].self, from: data) {
            for customAgent in custom {
                let disabled = userDefaults.bool(forKey: Self.agentDisabledPrefix + customAgent.id)
                var def = customAgent
                def.isEnabled = !disabled
                merged.append(def)
            }
        }
        self.catalog = merged
    }

    /// Registers a custom agent definition and persists to UserDefaults.
    public func addCustomAgent(displayName: String, processNames: [String], bundleIdentifiers: [String] = []) {
        let id = UUID().uuidString.lowercased()
        let custom = AgentDefinition(
            id: id,
            displayName: displayName,
            processNames: processNames,
            bundleIdentifiers: bundleIdentifiers,
            isCustom: true,
            isEnabled: true
        )
        var existingCustom = loadStoredCustomAgents()
        existingCustom.append(custom)
        if let encoded = try? JSONEncoder().encode(existingCustom) {
            userDefaults.set(encoded, forKey: Self.customAgentsKey)
        }
        loadCatalog()
    }

    /// Removes a custom agent definition by ID.
    public func removeCustomAgent(id: String) {
        var existingCustom = loadStoredCustomAgents()
        existingCustom.removeAll { $0.id == id }
        if let encoded = try? JSONEncoder().encode(existingCustom) {
            userDefaults.set(encoded, forKey: Self.customAgentsKey)
        }
        loadCatalog()
    }

    /// Enables or disables an agent definition.
    public func setAgentEnabled(id: String, isEnabled: Bool) {
        userDefaults.set(!isEnabled, forKey: Self.agentDisabledPrefix + id)
        loadCatalog()
        if !isEnabled {
            activeAgents.remove(id)
            if activePopup?.agentName == catalog.first(where: { $0.id == id })?.displayName {
                activePopup = nil
            }
            sessions[id] = nil
            contextReadings[id] = nil
            if latestContext?.agentID == id { latestContext = nil }
            if activeWarning?.agentID == id {
                acknowledgeWarning()
            } else if approvalOverrideAgentID == id {
                approvalOverrideAgentID = nil
                presentWarningBubble()
            }
        }
    }

    public func isAgentEnabled(id: String) -> Bool {
        return catalog.first(where: { $0.id == id })?.isEnabled ?? false
    }

    private func loadStoredCustomAgents() -> [AgentDefinition] {
        guard let data = userDefaults.data(forKey: Self.customAgentsKey),
              let list = try? JSONDecoder().decode([AgentDefinition].self, from: data) else {
            return []
        }
        return list
    }

    /// Starts all registered adapters.
    public func startMonitoring() {
        for adapter in adapters {
            adapter.start { [weak self] event in
                Task { @MainActor [weak self] in
                    self?.handleEvent(event)
                }
            }
        }
        stallTask?.cancel()
        let sweepNanoseconds = UInt64(stallSweepInterval * 1_000_000_000)
        stallTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: sweepNanoseconds)
                // Cancel wakes the sleep early: don't run one last sweep after stopMonitoring().
                guard !Task.isCancelled, let self else { return }
                self.evaluateStalls()
            }
        }
    }

    /// Stops all registered adapters.
    public func stopMonitoring() {
        for adapter in adapters {
            adapter.stop()
        }
        dismissTask?.cancel()
        dismissTask = nil
        stallTask?.cancel()
        stallTask = nil
        activePopup = nil
        activeAgents.removeAll()
        sessions.removeAll()
        contextReadings.removeAll()
        latestContext = nil
        activeWarning = nil
        approvalOverrideAgentID = nil
    }

    /// Processes an incoming AgentEvent and evaluates popup display rules.
    public func handleEvent(_ event: AgentEvent) {
        let now = clock()

        // Discard events older than 60 seconds (NFR-004)
        if now.timeIntervalSince(event.timestamp) > 60.0 {
            return
        }

        // Verify if agent is enabled in catalog
        guard let agentDef = catalog.first(where: { $0.id == event.agentID }), agentDef.isEnabled else {
            return
        }

        let id = event.agentID
        let name = event.agentName
        var session = sessions[id] ?? SessionState(lastActivity: now)

        // Popup priority while a warning is active: data-model.md "Warning slot".
        switch event.kind {
        case .started:
            activeAgents.insert(id)
        case .working:
            activeAgents.insert(id)
            session.turnActive = true
            session.awaitingApproval = false
            session.lastActivity = now
            session.stallFired = false
            if activeWarning == nil {
                let text = event.message ?? "\(name) is working..."
                displayPopupIfEnabled(text: text, kind: .working, agentName: name, durationSeconds: 4.0)
            } else {
                restoreWarningBubble(ifOverriddenBy: id)
            }
        case .almostDone:
            activeAgents.insert(id)
            session.lastActivity = now
            if activeWarning == nil {
                if signalSettings.almostDoneEnabled {
                    let text = event.message ?? "✨ \(name) is almost done!"
                    displayPopupIfEnabled(text: text, kind: .almostDone, agentName: name, durationSeconds: 6.0)
                }
            } else {
                restoreWarningBubble(ifOverriddenBy: id)
            }
        case .needsApproval:
            activeAgents.insert(id)
            session.awaitingApproval = true
            if activeWarning?.agentID == id {
                acknowledgeWarning()
            } else if activeWarning != nil {
                approvalOverrideAgentID = id
            }
            let text = event.message ?? "\(name) needs your approval!"
            approvalPopupAgentID = id
            // Approval popup persists indefinitely until next event or manual action
            displayPopupIfEnabled(text: text, kind: .needsApproval, agentName: name, durationSeconds: nil)
        case .done:
            activeAgents.remove(id)
            // App presence (Claude desktop app shares the `claude` ID with Claude Code) never ends a turn or clears a warning.
            if !event.isProcessPresence {
                session.turnActive = false
                session.awaitingApproval = false
                session.pendingTools = 0
                if activeWarning?.agentID == id { acknowledgeWarning() }
            }
            if activeWarning == nil {
                let text = event.message ?? "\(name) is done!"
                // Done auto-dismisses after ~6.0 seconds
                displayPopupIfEnabled(text: text, kind: .done, agentName: name, durationSeconds: 6.0)
            } else {
                restoreWarningBubble(ifOverriddenBy: id)
            }
        case .warning:
            let reason = event.warningReason
            if signalSettings.isEnabled(reason) {
                raiseWarning(AgentWarning(agentID: id, agentName: name, reason: reason,
                                          text: event.message ?? "⚠️ \(name) reported a problem"))
            } else {
                restoreWarningBubble(ifOverriddenBy: id)
            }
        case .usage:
            session.tracksLog = true
            session.lastActivity = now
            session.stallFired = false
            if let pending = event.pendingTools { session.pendingTools = pending }
            if let turnActive = event.turnActive { session.turnActive = turnActive }
            if let tokens = event.contextTokens {
                let reading = AgentContextReading(agentID: id, agentName: name, tokens: tokens,
                                                  windowTokens: signalSettings.contextWindow(for: id))
                contextReadings[id] = reading
                latestContext = reading
                if reading.percent >= signalSettings.contextThresholdPercent {
                    if !session.contextFired {
                        session.contextFired = true
                        if !event.isSeed && signalSettings.contextWarningEnabled {
                            raiseWarning(AgentWarning(agentID: id, agentName: name, reason: .context,
                                text: "⚠️ \(name): context at \(reading.percent)%! Consider /compact soon."))
                        }
                    }
                } else {
                    session.contextFired = false
                }
            }
        }
        sessions[id] = session
    }

    /// Raises one stall warning per stall (FR-009). Runs every 5 s while monitoring; public for tests.
    public func evaluateStalls() {
        guard signalSettings.stallWarningEnabled else { return }
        let now = clock()
        let minutes = signalSettings.stallTimeoutMinutes
        for (id, session) in sessions
        where session.tracksLog && session.turnActive && !session.awaitingApproval && session.pendingTools == 0 && !session.stallFired
            && now.timeIntervalSince(session.lastActivity) >= Double(minutes) * 60 {
            guard let agent = catalog.first(where: { $0.id == id }), agent.isEnabled else { continue }
            sessions[id]?.stallFired = true
            raiseWarning(AgentWarning(agentID: id, agentName: agent.displayName, reason: .stall,
                                      text: "⚠️ \(agent.displayName) may be stuck: no output for \(minutes) min."))
        }
    }

    /// Clears the warning (Got it / menu Dismiss Agent Warning) and its bubble.
    public func acknowledgeWarning() {
        activeWarning = nil
        approvalOverrideAgentID = nil
        if activePopup?.kind == .warning {
            dismissPopup()
        }
    }

    private func raiseWarning(_ warning: AgentWarning) {
        activeWarning = warning
        // Approval takes the bubble (FR-010): a warning raised while another agent's approval shows waits behind it.
        if activePopup?.kind == .needsApproval, let approver = approvalPopupAgentID, approver != warning.agentID {
            approvalOverrideAgentID = approver
            return
        }
        approvalOverrideAgentID = nil
        presentWarningBubble()
    }

    private func presentWarningBubble() {
        guard let warning = activeWarning else { return }
        displayPopupIfEnabled(text: warning.text, kind: .warning, agentName: warning.agentName, durationSeconds: nil)
    }

    /// The approving agent's next lifecycle event supersedes its approval, so the warning bubble returns.
    private func restoreWarningBubble(ifOverriddenBy id: String) {
        guard approvalOverrideAgentID == id else { return }
        approvalOverrideAgentID = nil
        presentWarningBubble()
    }

    /// Re-applies the configured windows to stored readings; never raises a warning.
    private func recomputeContextReadings() {
        contextReadings = contextReadings.mapValues {
            AgentContextReading(agentID: $0.agentID, agentName: $0.agentName, tokens: $0.tokens,
                                windowTokens: signalSettings.contextWindow(for: $0.agentID))
        }
        latestContext = latestContext.flatMap { contextReadings[$0.agentID] }
    }

    private func displayPopupIfEnabled(text: String, kind: AgentEventKind, agentName: String, durationSeconds: TimeInterval?) {
        guard popupsEnabled else { return }
        displayPopup(text: text, kind: kind, agentName: agentName, durationSeconds: durationSeconds)
    }

    private func displayPopup(text: String, kind: AgentEventKind, agentName: String, durationSeconds: TimeInterval?) {
        dismissTask?.cancel()
        let expiresAt = durationSeconds.map { clock().addingTimeInterval($0) }
        activePopup = AgentPopupState(text: text, kind: kind, agentName: agentName, expiresAt: expiresAt)

        if let duration = durationSeconds {
            dismissTask = Task { @MainActor [weak self] in
                try? await Task.sleep(nanoseconds: UInt64(duration * 1_000_000_000))
                guard !Task.isCancelled else { return }
                if self?.activePopup?.expiresAt == expiresAt {
                    self?.activePopup = nil
                }
            }
        }
    }

    /// Manually dismisses the current popup.
    public func dismissPopup() {
        dismissTask?.cancel()
        dismissTask = nil
        activePopup = nil
    }
}
