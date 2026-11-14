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
    case personality = "personality"
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
        case .personality:
            return "AI Personality Commentary"
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
            return "On-device audio recording and local Speech transcription."
        case .personality:
            return "On-device Apple Foundation Models & context-aware commentary with Snarky, Supportive, and Cute presets."
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
             .personality,
             .deepTelemetry,
             .soundPacks:
            return .pro
        }
    }

    /// Whether this capability is on the upcoming roadmap rather than shipped in the current build (#144).
    public var isComingSoon: Bool {
        switch self {
        case .deepTelemetry, .soundPacks:
            return true
        case .multiMascot,
             .customThemes,
             .multiAgentSwarm,
             .meetingRecorder,
             .personality:
            return false
        }
    }
}

// MARK: - Beta Access Policy & QA Entitlement Override

/// Compile-time policy governing temporary Early Adopter Beta access vs. GA production gating (#144).
public enum BetaAccessPolicy: Sendable, Equatable {
    /// Unlocks all shipped Bitz Pro features during the Beta period (`buildDate ..< sunsetDate`)
    /// without requiring or storing a cryptographic token. Automatically falls back to `.free`
    /// once `sunsetDate` passes or if the system clock is rolled back before `buildDate`.
    case betaAllAccess(buildDate: Date, sunsetDate: Date)
    /// GA production mode: requires a valid Ed25519-signed `BITZ1` license key in Keychain for `.pro`.
    case production

    /// Build timestamp floor (`2026-11-10T00:00:00Z` UTC) to prevent clock-rollback extension of Beta access.
    public static let defaultBuildDate = Date(timeIntervalSince1970: 1_794_268_800)

    /// Beta sunset deadline (`2027-01-09T00:00:00Z` UTC — 60 days from `2026-11-10`).
    public static let defaultSunsetDate = Date(timeIntervalSince1970: 1_799_452_800)

    /// Active compiled policy for the current release line.
    public static let current: BetaAccessPolicy = .betaAllAccess(
        buildDate: defaultBuildDate,
        sunsetDate: defaultSunsetDate
    )

    /// Returns `true` if this policy grants temporary Beta Pro access at `now`.
    public func isBetaWindowActive(at now: Date) -> Bool {
        switch self {
        case let .betaAllAccess(buildDate, sunsetDate):
            return now >= buildDate && now < sunsetDate
        case .production:
            return false
        }
    }

    /// Sunset date if configured as `.betaAllAccess`, otherwise `nil`.
    public var sunsetDate: Date? {
        switch self {
        case let .betaAllAccess(_, sunsetDate):
            return sunsetDate
        case .production:
            return nil
        }
    }
}

/// Runtime QA / developer override for testing Free vs. Paid Pro behavior while `BetaAccessPolicy.current` is active (#144).
public enum BitzEntitlementOverride: String, CaseIterable, Sendable, Equatable, Identifiable {
    case automatic = "automatic"
    case simulateFreeTier = "simulate_free_tier"
    case simulatePaidPro = "simulate_paid_pro"

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .automatic:
            return "Default (Beta All-Access)"
        case .simulateFreeTier:
            return "Simulate GA Free Tier (Gate Closed)"
        case .simulatePaidPro:
            return "Simulate Paid Pro License"
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

    public func isExpired(at date: Date) -> Bool {
        guard let expiresAt else { return false }
        return date.timeIntervalSince1970 > expiresAt
    }

    public var isExpired: Bool {
        isExpired(at: Date())
    }
}

// MARK: - Licensing Errors

/// Potential error states encountered during offline license verification or storage.
public enum LicensingError: Error, LocalizedError, Sendable, Equatable {
    case invalidFormat
    case invalidPayload
    case invalidSignature
    case licenseExpired
    case revokedLicense
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
        case .revokedLicense:
            return "This license key has been revoked and is no longer valid."
        case .storageFailed(let reason):
            return "Failed to update license storage: \(reason)"
        }
    }
}
