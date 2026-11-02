import Foundation

/// Defines the kind of lifecycle / activity event emitted by an AI agent.
public enum AgentEventKind: String, Codable, Sendable, CaseIterable {
    case started
    case working
    case needsApproval
    case done
    case almostDone
    case warning
    /// Context reading / activity heartbeat; never shown as a bubble.
    case usage
}

/// A structured event emitted by an agent adapter when an agent state transition occurs.
public struct AgentEvent: Codable, Sendable, Equatable, Identifiable {
    public let id: UUID
    public let agentID: String
    public let agentName: String
    public let kind: AgentEventKind
    public let message: String?
    public let timestamp: Date
    /// Optional details, e.g. context tokens or a warning reason (see `MetadataKey`).
    public let metadata: [String: String]?

    public init(
        id: UUID = UUID(),
        agentID: String,
        agentName: String,
        kind: AgentEventKind,
        message: String? = nil,
        timestamp: Date = Date(),
        metadata: [String: String]? = nil
    ) {
        self.id = id
        self.agentID = agentID
        self.agentName = agentName
        self.kind = kind
        self.message = message
        self.timestamp = timestamp
        self.metadata = metadata
    }

    enum CodingKeys: String, CodingKey {
        case id
        case agentID
        case agentName
        case kind
        case message
        case timestamp
        case metadata
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        if let uuidString = try? container.decode(String.self, forKey: .id),
           let parsedUUID = UUID(uuidString: uuidString) {
            self.id = parsedUUID
        } else if let uuid = try? container.decode(UUID.self, forKey: .id) {
            self.id = uuid
        } else {
            self.id = UUID()
        }
        self.agentID = try container.decode(String.self, forKey: .agentID)
        self.agentName = try container.decode(String.self, forKey: .agentName)
        self.kind = try container.decode(AgentEventKind.self, forKey: .kind)
        self.message = try? container.decode(String.self, forKey: .message)
        self.timestamp = (try? container.decode(Date.self, forKey: .timestamp)) ?? Date()
        // Drop-box files come from user scripts: accept number/bool values, and never reject the event over bad metadata.
        self.metadata = (try? container.decodeIfPresent([String: MetadataValue].self, forKey: .metadata))?
            .mapValues(\.string)
    }

    /// A metadata value written as a JSON string, number or boolean, normalised to a string.
    private struct MetadataValue: Decodable {
        let string: String

        init(from decoder: Decoder) throws {
            let container = try decoder.singleValueContainer()
            if let value = try? container.decode(String.self) {
                string = value
            } else if let value = try? container.decode(Int.self) {
                string = String(value)
            } else if let value = try? container.decode(Double.self) {
                // 185000.0 → "185000", so integer accessors still read it
                string = value.rounded() == value && abs(value) < 1e15 ? String(Int(value)) : String(value)
            } else {
                string = String(try container.decode(Bool.self))
            }
        }
    }
}

extension AgentEvent {
    /// Keys used in `AgentEvent.metadata` (contract: kitty-specs/agent-usage-gauges-warnings-01M666F5/contracts/agent-event-contract.md).
    public enum MetadataKey {
        public static let reason = "reason"
        public static let contextTokens = "contextTokens"
        public static let pendingTools = "pendingTools"
        public static let turnActive = "turnActive"
        public static let seed = "seed"
        /// `process` on `ProcessAgentAdapter` events (app presence).
        public static let source = "source"
    }

    /// Latest turn's input tokens; `nil` when absent, non-numeric or negative.
    public var contextTokens: Int? { nonNegativeInt(MetadataKey.contextTokens) }

    /// Tool calls still running; `nil` when absent, non-numeric or negative.
    public var pendingTools: Int? { nonNegativeInt(MetadataKey.pendingTools) }

    public var turnActive: Bool? { metadata?[MetadataKey.turnActive].flatMap { Bool($0) } }

    /// Reading produced from the startup / session-switch tail; never raises a context warning.
    public var isSeed: Bool { metadata?[MetadataKey.seed] == "true" }

    /// App-presence event from `ProcessAgentAdapter`; its `done` never clears a warning or ends a turn.
    public var isProcessPresence: Bool { metadata?[MetadataKey.source] == "process" }

    public var warningReason: AgentWarningReason {
        metadata?[MetadataKey.reason].flatMap { AgentWarningReason(rawValue: $0) } ?? .reported
    }

    private func nonNegativeInt(_ key: String) -> Int? {
        guard let value = metadata?[key].flatMap({ Int($0) }), value >= 0 else { return nil }
        return value
    }
}

/// Why an agent warning was raised.
public enum AgentWarningReason: String, Codable, Sendable, CaseIterable {
    case context
    case loop
    case stall
    /// Raised by an agent or script through the drop-box; has no toggle.
    case reported
}

/// The single active agent warning shown on the mascot.
public struct AgentWarning: Sendable, Equatable {
    public let agentID: String
    public let agentName: String
    public let reason: AgentWarningReason
    public let text: String

    public init(agentID: String, agentName: String, reason: AgentWarningReason, text: String) {
        self.agentID = agentID
        self.agentName = agentName
        self.reason = reason
        self.text = text
    }
}

/// An agent's latest context window usage.
public struct AgentContextReading: Sendable, Equatable {
    public let agentID: String
    public let agentName: String
    public let tokens: Int
    public let windowTokens: Int

    public init(agentID: String, agentName: String, tokens: Int, windowTokens: Int) {
        self.agentID = agentID
        self.agentName = agentName
        self.tokens = tokens
        self.windowTokens = windowTokens
    }

    /// Percent of the configured window, capped at 100 (the window setting may be smaller than the real one).
    public var percent: Int {
        // Double math: drop-box token counts come from user scripts and could overflow `tokens * 100`.
        windowTokens > 0 ? Int(min(100, Double(tokens) * 100 / Double(windowTokens))) : 0
    }

    /// e.g. `Claude ctx 148k · 74%`
    public var compactText: String {
        "\(agentName) ctx \(Self.formatTokens(tokens)) · \(percent)%"
    }

    public static func formatTokens(_ tokens: Int) -> String {
        if tokens < 1_000 { return "\(tokens)" }
        if tokens < 1_000_000 { return "\(tokens / 1_000)k" }
        return String(format: "%.1fM", Double(tokens) / 1_000_000)
    }
}

/// User settings for agent signals (almost done, context, loop and stall warnings).
public struct AgentSignalSettings: Codable, Sendable, Equatable {
    public static let defaultContextWindow = 200_000
    public static let `default` = AgentSignalSettings()

    public var almostDoneEnabled = true
    public var contextWarningEnabled = true
    public var loopWarningEnabled = true
    public var stallWarningEnabled = true
    /// 50...99
    public var contextThresholdPercent = 90
    /// 1...30
    public var stallTimeoutMinutes = 3
    /// Session logs don't state the model's window, so it is a per-agent setting.
    public var contextWindowTokens: [String: Int] = ["claude": 200_000, "antigravity": 1_000_000]

    public init() {}

    public init(from decoder: Decoder) throws {
        // Field by field, so a blob missing a newer field keeps the other stored values.
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let defaults = AgentSignalSettings()
        almostDoneEnabled = try container.decodeIfPresent(Bool.self, forKey: .almostDoneEnabled) ?? defaults.almostDoneEnabled
        contextWarningEnabled = try container.decodeIfPresent(Bool.self, forKey: .contextWarningEnabled) ?? defaults.contextWarningEnabled
        loopWarningEnabled = try container.decodeIfPresent(Bool.self, forKey: .loopWarningEnabled) ?? defaults.loopWarningEnabled
        stallWarningEnabled = try container.decodeIfPresent(Bool.self, forKey: .stallWarningEnabled) ?? defaults.stallWarningEnabled
        contextThresholdPercent = try container.decodeIfPresent(Int.self, forKey: .contextThresholdPercent) ?? defaults.contextThresholdPercent
        stallTimeoutMinutes = try container.decodeIfPresent(Int.self, forKey: .stallTimeoutMinutes) ?? defaults.stallTimeoutMinutes
        contextWindowTokens = try container.decodeIfPresent([String: Int].self, forKey: .contextWindowTokens) ?? defaults.contextWindowTokens
    }

    public func contextWindow(for agentID: String) -> Int {
        contextWindowTokens[agentID] ?? Self.defaultContextWindow
    }

    public func isEnabled(_ reason: AgentWarningReason) -> Bool {
        switch reason {
        case .context: return contextWarningEnabled
        case .loop: return loopWarningEnabled
        case .stall: return stallWarningEnabled
        case .reported: return true
        }
    }

    public func clamped() -> AgentSignalSettings {
        var copy = self
        copy.contextThresholdPercent = min(99, max(50, contextThresholdPercent))
        copy.stallTimeoutMinutes = min(30, max(1, stallTimeoutMinutes))
        copy.contextWindowTokens = contextWindowTokens.filter { $0.value > 0 }
        return copy
    }
}

/// Metadata and matching rules for an AI agent.
public struct AgentDefinition: Codable, Sendable, Equatable, Identifiable {
    public let id: String
    public let displayName: String
    public let processNames: [String]
    public let bundleIdentifiers: [String]
    public let isCustom: Bool
    public var isEnabled: Bool

    public init(
        id: String,
        displayName: String,
        processNames: [String] = [],
        bundleIdentifiers: [String] = [],
        isCustom: Bool = false,
        isEnabled: Bool = true
    ) {
        self.id = id
        self.displayName = displayName
        self.processNames = processNames
        self.bundleIdentifiers = bundleIdentifiers
        self.isCustom = isCustom
        self.isEnabled = isEnabled
    }

    /// Checks if a given process name or bundle ID matches this agent definition.
    public func matches(processName: String? = nil, bundleIdentifier: String? = nil) -> Bool {
        // Exclude Apple system bundles (e.g., com.apple.TextInputUI.xpc.CursorUIViewService)
        if let bundle = bundleIdentifier?.lowercased(), bundle.hasPrefix("com.apple.") {
            return false
        }

        if let bundleIdentifier = bundleIdentifier?.lowercased() {
            for bundle in bundleIdentifiers {
                if bundleIdentifier == bundle.lowercased() {
                    return true
                }
            }
        }

        if let processName = processName?.lowercased() {
            for name in processNames {
                let target = name.lowercased()
                if processName == target || processName == "\(target) helper" {
                    return true
                }
            }
        }

        return false
    }

    /// Built-in catalog of supported AI agents out-of-the-box.
    public static var builtInCatalog: [AgentDefinition] {
        [
            AgentDefinition(
                id: "claude",
                displayName: "Claude",
                processNames: ["claude", "claude-code"],
                bundleIdentifiers: ["com.anthropic.claudefordesktop"]
            ),
            AgentDefinition(
                id: "gemini",
                displayName: "Gemini",
                processNames: ["gemini"],
                bundleIdentifiers: ["com.google.GeminiMacOS"]
            ),
            AgentDefinition(
                id: "antigravity",
                displayName: "Antigravity",
                processNames: ["antigravity", "agy"],
                bundleIdentifiers: ["com.google.antigravity", "com.google.antigravity-ide"]
            ),
            AgentDefinition(
                id: "codex",
                displayName: "Codex / ChatGPT",
                processNames: ["codex"],
                bundleIdentifiers: ["com.openai.chat"]
            ),
            AgentDefinition(
                id: "cursor",
                displayName: "Cursor",
                processNames: ["cursor"],
                bundleIdentifiers: ["com.todesktop.230313mzl4w4u92"]
            ),
            AgentDefinition(
                id: "windsurf",
                displayName: "Windsurf",
                processNames: ["windsurf"],
                bundleIdentifiers: ["com.exafunction.windsurf"]
            ),
            AgentDefinition(
                id: "copilot",
                displayName: "GitHub Copilot",
                processNames: ["copilot", "github-copilot"],
                bundleIdentifiers: ["com.microsoft.VSCode"]
            ),
            AgentDefinition(
                id: "aider",
                displayName: "Aider",
                processNames: ["aider"]
            ),
            AgentDefinition(
                id: "goose",
                displayName: "Goose",
                processNames: ["goose"]
            ),
            AgentDefinition(
                id: "opencode",
                displayName: "OpenCode",
                processNames: ["opencode"]
            ),
            AgentDefinition(
                id: "amp",
                displayName: "Amp",
                processNames: ["amp"]
            ),
            AgentDefinition(
                id: "cline",
                displayName: "Cline / Roo",
                processNames: ["cline", "roo-cline"]
            )
        ]
    }
}

/// Represents the visual popup notification shown on the MascotOverlay.
public struct AgentPopupState: Sendable, Equatable {
    public let text: String
    public let kind: AgentEventKind
    public let agentName: String
    public let expiresAt: Date?

    public init(text: String, kind: AgentEventKind, agentName: String, expiresAt: Date?) {
        self.text = text
        self.kind = kind
        self.agentName = agentName
        self.expiresAt = expiresAt
    }

    public var isExpired: Bool {
        guard let expiresAt = expiresAt else { return false }
        return Date() >= expiresAt
    }
}
