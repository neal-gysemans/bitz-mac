import XCTest
import CryptoKit
@testable import BitzCore

// MARK: - Mock License Storage

private final class MockLicenseStorage: LicenseStorageProtocol, @unchecked Sendable {
    private var token: String?
    private let lock = NSLock()

    init(token: String? = nil) {
        self.token = token
    }

    func loadLicenseToken() -> String? {
        lock.lock()
        defer { lock.unlock() }
        return token
    }

    func saveLicenseToken(_ token: String) throws {
        lock.lock()
        defer { lock.unlock() }
        self.token = token
    }

    func deleteLicenseToken() throws {
        lock.lock()
        defer { lock.unlock() }
        self.token = nil
    }
}

// MARK: - Licensing Service Tests

final class LicensingServiceTests: XCTestCase {
    private var testPrivateKey: Curve25519.Signing.PrivateKey!
    private var testPublicKeyData: Data!

    override func setUp() {
        super.setUp()
        testPrivateKey = Curve25519.Signing.PrivateKey()
        testPublicKeyData = testPrivateKey.publicKey.rawRepresentation
    }

    // MARK: - Helper to Mint Test Tokens

    private func makeToken(
        tier: String = "pro",
        licenseId: String = "BTZ-TEST-9999",
        issuedAt: TimeInterval = Date().timeIntervalSince1970,
        expiresAt: TimeInterval? = nil,
        tamperSignature: Bool = false
    ) throws -> String {
        let payload = LicensePayload(
            tier: tier,
            licenseId: licenseId,
            issuedAt: issuedAt,
            expiresAt: expiresAt
        )

        let payloadData = try JSONEncoder().encode(payload)
        let payloadEncoded = LicensingService.base64URLEncode(payloadData)

        let signedData = Data("BITZ1.\(payloadEncoded)".utf8)
        var signature = try testPrivateKey.signature(for: signedData)

        if tamperSignature {
            // Flip the last byte of the signature
            var bytes = [UInt8](signature)
            bytes[bytes.count - 1] ^= 0xFF
            signature = Data(bytes)
        }

        let signatureEncoded = LicensingService.base64URLEncode(signature)
        return "BITZ1.\(payloadEncoded).\(signatureEncoded)"
    }

    // MARK: - Tests

    @MainActor
    func testInitialStateDefaultsToFree() {
        let storage = MockLicenseStorage()
        let service = LicensingService(storage: storage, publicKeyData: testPublicKeyData)

        XCTAssertEqual(service.currentTier, .free)
        XCTAssertNil(service.activeLicense)

        // Pro features are locked
        for feature in BitzFeature.allCases {
            XCTAssertFalse(service.isFeatureUnlocked(feature))
        }
    }

    @MainActor
    func testValidLicenseActivationUnlocksPro() throws {
        let storage = MockLicenseStorage()
        let service = LicensingService(storage: storage, publicKeyData: testPublicKeyData)

        let key = try makeToken(licenseId: "BTZ-PRO-2026-ALPHA")
        try service.activateLicense(key: key)

        XCTAssertEqual(service.currentTier, .pro)
        XCTAssertEqual(service.activeLicense?.licenseId, "BTZ-PRO-2026-ALPHA")
        XCTAssertEqual(service.activeLicense?.resolvedTier, .pro)

        // All Pro features unlocked
        for feature in BitzFeature.allCases {
            XCTAssertTrue(service.isFeatureUnlocked(feature))
        }

        // Stored in persistence
        XCTAssertEqual(storage.loadLicenseToken(), key)
    }

    @MainActor
    func testRestoresValidLicenseFromStorageOnInit() throws {
        let key = try makeToken(licenseId: "BTZ-PERSISTED-001")
        let storage = MockLicenseStorage(token: key)

        let service = LicensingService(storage: storage, publicKeyData: testPublicKeyData)

        XCTAssertEqual(service.currentTier, .pro)
        XCTAssertEqual(service.activeLicense?.licenseId, "BTZ-PERSISTED-001")
        XCTAssertTrue(service.isFeatureUnlocked(.multiMascot))
    }

    @MainActor
    func testCorruptSignatureThrowsAndLeavesFree() throws {
        let storage = MockLicenseStorage()
        let service = LicensingService(storage: storage, publicKeyData: testPublicKeyData)

        let corruptKey = try makeToken(tamperSignature: true)

        XCTAssertThrowsError(try service.activateLicense(key: corruptKey)) { error in
            XCTAssertEqual(error as? LicensingError, .invalidSignature)
        }

        XCTAssertEqual(service.currentTier, .free)
        XCTAssertNil(service.activeLicense)
        XCTAssertNil(storage.loadLicenseToken())
    }

    @MainActor
    func testMalformedTokenFormatThrows() {
        let storage = MockLicenseStorage()
        let service = LicensingService(storage: storage, publicKeyData: testPublicKeyData)

        let invalidTokens = [
            "",
            "   ",
            "BITZ1.only_two_parts",
            "WRONGHEADER.payload.signature",
            "BITZ1.invalid$base64.signature"
        ]

        for token in invalidTokens {
            XCTAssertThrowsError(try service.activateLicense(key: token)) { error in
                XCTAssertEqual(error as? LicensingError, .invalidFormat)
            }
        }

        XCTAssertEqual(service.currentTier, .free)
    }

    @MainActor
    func testExpiredLicenseThrowsAndLeavesFree() throws {
        let storage = MockLicenseStorage()
        let service = LicensingService(storage: storage, publicKeyData: testPublicKeyData)

        let expiredKey = try makeToken(
            expiresAt: Date().timeIntervalSince1970 - 3600 // Expired 1 hour ago
        )

        XCTAssertThrowsError(try service.activateLicense(key: expiredKey)) { error in
            XCTAssertEqual(error as? LicensingError, .licenseExpired)
        }

        XCTAssertEqual(service.currentTier, .free)
        XCTAssertNil(service.activeLicense)
    }

    @MainActor
    func testDeactivationRevertsToFreeAndClearsStorage() throws {
        let storage = MockLicenseStorage()
        let service = LicensingService(storage: storage, publicKeyData: testPublicKeyData)

        let key = try makeToken()
        try service.activateLicense(key: key)
        XCTAssertEqual(service.currentTier, .pro)

        try service.deactivateLicense()
        XCTAssertEqual(service.currentTier, .free)
        XCTAssertNil(service.activeLicense)
        XCTAssertNil(storage.loadLicenseToken())
        XCTAssertFalse(service.isFeatureUnlocked(.multiMascot))
    }

    @MainActor
    func testCorruptStoredTokenPurgedOnInit() {
        let storage = MockLicenseStorage(token: "CORRUPTED-TOKEN-RECEIPT")
        let service = LicensingService(storage: storage, publicKeyData: testPublicKeyData)

        XCTAssertEqual(service.currentTier, .free)
        XCTAssertNil(service.activeLicense)
        // Verify corrupted token was deleted from storage
        XCTAssertNil(storage.loadLicenseToken())
    }

    @MainActor
    func testProductionPublicKeyDecodesProperly() {
        XCTAssertFalse(LicensingService.defaultPublicKeyData.isEmpty)
        XCTAssertEqual(LicensingService.defaultPublicKeyData.count, 32)
        XCTAssertNoThrow(try Curve25519.Signing.PublicKey(rawRepresentation: LicensingService.defaultPublicKeyData))
    }

    // MARK: - Feature Gating Tests

    func testAvatarThemePresetProClassification() {
        XCTAssertFalse(AvatarThemePreset.cyberpunkClassic.isPro)
        XCTAssertFalse(AvatarThemePreset.colorblindSafe.isPro)
        XCTAssertTrue(AvatarThemePreset.tokyoNight.isPro)
        XCTAssertTrue(AvatarThemePreset.dracula.isPro)
        XCTAssertTrue(AvatarThemePreset.catppuccinMocha.isPro)
        XCTAssertTrue(AvatarThemePreset.nord.isPro)
        XCTAssertTrue(AvatarThemePreset.matrix.isPro)
        XCTAssertTrue(AvatarThemePreset.stealth.isPro)
        XCTAssertTrue(AvatarThemePreset.solarized.isPro)
    }

    @MainActor
    func testAvatarPaletteStoreGatingWithLicensingService() throws {
        let suite = "BitzTests.PaletteStoreGating.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }

        let storage = MockLicenseStorage()
        let service = LicensingService(storage: storage, publicKeyData: testPublicKeyData)

        // Free tier
        let freeStore = AvatarPaletteStore(userDefaults: defaults, licensingService: service)
        XCTAssertEqual(freeStore.selectedPreset, .cyberpunkClassic)

        // Attempt Pro theme selection on Free
        XCTAssertFalse(freeStore.selectPreset(.tokyoNight))
        XCTAssertEqual(freeStore.selectedPreset, .cyberpunkClassic)

        // Free theme selection allowed
        XCTAssertTrue(freeStore.selectPreset(.colorblindSafe))
        XCTAssertEqual(freeStore.selectedPreset, .colorblindSafe)

        // Custom hex overrides rejected on Free
        XCTAssertFalse(freeStore.setChassisHex("#112233"))
        XCTAssertNil(freeStore.chassisOverride)
        XCTAssertFalse(freeStore.setTrimHex("#445566"))
        XCTAssertNil(freeStore.trimOverride)
        XCTAssertFalse(freeStore.setEmotionHex("#AABBCC", for: .superCharged))

        // Activate Pro
        let token = try makeToken()
        try service.activateLicense(key: token)

        let proStore = AvatarPaletteStore(userDefaults: defaults, licensingService: service)
        // Pro theme selection allowed
        XCTAssertTrue(proStore.selectPreset(.tokyoNight))
        XCTAssertEqual(proStore.selectedPreset, .tokyoNight)

        // Custom hex overrides allowed
        XCTAssertTrue(proStore.setChassisHex("#112233"))
        XCTAssertEqual(proStore.chassisOverride, "#112233")
    }

    @MainActor
    func testAgentMonitorServiceMultiAgentGating() throws {
        let suite = "BitzTests.AgentMonitorGating.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }

        let storage = MockLicenseStorage()
        let service = LicensingService(storage: storage, publicKeyData: testPublicKeyData)

        let monitor = AgentMonitorService(userDefaults: defaults, licensingService: service)

        // Free tier: start Agent A
        monitor.handleEvent(AgentEvent(agentID: "claude", agentName: "Claude Code", kind: .working))
        XCTAssertEqual(monitor.activeAgents, ["claude"])

        // Agent B starts on Free tier: replaces Agent A, so count remains 1
        monitor.handleEvent(AgentEvent(agentID: "antigravity", agentName: "Antigravity", kind: .working))
        XCTAssertEqual(monitor.activeAgents, ["antigravity"])
        XCTAssertEqual(monitor.activeAgents.count, 1)

        // Activate Pro
        let token = try makeToken()
        try service.activateLicense(key: token)

        // Now start Agent A alongside Agent B: Swarm allows both simultaneously
        monitor.handleEvent(AgentEvent(agentID: "claude", agentName: "Claude Code", kind: .working))
        XCTAssertTrue(monitor.activeAgents.contains("claude"))
        XCTAssertTrue(monitor.activeAgents.contains("antigravity"))
        XCTAssertEqual(monitor.activeAgents.count, 2)
    }

    @MainActor
    func testPersonalitySettingsStoreGatingWithLicensingService() throws {
        let suite = "BitzTests.PersonalityGating.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }

        let storage = MockLicenseStorage()
        let service = LicensingService(storage: storage, publicKeyData: testPublicKeyData)

        let store = PersonalitySettingsStore(userDefaults: defaults, licensingService: service)
        XCTAssertFalse(store.isPersonalityUnlocked)
        XCTAssertFalse(store.isEnabled)

        // Attempt to enable on Free tier is blocked
        store.setEnabled(true)
        XCTAssertFalse(store.isEnabled)

        // Activate Pro
        let token = try makeToken()
        try service.activateLicense(key: token)
        XCTAssertTrue(store.isPersonalityUnlocked)

        // Enable on Pro tier succeeds
        store.setEnabled(true)
        XCTAssertTrue(store.isEnabled)

        // Deactivate Pro: validateTierEntitlement reverts to disabled
        try service.deactivateLicense()
        store.validateTierEntitlement()
        XCTAssertFalse(store.isEnabled)
    }

    @MainActor
    func testMeetingRecorderServiceGatingWithLicensingService() async throws {
        let suite = "BitzTests.MeetingRecorderGating.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }

        let storage = MockLicenseStorage()
        let service = LicensingService(storage: storage, publicKeyData: testPublicKeyData)

        let settings = MeetingSettingsStore(userDefaults: defaults)
        let recorder = MeetingRecorderService(
            settingsStore: settings,
            licensingService: service
        )
        XCTAssertFalse(recorder.isMeetingRecorderUnlocked)

        await recorder.startRecording()
        XCTAssertFalse(recorder.isRecording)
        XCTAssertEqual(recorder.state, .failed)
        XCTAssertEqual(recorder.bubble?.text, MeetingBubble.proRequiredText)

        var openedPro = false
        recorder.onOpenProSettings = { openedPro = true }
        recorder.perform(.openSettings)
        XCTAssertTrue(openedPro)
    }

    // MARK: - Periodic Background Validation Tests

    @MainActor
    func testPeriodicValidationScheduleStartAndStop() {
        let storage = MockLicenseStorage()
        let service = LicensingService(storage: storage, publicKeyData: testPublicKeyData)

        service.startPeriodicValidationSchedule(validationInterval: 0.1, wakeDebounce: 0.05, minCheckInterval: 0.01)
        // Calling start again should safely replace any existing timers/observers
        service.startPeriodicValidationSchedule(validationInterval: 0.1, wakeDebounce: 0.05, minCheckInterval: 0.01)
        service.stopPeriodicValidationSchedule()
    }

    @MainActor
    func testValidateActiveLicenseRemotelyRevokedKeyRevertsToFree() async throws {
        let storage = MockLicenseStorage()
        let mockBackend = MockLicensingTestBackend(validateHandler: { _, _ in
            RemoteLicenseResult(valid: false, error: "revoked")
        })
        let service = LicensingService(
            storage: storage,
            publicKeyData: testPublicKeyData,
            backendClient: mockBackend
        )

        // Seed a BTZ- key in storage
        let token = try makeToken(licenseId: "BTZ-BETA-ABCD-1234")
        try service.activateOfflineLicense(key: token)
        XCTAssertEqual(service.currentTier, .pro)

        // Run remote validation - backend reports invalid!
        await service.validateActiveLicenseRemotely()

        XCTAssertEqual(service.currentTier, .free)
        XCTAssertNil(service.activeLicense)
    }

    @MainActor
    func testValidateActiveLicenseRemotelyValidPreservesPro() async throws {
        let storage = MockLicenseStorage()
        let mockBackend = MockLicensingTestBackend(validateHandler: { _, _ in
            RemoteLicenseResult(valid: true, tier: "pro")
        })
        let service = LicensingService(
            storage: storage,
            publicKeyData: testPublicKeyData,
            backendClient: mockBackend
        )

        let token = try makeToken(licenseId: "BTZ-BETA-ABCD-5678")
        try service.activateOfflineLicense(key: token)
        XCTAssertEqual(service.currentTier, .pro)

        await service.validateActiveLicenseRemotely()

        XCTAssertEqual(service.currentTier, .pro)
        XCTAssertNotNil(service.activeLicense)
    }

    @MainActor
    func testValidateActiveLicenseRemotelyNetworkFailureGracePeriod() async throws {
        let storage = MockLicenseStorage()
        let mockBackend = MockLicensingTestBackend(validateHandler: { _, _ in
            throw URLError(.notConnectedToInternet)
        })
        let service = LicensingService(
            storage: storage,
            publicKeyData: testPublicKeyData,
            backendClient: mockBackend
        )

        // Valid unexpired license
        let token = try makeToken(licenseId: "BTZ-BETA-ABCD-9999", expiresAt: Date().addingTimeInterval(86400).timeIntervalSince1970)
        try service.activateOfflineLicense(key: token)
        XCTAssertEqual(service.currentTier, .pro)

        // Remote validation fails with network error, but within grace period -> still Pro
        await service.validateActiveLicenseRemotely()

        XCTAssertEqual(service.currentTier, .pro)
    }

    @MainActor
    func testStartupWithUnknownTokenPurgesAndRevertsToFree() {
        let storage = MockLicenseStorage(token: "invalid_unauthenticated_random_token")
        let service = LicensingService(
            storage: storage,
            publicKeyData: testPublicKeyData
        )

        XCTAssertEqual(service.currentTier, .free)
        XCTAssertNil(service.activeLicense)
        XCTAssertNil(storage.loadLicenseToken())
    }

    @MainActor
    func testDeactivateLicenseReleasesRemoteDeviceSeat() async throws {
        let storage = MockLicenseStorage()
        final class DeactivationCapture: @unchecked Sendable {
            private let lock = NSLock()
            private var _key: String?
            private var _device: String?
            func record(key: String, device: String) {
                lock.lock()
                _key = key
                _device = device
                lock.unlock()
            }
            var key: String? { lock.lock(); defer { lock.unlock() }; return _key }
            var device: String? { lock.lock(); defer { lock.unlock() }; return _device }
        }
        let capture = DeactivationCapture()
        let mockBackend = MockLicensingTestBackend(deactivateHandler: { key, device in
            capture.record(key: key, device: device)
            return RemoteDeactivateResult(success: true, deactivated: true)
        })

        let service = LicensingService(
            storage: storage,
            publicKeyData: testPublicKeyData,
            backendClient: mockBackend
        )

        let token = try makeToken(licenseId: "BTZ-BETA-RELEASE-TEST")
        try service.activateOfflineLicense(key: token)
        XCTAssertEqual(service.currentTier, .pro)

        try service.deactivateLicense()
        XCTAssertEqual(service.currentTier, .free)
        XCTAssertNil(service.activeLicense)

        // Yield to allow non-blocking async deactivation task to run
        try? await Task.sleep(nanoseconds: 50_000_000)

        XCTAssertEqual(capture.key, "BTZ-BETA-RELEASE-TEST")
        XCTAssertNotNil(capture.device)
    }

    @MainActor
    func testValidateActiveLicenseRemotelyPurgesNonPrefixToken() async {
        let storage = MockLicenseStorage()
        let service = LicensingService(
            storage: storage,
            publicKeyData: testPublicKeyData
        )

        // Force an unexpected payload in memory
        service.saveRegisteredEmail("test@bitz.app")
        await service.validateActiveLicenseRemotely()
        // With currentTier .free, nothing happens
        XCTAssertEqual(service.currentTier, .free)
    }
}

// MARK: - Test Mock Backend Client

private struct MockLicensingTestBackend: LicensingBackendClient {
    var activateHandler: (@Sendable (String, String, String?) async throws -> RemoteLicenseResult)?
    var validateHandler: (@Sendable (String, String) async throws -> RemoteLicenseResult)?
    var registerEmailHandler: (@Sendable (String, String) async throws -> RemoteEmailResult)?
    var deactivateHandler: (@Sendable (String, String) async throws -> RemoteDeactivateResult)?

    func activateBeta(deviceId: String, deviceName: String, customerEmail: String?) async throws -> RemoteLicenseResult {
        try await activateHandler?(deviceId, deviceName, customerEmail) ?? RemoteLicenseResult(valid: true)
    }

    func validate(licenseKey: String, deviceId: String) async throws -> RemoteLicenseResult {
        try await validateHandler?(licenseKey, deviceId) ?? RemoteLicenseResult(valid: true)
    }

    func registerEmail(licenseKey: String, customerEmail: String) async throws -> RemoteEmailResult {
        try await registerEmailHandler?(licenseKey, customerEmail) ?? RemoteEmailResult(success: true)
    }

    func deactivate(licenseKey: String, deviceId: String) async throws -> RemoteDeactivateResult {
        try await deactivateHandler?(licenseKey, deviceId) ?? RemoteDeactivateResult(success: true, deactivated: true)
    }
}
