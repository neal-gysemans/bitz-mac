import Foundation

/// Specific sound events that can be triggered by mascot state changes or agent monitor events.
public enum CyberSoundEvent: String, CaseIterable, Identifiable, Codable, Sendable {
    case purr = "purr"
    case burnout = "burnout"
    case overheating = "overheating"
    case charging = "charging"
    case agentNeedsApproval = "agentNeedsApproval"
    case allAgentsDone = "allAgentsDone"
    case meetingRecordingStarted = "meetingRecordingStarted"
    case meetingRecordingSaved = "meetingRecordingSaved"

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
        case .meetingRecordingStarted:
            return "Meeting Recording Started"
        case .meetingRecordingSaved:
            return "Meeting Recording Saved"
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
        // Reuses the bundled blip and fanfare; their own events give them their own toggles and gating
        case .meetingRecordingStarted:
            return "charging_blip.wav"
        case .meetingRecordingSaved:
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
        case .purr, .burnout, .overheating, .charging, .meetingRecordingStarted, .meetingRecordingSaved:
            return 0.0  // Governed by state transitions, continuous looping, or one recording
        }
    }

    /// Meeting recorder chimes confirm the user's own action, and the user is by definition in a call (#43 D5).
    public var ignoresCallSuppression: Bool {
        self == .meetingRecordingStarted || self == .meetingRecordingSaved
    }

    /// The start chime tells the user Bitz is listening, so only its own toggle and a muted Mac silence it (#43 D5, A2).
    public var ignoresMasterAndFocus: Bool {
        self == .meetingRecordingStarted
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
