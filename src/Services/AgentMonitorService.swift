import AppKit
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
    /// Total number of concurrently active agent sessions across all enabled agents (#153).
    @Published public private(set) var activeAgentCount: Int = 0
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
    /// Result message from the last Claude Code hook install/uninstall action (#94 C7: kept on the service so tab switches preserve it).
    @Published public var hookActionMessage: String? = nil
    @Published public var isHookActionError: Bool = false
    @Published public var signalSettings: AgentSignalSettings {
        didSet {
            let clamped = signalSettings.clamped()
            if clamped != signalSettings { signalSettings = clamped }
            if let data = try? JSONEncoder().encode(signalSettings) {
                userDefaults.set(data, forKey: Self.signalSettingsKey)
            }
            if !signalSettings.runawayCPUWarningEnabled {
                runawaySinceByAgent.removeAll()
                runawayFiredByAgent.removeAll()
            }
            recomputeContextReadings()
        }
    }

    private var adapters: [AgentAdapter] = []
    private let clock: @Sendable () -> Date
    private let userDefaults: UserDefaults
    private var dismissTask: Task<Void, Never>? = nil
    private var stallTask: Task<Void, Never>? = nil
    private var wakeObserver: NSObjectProtocol? = nil

    /// Per-session stall and context-crossing inputs, keyed by `(agentID, sessionID)` (#153).
    private struct SessionState {
        let agentID: String
        var turnActive = false
        var awaitingApproval = false
        var pendingTools = 0
        var lastActivity: Date
        var stallFired = false
        var contextFired = false
        /// Sends `usage` heartbeats (a session-log adapter); only these can stall (FR-009).
        var tracksLog = false
    }
    private static let defaultSessionSubkey = "__default__"
    private var activeSessionsByAgent: [String: Set<String>] = [:]
    private var sessions: [String: SessionState] = [:]
    private var runawaySinceByAgent: [String: Date] = [:]
    private var runawayFiredByAgent: Set<String> = []
    private var contextReadings: [String: AgentContextReading] = [:]
    private var latestContextStateKey: String? = nil
    private var activeWarningStateKey: String? = nil
    /// Agent/session whose approval bubble currently covers the warning bubble.
    private var approvalOverrideAgentID: String? = nil
    private var approvalOverrideStateKey: String? = nil
    /// Agent/session whose approval popup was shown last; valid while `activePopup` is that approval.
    private var approvalPopupAgentID: String? = nil
    private var approvalPopupStateKey: String? = nil
    private let stallSweepInterval: TimeInterval
    public var licensingService: (any LicensingServiceProtocol)?

    public var onEventHandled: (@MainActor (AgentEvent) -> Void)? = nil

    private static let customAgentsKey = "Bitz.AgentMonitor.CustomAgents"
    private static let agentDisabledPrefix = "Bitz.AgentMonitor.Disabled."
    private static let popupsEnabledKey = "Bitz.AgentMonitor.PopupsEnabled"
    private static let signalSettingsKey = "Bitz.AgentMonitor.SignalSettings"

    public init(
        adapters: [AgentAdapter] = [],
        clock: @escaping @Sendable () -> Date = { Date() },
        userDefaults: UserDefaults = .standard,
        stallSweepInterval: TimeInterval = 5,
        licensingService: (any LicensingServiceProtocol)? = nil
    ) {
        self.adapters = adapters
        self.clock = clock
        self.userDefaults = userDefaults
        self.stallSweepInterval = stallSweepInterval
        self.licensingService = licensingService
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
            activeSessionsByAgent.removeValue(forKey: id)
            syncPublishedActiveState()
            if activePopup?.agentName == catalog.first(where: { $0.id == id })?.displayName {
                activePopup = nil
            }
            sessions = sessions.filter { $0.value.agentID != id }
            runawaySinceByAgent.removeValue(forKey: id)
            runawayFiredByAgent.remove(id)
            contextReadings = contextReadings.filter { $0.value.agentID != id }
            if latestContext?.agentID == id {
                latestContext = nil
                latestContextStateKey = nil
            }
            if activeWarning?.agentID == id {
                acknowledgeWarning()
            } else if approvalOverrideAgentID == id {
                approvalOverrideAgentID = nil
                approvalOverrideStateKey = nil
                presentWarningBubble()
            }
        }
    }

    /// Number of currently active concurrent sessions for a catalog `agentID` (#153).
    public func activeSessionCount(for agentID: String) -> Int {
        activeSessionsByAgent[agentID]?.count ?? 0
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
        if wakeObserver == nil {
            wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
                forName: NSWorkspace.didWakeNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.handleSystemWake()
                }
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
        if let wakeObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(wakeObserver)
            self.wakeObserver = nil
        }
        activePopup = nil
        activeSessionsByAgent.removeAll()
        syncPublishedActiveState()
        sessions.removeAll()
        runawaySinceByAgent.removeAll()
        runawayFiredByAgent.removeAll()
        contextReadings.removeAll()
        latestContext = nil
        latestContextStateKey = nil
        activeWarning = nil
        activeWarningStateKey = nil
        approvalOverrideAgentID = nil
        approvalOverrideStateKey = nil
        approvalPopupAgentID = nil
        approvalPopupStateKey = nil
    }

    private static func makeStateKey(agentID: String, sessionID: String?) -> String {
        if let sessionID {
            return "\(agentID)::\(sessionID)"
        }
        return agentID
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
        let subkey = event.sessionID ?? Self.defaultSessionSubkey
        let stateKey = Self.makeStateKey(agentID: id, sessionID: event.sessionID)
        var session = sessions[stateKey] ?? SessionState(agentID: id, lastActivity: now)

        // Popup priority while a warning is active: data-model.md "Warning slot".
        switch event.kind {
        case .started:
            registerActiveSession(agentID: id, subkey: subkey)
        case .working:
            registerActiveSession(agentID: id, subkey: subkey)
            session.turnActive = true
            session.awaitingApproval = false
            session.lastActivity = now
            session.stallFired = false
            if activeWarning == nil {
                let text = event.message ?? "\(name) is working..."
                displayPopupIfEnabled(text: text, kind: .working, agentName: name, durationSeconds: 4.0)
            } else {
                restoreWarningBubble(ifOverriddenByAgentID: id, stateKey: stateKey)
            }
        case .almostDone:
            registerActiveSession(agentID: id, subkey: subkey)
            session.lastActivity = now
            if activeWarning == nil {
                if signalSettings.almostDoneEnabled {
                    let text = event.message ?? "✨ \(name) is almost done!"
                    displayPopupIfEnabled(text: text, kind: .almostDone, agentName: name, durationSeconds: 6.0)
                }
            } else {
                restoreWarningBubble(ifOverriddenByAgentID: id, stateKey: stateKey)
            }
        case .needsApproval:
            registerActiveSession(agentID: id, subkey: subkey)
            session.awaitingApproval = true
            if matchesActiveWarning(agentID: id, stateKey: stateKey) {
                acknowledgeWarning()
            } else if activeWarning != nil {
                approvalOverrideAgentID = id
                approvalOverrideStateKey = stateKey
            }
            let text = event.message ?? "\(name) needs your approval!"
            approvalPopupAgentID = id
            approvalPopupStateKey = stateKey
            // Approval popup persists indefinitely until next event or manual action
            displayPopupIfEnabled(text: text, kind: .needsApproval, agentName: name, durationSeconds: nil)
        case .done:
            unregisterActiveSession(agentID: id, sessionID: event.sessionID, isProcessPresence: event.isProcessPresence)
            if event.isProcessPresence || activeSessionsByAgent[id] == nil {
                runawaySinceByAgent.removeValue(forKey: id)
                runawayFiredByAgent.remove(id)
            }
            // App presence (Claude desktop app shares the `claude` ID with Claude Code) never ends a turn or clears a warning.
            if !event.isProcessPresence {
                session.turnActive = false
                session.awaitingApproval = false
                session.pendingTools = 0
                if matchesActiveWarning(agentID: id, stateKey: stateKey) { acknowledgeWarning() }
            }
            if activeWarning == nil {
                let text = event.message ?? "\(name) is done!"
                // Done auto-dismisses after ~6.0 seconds
                displayPopupIfEnabled(text: text, kind: .done, agentName: name, durationSeconds: 6.0)
            } else {
                restoreWarningBubble(ifOverriddenByAgentID: id, stateKey: stateKey)
            }
        case .failed:
            unregisterActiveSession(agentID: id, sessionID: event.sessionID, isProcessPresence: event.isProcessPresence)
            if event.isProcessPresence || activeSessionsByAgent[id] == nil {
                runawaySinceByAgent.removeValue(forKey: id)
                runawayFiredByAgent.remove(id)
            }
            if !event.isProcessPresence {
                session.turnActive = false
                session.awaitingApproval = false
                session.pendingTools = 0
                if matchesActiveWarning(agentID: id, stateKey: stateKey) { acknowledgeWarning() }
            }
            if activeWarning == nil {
                let text = event.message ?? "❌ \(name) failed!"
                displayPopupIfEnabled(text: text, kind: .failed, agentName: name, durationSeconds: 6.0)
            } else {
                restoreWarningBubble(ifOverriddenByAgentID: id, stateKey: stateKey)
            }
        case .warning:
            let reason = event.warningReason
            if signalSettings.isEnabled(reason) {
                raiseWarning(
                    AgentWarning(agentID: id, agentName: name, reason: reason,
                                 text: event.message ?? "⚠️ \(name) reported a problem"),
                    stateKey: stateKey
                )
            } else {
                restoreWarningBubble(ifOverriddenByAgentID: id, stateKey: stateKey)
            }
        case .usage:
            if !event.isProcessPresence {
                session.tracksLog = true
                session.lastActivity = now
                session.stallFired = false
            }
            if let pending = event.pendingTools { session.pendingTools = pending }
            if let turnActive = event.turnActive {
                session.turnActive = turnActive
                if turnActive {
                    registerActiveSession(agentID: id, subkey: subkey)
                } else if !session.awaitingApproval {
                    unregisterActiveSession(agentID: id, sessionID: event.sessionID, isProcessPresence: false)
                }
            }
            if let tokens = event.contextTokens {
                let reading = AgentContextReading(agentID: id, agentName: name, tokens: tokens,
                                                  windowTokens: signalSettings.contextWindow(for: id))
                contextReadings[stateKey] = reading
                latestContextStateKey = stateKey
                latestContext = reading
                if reading.percent >= signalSettings.contextThresholdPercent {
                    if !session.contextFired {
                        session.contextFired = true
                        if !event.isSeed && signalSettings.contextWarningEnabled {
                            raiseWarning(
                                AgentWarning(agentID: id, agentName: name, reason: .context,
                                             text: "⚠️ \(name): context at \(reading.percent)%! Consider /compact soon."),
                                stateKey: stateKey
                            )
                        }
                    }
                } else {
                    session.contextFired = false
                }
            }
            if let cpuPercent = event.cpuPercent {
                evaluateRunawayCPU(agentID: id, agentName: name, cpuPercent: cpuPercent, stateKey: stateKey, now: now)
            }
        }
        if event.kind != .usage || !event.isProcessPresence || sessions[stateKey] != nil {
            sessions[stateKey] = session
        }
        onEventHandled?(event)
    }

    /// Raises one stall warning per stall (FR-009). Runs every 5 s while monitoring; public for tests.
    public func evaluateStalls() {
        guard signalSettings.stallWarningEnabled else { return }
        let now = clock()
        let minutes = signalSettings.stallTimeoutMinutes
        for (stateKey, session) in sessions
        where session.tracksLog && session.turnActive && !session.awaitingApproval && session.pendingTools == 0 && !session.stallFired
            && now.timeIntervalSince(session.lastActivity) >= Double(minutes) * 60 {
            guard let agent = catalog.first(where: { $0.id == session.agentID }), agent.isEnabled else { continue }
            sessions[stateKey]?.stallFired = true
            raiseWarning(
                AgentWarning(agentID: session.agentID, agentName: agent.displayName, reason: .stall,
                             text: "⚠️ \(agent.displayName) may be stuck: no output for \(minutes) min."),
                stateKey: stateKey
            )
        }
    }

    /// Agents produce no output while the Mac sleeps, so each session gets a full stall timeout after wake. Public for tests.
    public func handleSystemWake() {
        let now = clock()
        for key in sessions.keys { sessions[key]?.lastActivity = now }
        for key in runawaySinceByAgent.keys { runawaySinceByAgent[key] = now }
    }

    private func evaluateRunawayCPU(agentID: String, agentName: String, cpuPercent: Double, stateKey: String, now: Date) {
        guard signalSettings.runawayCPUWarningEnabled else {
            runawaySinceByAgent.removeValue(forKey: agentID)
            runawayFiredByAgent.remove(agentID)
            return
        }

        let threshold = Double(signalSettings.runawayCPUPercentThreshold)
        guard cpuPercent >= threshold else {
            runawaySinceByAgent.removeValue(forKey: agentID)
            runawayFiredByAgent.remove(agentID)
            return
        }

        let since = runawaySinceByAgent[agentID] ?? now
        if runawaySinceByAgent[agentID] == nil {
            runawaySinceByAgent[agentID] = now
        }

        let requiredDuration = Double(signalSettings.runawayCPUDurationMinutes) * 60.0
        guard now.timeIntervalSince(since) >= requiredDuration else { return }
        guard !runawayFiredByAgent.contains(agentID) else { return }

        runawayFiredByAgent.insert(agentID)
        let roundedCPU = Int(min(max(cpuPercent, 0.0), 100_000.0).rounded())
        raiseWarning(
            AgentWarning(
                agentID: agentID,
                agentName: agentName,
                reason: .runawayCPU,
                text: "⚠️ \(agentName) is using \(roundedCPU)% CPU for \(signalSettings.runawayCPUDurationMinutes)+ min (possible runaway process)."
            ),
            stateKey: stateKey
        )
    }

    private func registerActiveSession(agentID: String, subkey: String) {
        if let licensingService, !licensingService.isFeatureUnlocked(.multiAgentSwarm) {
            // Free tier: allow at most 1 active simultaneously monitored session across all agents.
            activeSessionsByAgent = [agentID: [subkey]]
        } else {
            activeSessionsByAgent[agentID, default: []].insert(subkey)
        }
        syncPublishedActiveState()
    }

    private func unregisterActiveSession(agentID: String, sessionID: String?, isProcessPresence: Bool) {
        if let sessionID {
            activeSessionsByAgent[agentID]?.remove(sessionID)
        } else if isProcessPresence {
            activeSessionsByAgent[agentID]?.remove(Self.defaultSessionSubkey)
        } else {
            activeSessionsByAgent[agentID]?.remove(Self.defaultSessionSubkey)
        }
        if activeSessionsByAgent[agentID]?.isEmpty == true {
            activeSessionsByAgent.removeValue(forKey: agentID)
        }
        syncPublishedActiveState()
    }

    private func syncPublishedActiveState() {
        let updatedAgents = Set(activeSessionsByAgent.compactMap { $0.value.isEmpty ? nil : $0.key })
        let updatedCount = activeSessionsByAgent.values.reduce(0) { $0 + $1.count }
        if activeAgents != updatedAgents {
            activeAgents = updatedAgents
        }
        if activeAgentCount != updatedCount {
            activeAgentCount = updatedCount
        }
    }

    private func matchesActiveWarning(agentID: String, stateKey: String) -> Bool {
        guard let warning = activeWarning, warning.agentID == agentID else { return false }
        guard let warningKey = activeWarningStateKey else { return true }
        if warningKey == agentID || stateKey == agentID {
            return true
        }
        return warningKey == stateKey
    }

    /// Clears the warning (Got it / menu Dismiss Agent Warning) and its bubble.
    public func acknowledgeWarning() {
        activeWarning = nil
        activeWarningStateKey = nil
        approvalOverrideAgentID = nil
        approvalOverrideStateKey = nil
        if activePopup?.kind == .warning {
            dismissPopup()
        }
    }

    private func raiseWarning(_ warning: AgentWarning, stateKey: String) {
        activeWarning = warning
        activeWarningStateKey = stateKey
        // Approval takes the bubble (FR-010): a warning raised while another agent/session's approval shows waits behind it.
        if activePopup?.kind == .needsApproval,
           let approverAgent = approvalPopupAgentID,
           let approverKey = approvalPopupStateKey,
           approverKey != stateKey && (approverAgent != warning.agentID || (approverKey != approverAgent && stateKey != warning.agentID)) {
            approvalOverrideAgentID = approverAgent
            approvalOverrideStateKey = approverKey
            return
        }
        approvalOverrideAgentID = nil
        approvalOverrideStateKey = nil
        presentWarningBubble()
    }

    private func presentWarningBubble() {
        guard let warning = activeWarning else { return }
        displayPopupIfEnabled(text: warning.text, kind: .warning, agentName: warning.agentName, durationSeconds: nil)
    }

    /// The approving agent/session's next lifecycle event supersedes its approval, so the warning bubble returns.
    private func restoreWarningBubble(ifOverriddenByAgentID id: String, stateKey: String) {
        guard let overrideAgent = approvalOverrideAgentID, overrideAgent == id else { return }
        if let overrideKey = approvalOverrideStateKey,
           overrideKey != id && stateKey != id && overrideKey != stateKey {
            return
        }
        approvalOverrideAgentID = nil
        approvalOverrideStateKey = nil
        presentWarningBubble()
    }

    /// Re-applies the configured windows to stored readings; never raises a warning.
    private func recomputeContextReadings() {
        contextReadings = contextReadings.mapValues {
            AgentContextReading(agentID: $0.agentID, agentName: $0.agentName, tokens: $0.tokens,
                                windowTokens: signalSettings.contextWindow(for: $0.agentID))
        }
        if let key = latestContextStateKey {
            latestContext = contextReadings[key]
        } else {
            latestContext = latestContext.flatMap { contextReadings[$0.agentID] }
        }
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
