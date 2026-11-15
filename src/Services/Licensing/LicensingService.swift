import AppKit
import CryptoKit
import Foundation

/// Core domain service responsible for offline Ed25519 verification and Supabase seat
/// validation of Bitz Pro license keys, plus `BetaAccessPolicy` entitlement guardrails (`#144`, `#146`).
@MainActor
public final class LicensingService: LicensingServiceProtocol, ObservableObject {
    /// The canonical embedded Ed25519 public key used for production license verification.
    /// Base64: "5F3+zylHfBfB8nvILA9f6gxKCSAqIKa+ldsLoi/J514="
    nonisolated public static let defaultPublicKeyData: Data = Data(base64Encoded: "5F3+zylHfBfB8nvILA9f6gxKCSAqIKa+ldsLoi/J514=") ?? Data()

    /// Revoked license identifiers rejected during offline and remote verification (`#144`).
    nonisolated public static let revokedLicenseIDs: Set<String> = [
        "BTZ-LOCAL-DEV-PRO"
    ]

    /// Active product tier.
    @Published public private(set) var currentTier: BitzTier = .free

    /// The active verified license payload, if available.
    @Published public private(set) var activeLicense: LicensePayload? = nil

    /// The registered customer email for Beta outreach / updates.
    @Published public private(set) var registeredEmail: String? = nil

    /// `true` when `.pro` access is granted via the temporary `BetaAccessPolicy` rather than a stored license token.
    @Published public private(set) var isBetaAccessActive: Bool = false

    /// Runtime QA / developer override for testing Free vs. Paid Pro behavior while Beta All-Access is compiled in.
    @Published public private(set) var entitlementOverride: BitzEntitlementOverride = .automatic

    public let accessPolicy: BetaAccessPolicy
    /// Whether QA / developer entitlement overrides (`setEntitlementOverride`) are permitted in this build.
    public let isEntitlementOverrideAvailable: Bool

    /// `true` when QA override is temporarily simulating `.simulateFreeTier`.
    public var isSimulatingFreeTier: Bool {
        isEntitlementOverrideAvailable && entitlementOverride == .simulateFreeTier
    }
    private static let emailDefaultsKey = "bitz.licensing.customer_email"
    private let storage: LicenseStorageProtocol
    private let publicKeyData: Data
    private let backendClient: (any LicensingBackendClient)?
    private let clock: () -> Date
    private let userDefaults: UserDefaults
    private var storedVerifiedLicense: LicensePayload? = nil

    private var validationTask: Task<Void, Never>?
    private var entitlementWakeObserver: (any NSObjectProtocol)?
    private var validationWakeObserver: (any NSObjectProtocol)?
    private var lastValidationTime: Date?

    /// Returns whether runtime QA entitlement overrides are allowed by default for `accessPolicy`.
    /// Locked strictly to `#if DEBUG` builds with non-`.production` access policy so Release DMG binaries cannot bypass GA gating.
    nonisolated public static func defaultAllowEntitlementOverride(
        for accessPolicy: BetaAccessPolicy,
        bundleIdentifier: String? = Bundle.main.bundleIdentifier,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        isDebugBuild: Bool = {
            #if DEBUG
            return true
            #else
            return false
            #endif
        }()
    ) -> Bool {
        _ = bundleIdentifier
        _ = environment
        return accessPolicy != .production && isDebugBuild
    }

    public init(
        storage: LicenseStorageProtocol = KeychainLicenseStorage(),
        publicKeyData: Data = LicensingService.defaultPublicKeyData,
        backendClient: (any LicensingBackendClient)? = nil,
        accessPolicy: BetaAccessPolicy = .current,
        clock: @escaping () -> Date = { Date() },
        userDefaults: UserDefaults = .standard,
        allowEntitlementOverride: Bool? = nil
    ) {
        self.storage = storage
        self.publicKeyData = publicKeyData
        self.backendClient = backendClient
        self.accessPolicy = accessPolicy
        self.clock = clock
        self.userDefaults = userDefaults
        self.isEntitlementOverrideAvailable = allowEntitlementOverride ?? Self.defaultAllowEntitlementOverride(for: accessPolicy)
        self.registeredEmail = userDefaults.string(forKey: Self.emailDefaultsKey)

        // Restore previously stored license on startup
        if let storedToken = storage.loadLicenseToken() {
            let trimmedToken = storedToken.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmedToken.hasPrefix("BITZ1.") {
                do {
                    let payload = try Self.validate(token: trimmedToken, publicKeyData: publicKeyData, now: clock())
                    self.storedVerifiedLicense = payload
                } catch {
                    // If stored token is invalid, expired, or revoked, purge corrupted receipt
                    self.storedVerifiedLicense = nil
                    try? storage.deleteLicenseToken()
                }
            } else if trimmedToken.hasPrefix("BTZ-") {
                let decoded = Self.decodeRemoteStorageToken(trimmedToken, now: clock())
                if Self.revokedLicenseIDs.contains(decoded.licenseId) {
                    self.storedVerifiedLicense = nil
                    try? storage.deleteLicenseToken()
                } else if let payload = decoded.payload, !payload.isExpired(at: clock()) {
                    self.storedVerifiedLicense = payload
                } else {
                    self.storedVerifiedLicense = nil
                    try? storage.deleteLicenseToken()
                }
            } else {
                // Unknown or corrupt token format: purge and revert to free
                self.storedVerifiedLicense = nil
                try? storage.deleteLicenseToken()
            }
        }

        refreshEntitlement()

        self.entitlementWakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.refreshEntitlement()
            }
        }
    }

    /// Sets the runtime QA / developer entitlement override when permitted and re-evaluates tier state.
    public func setEntitlementOverride(_ newOverride: BitzEntitlementOverride) {
        guard isEntitlementOverrideAvailable else {
            if entitlementOverride != .automatic {
                entitlementOverride = .automatic
                refreshEntitlement()
            }
            return
        }
        guard entitlementOverride != newOverride else { return }
        entitlementOverride = newOverride
        refreshEntitlement()
    }

    private struct ResolvedEntitlement {
        let tier: BitzTier
        let activeLicense: LicensePayload?
        let isBetaAccessActive: Bool
    }

    /// Pure computation of effective tier/license/Beta state at `now` with no Keychain or `@Published` side effects.
    private func resolveEntitlement(at now: Date) -> ResolvedEntitlement {
        let validStoredLicense: LicensePayload? = {
            guard let storedVerifiedLicense,
                  !storedVerifiedLicense.isExpired(at: now),
                  !Self.revokedLicenseIDs.contains(storedVerifiedLicense.licenseId) else {
                return nil
            }
            return storedVerifiedLicense
        }()

        let effectiveOverride: BitzEntitlementOverride = isEntitlementOverrideAvailable ? entitlementOverride : .automatic

        switch effectiveOverride {
        case .simulateFreeTier:
            return ResolvedEntitlement(tier: .free, activeLicense: nil, isBetaAccessActive: false)

        case .simulatePaidPro:
            let simulated = validStoredLicense ?? LicensePayload(
                tier: "pro",
                licenseId: "BTZ-QA-SIMULATED-PRO",
                issuedAt: now.timeIntervalSince1970,
                expiresAt: nil
            )
            return ResolvedEntitlement(tier: .pro, activeLicense: simulated, isBetaAccessActive: false)

        case .automatic:
            if let verified = validStoredLicense {
                return ResolvedEntitlement(tier: verified.resolvedTier, activeLicense: verified, isBetaAccessActive: false)
            } else if accessPolicy.isBetaWindowActive(at: now) {
                return ResolvedEntitlement(tier: .pro, activeLicense: nil, isBetaAccessActive: true)
            } else {
                return ResolvedEntitlement(tier: .free, activeLicense: nil, isBetaAccessActive: false)
            }
        }
    }

    /// Re-evaluates license expiration, Beta sunset window, and QA overrides, purging expired keys and updating `@Published` properties.
    public func refreshEntitlement() {
        let now = clock()

        if let storedVerifiedLicense,
           storedVerifiedLicense.isExpired(at: now) || Self.revokedLicenseIDs.contains(storedVerifiedLicense.licenseId) {
            self.storedVerifiedLicense = nil
            try? storage.deleteLicenseToken()
        }

        let resolved = resolveEntitlement(at: now)
        if activeLicense != resolved.activeLicense {
            activeLicense = resolved.activeLicense
        }
        if isBetaAccessActive != resolved.isBetaAccessActive {
            isBetaAccessActive = resolved.isBetaAccessActive
        }
        if currentTier != resolved.tier {
            currentTier = resolved.tier
        }
    }

    /// Pure read evaluating whether the requested feature is unlocked at the current time without mutating state.
    public func isFeatureUnlocked(_ feature: BitzFeature) -> Bool {
        if feature.requiredTier == .free {
            return true
        }
        return resolveEntitlement(at: clock()).tier == .pro
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

        let payload = try Self.validate(token: trimmedKey, publicKeyData: publicKeyData, now: clock())

        // Persist token in secure storage
        try storage.saveLicenseToken(trimmedKey)

        self.storedVerifiedLicense = payload
        if entitlementOverride == .simulateFreeTier {
            entitlementOverride = .automatic
        }
        refreshEntitlement()
    }

    /// Asynchronous validation supporting both offline BITZ1 tokens and remote Supabase keys (e.g. BTZ-BETA-XXXX-XXXX).
    public func activateLicense(key: String) async throws {
        let trimmedRaw = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedRaw.isEmpty else {
            throw LicensingError.invalidFormat
        }

        // Preserve original base64url casing for signed BITZ1 tokens.
        if trimmedRaw.uppercased().hasPrefix("BITZ1.") {
            try activateOfflineLicense(key: trimmedRaw)
            return
        }

        let normalizedKey = trimmedRaw.uppercased()
        if Self.revokedLicenseIDs.contains(normalizedKey) {
            throw LicensingError.revokedLicense
        }

        guard let backend = backendClient else {
            throw LicensingError.storageFailed("Remote licensing backend is unavailable")
        }

        let deviceId = DeviceHardwareIdentifier.hashedDeviceID()
        let result = try await backend.validate(licenseKey: normalizedKey, deviceId: deviceId)

        guard result.valid else {
            let errorMsg = result.message ?? result.error ?? "Invalid or expired license key"
            throw LicensingError.storageFailed(errorMsg)
        }

        let now = clock()
        let resolvedLicenseId = result.licenseKey?.trimmingCharacters(in: .whitespacesAndNewlines).uppercased() ?? normalizedKey
        if Self.revokedLicenseIDs.contains(resolvedLicenseId) {
            throw LicensingError.revokedLicense
        }

        let expiresAtInterval = result.expiresAt?.timeIntervalSince1970
        let payload = LicensePayload(
            tier: result.tier ?? "pro",
            licenseId: resolvedLicenseId,
            issuedAt: now.timeIntervalSince1970,
            expiresAt: expiresAtInterval
        )

        if payload.isExpired(at: now) {
            throw LicensingError.licenseExpired
        }

        try storage.saveLicenseToken(Self.encodeRemoteStorageToken(payload))
        self.storedVerifiedLicense = payload
        if entitlementOverride == .simulateFreeTier {
            entitlementOverride = .automatic
        }
        refreshEntitlement()
        if let email = result.customerEmail {
            self.saveRegisteredEmail(email)
        }
    }

    /// Deactivates the active license, removes the token from Keychain, and releases remote seats when applicable.
    public func deactivateLicense() throws {
        let currentLicenseId = storedVerifiedLicense?.licenseId
        let backend = backendClient

        try storage.deleteLicenseToken()
        userDefaults.removeObject(forKey: Self.emailDefaultsKey)
        self.registeredEmail = nil
        self.storedVerifiedLicense = nil
        if entitlementOverride == .simulatePaidPro {
            entitlementOverride = .automatic
        }
        refreshEntitlement()

        // Release device seat in remote backend for stored BTZ- keys
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
        userDefaults.set(trimmed, forKey: Self.emailDefaultsKey)
        self.registeredEmail = trimmed

        // Non-blocking background sync to remote backend if a real stored license and client are present
        if let backend = backendClient, let license = storedVerifiedLicense {
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
        validationWakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.refreshEntitlement()
                try? await Task.sleep(nanoseconds: UInt64(wakeDebounce * 1_000_000_000))
                if let last = self.lastValidationTime, self.clock().timeIntervalSince(last) < minCheckInterval {
                    return
                }
                await self.validateActiveLicenseRemotely()
            }
        }

        // 2. Daily background check loop + periodic local expiration/sunset sweep
        validationTask = Task { [weak self] in
            // Initial 15s delay so app launch remains instantaneous
            try? await Task.sleep(nanoseconds: 15_000_000_000)
            guard let self, !Task.isCancelled else { return }
            await self.validateActiveLicenseRemotely()

            let localSweepInterval: TimeInterval = min(3_600, max(0.05, validationInterval))
            while !Task.isCancelled {
                var elapsed: TimeInterval = 0
                while elapsed < validationInterval, !Task.isCancelled {
                    let step = min(localSweepInterval, validationInterval - elapsed)
                    try? await Task.sleep(nanoseconds: UInt64(step * 1_000_000_000))
                    guard !Task.isCancelled else { return }
                    elapsed += step
                    self.refreshEntitlement()
                }
                guard !Task.isCancelled else { return }
                await self.validateActiveLicenseRemotely()
            }
        }
    }

    public func stopPeriodicValidationSchedule() {
        validationTask?.cancel()
        validationTask = nil
        if let validationWakeObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(validationWakeObserver)
            self.validationWakeObserver = nil
        }
    }

    /// Checks the active stored license with Supabase. Reverts to Free tier (or Beta fallback) if expired or revoked.
    public func validateActiveLicenseRemotely() async {
        refreshEntitlement()
        guard let license = storedVerifiedLicense else { return }

        let now = clock()
        if Self.revokedLicenseIDs.contains(license.licenseId) {
            try? deactivateLicense()
            return
        }

        // Offline BITZ1 token without a remote BTZ- license ID: check local expiration only
        let storedToken = storage.loadLicenseToken()?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if license.licenseId.hasPrefix("BITZ1.") || (storedToken.hasPrefix("BITZ1.") && !license.licenseId.hasPrefix("BTZ-")) {
            if license.isExpired(at: now) {
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
        lastValidationTime = now

        let deviceId = DeviceHardwareIdentifier.hashedDeviceID()
        do {
            let result = try await backend.validate(licenseKey: license.licenseId, deviceId: deviceId)
            if !result.valid {
                // Key was revoked or expired in Supabase!
                try? deactivateLicense()
            } else if let expiresAt = result.expiresAt, clock() > expiresAt {
                try? deactivateLicense()
            } else {
                let refreshedPayload = LicensePayload(
                    tier: result.tier ?? license.tier,
                    licenseId: license.licenseId,
                    issuedAt: license.issuedAt,
                    expiresAt: result.expiresAt?.timeIntervalSince1970
                )
                self.storedVerifiedLicense = refreshedPayload
                try? storage.saveLicenseToken(Self.encodeRemoteStorageToken(refreshedPayload))
                refreshEntitlement()
            }
        } catch {
            // Offline grace period: If network fails, do NOT immediately downgrade
            if license.isExpired(at: clock()) {
                try? deactivateLicense()
            }
        }
    }

    nonisolated private static func encodeRemoteStorageToken(_ payload: LicensePayload) -> String {
        guard let data = try? JSONEncoder().encode(payload) else {
            return payload.licenseId.uppercased()
        }
        return "\(payload.licenseId.uppercased())\n\(base64URLEncode(data))"
    }

    nonisolated private static func decodeRemoteStorageToken(_ rawToken: String, now: Date) -> (licenseId: String, payload: LicensePayload?) {
        let parts = rawToken.split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: true)
        let licenseId = String(parts.first ?? Substring(rawToken)).trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        if parts.count == 2 {
            guard let data = base64URLDecode(String(parts[1])),
                  let payload = try? JSONDecoder().decode(LicensePayload.self, from: data),
                  payload.licenseId.uppercased() == licenseId else {
                return (licenseId, nil)
            }
            return (licenseId, payload)
        }
        return (
            licenseId,
            LicensePayload(tier: "pro", licenseId: licenseId, issuedAt: now.timeIntervalSince1970)
        )
    }

    isolated deinit {
        validationTask?.cancel()
        if let entitlementWakeObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(entitlementWakeObserver)
        }
        if let validationWakeObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(validationWakeObserver)
        }
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
