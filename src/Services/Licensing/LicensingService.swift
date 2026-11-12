import Foundation
import AppKit
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

    /// The registered customer email for Beta outreach / updates.
    @Published public private(set) var registeredEmail: String? = nil

    private static let emailDefaultsKey = "bitz.licensing.customer_email"
    private let storage: LicenseStorageProtocol
    private let publicKeyData: Data
    private let backendClient: (any LicensingBackendClient)?

    private var validationTask: Task<Void, Never>?
    private var wakeObserver: (any NSObjectProtocol)?
    private var lastValidationTime: Date?

    public init(
        storage: LicenseStorageProtocol = KeychainLicenseStorage(),
        publicKeyData: Data = LicensingService.defaultPublicKeyData,
        backendClient: (any LicensingBackendClient)? = nil
    ) {
        self.storage = storage
        self.publicKeyData = publicKeyData
        self.backendClient = backendClient
        self.registeredEmail = UserDefaults.standard.string(forKey: Self.emailDefaultsKey)

        // Restore previously stored license on startup
        if let storedToken = storage.loadLicenseToken() {
            if storedToken.hasPrefix("BITZ1.") {
                do {
                    let payload = try Self.validate(token: storedToken, publicKeyData: publicKeyData)
                    self.activeLicense = payload
                    self.currentTier = payload.resolvedTier
                } catch {
                    self.activeLicense = nil
                    self.currentTier = .free
                    try? storage.deleteLicenseToken()
                }
            } else if storedToken.hasPrefix("BTZ-") {
                self.activeLicense = LicensePayload(tier: "pro", licenseId: storedToken, issuedAt: Date().timeIntervalSince1970)
                self.currentTier = .pro
            } else {
                // Unknown or corrupt token format: purge and revert to free
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

    /// Synchronous offline validation and activation of an Ed25519 license token.
    public func activateLicense(key: String) throws {
        try activateOfflineLicense(key: key)
    }

    /// Pure offline activation using Curve25519 signature checks.
    public func activateOfflineLicense(key: String) throws {
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

    /// Asynchronous validation supporting both offline BITZ1 tokens and remote Supabase keys (e.g. BTZ-BETA-XXXX-XXXX).
    public func activateLicense(key: String) async throws {
        let trimmedKey = key.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        guard !trimmedKey.isEmpty else {
            throw LicensingError.invalidFormat
        }

        if trimmedKey.hasPrefix("BITZ1.") {
            try activateOfflineLicense(key: trimmedKey)
            return
        }

        guard let backend = backendClient else {
            throw LicensingError.storageFailed("Remote licensing backend is unavailable")
        }

        let deviceId = DeviceHardwareIdentifier.hashedDeviceID()
        let result = try await backend.validate(licenseKey: trimmedKey, deviceId: deviceId)

        guard result.valid else {
            let errorMsg = result.message ?? result.error ?? "Invalid or expired license key"
            throw LicensingError.storageFailed(errorMsg)
        }

        let expiresAtInterval = result.expiresAt?.timeIntervalSince1970
        let payload = LicensePayload(
            tier: result.tier ?? "pro",
            licenseId: result.licenseKey ?? trimmedKey,
            issuedAt: Date().timeIntervalSince1970,
            expiresAt: expiresAtInterval
        )

        try storage.saveLicenseToken(trimmedKey)
        self.activeLicense = payload
        self.currentTier = payload.resolvedTier
        if let email = result.customerEmail {
            self.saveRegisteredEmail(email)
        }
    }

    /// Deactivates the active license and reverts the user to Free tier.
    public func deactivateLicense() throws {
        let currentLicenseId = activeLicense?.licenseId
        let backend = backendClient

        try storage.deleteLicenseToken()
        UserDefaults.standard.removeObject(forKey: Self.emailDefaultsKey)
        self.registeredEmail = nil
        self.activeLicense = nil
        self.currentTier = .free

        // Release device seat in remote backend for BTZ- keys
        if let currentLicenseId, currentLicenseId.hasPrefix("BTZ-"), let backend {
            Task {
                let deviceId = DeviceHardwareIdentifier.hashedDeviceID()
                _ = try? await backend.deactivate(licenseKey: currentLicenseId, deviceId: deviceId)
            }
        }
    }

    /// Saves or updates the registered user email address for Beta communications.
    public func saveRegisteredEmail(_ email: String) {
        let trimmed = email.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !trimmed.isEmpty else { return }
        UserDefaults.standard.set(trimmed, forKey: Self.emailDefaultsKey)
        self.registeredEmail = trimmed

        // Non-blocking background sync to remote backend if active license and client are present
        if let backend = backendClient, let license = activeLicense {
            Task {
                _ = try? await backend.registerEmail(licenseKey: license.licenseId, customerEmail: trimmed)
            }
        }
    }

    // MARK: - Periodic Background Validation

    /// Starts the daily background validation schedule (every 24 hours + on system wake).
    public func startPeriodicValidationSchedule(
        validationInterval: TimeInterval = 86_400,
        wakeDebounce: TimeInterval = 20.0,
        minCheckInterval: TimeInterval = 21_600
    ) {
        stopPeriodicValidationSchedule()

        // 1. Listen for system wake notifications (debounced by 20s to allow Wi-Fi re-connect)
        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            Task { @MainActor [weak self] in
                guard let self else { return }
                try? await Task.sleep(nanoseconds: UInt64(wakeDebounce * 1_000_000_000))
                if let last = self.lastValidationTime, Date().timeIntervalSince(last) < minCheckInterval {
                    return
                }
                await self.validateActiveLicenseRemotely()
            }
        }

        // 2. Daily background check loop
        validationTask = Task { [weak self] in
            // Initial 15s delay so app launch remains instantaneous
            try? await Task.sleep(nanoseconds: 15_000_000_000)
            guard let self, !Task.isCancelled else { return }
            await self.validateActiveLicenseRemotely()

            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: UInt64(validationInterval * 1_000_000_000))
                guard !Task.isCancelled else { return }
                await self.validateActiveLicenseRemotely()
            }
        }
    }

    public func stopPeriodicValidationSchedule() {
        validationTask?.cancel()
        validationTask = nil
        if let wakeObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(wakeObserver)
            self.wakeObserver = nil
        }
    }

    /// Checks the active license with Supabase. Reverts to Free tier if expired or revoked.
    public func validateActiveLicenseRemotely() async {
        guard let license = activeLicense, currentTier == .pro else { return }

        // Offline BITZ1 token: check local cryptographic expiration
        if license.licenseId.hasPrefix("BITZ1.") {
            if license.isExpired {
                try? deactivateLicense()
            }
            return
        }

        // Unknown token format: purge immediately
        guard license.licenseId.hasPrefix("BTZ-") else {
            try? deactivateLicense()
            return
        }

        guard let backend = backendClient else { return }
        lastValidationTime = Date()

        let deviceId = DeviceHardwareIdentifier.hashedDeviceID()
        do {
            let result = try await backend.validate(licenseKey: license.licenseId, deviceId: deviceId)
            if !result.valid {
                // Key was revoked or expired in Supabase!
                try? deactivateLicense()
            } else if let expiresAt = result.expiresAt, Date() > expiresAt {
                try? deactivateLicense()
            }
        } catch {
            // Offline grace period: If network fails, do NOT immediately downgrade
            if let expiresAt = license.expiresAt, Date().timeIntervalSince1970 > expiresAt {
                try? deactivateLicense()
            }
        }
    }

    isolated deinit {
        validationTask?.cancel()
        if let wakeObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(wakeObserver)
        }
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
