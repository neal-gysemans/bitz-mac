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
            UserDefaults.standard.set(popupsEnabled, forKey: Self.popupsEnabledKey)
            if !popupsEnabled {
                activePopup = nil
            }
        }
    }

    private var adapters: [AgentAdapter] = []
    private let clock: @Sendable () -> Date
    private var dismissTask: Task<Void, Never>? = nil

    public var onEventHandled: (@MainActor (AgentEvent) -> Void)? = nil

    private static let customAgentsKey = "Bitz.AgentMonitor.CustomAgents"
    private static let agentDisabledPrefix = "Bitz.AgentMonitor.Disabled."
    private static let popupsEnabledKey = "Bitz.AgentMonitor.PopupsEnabled"

    public init(
        adapters: [AgentAdapter] = [],
        clock: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.adapters = adapters
        self.clock = clock
        self.popupsEnabled = UserDefaults.standard.object(forKey: Self.popupsEnabledKey) as? Bool ?? true
        loadCatalog()
    }

    /// Loads built-in and user-custom agent definitions.
    public func loadCatalog() {
        var merged: [AgentDefinition] = []
        for builtIn in AgentDefinition.builtInCatalog {
            let disabled = UserDefaults.standard.bool(forKey: Self.agentDisabledPrefix + builtIn.id)
            var def = builtIn
            def.isEnabled = !disabled
            merged.append(def)
        }

        if let data = UserDefaults.standard.data(forKey: Self.customAgentsKey),
           let custom = try? JSONDecoder().decode([AgentDefinition].self, from: data) {
            for customAgent in custom {
                let disabled = UserDefaults.standard.bool(forKey: Self.agentDisabledPrefix + customAgent.id)
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
            UserDefaults.standard.set(encoded, forKey: Self.customAgentsKey)
        }
        loadCatalog()
    }

    /// Removes a custom agent definition by ID.
    public func removeCustomAgent(id: String) {
        var existingCustom = loadStoredCustomAgents()
        existingCustom.removeAll { $0.id == id }
        if let encoded = try? JSONEncoder().encode(existingCustom) {
            UserDefaults.standard.set(encoded, forKey: Self.customAgentsKey)
        }
        loadCatalog()
    }

    /// Enables or disables an agent definition.
    public func setAgentEnabled(id: String, isEnabled: Bool) {
        UserDefaults.standard.set(!isEnabled, forKey: Self.agentDisabledPrefix + id)
        loadCatalog()
        if !isEnabled {
            activeAgents.remove(id)
            if activePopup?.agentName == catalog.first(where: { $0.id == id })?.displayName {
                activePopup = nil
            }
        }
    }

    public func isAgentEnabled(id: String) -> Bool {
        return catalog.first(where: { $0.id == id })?.isEnabled ?? false
    }

    private func loadStoredCustomAgents() -> [AgentDefinition] {
        guard let data = UserDefaults.standard.data(forKey: Self.customAgentsKey),
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
    }

    /// Stops all registered adapters.
    public func stopMonitoring() {
        for adapter in adapters {
            adapter.stop()
        }
        dismissTask?.cancel()
        dismissTask = nil
        activePopup = nil
        activeAgents.removeAll()
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

        switch event.kind {
        case .started, .working:
            activeAgents.insert(event.agentID)
            if popupsEnabled && event.kind == .working {
                let text = event.message ?? "\(event.agentName) is working..."
                displayPopup(text: text, kind: .working, agentName: event.agentName, durationSeconds: 4.0)
            }
        case .needsApproval:
            activeAgents.insert(event.agentID)
            if popupsEnabled {
                let text = event.message ?? "\(event.agentName) needs your approval!"
                // Approval popup persists indefinitely until next event or manual action
                displayPopup(text: text, kind: .needsApproval, agentName: event.agentName, durationSeconds: nil)
            }
        case .done:
            activeAgents.remove(event.agentID)
            if popupsEnabled {
                let text = event.message ?? "\(event.agentName) is done!"
                // Done auto-dismisses after ~6.0 seconds
                displayPopup(text: text, kind: .done, agentName: event.agentName, durationSeconds: 6.0)
            }
        }

        onEventHandled?(event)
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
