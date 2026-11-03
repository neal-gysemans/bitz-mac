import Foundation

/// Specific sound events that can be triggered by mascot state changes or agent monitor events.
public enum CyberSoundEvent: String, CaseIterable, Identifiable, Codable, Sendable {
    case purr = "purr"
    case burnout = "burnout"
    case overheating = "overheating"
    case charging = "charging"
    case agentNeedsApproval = "agentNeedsApproval"
    case allAgentsDone = "allAgentsDone"

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .purr:
            return "Soothing Cat Purr"
        case .burnout:
            return "Burnout Glitch"
        case .overheating:
            return "Thermal Alarm"
        case .charging:
            return "Charging Blip"
        case .agentNeedsApproval:
            return "Agent Attention Chime"
        case .allAgentsDone:
            return "All Agents Done Fanfare"
        }
    }

    public var assetFileName: String {
        switch self {
        case .purr:
            return "purr_loop.wav"
        case .burnout:
            return "burnout_glitch.wav"
        case .overheating:
            return "overheat_alarm.wav"
        case .charging:
            return "charging_blip.wav"
        case .agentNeedsApproval:
            return "agent_chime.wav"
        case .allAgentsDone:
            return "all_done_fanfare.wav"
        }
    }

    public var isLooping: Bool {
        self == .purr
    }

    public var defaultCooldown: TimeInterval {
        switch self {
        case .agentNeedsApproval:
            return 10.0 // Minimum 10 seconds between chimes for an agent
        case .allAgentsDone:
            return 60.0 // Minimum 60 seconds between all-done fanfares
        case .purr, .burnout, .overheating, .charging:
            return 0.0  // Governed by state transitions or continuous looping
        }
    }
}

/// Reason why an audio playback attempt was skipped or suppressed.
public enum AudioSuppressionReason: String, Sendable, Equatable {
    case masterDisabled
    case eventDisabled
    case systemMuted
    case focusActive
    case callOrScreenSharingActive
    case cooldownActive
    case rateLimited
    case sameState
    case assetMissing

    /// User-facing cause when the environment (not a setting or cooldown) muted a sound; nil otherwise.
    public var environmentDescription: String? {
        switch self {
        case .systemMuted: return "system output is muted"
        case .focusActive: return "Focus / Do Not Disturb is on"
        case .callOrScreenSharingActive: return "microphone in use by another app"
        case .masterDisabled, .eventDisabled, .cooldownActive, .rateLimited, .sameState, .assetMissing: return nil
        }
    }
}
