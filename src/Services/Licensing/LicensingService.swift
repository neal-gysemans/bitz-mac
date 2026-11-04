import Foundation
import CryptoKit

/// Core domain service responsible for backendless, offline cryptographic validation
/// of Bitz Pro license keys and managing tier entitlements.
@MainActor
public final class LicensingService: LicensingServiceProtocol, ObservableObject {
    /// The canonical embedded Ed25519 public key used for production license verification.
    /// Base64: "5F3+zylHfBfB8nvILA9f6gxKCSAqIKa+ldsLoi/J514="
    public static let defaultPublicKeyData: Data = Data(base64Encoded: "5F3+zylHfBfB8nvILA9f6gxKCSAqIKa+ldsLoi/J514=") ?? Data()

    /// Active product tier. Defaults to `.free`.
    @Published public private(set) var currentTier: BitzTier = .free

    /// The active verified license payload, if available.
    @Published public private(set) var activeLicense: LicensePayload? = nil

    private let storage: LicenseStorageProtocol
    private let publicKeyData: Data

    public init(
        storage: LicenseStorageProtocol = KeychainLicenseStorage(),
        publicKeyData: Data = LicensingService.defaultPublicKeyData
    ) {
        self.storage = storage
        self.publicKeyData = publicKeyData

        // Restore previously stored license on startup
        if let storedToken = storage.loadLicenseToken() {
            do {
                let payload = try Self.validate(token: storedToken, publicKeyData: publicKeyData)
                self.activeLicense = payload
                self.currentTier = payload.resolvedTier
            } catch {
                // If stored token is invalid or expired, revert to free and purge corrupted receipt
                self.activeLicense = nil
                self.currentTier = .free
                try? storage.deleteLicenseToken()
            }
        }
    }

    /// Evaluates whether the requested feature is unlocked for the user.
    public func isFeatureUnlocked(_ feature: BitzFeature) -> Bool {
        if feature.requiredTier == .free {
            return true
        }

        guard currentTier == .pro else {
            return false
        }

        // If license payload is present and expired, deny Pro access
        if let activeLicense, activeLicense.isExpired {
            return false
        }

        return true
    }

    /// Offline validation and activation of a license key token.
    public func activateLicense(key: String) throws {
        let trimmedKey = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedKey.isEmpty else {
            throw LicensingError.invalidFormat
        }

        let payload = try Self.validate(token: trimmedKey, publicKeyData: publicKeyData)

        // Persist token in secure storage
        try storage.saveLicenseToken(trimmedKey)

        self.activeLicense = payload
        self.currentTier = payload.resolvedTier
    }

    /// Deactivates the active license and reverts the user to Free tier.
    public func deactivateLicense() throws {
        try storage.deleteLicenseToken()
        self.activeLicense = nil
        self.currentTier = .free
    }

    // MARK: - Cryptographic Verification (Pure Offline Function)

    /// Validates a license token string against an Ed25519 public key.
    /// Token format: `BITZ1.<base64url_json_payload>.<base64url_signature>`
    nonisolated public static func validate(token: String, publicKeyData: Data) throws -> LicensePayload {
        let parts = token.components(separatedBy: ".")
        guard parts.count == 3 else {
            throw LicensingError.invalidFormat
        }

        let header = parts[0]
        let payloadEncoded = parts[1]
        let signatureEncoded = parts[2]

        guard header == "BITZ1" else {
            throw LicensingError.invalidFormat
        }

        guard let payloadData = base64URLDecode(payloadEncoded),
              let signatureData = base64URLDecode(signatureEncoded) else {
            throw LicensingError.invalidFormat
        }

        guard signatureData.count == 64 else {
            throw LicensingError.invalidSignature
        }

        guard let publicKey = try? Curve25519.Signing.PublicKey(rawRepresentation: publicKeyData) else {
            throw LicensingError.invalidSignature
        }

        let signedData = Data("\(header).\(payloadEncoded)".utf8)
        guard publicKey.isValidSignature(signatureData, for: signedData) else {
            throw LicensingError.invalidSignature
        }

        let decoder = JSONDecoder()
        guard let payload = try? decoder.decode(LicensePayload.self, from: payloadData) else {
            throw LicensingError.invalidPayload
        }

        guard !payload.isExpired else {
            throw LicensingError.licenseExpired
        }

        return payload
    }

    // MARK: - Base64URL Helpers

    nonisolated public static func base64URLDecode(_ string: String) -> Data? {
        var base64 = string
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")

        let remainder = base64.count % 4
        if remainder > 0 {
            base64.append(String(repeating: "=", count: 4 - remainder))
        }

        return Data(base64Encoded: base64)
    }

    nonisolated public static func base64URLEncode(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}
