import Foundation

/// Protocol abstracting license token persistence to allow clean decoupling
/// from the macOS Keychain and deterministic in-memory testing.
public protocol LicenseStorageProtocol: Sendable {
    /// Loads the stored license token string, if any exists.
    func loadLicenseToken() -> String?

    /// Saves the validated license token string securely.
    func saveLicenseToken(_ token: String) throws

    /// Deletes the stored license token from persistence.
    func deleteLicenseToken() throws
}
