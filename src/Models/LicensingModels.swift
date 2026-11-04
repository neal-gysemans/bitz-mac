import Foundation

// MARK: - Bitz Licensing Tiers

/// The tier of features available to the user.
public enum BitzTier: String, Codable, Sendable, Equatable, CaseIterable {
    /// Full desktop companion with core cyber cat, all wellness PTS states,
    /// drag & snap windowing, single AI coding agent tracking, standard telemetry, and cyber SFX.
    case free

    /// Expression, extra companions, and power-user workflows:
    /// Multi-mascot roster, custom themes/visors, multi-agent swarm, and meeting recorder.
    case pro

    public var displayName: String {
        switch self {
        case .free:
            return "Free Companion"
        case .pro:
            return "Bitz Pro"
        }
    }
}

// MARK: - Bitz Features

/// Discrete feature capabilities gated by tier.
public enum BitzFeature: String, Codable, Sendable, Equatable, CaseIterable, Hashable {
    case multiMascot = "multi_mascot"
    case customThemes = "custom_themes"
    case multiAgentSwarm = "multi_agent_swarm"
    case meetingRecorder = "meeting_recorder"
    case deepTelemetry = "deep_telemetry"
    case soundPacks = "sound_packs"

    public var title: String {
        switch self {
        case .multiMascot:
            return "Mascot Roster"
        case .customThemes:
            return "Palette & Visor Studio"
        case .multiAgentSwarm:
            return "Multi-Agent Swarm"
        case .meetingRecorder:
            return "Local Meeting Assistant"
        case .deepTelemetry:
            return "Deep Telemetry"
        case .soundPacks:
            return "Audio Studio Packs"
        }
    }

    public var description: String {
        switch self {
        case .multiMascot:
            return "Unlock Byte (Dog), Aero (Hover Drone), Pixel (Mech), and seasonal companions."
        case .customThemes:
            return "Custom cyberpunk color palettes and LED visor light matrices."
        case .multiAgentSwarm:
            return "Monitor 2+ simultaneous background agents with aggregated status and stall alerts."
        case .meetingRecorder:
            return "On-device audio recording and local Whisper transcription."
        case .deepTelemetry:
            return "Per-process battery impact and browser tab memory inspection."
        case .soundPacks:
            return "Chiptune, Mechanical Switches, and Soft Chimes audio packs."
        }
    }

    public var requiredTier: BitzTier {
        switch self {
        case .multiMascot,
             .customThemes,
             .multiAgentSwarm,
             .meetingRecorder,
             .deepTelemetry,
             .soundPacks:
            return .pro
        }
    }
}

// MARK: - License Payload

/// Cryptographically signed payload contained within a license token.
public struct LicensePayload: Codable, Sendable, Equatable {
    public let tier: String
    public let licenseId: String
    public let issuedAt: TimeInterval
    public let expiresAt: TimeInterval?

    enum CodingKeys: String, CodingKey {
        case tier
        case licenseId = "license_id"
        case issuedAt = "issued_at"
        case expiresAt = "expires_at"
    }

    public init(
        tier: String,
        licenseId: String,
        issuedAt: TimeInterval,
        expiresAt: TimeInterval? = nil
    ) {
        self.tier = tier
        self.licenseId = licenseId
        self.issuedAt = issuedAt
        self.expiresAt = expiresAt
    }

    public var resolvedTier: BitzTier {
        BitzTier(rawValue: tier) ?? .free
    }

    public var isExpired: Bool {
        guard let expiresAt else { return false }
        return Date().timeIntervalSince1970 > expiresAt
    }
}

// MARK: - Licensing Errors

/// Potential error states encountered during offline license verification or storage.
public enum LicensingError: Error, LocalizedError, Sendable, Equatable {
    case invalidFormat
    case invalidPayload
    case invalidSignature
    case licenseExpired
    case storageFailed(String)

    public var errorDescription: String? {
        switch self {
        case .invalidFormat:
            return "Invalid license key format. Expected 'BITZ1.<payload>.<signature>'."
        case .invalidPayload:
            return "The license payload could not be decoded or contains invalid fields."
        case .invalidSignature:
            return "Cryptographic signature verification failed. The license key is invalid or tampered with."
        case .licenseExpired:
            return "This license key has expired."
        case .storageFailed(let reason):
            return "Failed to update license storage: \(reason)"
        }
    }
}
