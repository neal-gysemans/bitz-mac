import Foundation

/// Defines the contract for query, activation, and feature-gating of Bitz licenses.
@MainActor
public protocol LicensingServiceProtocol: AnyObject, ObservableObject {
    /// The currently active product tier.
    var currentTier: BitzTier { get }

    /// The decoded payload of the active license, if one is active.
    var activeLicense: LicensePayload? { get }

    /// Checks if a specific feature is unlocked under the current tier.
    func isFeatureUnlocked(_ feature: BitzFeature) -> Bool

    /// Cryptographically validates and activates a license key token.
    /// Saves the token to persistent storage if valid.
    func activateLicense(key: String) throws

    /// Deactivates the current license and reverts to the Free tier.
    func deactivateLicense() throws
}
