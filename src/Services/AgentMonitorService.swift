import AppKit
import Foundation
import Combine
import SQLite3

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
    /// Priority-sorted snapshots of all tracked agent sessions for the 3D Command Deck (WP1).
    @Published public private(set) var sessionSnapshots: [AgentSessionSnapshot] = []
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

    /// Per-session state, lifecycle, and telemetry inputs, keyed by `(agentID, sessionID)` (#153, WP1).
    private struct SessionState {
        let agentID: String
        var agentName: String
        var sessionID: String?
        var lifecycleState: AgentSessionLifecycleState = .idle
        var activeWarningReason: AgentWarningReason? = nil
        var workingDir: String? = nil
        var autoDerivedLabel: String? = nil
        var lastMessage: String? = nil
        var linkedApprovalRequest: AgentApprovalRequest? = nil
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
    private let summariesDatabaseURL: URL?

    public static var defaultSummariesDatabaseURL: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".gemini/antigravity/conversation_summaries.db")
    }

    public var onEventHandled: (@MainActor (AgentEvent) -> Void)? = nil

    private static let customAgentsKey = "Bitz.AgentMonitor.CustomAgents"
    private static let agentDisabledPrefix = "Bitz.AgentMonitor.Disabled."
    private static let primaryFreeAgentKey = "Bitz.AgentMonitor.PrimaryFreeAgentID"
    private static let popupsEnabledKey = "Bitz.AgentMonitor.PopupsEnabled"
    private static let signalSettingsKey = "Bitz.AgentMonitor.SignalSettings"

    /// Whether Multi-Agent Swarm (monitoring 2+ agents simultaneously) is unlocked.
    public var isMultiAgentSwarmUnlocked: Bool {
        licensingService?.isFeatureUnlocked(.multiAgentSwarm) ?? true
    }

    public init(
        adapters: [AgentAdapter] = [],
        clock: @escaping @Sendable () -> Date = { Date() },
        userDefaults: UserDefaults = .standard,
        stallSweepInterval: TimeInterval = 5,
        licensingService: (any LicensingServiceProtocol)? = nil,
        summariesDatabaseURL: URL? = nil
    ) {
        self.adapters = adapters
        self.clock = clock
        self.userDefaults = userDefaults
        self.stallSweepInterval = stallSweepInterval
        self.licensingService = licensingService
        self.summariesDatabaseURL = summariesDatabaseURL
        self.popupsEnabled = userDefaults.object(forKey: Self.popupsEnabledKey) as? Bool ?? true
        self.signalSettings = userDefaults.data(forKey: Self.signalSettingsKey)
            .flatMap { try? JSONDecoder().decode(AgentSignalSettings.self, from: $0) }?
            .clamped() ?? .default
        loadCatalog()
    }

    /// Loads built-in and user-custom agent definitions, clamping to at most 1 enabled agent when `.multiAgentSwarm` is locked (#144).
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

        if !isMultiAgentSwarmUnlocked {
            let storedPrimary = userDefaults.string(forKey: Self.primaryFreeAgentKey)
            let chosenPrimaryID: String
            if let storedPrimary {
                // An empty string means the user explicitly toggled off their single Free-tier agent.
                chosenPrimaryID = storedPrimary
            } else {
                let activeCandidate = activeAgents.sorted().first { activeID in
                    merged.contains { $0.id == activeID && $0.isEnabled }
                }
                let fallbackCandidate = merged.first(where: { $0.isEnabled })?.id ?? ""
                chosenPrimaryID = activeCandidate ?? fallbackCandidate
                userDefaults.set(chosenPrimaryID, forKey: Self.primaryFreeAgentKey)
            }

            for index in merged.indices {
                merged[index].isEnabled = merged[index].isEnabled && (merged[index].id == chosenPrimaryID)
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
        if !isMultiAgentSwarmUnlocked {
            userDefaults.set(id, forKey: Self.primaryFreeAgentKey)
        }
        loadCatalog()
        pruneStateForDisabledAgents()
    }

    /// Removes a custom agent definition by ID.
    public func removeCustomAgent(id: String) {
        let removedDisplayName = catalog.first(where: { $0.id == id })?.displayName
        var existingCustom = loadStoredCustomAgents()
        existingCustom.removeAll { $0.id == id }
        if let encoded = try? JSONEncoder().encode(existingCustom) {
            userDefaults.set(encoded, forKey: Self.customAgentsKey)
        }
        if userDefaults.string(forKey: Self.primaryFreeAgentKey) == id {
            userDefaults.removeObject(forKey: Self.primaryFreeAgentKey)
        }
        loadCatalog()
        clearAgentState(id: id, displayNameHint: removedDisplayName)
        pruneStateForDisabledAgents()
    }

    /// Enables or disables an agent definition.
    public func setAgentEnabled(id: String, isEnabled: Bool) {
        userDefaults.set(!isEnabled, forKey: Self.agentDisabledPrefix + id)
        if !isMultiAgentSwarmUnlocked {
            if isEnabled {
                userDefaults.set(id, forKey: Self.primaryFreeAgentKey)
            } else if userDefaults.string(forKey: Self.primaryFreeAgentKey) == id {
                userDefaults.set("", forKey: Self.primaryFreeAgentKey)
            }
        }
        loadCatalog()
        if !isEnabled {
            clearAgentState(id: id)
        }
        pruneStateForDisabledAgents()
    }

    /// Re-evaluates Multi-Agent Swarm entitlement after a tier change (`#144`).
    public func validateTierEntitlement() {
        if isMultiAgentSwarmUnlocked {
            userDefaults.removeObject(forKey: Self.primaryFreeAgentKey)
        } else {
            let currentPrimary = userDefaults.string(forKey: Self.primaryFreeAgentKey)
            if currentPrimary == nil || currentPrimary?.isEmpty == true {
                userDefaults.removeObject(forKey: Self.primaryFreeAgentKey)
            }
        }
        loadCatalog()
        pruneStateForDisabledAgents()
        clampActiveSessionsToSinglePairIfLocked()
        if !isMultiAgentSwarmUnlocked {
            if activeWarning != nil {
                acknowledgeWarning()
            }
            for key in Array(sessions.keys) {
                guard var entry = sessions[key], entry.activeWarningReason != nil else { continue }
                entry.activeWarningReason = nil
                if entry.lifecycleState == .warning {
                    entry.lifecycleState = entry.turnActive ? .working : .idle
                }
                sessions[key] = entry
            }
            recomputeSessionSnapshots()
        }
    }

    private func pruneStateForDisabledAgents() {
        let enabledIDs = Set(catalog.filter(\.isEnabled).map(\.id))
        var trackedIDs = Set(activeSessionsByAgent.keys)
        for session in sessions.values {
            trackedIDs.insert(session.agentID)
        }
        for reading in contextReadings.values {
            trackedIDs.insert(reading.agentID)
        }
        if let latestID = latestContext?.agentID {
            trackedIDs.insert(latestID)
        }
        if let warningID = activeWarning?.agentID {
            trackedIDs.insert(warningID)
        }
        for id in trackedIDs where !enabledIDs.contains(id) {
            clearAgentState(id: id)
        }
    }

    private func clampActiveSessionsToSinglePairIfLocked() {
        guard !isMultiAgentSwarmUnlocked else { return }

        let enabledIDs = Set(catalog.filter(\.isEnabled).map(\.id))
        var candidates: [(agentID: String, subkey: String, stateKey: String, isEnabled: Bool, lastActivity: Date)] = []
        for (agentID, subkeys) in activeSessionsByAgent {
            for subkey in subkeys {
                let sessionID: String? = (subkey == Self.defaultSessionSubkey) ? nil : subkey
                let stateKey = Self.makeStateKey(agentID: agentID, sessionID: sessionID)
                candidates.append((
                    agentID: agentID,
                    subkey: subkey,
                    stateKey: stateKey,
                    isEnabled: enabledIDs.contains(agentID),
                    lastActivity: sessions[stateKey]?.lastActivity ?? .distantPast
                ))
            }
        }

        if let kept = candidates.sorted(by: { lhs, rhs in
            if lhs.isEnabled != rhs.isEnabled { return lhs.isEnabled }
            if lhs.lastActivity != rhs.lastActivity { return lhs.lastActivity > rhs.lastActivity }
            if lhs.agentID != rhs.agentID { return lhs.agentID < rhs.agentID }
            return lhs.subkey < rhs.subkey
        }).first {
            activeSessionsByAgent = [kept.agentID: [kept.subkey]]
            pruneOtherSessionState(keepingStateKey: kept.stateKey)
        } else {
            activeSessionsByAgent.removeAll()
            let remainingKeys = Set(sessions.keys).union(contextReadings.keys)
            if let keptKey = remainingKeys.sorted(by: { lhs, rhs in
                let lhsEnabled = enabledIDs.contains(sessions[lhs]?.agentID ?? contextReadings[lhs]?.agentID ?? "")
                let rhsEnabled = enabledIDs.contains(sessions[rhs]?.agentID ?? contextReadings[rhs]?.agentID ?? "")
                if lhsEnabled != rhsEnabled { return lhsEnabled }
                let lhsTime = sessions[lhs]?.lastActivity ?? .distantPast
                let rhsTime = sessions[rhs]?.lastActivity ?? .distantPast
                if lhsTime != rhsTime { return lhsTime > rhsTime }
                return lhs < rhs
            }).first {
                pruneOtherSessionState(keepingStateKey: keptKey)
            }
            recomputeSessionSnapshots()
        }

        syncPublishedActiveState()
    }

    private func pruneOtherSessionState(keepingStateKey keptStateKey: String) {
        let allKeys = Set(sessions.keys).union(contextReadings.keys)
        for stateKey in allKeys where stateKey != keptStateKey {
            clearSessionState(stateKey: stateKey)
        }
        if latestContext == nil, let keptReading = contextReadings[keptStateKey] {
            latestContext = keptReading
            latestContextStateKey = keptStateKey
        }
        recomputeSessionSnapshots()
    }

    private func clearSessionState(stateKey: String) {
        sessions.removeValue(forKey: stateKey)
        contextReadings.removeValue(forKey: stateKey)
        if latestContextStateKey == stateKey {
            latestContext = nil
            latestContextStateKey = nil
        }
        if activeWarningStateKey == stateKey {
            acknowledgeWarning()
        } else if approvalOverrideStateKey == stateKey {
            approvalOverrideAgentID = nil
            approvalOverrideStateKey = nil
            presentWarningBubble()
        }
        if approvalPopupStateKey == stateKey {
            approvalPopupAgentID = nil
            approvalPopupStateKey = nil
        }
    }

    private func clearAgentState(id: String, displayNameHint: String? = nil) {
        let resolvedDisplayName = displayNameHint ?? catalog.first(where: { $0.id == id })?.displayName
        activeSessionsByAgent.removeValue(forKey: id)
        syncPublishedActiveState()
        if let resolvedDisplayName, activePopup?.agentName == resolvedDisplayName {
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
        if approvalPopupAgentID == id {
            approvalPopupAgentID = nil
            approvalPopupStateKey = nil
        }
        recomputeSessionSnapshots()
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
        sessionSnapshots.removeAll()
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

    public static func makeStateKey(agentID: String, sessionID: String?) -> String {
        if let sessionID {
            return "\(agentID)::\(sessionID)"
        }
        return agentID
    }

    /// Processes an incoming AgentEvent and evaluates popup display rules.
    public func handleEvent(_ event: AgentEvent) {
        processEvent(event, bypassCatalogGate: false)
    }

    /// Processes a user-triggered simulated event (e.g. Advanced settings QA buttons),
    /// bypassing Free-tier catalog/multi-agent locks so alert & audio testing always works (`#144`).
    public func handleSimulatedEvent(_ event: AgentEvent) {
        processEvent(event, bypassCatalogGate: true)
    }

    private func processEvent(_ event: AgentEvent, bypassCatalogGate: Bool) {
        let now = clock()

        // Discard events older than 60 seconds (NFR-004)
        if now.timeIntervalSince(event.timestamp) > 60.0 {
            return
        }

        // Verify if agent is enabled in catalog unless explicitly bypassed by user simulation
        let agentDef = catalog.first(where: { $0.id == event.agentID })
        let isAgentEnabled = agentDef?.isEnabled ?? false
        if !bypassCatalogGate {
            guard isAgentEnabled else {
                return
            }

            // When Multi-Agent Swarm is locked, strictly ignore events from a 2nd concurrent agent while a 1st agent is active (#144)
            if !isMultiAgentSwarmUnlocked, !activeAgents.isEmpty, !activeAgents.contains(event.agentID) {
                return
            }
        }

        // Do not overwrite/pollute active-session tracking with simulated events for disabled agents
        let tracksSessionState = !bypassCatalogGate || isAgentEnabled

        let id = event.agentID
        let name = event.agentName
        let subkey = event.sessionID ?? Self.defaultSessionSubkey
        let stateKey = Self.makeStateKey(agentID: id, sessionID: event.sessionID)
        var session = sessions[stateKey] ?? SessionState(
            agentID: id,
            agentName: name,
            sessionID: event.sessionID,
            lifecycleState: .idle,
            lastActivity: now
        )

        session.agentName = name
        if let sid = event.sessionID { session.sessionID = sid }
        if let wd = event.workingDir { session.workingDir = wd }
        if let customLabel = event.metadata?[AgentEvent.MetadataKey.sessionLabel], !customLabel.isEmpty {
            session.autoDerivedLabel = customLabel
        }
        if let msg = event.message, !msg.isEmpty, event.kind != .usage {
            session.lastMessage = msg
        }

        // Popup priority while a warning is active: data-model.md "Warning slot".
        switch event.kind {
        case .started:
            if event.isProcessPresence {
                session.turnActive = false
                if session.activeWarningReason == nil {
                    session.lifecycleState = .idle
                }
            } else {
                if tracksSessionState {
                    registerActiveSession(agentID: id, subkey: subkey)
                }
                session.turnActive = true
                session.lifecycleState = .working
            }
            session.lastActivity = now
            session.stallFired = false
        case .working:
            if tracksSessionState {
                registerActiveSession(agentID: id, subkey: subkey)
            }
            session.turnActive = true
            session.awaitingApproval = false
            session.linkedApprovalRequest = nil
            session.lastActivity = now
            session.stallFired = false
            if session.activeWarningReason == nil {
                session.lifecycleState = .working
            }
            if activeWarning == nil {
                let text = event.message ?? "\(name) is working..."
                displayPopupIfEnabled(text: text, kind: .working, agentName: name, durationSeconds: 4.0)
            } else if !event.isProcessPresence {
                restoreWarningBubble(ifOverriddenByAgentID: id, stateKey: stateKey)
            }
        case .almostDone:
            if tracksSessionState {
                registerActiveSession(agentID: id, subkey: subkey)
            }
            session.turnActive = true
            session.lastActivity = now
            if session.activeWarningReason == nil {
                session.lifecycleState = .almostDone
            }
            if activeWarning == nil {
                if signalSettings.almostDoneEnabled {
                    let text = event.message ?? "✨ \(name) is almost done!"
                    displayPopupIfEnabled(text: text, kind: .almostDone, agentName: name, durationSeconds: 6.0)
                }
            } else {
                restoreWarningBubble(ifOverriddenByAgentID: id, stateKey: stateKey)
            }
        case .needsApproval:
            if tracksSessionState {
                registerActiveSession(agentID: id, subkey: subkey)
            }
            session.turnActive = true
            session.awaitingApproval = true
            session.lastActivity = now
            session.lifecycleState = .needsApproval
            if let requestID = event.approvalRequestID {
                let req = AgentApprovalRequest(
                    id: requestID,
                    agentID: id,
                    agentName: name,
                    sessionID: event.sessionID,
                    toolName: event.toolName,
                    commandSummary: event.commandSummary,
                    decisionChannel: event.approvalChannel,
                    owningPID: event.owningPID.map { pid_t($0) },
                    bundleID: event.bundleID,
                    workingDir: event.workingDir ?? session.workingDir,
                    createdAt: now
                )
                session.linkedApprovalRequest = req
            }
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
            displayPopupIfEnabled(
                text: text,
                kind: .needsApproval,
                agentName: name,
                durationSeconds: nil,
                agentID: id,
                approvalRequestID: event.approvalRequestID
            )
        case .done:
            if tracksSessionState {
                unregisterActiveSession(agentID: id, sessionID: event.sessionID, isProcessPresence: event.isProcessPresence)
            }
            if event.isProcessPresence || activeSessionsByAgent[id] == nil {
                runawaySinceByAgent.removeValue(forKey: id)
                runawayFiredByAgent.remove(id)
            }
            // App presence (Claude desktop app shares the `claude` ID with Claude Code) never ends a turn or clears a warning.
            if !event.isProcessPresence {
                session.turnActive = false
                session.awaitingApproval = false
                session.linkedApprovalRequest = nil
                session.pendingTools = 0
                session.activeWarningReason = nil
                session.lifecycleState = .done
                if matchesActiveWarning(agentID: id, stateKey: stateKey) { acknowledgeWarning() }
            }
            if activeWarning == nil {
                let text = event.message ?? "\(name) is done!"
                // Done auto-dismisses after ~6.0 seconds
                displayPopupIfEnabled(text: text, kind: .done, agentName: name, durationSeconds: 6.0)
            } else if !event.isProcessPresence {
                restoreWarningBubble(ifOverriddenByAgentID: id, stateKey: stateKey)
            }
        case .failed:
            if tracksSessionState {
                unregisterActiveSession(agentID: id, sessionID: event.sessionID, isProcessPresence: event.isProcessPresence)
            }
            if event.isProcessPresence || activeSessionsByAgent[id] == nil {
                runawaySinceByAgent.removeValue(forKey: id)
                runawayFiredByAgent.remove(id)
            }
            if !event.isProcessPresence {
                session.turnActive = false
                session.awaitingApproval = false
                session.linkedApprovalRequest = nil
                session.pendingTools = 0
                session.lifecycleState = .failed
                if matchesActiveWarning(agentID: id, stateKey: stateKey) { acknowledgeWarning() }
            }
            if activeWarning == nil {
                let text = event.message ?? "❌ \(name) failed!"
                displayPopupIfEnabled(text: text, kind: .failed, agentName: name, durationSeconds: 6.0)
            } else if !event.isProcessPresence {
                restoreWarningBubble(ifOverriddenByAgentID: id, stateKey: stateKey)
            }
            case .warning:
            let reason = event.warningReason
            if isMultiAgentSwarmUnlocked && signalSettings.isEnabled(reason) {
                session.activeWarningReason = reason
                session.lifecycleState = .warning
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
                    if tracksSessionState {
                        registerActiveSession(agentID: id, subkey: subkey)
                    }
                    if session.lifecycleState == .idle || session.lifecycleState == .done {
                        session.lifecycleState = .working
                    }
                } else if !session.awaitingApproval {
                    if tracksSessionState {
                        unregisterActiveSession(agentID: id, sessionID: event.sessionID, isProcessPresence: false)
                    }
                    if session.lifecycleState != .warning && session.lifecycleState != .failed {
                        session.lifecycleState = .idle
                    }
                }
            }
            if let tokens = event.contextTokens, tracksSessionState {
                let reading = AgentContextReading(agentID: id, agentName: name, tokens: tokens,
                                                  windowTokens: signalSettings.contextWindow(for: id))
                contextReadings[stateKey] = reading
                latestContextStateKey = stateKey
                latestContext = reading
                if isMultiAgentSwarmUnlocked && reading.percent >= signalSettings.contextThresholdPercent {
                    if !session.contextFired {
                        session.contextFired = true
                        if !event.isSeed && signalSettings.contextWarningEnabled {
                            session.activeWarningReason = .context
                            session.lifecycleState = .warning
                            raiseWarning(
                                AgentWarning(agentID: id, agentName: name, reason: .context,
                                             text: "⚠️ \(name): context at \(reading.percent)%! Consider /compact soon."),
                                stateKey: stateKey
                            )
                        }
                    }
                } else {
                    session.contextFired = false
                    if session.activeWarningReason == .context {
                        session.activeWarningReason = nil
                        if session.lifecycleState == .warning {
                            session.lifecycleState = session.turnActive ? .working : .idle
                        }
                    }
                }
            }
            if isMultiAgentSwarmUnlocked, let cpuPercent = event.cpuPercent {
                evaluateRunawayCPU(agentID: id, agentName: name, cpuPercent: cpuPercent, stateKey: stateKey, now: now)
            }
        }
        if tracksSessionState && (event.kind != .usage || !event.isProcessPresence || sessions[stateKey] != nil) {
            sessions[stateKey] = session
            recomputeSessionSnapshots()
        }
        onEventHandled?(event)
    }

    /// Raises one stall warning per stall (FR-009). Runs every 5 s while monitoring; public for tests.
    public func evaluateStalls() {
        guard isMultiAgentSwarmUnlocked && signalSettings.stallWarningEnabled else { return }
        let now = clock()
        let minutes = signalSettings.stallTimeoutMinutes
        var changed = false
        for (stateKey, session) in sessions
        where session.tracksLog && session.turnActive && !session.awaitingApproval && session.pendingTools == 0 && !session.stallFired
            && now.timeIntervalSince(session.lastActivity) >= Double(minutes) * 60 {
            guard let agent = catalog.first(where: { $0.id == session.agentID }), agent.isEnabled else { continue }
            sessions[stateKey]?.stallFired = true
            sessions[stateKey]?.activeWarningReason = .stall
            sessions[stateKey]?.lifecycleState = .warning
            changed = true
            raiseWarning(
                AgentWarning(agentID: session.agentID, agentName: agent.displayName, reason: .stall,
                             text: "⚠️ \(agent.displayName) may be stuck: no output for \(minutes) min."),
                stateKey: stateKey
            )
        }
        if changed {
            recomputeSessionSnapshots()
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
        if !isMultiAgentSwarmUnlocked {
            // Free tier: allow at most 1 active simultaneously monitored (agentID, subkey) pair across all agents (#144, #153).
            let sessionID: String? = (subkey == Self.defaultSessionSubkey) ? nil : subkey
            let keptStateKey = Self.makeStateKey(agentID: agentID, sessionID: sessionID)
            pruneOtherSessionState(keepingStateKey: keptStateKey)
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
    /// Can target a specific session via `stateKey`, or clears active / all warnings when `stateKey` is nil.
    public func acknowledgeWarning(stateKey: String? = nil) {
        if let stateKey {
            if let session = sessions[stateKey] {
                sessions[stateKey]?.activeWarningReason = nil
                if sessions[stateKey]?.lifecycleState == .warning {
                    sessions[stateKey]?.lifecycleState = session.turnActive ? .working : .idle
                }
            }
            if activeWarningStateKey == stateKey {
                activeWarning = nil
                activeWarningStateKey = nil
                approvalOverrideAgentID = nil
                approvalOverrideStateKey = nil
                if activePopup?.kind == .warning {
                    dismissPopup()
                }
            }
        } else {
            for key in sessions.keys {
                if sessions[key]?.activeWarningReason != nil {
                    sessions[key]?.activeWarningReason = nil
                    if sessions[key]?.lifecycleState == .warning {
                        let turnActive = sessions[key]?.turnActive ?? false
                        sessions[key]?.lifecycleState = turnActive ? .working : .idle
                    }
                }
            }
            activeWarning = nil
            activeWarningStateKey = nil
            approvalOverrideAgentID = nil
            approvalOverrideStateKey = nil
            if activePopup?.kind == .warning {
                dismissPopup()
            }
        }
        recomputeSessionSnapshots()
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
        recomputeSessionSnapshots()
    }

    /// Sets or clears a linked approval request for a given session.
    public func setLinkedApprovalRequest(_ request: AgentApprovalRequest?, for stateKey: String) {
        guard sessions[stateKey] != nil else { return }
        sessions[stateKey]?.linkedApprovalRequest = request
        if let request {
            sessions[stateKey]?.awaitingApproval = true
            sessions[stateKey]?.lifecycleState = .needsApproval
            if request.workingDir != nil && sessions[stateKey]?.workingDir == nil {
                sessions[stateKey]?.workingDir = request.workingDir
            }
        } else {
            sessions[stateKey]?.awaitingApproval = false
            if sessions[stateKey]?.lifecycleState == .needsApproval {
                let turnActive = sessions[stateKey]?.turnActive ?? false
                sessions[stateKey]?.lifecycleState = turnActive ? .working : .idle
            }
        }
        recomputeSessionSnapshots()
    }

    /// Clears any linked approval request matching the given requestID.
    public func clearLinkedApprovalRequest(requestID: String) {
        var changed = false
        for (stateKey, session) in sessions where session.linkedApprovalRequest?.id == requestID {
            sessions[stateKey]?.linkedApprovalRequest = nil
            sessions[stateKey]?.awaitingApproval = false
            if sessions[stateKey]?.lifecycleState == .needsApproval {
                let turnActive = session.turnActive
                sessions[stateKey]?.lifecycleState = turnActive ? .working : .idle
            }
            changed = true
        }
        if changed {
            recomputeSessionSnapshots()
        }
    }

    /// Removes a specific session snapshot and state.
    public func removeSession(stateKey: String) {
        sessions.removeValue(forKey: stateKey)
        contextReadings.removeValue(forKey: stateKey)
        recomputeSessionSnapshots()
    }

    /// Auto-derives readable session label (`<Agent> · <repo/title>`).
    public func deriveSessionLabel(
        agentID: String,
        agentName: String,
        sessionID: String?,
        workingDir: String?,
        fallbackIndex: Int
    ) -> String {
        // 1. Antigravity: query conversation_summaries.db
        if agentID == "antigravity", let sessionID, !sessionID.isEmpty {
            let dbURL = summariesDatabaseURL ?? Self.defaultSummariesDatabaseURL
            let (title, folder) = Self.queryConversationSummary(for: sessionID, databaseURL: dbURL)
            if let title, !title.isEmpty {
                return "\(agentName) · \(title)"
            }
            if let folder, !folder.isEmpty {
                return "\(agentName) · \(folder)"
            }
        }

        // 2. Working directory or project slug
        if let workingDir, !workingDir.isEmpty {
            if workingDir.hasPrefix("-") && workingDir.contains("-Code-") {
                let slug = Self.resolveClaudeProjectSlug(workingDir)
                return "\(agentName) · \(slug)"
            }
            let name = URL(fileURLWithPath: workingDir).lastPathComponent
            if !name.isEmpty && name != "/" {
                return "\(agentName) · \(name)"
            }
        }

        // 3. Claude Code: sessionID slug resolution
        if agentID == "claude", let sessionID, sessionID.hasPrefix("-") {
            let slug = Self.resolveClaudeProjectSlug(sessionID)
            return "\(agentName) · \(slug)"
        }

        // 4. Fallback to short session identifier
        if let sessionID, !sessionID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            let clean = sessionID.trimmingCharacters(in: .whitespacesAndNewlines)
            let short = String(clean.prefix(6))
            return "\(agentName) · \(short)"
        }

        // 5. Fallback index
        return "\(agentName) · #\(fallbackIndex)"
    }

    /// Queries Antigravity conversation title and workspace URI from `conversation_summaries.db`.
    public static func queryConversationSummary(
        for conversationID: String,
        databaseURL: URL
    ) -> (title: String?, workspaceFolder: String?) {
        guard !conversationID.isEmpty,
              FileManager.default.fileExists(atPath: databaseURL.path) else {
            return (nil, nil)
        }
        var db: OpaquePointer?
        guard sqlite3_open_v2(databaseURL.path, &db, SQLITE_OPEN_READONLY | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK else {
            return (nil, nil)
        }
        defer { sqlite3_close(db) }
        sqlite3_busy_timeout(db, 20)

        var stmt: OpaquePointer?
        let sql = "SELECT title, workspace_uris FROM conversation_summaries WHERE conversation_id = ? LIMIT 1;"
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            return (nil, nil)
        }
        defer { sqlite3_finalize(stmt) }

        let sqliteTransient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        _ = conversationID.withCString { cStr in
            sqlite3_bind_text(stmt, 1, cStr, -1, sqliteTransient)
        }

        guard sqlite3_step(stmt) == SQLITE_ROW else {
            return (nil, nil)
        }

        var title: String? = nil
        if let cTitle = sqlite3_column_text(stmt, 0) {
            let str = String(cString: cTitle).trimmingCharacters(in: .whitespacesAndNewlines)
            if !str.isEmpty {
                title = str
            }
        }

        var folder: String? = nil
        if let cUris = sqlite3_column_text(stmt, 1) {
            let raw = String(cString: cUris).trimmingCharacters(in: .whitespacesAndNewlines)
            if let data = raw.data(using: .utf8),
               let uris = try? JSONDecoder().decode([String].self, from: data),
               let firstURI = uris.first,
               let url = URL(string: firstURI) {
                let name = url.lastPathComponent.trimmingCharacters(in: .whitespacesAndNewlines)
                if !name.isEmpty && name != "/" {
                    folder = name
                }
            }
        }

        return (title, folder)
    }

    /// Resolves a Claude Code project slug (e.g. `-Volumes-DevDrive-Code-bitz-mac`) to a repo folder name.
    public static func resolveClaudeProjectSlug(_ rawSlug: String) -> String {
        var slug = rawSlug
        if let range = slug.range(of: "--claude-worktrees-") {
            slug = String(slug[..<range.lowerBound])
        }

        let tokens = slug.split(separator: "-").map(String.init)
        guard !tokens.isEmpty else { return slug }

        let markers = ["Code", "projects", "repos", "Work", "dev", "src"]
        for marker in markers {
            if let mIdx = tokens.firstIndex(where: { $0.caseInsensitiveCompare(marker) == .orderedSame }), mIdx + 1 < tokens.count {
                return tokens[(mIdx + 1)...].joined(separator: "-")
            }
        }

        return tokens.joined(separator: "-")
    }

    /// Recomputes and publishes priority-sorted session snapshots.
    private func recomputeSessionSnapshots() {
        var snapshots: [AgentSessionSnapshot] = []
        snapshots.reserveCapacity(sessions.count)

        let agentsWithExplicitSessions = Set(sessions.values.compactMap { $0.sessionID != nil ? $0.agentID : nil })

        var agentSessionIndices: [String: Int] = [:]

        for (stateKey, session) in sessions {
            guard let agentDef = catalog.first(where: { $0.id == session.agentID }), agentDef.isEnabled else {
                continue
            }

            // Suppress bare process-presence idle placeholders when explicit named sessions exist for that agent.
            if session.sessionID == nil,
               agentsWithExplicitSessions.contains(session.agentID),
               session.lifecycleState == .idle,
               !session.tracksLog,
               session.linkedApprovalRequest == nil,
               session.activeWarningReason == nil {
                continue
            }

            let index = (agentSessionIndices[session.agentID] ?? 0) + 1
            agentSessionIndices[session.agentID] = index

            let label: String
            if let cached = session.autoDerivedLabel {
                label = cached
            } else {
                let derived = deriveSessionLabel(
                    agentID: session.agentID,
                    agentName: session.agentName,
                    sessionID: session.sessionID,
                    workingDir: session.workingDir,
                    fallbackIndex: index
                )
                if !derived.contains(" · #") && (session.sessionID == nil || !derived.hasSuffix(" · \(session.sessionID!.prefix(6))")) {
                    sessions[stateKey]?.autoDerivedLabel = derived
                }
                label = derived
            }

            let contextReading = contextReadings[stateKey]

            let snapshot = AgentSessionSnapshot(
                stateKey: stateKey,
                agentID: session.agentID,
                agentName: session.agentName,
                sessionID: session.sessionID,
                sessionLabel: label,
                lifecycleState: session.lifecycleState,
                activeWarning: session.activeWarningReason,
                contextReading: contextReading,
                pendingTools: session.pendingTools,
                lastActivity: session.lastActivity,
                linkedApprovalRequest: session.linkedApprovalRequest,
                workingDir: session.workingDir,
                statusMessage: session.lastMessage
            )
            snapshots.append(snapshot)
        }

        // Sort by attention priority primary, lastActivity descending secondary, stateKey deterministic tertiary
        snapshots.sort { lhs, rhs in
            lhs.lifecycleState != rhs.lifecycleState ? lhs.lifecycleState < rhs.lifecycleState
                : lhs.lastActivity != rhs.lastActivity ? lhs.lastActivity > rhs.lastActivity
                : lhs.stateKey < rhs.stateKey
        }

        self.sessionSnapshots = snapshots
    }

    private func displayPopupIfEnabled(
        text: String,
        kind: AgentEventKind,
        agentName: String,
        durationSeconds: TimeInterval?,
        agentID: String? = nil,
        approvalRequestID: String? = nil
    ) {
        guard popupsEnabled else { return }
        displayPopup(
            text: text,
            kind: kind,
            agentName: agentName,
            durationSeconds: durationSeconds,
            agentID: agentID,
            approvalRequestID: approvalRequestID
        )
    }

    private func displayPopup(
        text: String,
        kind: AgentEventKind,
        agentName: String,
        durationSeconds: TimeInterval?,
        agentID: String? = nil,
        approvalRequestID: String? = nil
    ) {
        dismissTask?.cancel()
        let expiresAt = durationSeconds.map { clock().addingTimeInterval($0) }
        activePopup = AgentPopupState(
            text: text,
            kind: kind,
            agentName: agentName,
            expiresAt: expiresAt,
            agentID: agentID,
            approvalRequestID: approvalRequestID
        )

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
