import AppKit
import Foundation
import CryptoKit

/// Core domain service responsible for backendless, offline cryptographic validation
/// of Bitz Pro license keys and managing tier entitlements (`#144`).
@MainActor
public final class LicensingService: LicensingServiceProtocol, ObservableObject {
    /// The canonical embedded Ed25519 public key used for production license verification.
    /// Base64: "5F3+zylHfBfB8nvILA9f6gxKCSAqIKa+ldsLoi/J514="
    nonisolated public static let defaultPublicKeyData: Data = Data(base64Encoded: "5F3+zylHfBfB8nvILA9f6gxKCSAqIKa+ldsLoi/J514=") ?? Data()

    /// Revoked license identifiers rejected during offline verification (`#144`).
    nonisolated public static let revokedLicenseIDs: Set<String> = [
        "BTZ-LOCAL-DEV-PRO"
    ]

    /// Active product tier.
    @Published public private(set) var currentTier: BitzTier = .free

    /// The active verified license payload, if available.
    @Published public private(set) var activeLicense: LicensePayload? = nil

    /// `true` when `.pro` access is granted via the temporary `BetaAccessPolicy` rather than a stored license token.
    @Published public private(set) var isBetaAccessActive: Bool = false

    /// Runtime QA / developer override for testing Free vs. Paid Pro behavior while Beta All-Access is compiled in.
    @Published public private(set) var entitlementOverride: BitzEntitlementOverride = .automatic

    public let accessPolicy: BetaAccessPolicy
    private let storage: LicenseStorageProtocol
    private let publicKeyData: Data
    private let clock: () -> Date
    private var storedVerifiedLicense: LicensePayload? = nil
    nonisolated(unsafe) private var wakeObserver: NSObjectProtocol? = nil

    public init(
        storage: LicenseStorageProtocol = KeychainLicenseStorage(),
        publicKeyData: Data = LicensingService.defaultPublicKeyData,
        accessPolicy: BetaAccessPolicy = .current,
        clock: @escaping () -> Date = { Date() }
    ) {
        self.storage = storage
        self.publicKeyData = publicKeyData
        self.accessPolicy = accessPolicy
        self.clock = clock

        // Restore previously stored license on startup
        if let storedToken = storage.loadLicenseToken() {
            do {
                let payload = try Self.validate(token: storedToken, publicKeyData: publicKeyData, now: clock())
                self.storedVerifiedLicense = payload
            } catch {
                // If stored token is invalid, expired, or revoked, purge corrupted receipt
                self.storedVerifiedLicense = nil
                try? storage.deleteLicenseToken()
            }
        }

        refreshEntitlement()

        self.wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.refreshEntitlement()
            }
        }
    }

    deinit {
        if let wakeObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(wakeObserver)
        }
    }

    /// Sets the runtime QA / developer entitlement override and immediately re-evaluates tier state.
    public func setEntitlementOverride(_ newOverride: BitzEntitlementOverride) {
        guard entitlementOverride != newOverride else { return }
        entitlementOverride = newOverride
        refreshEntitlement()
    }

    /// Re-evaluates license expiration, Beta sunset window, and QA overrides, updating `currentTier` if changed.
    public func refreshEntitlement() {
        let now = clock()

        if let storedVerifiedLicense, storedVerifiedLicense.isExpired(at: now) {
            self.storedVerifiedLicense = nil
            try? storage.deleteLicenseToken()
        }

        let nextLicense: LicensePayload?
        let nextBetaActive: Bool
        let nextTier: BitzTier

        switch entitlementOverride {
        case .simulateFreeTier:
            nextLicense = nil
            nextBetaActive = false
            nextTier = .free

        case .simulatePaidPro:
            nextLicense = storedVerifiedLicense ?? LicensePayload(
                tier: "pro",
                licenseId: "BTZ-QA-SIMULATED-PRO",
                issuedAt: now.timeIntervalSince1970,
                expiresAt: nil
            )
            nextBetaActive = false
            nextTier = .pro

        case .automatic:
            if let verified = storedVerifiedLicense {
                nextLicense = verified
                nextBetaActive = false
                nextTier = verified.resolvedTier
            } else if accessPolicy.isBetaWindowActive(at: now) {
                nextLicense = nil
                nextBetaActive = true
                nextTier = .pro
            } else {
                nextLicense = nil
                nextBetaActive = false
                nextTier = .free
            }
        }

        if activeLicense != nextLicense {
            activeLicense = nextLicense
        }
        if isBetaAccessActive != nextBetaActive {
            isBetaAccessActive = nextBetaActive
        }
        if currentTier != nextTier {
            currentTier = nextTier
        }
    }

    /// Evaluates whether the requested feature is unlocked for the user.
    public func isFeatureUnlocked(_ feature: BitzFeature) -> Bool {
        let now = clock()
        if let storedVerifiedLicense, storedVerifiedLicense.isExpired(at: now) {
            refreshEntitlement()
        } else if isBetaAccessActive && !accessPolicy.isBetaWindowActive(at: now) {
            refreshEntitlement()
        }

        if feature.requiredTier == .free {
            return true
        }

        guard currentTier == .pro else {
            return false
        }

        if let activeLicense, activeLicense.isExpired(at: now) {
            refreshEntitlement()
            return currentTier == .pro
        }

        return true
    }

    /// Offline validation and activation of a license key token.
    public func activateLicense(key: String) throws {
        let trimmedKey = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedKey.isEmpty else {
            throw LicensingError.invalidFormat
        }

        let payload = try Self.validate(token: trimmedKey, publicKeyData: publicKeyData, now: clock())

        // Persist token in secure storage
        try storage.saveLicenseToken(trimmedKey)

        self.storedVerifiedLicense = payload
        if entitlementOverride == .simulateFreeTier {
            entitlementOverride = .automatic
        }
        refreshEntitlement()
    }

    /// Deactivates the active license and removes the token from Keychain.
    public func deactivateLicense() throws {
        try storage.deleteLicenseToken()
        self.storedVerifiedLicense = nil
        if entitlementOverride == .simulatePaidPro {
            entitlementOverride = .automatic
        }
        refreshEntitlement()
    }

    // MARK: - Cryptographic Verification (Pure Offline Function)

    /// Validates a license token string against an Ed25519 public key.
    /// Token format: `BITZ1.<base64url_json_payload>.<base64url_signature>`
    nonisolated public static func validate(
        token: String,
        publicKeyData: Data,
        now: Date = Date()
    ) throws -> LicensePayload {
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

        guard !revokedLicenseIDs.contains(payload.licenseId) else {
            throw LicensingError.revokedLicense
        }

        guard !payload.isExpired(at: now) else {
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
