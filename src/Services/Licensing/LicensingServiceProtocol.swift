import Foundation

/// Defines the contract for query, activation, and feature-gating of Bitz licenses.
@MainActor
public protocol LicensingServiceProtocol: AnyObject, ObservableObject {
    /// The currently active product tier.
    var currentTier: BitzTier { get }

    /// The decoded payload of the active license, if one is active.
    var activeLicense: LicensePayload? { get }

    /// The registered customer email for Beta outreach / updates.
    var registeredEmail: String? { get }

    /// Checks if a specific feature is unlocked under the current tier.
    func isFeatureUnlocked(_ feature: BitzFeature) -> Bool

    /// Cryptographically validates and activates a license key token offline.
    func activateOfflineLicense(key: String) throws

    /// Validates and activates a license key (supports both offline BITZ1 tokens and remote Supabase / Lemon Squeezy keys).
    func activateLicense(key: String) async throws

    /// Deactivates the current license and reverts to the Free tier.
    func deactivateLicense() throws

    /// Saves or updates the user's registered email.
    func saveRegisteredEmail(_ email: String)
}

public extension LicensingServiceProtocol {
    var registeredEmail: String? { nil }
    func saveRegisteredEmail(_ email: String) {}
    func activateLicense(key: String) throws {
        try activateOfflineLicense(key: key)
    }
    func activateOfflineLicense(key: String) throws {
        throw LicensingError.invalidFormat
    }
}
