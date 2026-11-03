import Foundation

// Make BitzState Codable for context serialization
extension BitzState: Codable {}

/// Personality preset determining Bitz's demeanor, commentary tone, and system prompt.
public enum PersonalityPreset: String, CaseIterable, Codable, Sendable, Identifiable {
    case snarky
    case supportive
    case cute

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .snarky: return "Snarky"
        case .supportive: return "Supportive"
        case .cute: return "Cute"
        }
    }

    /// System instructions given to on-device LLMs or used for templated commentary.
    public var systemPrompt: String {
        switch self {
        case .snarky:
            return "You are Bitz, a witty, sarcastic cyber-cat desktop mascot on macOS. You make clever, dry, slightly teasing observations about the user's computer habits, high temperatures, work streaks, and coding agents. Always stay playful and affectionate—never genuinely mean or insulting. Respond in exactly one sentence under 80 characters. Never use quotation marks, window titles, or raw URLs."
        case .supportive:
            return "You are Bitz, an encouraging, mindful cyber-cat companion on macOS. You gently celebrate deep focus streaks, suggest friendly wellness breaks, and acknowledge hard work without nagging. Respond in exactly one sentence under 80 characters. Never use quotation marks, window titles, or raw URLs."
        case .cute:
            return "You are Bitz, an adorable, enthusiastic cyber-cat companion on macOS. You make cute, purr-filled remarks about computer warmth, coding sessions, and taking care of yourself. Use cheerful cat-like energy. Respond in exactly one sentence under 80 characters. Never use quotation marks, window titles, or raw URLs."
        }
    }

    /// Short guideline summarizing the preset's tone.
    public var toneGuide: String {
        switch self {
        case .snarky:
            return "Playfully sarcastic, dry wit, light ribbing on long hours or high temps."
        case .supportive:
            return "Gentle, encouraging, mindful of health, celebrate small wins."
        case .cute:
            return "Energetic, feline quirks, purrs, sweet observations."
        }
    }
}

/// Immutable snapshot of contextual signals used to generate or select commentary.
public struct PersonalityContext: Sendable, Equatable, Codable {
    public let wellnessState: BitzState
    public let currentPoints: Double
    public let continuousWorkMinutes: Double
    public let temperatureCelsius: Double?
    public let cpuLoadPercentage: Double?
    public let frontmostAppName: String?
    public let isFrontmostProductive: Bool?
    public let activeAgentNames: [String]
    public let recentCommitCount: Int?

    public init(
        wellnessState: BitzState = .balanced,
        currentPoints: Double = 50.0,
        continuousWorkMinutes: Double = 0.0,
        temperatureCelsius: Double? = nil,
        cpuLoadPercentage: Double? = nil,
        frontmostAppName: String? = nil,
        isFrontmostProductive: Bool? = nil,
        activeAgentNames: [String] = [],
        recentCommitCount: Int? = nil
    ) {
        self.wellnessState = wellnessState
        self.currentPoints = currentPoints
        self.continuousWorkMinutes = continuousWorkMinutes
        self.temperatureCelsius = temperatureCelsius
        self.cpuLoadPercentage = cpuLoadPercentage
        self.frontmostAppName = frontmostAppName
        self.isFrontmostProductive = isFrontmostProductive
        self.activeAgentNames = activeAgentNames
        self.recentCommitCount = recentCommitCount
    }
}

/// Errors occurring during on-device commentary generation.
public enum PersonalityError: Error, Sendable, Equatable {
    case modelUnavailable(String)
    case generationFailed(String)
    case timedOut
    case rateLimited
    case gated(String)
    case outputEmpty
    case outputSanitizedAway
}
