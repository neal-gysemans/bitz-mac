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
    func testInitialStateDefaultsToFreeUnderProductionPolicy() {
        let storage = MockLicenseStorage()
        let service = LicensingService(storage: storage, publicKeyData: testPublicKeyData, accessPolicy: .production)

        XCTAssertEqual(service.currentTier, .free)
        XCTAssertNil(service.activeLicense)
        XCTAssertFalse(service.isBetaAccessActive)

        // Pro features are locked
        for feature in BitzFeature.allCases {
            XCTAssertFalse(service.isFeatureUnlocked(feature))
        }
    }

    @MainActor
    func testDefaultBetaAccessPolicyUnlocksProBeforeSunsetDate() {
        let storage = MockLicenseStorage()
        let midBetaDate = Date(timeIntervalSince1970: 1_795_000_000) // Inside 2026-11-10 ..< 2027-01-09
        let service = LicensingService(
            storage: storage,
            publicKeyData: testPublicKeyData,
            clock: { midBetaDate }
        )

        XCTAssertEqual(service.currentTier, .pro)
        XCTAssertTrue(service.isBetaAccessActive)
        XCTAssertNil(service.activeLicense)

        for feature in BitzFeature.allCases {
            XCTAssertTrue(service.isFeatureUnlocked(feature))
        }
    }

    @MainActor
    func testBetaAccessPolicySunsetAndClockRollbackGuardrail() {
        let storage = MockLicenseStorage()
        var currentTime = Date(timeIntervalSince1970: 1_795_000_000)

        let service = LicensingService(
            storage: storage,
            publicKeyData: testPublicKeyData,
            accessPolicy: .current,
            clock: { currentTime }
        )
        XCTAssertEqual(service.currentTier, .pro)
        XCTAssertTrue(service.isBetaAccessActive)

        // 1. Advance clock past Beta sunset deadline (2027-01-09T00:00:00Z)
        currentTime = BetaAccessPolicy.defaultSunsetDate.addingTimeInterval(1)
        // isFeatureUnlocked closes the gate immediately as a pure read without mutating @Published state
        XCTAssertFalse(service.isFeatureUnlocked(.multiMascot))
        XCTAssertEqual(service.currentTier, .pro)
        XCTAssertTrue(service.isBetaAccessActive)

        // refreshEntitlement publishes the downgrade off the view-rendering path
        service.refreshEntitlement()
        XCTAssertEqual(service.currentTier, .free)
        XCTAssertFalse(service.isBetaAccessActive)

        // 2. Roll clock back before build timestamp floor (2026-11-10T00:00:00Z)
        currentTime = BetaAccessPolicy.defaultBuildDate.addingTimeInterval(-60)
        service.refreshEntitlement()
        XCTAssertEqual(service.currentTier, .free)
        XCTAssertFalse(service.isBetaAccessActive)
        XCTAssertFalse(service.isFeatureUnlocked(.customThemes))
    }

    @MainActor
    func testRevokedLocalDevTokenRejectedAndPurged() throws {
        // 1. Token signed with test key using revoked ID "BTZ-LOCAL-DEV-PRO"
        let revokedTestToken = try makeToken(licenseId: "BTZ-LOCAL-DEV-PRO")
        let storage = MockLicenseStorage(token: revokedTestToken)
        let service = LicensingService(storage: storage, publicKeyData: testPublicKeyData, accessPolicy: .production)

        XCTAssertEqual(service.currentTier, .free)
        XCTAssertNil(service.activeLicense)
        XCTAssertNil(storage.loadLicenseToken(), "Revoked dev token must be purged from storage on init")

        XCTAssertThrowsError(try service.activateLicense(key: revokedTestToken)) { error in
            XCTAssertEqual(error as? LicensingError, .revokedLicense)
        }

        // 2. Historical leaked production token from package_and_run.sh rejected against defaultPublicKeyData
        let historicalLeakedToken = "BITZ1.eyJsaWNlbnNlX2lkIjoiQlRaLUxPQ0FMLURFVi1QUk8iLCJ0aWVyIjoicHJvIiwiaXNzdWVkX2F0IjoxNzc1NjAwMDAwLCJwdXJjaGFzZXJfZW1haWwiOiJsb2NhbC1kZXZAYml0ei5hcHAifQ.7O-bo3C8CbTRuI3ZL2iFQ6biivRBy2POB2PZunmOjgQ2zJRu0Abb3dgOlHNkm3APF-g4pbH1xSEjtOaJsHa7DQ"
        XCTAssertThrowsError(
            try LicensingService.validate(
                token: historicalLeakedToken,
                publicKeyData: LicensingService.defaultPublicKeyData
            )
        ) { error in
            XCTAssertEqual(error as? LicensingError, .revokedLicense)
        }
    }

    @MainActor
    func testRuntimeLicenseExpirationTransitionsToFree() throws {
        let storage = MockLicenseStorage()
        var currentTime = Date(timeIntervalSince1970: 1_795_000_000)
        let service = LicensingService(
            storage: storage,
            publicKeyData: testPublicKeyData,
            accessPolicy: .production,
            clock: { currentTime }
        )

        let shortLivedKey = try makeToken(
            issuedAt: currentTime.timeIntervalSince1970,
            expiresAt: currentTime.addingTimeInterval(60).timeIntervalSince1970
        )
        try service.activateLicense(key: shortLivedKey)
        XCTAssertEqual(service.currentTier, .pro)
        XCTAssertTrue(service.isFeatureUnlocked(.multiMascot))

        // Advance time past expiration while session is running:
        // isFeatureUnlocked denies access immediately as a pure read without mutating Keychain or @Published state.
        currentTime = currentTime.addingTimeInterval(120)
        XCTAssertFalse(service.isFeatureUnlocked(.multiMascot))
        XCTAssertEqual(service.currentTier, .pro)
        XCTAssertNotNil(service.activeLicense)
        XCTAssertEqual(storage.loadLicenseToken(), shortLivedKey)

        // Wake / periodic refresh publishes the expiration and purges the stale token.
        service.refreshEntitlement()
        XCTAssertEqual(service.currentTier, .free)
        XCTAssertNil(service.activeLicense)
        XCTAssertNil(storage.loadLicenseToken())
    }

    @MainActor
    func testEntitlementOverrideLiveSwitching() {
        let storage = MockLicenseStorage()
        let midBetaDate = Date(timeIntervalSince1970: 1_795_000_000)
        let service = LicensingService(
            storage: storage,
            publicKeyData: testPublicKeyData,
            accessPolicy: .current,
            clock: { midBetaDate }
        )

        XCTAssertEqual(service.entitlementOverride, .automatic)
        XCTAssertEqual(service.currentTier, .pro)
        XCTAssertTrue(service.isBetaAccessActive)

        // Simulate GA Free Tier (Gate Closed)
        service.setEntitlementOverride(.simulateFreeTier)
        XCTAssertEqual(service.currentTier, .free)
        XCTAssertFalse(service.isBetaAccessActive)
        XCTAssertFalse(service.isFeatureUnlocked(.multiMascot))

        // Simulate Paid Pro License
        service.setEntitlementOverride(.simulatePaidPro)
        XCTAssertEqual(service.currentTier, .pro)
        XCTAssertFalse(service.isBetaAccessActive)
        XCTAssertEqual(service.activeLicense?.licenseId, "BTZ-QA-SIMULATED-PRO")
        XCTAssertTrue(service.isFeatureUnlocked(.multiMascot))

        // Reset back to Default (Beta All-Access)
        service.setEntitlementOverride(.automatic)
        XCTAssertEqual(service.currentTier, .pro)
        XCTAssertTrue(service.isBetaAccessActive)
        XCTAssertNil(service.activeLicense)
    }

    func testFeatureComingSoonClassification() {
        XCTAssertFalse(BitzFeature.multiMascot.isComingSoon)
        XCTAssertFalse(BitzFeature.customThemes.isComingSoon)
        XCTAssertFalse(BitzFeature.multiAgentSwarm.isComingSoon)
        XCTAssertFalse(BitzFeature.meetingRecorder.isComingSoon)
        XCTAssertFalse(BitzFeature.personality.isComingSoon)
        XCTAssertTrue(BitzFeature.deepTelemetry.isComingSoon)
        XCTAssertTrue(BitzFeature.soundPacks.isComingSoon)
    }

    @MainActor
    func testValidLicenseActivationUnlocksPro() throws {
        let storage = MockLicenseStorage()
        let service = LicensingService(storage: storage, publicKeyData: testPublicKeyData, accessPolicy: .production)

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

        let service = LicensingService(storage: storage, publicKeyData: testPublicKeyData, accessPolicy: .production)

        XCTAssertEqual(service.currentTier, .pro)
        XCTAssertEqual(service.activeLicense?.licenseId, "BTZ-PERSISTED-001")
        XCTAssertTrue(service.isFeatureUnlocked(.multiMascot))
    }

    @MainActor
    func testCorruptSignatureThrowsAndLeavesFree() throws {
        let storage = MockLicenseStorage()
        let service = LicensingService(storage: storage, publicKeyData: testPublicKeyData, accessPolicy: .production)

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
        let service = LicensingService(storage: storage, publicKeyData: testPublicKeyData, accessPolicy: .production)

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
        let service = LicensingService(storage: storage, publicKeyData: testPublicKeyData, accessPolicy: .production)

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
        let service = LicensingService(storage: storage, publicKeyData: testPublicKeyData, accessPolicy: .production)

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
        let service = LicensingService(storage: storage, publicKeyData: testPublicKeyData, accessPolicy: .production)

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
        let service = LicensingService(storage: storage, publicKeyData: testPublicKeyData, accessPolicy: .production)

        // Free tier
        let freeStore = AvatarPaletteStore(userDefaults: defaults, licensingService: service)
        XCTAssertEqual(freeStore.selectedPreset, .cyberpunkClassic)

        // Attempt Pro theme selection on Free
        XCTAssertFalse(freeStore.selectPreset(.tokyoNight))
        XCTAssertEqual(freeStore.selectedPreset, .cyberpunkClassic)

        // Free theme selection allowed
        XCTAssertTrue(freeStore.selectPreset(.colorblindSafe))
        XCTAssertEqual(freeStore.selectedPreset, .colorblindSafe)

        // Custom hex overrides and custom glow intensity rejected on Free
        XCTAssertFalse(freeStore.setChassisHex("#112233"))
        XCTAssertNil(freeStore.chassisOverride)
        XCTAssertFalse(freeStore.setTrimHex("#445566"))
        XCTAssertNil(freeStore.trimOverride)
        XCTAssertFalse(freeStore.setEmotionHex("#AABBCC", for: .superCharged))
        XCTAssertFalse(freeStore.setGlowIntensity(1.4))
        XCTAssertEqual(freeStore.glowIntensity, 1.0, accuracy: 0.001)

        // Activate Pro
        let token = try makeToken()
        try service.activateLicense(key: token)

        let proStore = AvatarPaletteStore(userDefaults: defaults, licensingService: service)
        // Pro theme selection allowed
        XCTAssertTrue(proStore.selectPreset(.tokyoNight))
        XCTAssertEqual(proStore.selectedPreset, .tokyoNight)

        // Custom hex overrides and custom glow intensity allowed
        XCTAssertTrue(proStore.setChassisHex("#112233"))
        XCTAssertEqual(proStore.chassisOverride, "#112233")
        XCTAssertTrue(proStore.setGlowIntensity(1.4))
        XCTAssertEqual(proStore.glowIntensity, 1.4, accuracy: 0.001)

        // Downgrade back to Free resets preset, overrides, and glow intensity
        try service.deactivateLicense()
        proStore.validateTierEntitlement()
        XCTAssertEqual(proStore.selectedPreset, .cyberpunkClassic)
        XCTAssertNil(proStore.chassisOverride)
        XCTAssertEqual(proStore.glowIntensity, 1.0, accuracy: 0.001)
    }

    @MainActor
    func testAgentMonitorServiceMultiAgentGating() throws {
        let suite = "BitzTests.AgentMonitorGating.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }

        let storage = MockLicenseStorage()
        let service = LicensingService(storage: storage, publicKeyData: testPublicKeyData, accessPolicy: .production)

        let monitor = AgentMonitorService(userDefaults: defaults, licensingService: service)
        XCTAssertEqual(monitor.catalog.filter(\.isEnabled).map(\.id), ["claude"])

        // Free tier: start Agent A ("claude")
        monitor.handleEvent(AgentEvent(agentID: "claude", agentName: "Claude Code", kind: .working))
        XCTAssertEqual(monitor.activeAgents, ["claude"])

        // Agent B ("antigravity") event is ignored on Free tier while Agent A is active
        monitor.handleEvent(AgentEvent(agentID: "antigravity", agentName: "Antigravity", kind: .working))
        XCTAssertEqual(monitor.activeAgents, ["claude"])
        XCTAssertEqual(monitor.activeAgents.count, 1)

        // Switching enabled agent on Free tier to "antigravity" disables "claude" and clears its active state
        monitor.setAgentEnabled(id: "antigravity", isEnabled: true)
        XCTAssertEqual(monitor.catalog.filter(\.isEnabled).map(\.id), ["antigravity"])
        XCTAssertTrue(monitor.activeAgents.isEmpty)

        monitor.handleEvent(AgentEvent(agentID: "antigravity", agentName: "Antigravity", kind: .working))
        XCTAssertEqual(monitor.activeAgents, ["antigravity"])

        // Activate Pro and validate entitlement: all built-in agents enabled, Swarm allows concurrent agents
        let token = try makeToken()
        try service.activateLicense(key: token)
        monitor.validateTierEntitlement()
        XCTAssertGreaterThan(monitor.catalog.filter(\.isEnabled).count, 1)

        monitor.handleEvent(AgentEvent(agentID: "claude", agentName: "Claude Code", kind: .working))
        XCTAssertTrue(monitor.activeAgents.contains("claude"))
        XCTAssertTrue(monitor.activeAgents.contains("antigravity"))
        XCTAssertEqual(monitor.activeAgents.count, 2)

        // Deactivate Pro and validate entitlement: clamps enabled catalog to 1 and prunes secondary active agents
        try service.deactivateLicense()
        monitor.validateTierEntitlement()
        XCTAssertEqual(monitor.catalog.filter(\.isEnabled).count, 1)
        XCTAssertEqual(monitor.activeAgents.count, 1)
    }

    @MainActor
    func testPersonalitySettingsStoreGatingWithLicensingService() throws {
        let suite = "BitzTests.PersonalityGating.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }

        let storage = MockLicenseStorage()
        let service = LicensingService(storage: storage, publicKeyData: testPublicKeyData, accessPolicy: .production)

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
        let service = LicensingService(storage: storage, publicKeyData: testPublicKeyData, accessPolicy: .production)

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

    private func makeIsolatedDefaults(_ prefix: String) -> (UserDefaults, String) {
        let suite = "BitzTests.\(prefix).\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        return (defaults, suite)
    }

    @MainActor
    func testPeriodicValidationScheduleStartAndStop() {
        let (defaults, suite) = makeIsolatedDefaults("PeriodicSchedule")
        defer { defaults.removePersistentDomain(forName: suite) }

        let storage = MockLicenseStorage()
        let service = LicensingService(
            storage: storage,
            publicKeyData: testPublicKeyData,
            accessPolicy: .production,
            userDefaults: defaults
        )

        service.startPeriodicValidationSchedule(validationInterval: 0.1, wakeDebounce: 0.05, minCheckInterval: 0.01)
        // Calling start again should safely replace any existing timers/observers
        service.startPeriodicValidationSchedule(validationInterval: 0.1, wakeDebounce: 0.05, minCheckInterval: 0.01)
        service.stopPeriodicValidationSchedule()
    }

    @MainActor
    func testValidateActiveLicenseRemotelyRevokedKeyRevertsToFree() async throws {
        let (defaults, suite) = makeIsolatedDefaults("RemoteRevoke")
        defer { defaults.removePersistentDomain(forName: suite) }

        let storage = MockLicenseStorage()
        let mockBackend = MockLicensingTestBackend(validateHandler: { _, _ in
            RemoteLicenseResult(valid: false, error: "revoked")
        })
        let service = LicensingService(
            storage: storage,
            publicKeyData: testPublicKeyData,
            backendClient: mockBackend,
            accessPolicy: .production,
            userDefaults: defaults
        )

        // Seed a BTZ- key in storage
        let token = try makeToken(licenseId: "BTZ-BETA-ABCD-1234")
        try service.activateOfflineLicense(key: token)
        XCTAssertEqual(service.currentTier, .pro)

        // Run remote validation - backend reports invalid!
        await service.validateActiveLicenseRemotely()

        XCTAssertEqual(service.currentTier, .free)
        XCTAssertNil(service.activeLicense)
        XCTAssertFalse(service.isBetaAccessActive)
    }

    @MainActor
    func testValidateActiveLicenseRemotelyValidPreservesPro() async throws {
        let (defaults, suite) = makeIsolatedDefaults("RemoteValid")
        defer { defaults.removePersistentDomain(forName: suite) }

        let storage = MockLicenseStorage()
        let mockBackend = MockLicensingTestBackend(validateHandler: { _, _ in
            RemoteLicenseResult(valid: true, tier: "pro")
        })
        let service = LicensingService(
            storage: storage,
            publicKeyData: testPublicKeyData,
            backendClient: mockBackend,
            accessPolicy: .production,
            userDefaults: defaults
        )

        let token = try makeToken(licenseId: "BTZ-BETA-ABCD-5678")
        try service.activateOfflineLicense(key: token)
        XCTAssertEqual(service.currentTier, .pro)

        await service.validateActiveLicenseRemotely()

        XCTAssertEqual(service.currentTier, .pro)
        XCTAssertNotNil(service.activeLicense)
        XCTAssertFalse(service.isBetaAccessActive)
    }

    @MainActor
    func testValidateActiveLicenseRemotelyNetworkFailureGracePeriod() async throws {
        let (defaults, suite) = makeIsolatedDefaults("RemoteGrace")
        defer { defaults.removePersistentDomain(forName: suite) }

        let storage = MockLicenseStorage()
        let mockBackend = MockLicensingTestBackend(validateHandler: { _, _ in
            throw URLError(.notConnectedToInternet)
        })
        let service = LicensingService(
            storage: storage,
            publicKeyData: testPublicKeyData,
            backendClient: mockBackend,
            accessPolicy: .production,
            userDefaults: defaults
        )

        // Valid unexpired license
        let token = try makeToken(licenseId: "BTZ-BETA-ABCD-9999", expiresAt: Date().addingTimeInterval(86400).timeIntervalSince1970)
        try service.activateOfflineLicense(key: token)
        XCTAssertEqual(service.currentTier, .pro)

        // Remote validation fails with network error, but within grace period -> still Pro
        await service.validateActiveLicenseRemotely()

        XCTAssertEqual(service.currentTier, .pro)
        XCTAssertNotNil(service.activeLicense)
    }

    @MainActor
    func testStartupWithUnknownTokenPurgesAndRevertsToFree() {
        let (defaults, suite) = makeIsolatedDefaults("UnknownStartup")
        defer { defaults.removePersistentDomain(forName: suite) }

        let storage = MockLicenseStorage(token: "invalid_unauthenticated_random_token")
        let service = LicensingService(
            storage: storage,
            publicKeyData: testPublicKeyData,
            accessPolicy: .production,
            userDefaults: defaults
        )

        XCTAssertEqual(service.currentTier, .free)
        XCTAssertNil(service.activeLicense)
        XCTAssertNil(storage.loadLicenseToken())
    }

    @MainActor
    func testDeactivateLicenseReleasesRemoteDeviceSeat() async throws {
        let (defaults, suite) = makeIsolatedDefaults("RemoteDeactivate")
        defer { defaults.removePersistentDomain(forName: suite) }

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
            backendClient: mockBackend,
            accessPolicy: .production,
            userDefaults: defaults
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
        let (defaults, suite) = makeIsolatedDefaults("PurgeNonPrefix")
        defer { defaults.removePersistentDomain(forName: suite) }

        let storage = MockLicenseStorage()
        let service = LicensingService(
            storage: storage,
            publicKeyData: testPublicKeyData,
            accessPolicy: .production,
            userDefaults: defaults
        )

        // Force an unexpected payload in memory
        service.saveRegisteredEmail("test@bitz.app")
        await service.validateActiveLicenseRemotely()
        // With currentTier .free, nothing happens
        XCTAssertEqual(service.currentTier, .free)
    }

    @MainActor
    func testAsyncActivateLicensePreservesOfflineTokenCaseAndRejectsRevokedRemoteKey() async throws {
        let (defaults, suite) = makeIsolatedDefaults("AsyncActivateMixed")
        defer { defaults.removePersistentDomain(forName: suite) }

        final class BackendCallCounter: @unchecked Sendable {
            private let lock = NSLock()
            private var _calls = 0
            func increment() { lock.lock(); _calls += 1; lock.unlock() }
            var calls: Int { lock.lock(); defer { lock.unlock() }; return _calls }
        }
        let counter = BackendCallCounter()
        let mockBackend = MockLicensingTestBackend(validateHandler: { _, _ in
            counter.increment()
            return RemoteLicenseResult(valid: true, tier: "pro")
        })

        let storage = MockLicenseStorage()
        let service = LicensingService(
            storage: storage,
            publicKeyData: testPublicKeyData,
            backendClient: mockBackend,
            accessPolicy: .production,
            userDefaults: defaults
        )

        // Mixed-case base64url offline BITZ1 token must NOT be uppercased before cryptographic verification.
        let offlineToken = try makeToken(licenseId: "offline-mixed-case")
        try await service.activateLicense(key: "  \(offlineToken)  ")
        XCTAssertEqual(service.currentTier, .pro)
        XCTAssertEqual(service.activeLicense?.licenseId, "offline-mixed-case")
        XCTAssertEqual(counter.calls, 0)

        // Revoked BTZ-LOCAL-DEV-PRO must be rejected locally regardless of case without hitting backend.
        do {
            try await service.activateLicense(key: "btz-local-dev-pro")
            XCTFail("Expected LicensingError.revokedLicense")
        } catch let error as LicensingError {
            XCTAssertEqual(error, .revokedLicense)
        }
        XCTAssertEqual(counter.calls, 0)
    }

    @MainActor
    func testRemoteRevocationDuringBetaWindowRevertsToBetaFallback() async throws {
        let (defaults, suite) = makeIsolatedDefaults("BetaRevokeFallback")
        defer { defaults.removePersistentDomain(forName: suite) }

        let now = Date(timeIntervalSince1970: 1_795_000_000) // Inside 2026-11-10 ..< 2027-01-09
        let betaPolicy = BetaAccessPolicy.betaAllAccess(
            buildDate: Date(timeIntervalSince1970: 1_794_268_800),
            sunsetDate: Date(timeIntervalSince1970: 1_799_452_800)
        )
        let mockBackend = MockLicensingTestBackend(validateHandler: { _, _ in
            RemoteLicenseResult(valid: false, error: "revoked")
        })
        let storage = MockLicenseStorage(token: "BTZ-BETA-REVOKED-1")
        let service = LicensingService(
            storage: storage,
            publicKeyData: testPublicKeyData,
            backendClient: mockBackend,
            accessPolicy: betaPolicy,
            clock: { now },
            userDefaults: defaults
        )

        XCTAssertEqual(service.currentTier, .pro)
        XCTAssertFalse(service.isBetaAccessActive)
        XCTAssertEqual(service.activeLicense?.licenseId, "BTZ-BETA-REVOKED-1")

        await service.validateActiveLicenseRemotely()

        XCTAssertNil(storage.loadLicenseToken())
        XCTAssertNil(service.activeLicense)
        XCTAssertEqual(service.currentTier, .pro)
        XCTAssertTrue(service.isBetaAccessActive)
    }

    @MainActor
    func testSimulatePaidProOverrideDoesNotCallRemoteDeactivateOrEmailSync() async throws {
        let (defaults, suite) = makeIsolatedDefaults("SimulatedProNoRPC")
        defer { defaults.removePersistentDomain(forName: suite) }

        final class RPCCapture: @unchecked Sendable {
            private let lock = NSLock()
            private var _deactivated = false
            private var _emailRegistered = false
            func markDeactivated() { lock.lock(); _deactivated = true; lock.unlock() }
            func markEmailRegistered() { lock.lock(); _emailRegistered = true; lock.unlock() }
            var deactivated: Bool { lock.lock(); defer { lock.unlock() }; return _deactivated }
            var emailRegistered: Bool { lock.lock(); defer { lock.unlock() }; return _emailRegistered }
        }
        let capture = RPCCapture()
        let mockBackend = MockLicensingTestBackend(
            registerEmailHandler: { _, _ in
                capture.markEmailRegistered()
                return RemoteEmailResult(success: true)
            },
            deactivateHandler: { _, _ in
                capture.markDeactivated()
                return RemoteDeactivateResult(success: true, deactivated: true)
            }
        )
        let storage = MockLicenseStorage()
        let service = LicensingService(
            storage: storage,
            publicKeyData: testPublicKeyData,
            backendClient: mockBackend,
            accessPolicy: .production,
            userDefaults: defaults,
            allowEntitlementOverride: true
        )

        service.setEntitlementOverride(.simulatePaidPro)
        XCTAssertEqual(service.activeLicense?.licenseId, "BTZ-QA-SIMULATED-PRO")

        service.saveRegisteredEmail("qa@bitz.app")
        await service.validateActiveLicenseRemotely()
        try service.deactivateLicense()
        try? await Task.sleep(nanoseconds: 50_000_000)

        XCTAssertFalse(capture.emailRegistered)
        XCTAssertFalse(capture.deactivated)
        XCTAssertEqual(service.currentTier, .free)
        XCTAssertEqual(service.entitlementOverride, .automatic)
    }

    @MainActor
    func testAgentMonitorServiceFreeTierClampsSameAgentConcurrentSessionsAndDowngrade() throws {
        let (defaults, suite) = makeIsolatedDefaults("AgentMonitorFreeClamp")
        defer { defaults.removePersistentDomain(forName: suite) }

        let now = Date()
        let storage = MockLicenseStorage()
        let service = LicensingService(
            storage: storage,
            publicKeyData: testPublicKeyData,
            accessPolicy: .production,
            clock: { now },
            userDefaults: defaults
        )

        let monitor = AgentMonitorService(
            clock: { now },
            userDefaults: defaults,
            licensingService: service
        )
        XCTAssertEqual(monitor.catalog.filter(\.isEnabled).map(\.id), ["claude"])

        // On Free tier, concurrent sessions within the same agent stay clamped to 1 active session.
        monitor.handleEvent(AgentEvent(
            agentID: "claude",
            agentName: "Claude Code",
            kind: .working,
            timestamp: now,
            metadata: [AgentEvent.MetadataKey.sessionID: "s1"]
        ))
        monitor.handleEvent(AgentEvent(
            agentID: "claude",
            agentName: "Claude Code",
            kind: .usage,
            timestamp: now,
            metadata: [
                AgentEvent.MetadataKey.sessionID: "s1",
                AgentEvent.MetadataKey.contextTokens: "50000",
                AgentEvent.MetadataKey.turnActive: "true"
            ]
        ))
        XCTAssertEqual(monitor.activeAgentCount, 1)
        XCTAssertEqual(monitor.activeSessionCount(for: "claude"), 1)
        XCTAssertEqual(monitor.latestContext?.tokens, 50_000)

        monitor.handleEvent(AgentEvent(
            agentID: "claude",
            agentName: "Claude Code",
            kind: .working,
            timestamp: now,
            metadata: [AgentEvent.MetadataKey.sessionID: "s2"]
        ))
        XCTAssertEqual(monitor.activeAgentCount, 1)
        XCTAssertEqual(monitor.activeSessionCount(for: "claude"), 1)
        // Old session's context reading was pruned rather than leaking behind s2.
        XCTAssertNil(monitor.latestContext)

        // Upgrade to Pro: multi-session and multi-agent both accumulate freely.
        let token = try makeToken()
        try service.activateLicense(key: token)
        monitor.validateTierEntitlement()
        monitor.handleEvent(AgentEvent(
            agentID: "claude",
            agentName: "Claude Code",
            kind: .working,
            timestamp: now,
            metadata: [AgentEvent.MetadataKey.sessionID: "s1"]
        ))
        monitor.handleEvent(AgentEvent(
            agentID: "claude",
            agentName: "Claude Code",
            kind: .working,
            timestamp: now,
            metadata: [AgentEvent.MetadataKey.sessionID: "s2"]
        ))
        monitor.handleEvent(AgentEvent(
            agentID: "antigravity",
            agentName: "Antigravity",
            kind: .working,
            timestamp: now,
            metadata: [AgentEvent.MetadataKey.sessionID: "a1"]
        ))
        XCTAssertEqual(monitor.activeAgentCount, 3)

        // Downgrade back to Free: clamps to 1 enabled agent AND 1 active session total.
        try service.deactivateLicense()
        monitor.validateTierEntitlement()
        XCTAssertEqual(monitor.catalog.filter(\.isEnabled).count, 1)
        XCTAssertEqual(monitor.activeAgents.count, 1)
        XCTAssertEqual(monitor.activeAgentCount, 1)
    }

    @MainActor
    func testEntitlementOverrideRefusedInProductionPolicyWithDefaultInit() {
        let (defaults, suite) = makeIsolatedDefaults("ProdOverrideLocked")
        defer { defaults.removePersistentDomain(forName: suite) }

        let storage = MockLicenseStorage()
        let service = LicensingService(
            storage: storage,
            publicKeyData: testPublicKeyData,
            accessPolicy: .production,
            userDefaults: defaults
        )

        XCTAssertFalse(service.isEntitlementOverrideAvailable)
        service.setEntitlementOverride(.simulatePaidPro)
        XCTAssertEqual(service.entitlementOverride, .automatic)
        XCTAssertEqual(service.currentTier, .free)
        XCTAssertNil(service.activeLicense)
        XCTAssertFalse(service.isFeatureUnlocked(.multiMascot))

        // Production policy must still deny override defaults even if .dev bundle or QA env flags are present.
        XCTAssertFalse(
            LicensingService.defaultAllowEntitlementOverride(
                for: .production,
                bundleIdentifier: "com.bitz.cybercat.dev",
                environment: ["BITZ_QA_OVERRIDES": "1"],
                isDebugBuild: true
            )
        )

        // Release binaries (isDebugBuild == false) must NEVER permit entitlement overrides, even with .dev bundle ID or env flag.
        XCTAssertFalse(
            LicensingService.defaultAllowEntitlementOverride(
                for: .current,
                bundleIdentifier: "com.bitz.cybercat",
                environment: [:],
                isDebugBuild: false
            )
        )
        XCTAssertFalse(
            LicensingService.defaultAllowEntitlementOverride(
                for: .current,
                bundleIdentifier: "com.bitz.cybercat.dev",
                environment: ["BITZ_QA_OVERRIDES": "1"],
                isDebugBuild: false
            )
        )

        // Only non-.production Debug builds enable the override toggle by default.
        XCTAssertTrue(
            LicensingService.defaultAllowEntitlementOverride(
                for: .current,
                bundleIdentifier: "com.bitz.cybercat",
                environment: [:],
                isDebugBuild: true
            )
        )
    }

    @MainActor
    func testSimulateFreeTierDoesNotPersistDestructiveDowngradeAcrossStores() {
        let (defaults, suite) = makeIsolatedDefaults("SimulateFreeNonDestructive")
        defer { defaults.removePersistentDomain(forName: suite) }

        let midBetaDate = Date(timeIntervalSince1970: 1_795_000_000)
        let storage = MockLicenseStorage()
        let service = LicensingService(
            storage: storage,
            publicKeyData: testPublicKeyData,
            accessPolicy: .current,
            clock: { midBetaDate },
            userDefaults: defaults,
            allowEntitlementOverride: true
        )

        let paletteStore = AvatarPaletteStore(userDefaults: defaults, licensingService: service)
        let characterStore = AvatarCharacterStore(userDefaults: defaults, licensingService: service)
        let personalityStore = PersonalitySettingsStore(userDefaults: defaults, licensingService: service)

        // Configure Pro customizations across all 3 stores.
        XCTAssertTrue(paletteStore.selectPreset(.tokyoNight))
        XCTAssertTrue(paletteStore.setChassisHex("#112233"))
        XCTAssertTrue(paletteStore.setTrimHex("#445566"))
        XCTAssertTrue(paletteStore.setGlowIntensity(1.4))
        XCTAssertTrue(paletteStore.setEmotionHex("#AABBCC", for: .balanced))
        XCTAssertTrue(characterStore.selectCharacter(.hoverDrone))
        XCTAssertTrue(personalityStore.setEnabled(true))

        // Switch to .simulateFreeTier: all 3 stores clamp in memory WITHOUT overwriting persisted Pro defaults.
        service.setEntitlementOverride(.simulateFreeTier)
        XCTAssertTrue(service.isSimulatingFreeTier)
        paletteStore.validateTierEntitlement()
        characterStore.validateTierEntitlement()
        personalityStore.validateTierEntitlement()

        XCTAssertEqual(paletteStore.selectedPreset, .cyberpunkClassic)
        XCTAssertNil(paletteStore.chassisOverride)
        XCTAssertNil(paletteStore.trimOverride)
        XCTAssertEqual(paletteStore.glowIntensity, 1.0, accuracy: 0.001)
        XCTAssertTrue(paletteStore.emotionOverrides.isEmpty)
        XCTAssertEqual(characterStore.selectedCharacter, .defaultCharacter)
        XCTAssertFalse(personalityStore.isEnabled)

        // Verify UserDefaults retained the Pro values intact.
        XCTAssertEqual(defaults.string(forKey: AvatarPaletteStore.themeIdKey), AvatarThemePreset.tokyoNight.rawValue)
        XCTAssertEqual(defaults.string(forKey: AvatarPaletteStore.chassisKey), "#112233")
        XCTAssertEqual(defaults.string(forKey: AvatarPaletteStore.trimKey), "#445566")
        XCTAssertEqual(defaults.double(forKey: AvatarPaletteStore.glowKey), 1.4, accuracy: 0.001)
        let persistedEmotions = defaults.dictionary(forKey: AvatarPaletteStore.emotionOverridesKey) as? [String: String]
        XCTAssertEqual(persistedEmotions?[AvatarEmotionColorSlot.balanced.rawValue], "#AABBCC")
        XCTAssertEqual(defaults.string(forKey: AvatarCharacterStore.selectedCharacterKey), MascotCharacter.hoverDrone.rawValue)
        XCTAssertTrue(defaults.bool(forKey: PersonalitySettingsStore.isEnabledKey))

        // Restore .automatic and re-validate: all 3 stores recover their persisted Pro configuration.
        service.setEntitlementOverride(.automatic)
        XCTAssertFalse(service.isSimulatingFreeTier)
        paletteStore.validateTierEntitlement()
        characterStore.validateTierEntitlement()
        personalityStore.validateTierEntitlement()

        XCTAssertEqual(paletteStore.selectedPreset, .tokyoNight)
        XCTAssertEqual(paletteStore.chassisOverride, "#112233")
        XCTAssertEqual(paletteStore.trimOverride, "#445566")
        XCTAssertEqual(paletteStore.glowIntensity, 1.4, accuracy: 0.001)
        XCTAssertEqual(paletteStore.emotionOverrides[.balanced], "#AABBCC")
        XCTAssertEqual(characterStore.selectedCharacter, .hoverDrone)
        XCTAssertTrue(personalityStore.isEnabled)
    }

    @MainActor
    func testAgentMonitorServiceSimulatedEventWorksOnFreeTierWithoutClobberingPrimary() {
        let (defaults, suite) = makeIsolatedDefaults("SimulatedEventFreeTier")
        defer { defaults.removePersistentDomain(forName: suite) }

        let now = Date()
        let storage = MockLicenseStorage()
        let service = LicensingService(
            storage: storage,
            publicKeyData: testPublicKeyData,
            accessPolicy: .production,
            clock: { now },
            userDefaults: defaults
        )

        let monitor = AgentMonitorService(
            clock: { now },
            userDefaults: defaults,
            licensingService: service
        )
        var handledKinds: [AgentEventKind] = []
        monitor.onEventHandled = { event in
            handledKinds.append(event.kind)
        }

        // Primary Free-tier agent ("claude") is running; "antigravity" is disabled by catalog gate.
        monitor.handleEvent(AgentEvent(agentID: "claude", agentName: "Claude Code", kind: .started, timestamp: now))
        XCTAssertEqual(monitor.activeAgents, ["claude"])
        XCTAssertEqual(monitor.activeAgentCount, 1)

        // Non-simulated antigravity event is dropped in Free tier.
        monitor.handleEvent(AgentEvent(
            agentID: "antigravity",
            agentName: "Antigravity",
            kind: .needsApproval,
            message: "Antigravity has a question for you!",
            timestamp: now
        ))
        XCTAssertNil(monitor.activePopup)
        XCTAssertEqual(handledKinds, [.started])

        // Simulated events from Advanced settings bypass Free-tier gate without evicting "claude".
        monitor.handleSimulatedEvent(AgentEvent(
            agentID: "antigravity",
            agentName: "Antigravity",
            kind: .needsApproval,
            message: "Antigravity has a question for you!",
            timestamp: now
        ))
        XCTAssertEqual(monitor.activePopup?.kind, .needsApproval)
        XCTAssertEqual(monitor.activePopup?.agentName, "Antigravity")
        XCTAssertEqual(monitor.activeAgents, ["claude"])
        XCTAssertEqual(monitor.activeAgentCount, 1)

        monitor.handleSimulatedEvent(AgentEvent(
            agentID: "antigravity",
            agentName: "Antigravity",
            kind: .done,
            message: "Antigravity finished all tasks!",
            timestamp: now
        ))
        XCTAssertEqual(monitor.activePopup?.kind, .done)
        XCTAssertEqual(monitor.activePopup?.agentName, "Antigravity")
        XCTAssertEqual(monitor.activeAgents, ["claude"])
        XCTAssertEqual(monitor.activeAgentCount, 1)
        XCTAssertEqual(handledKinds, [.started, .needsApproval, .done])
    }

    @MainActor
    func testRemoteLicensePersistsExpirationAcrossRestartAndExpiresOffline() async throws {
        let (defaults, suite) = makeIsolatedDefaults("RemotePersistExpire")
        defer { defaults.removePersistentDomain(forName: suite) }

        final class ClockBox: @unchecked Sendable {
            private let lock = NSLock()
            private var _now: Date
            init(_ now: Date) { self._now = now }
            var now: Date {
                get { lock.lock(); defer { lock.unlock() }; return _now }
                set { lock.lock(); _now = newValue; lock.unlock() }
            }
        }

        let start = Date(timeIntervalSince1970: 1_800_000_000)
        let expiresAt = start.addingTimeInterval(3600)
        let clockBox = ClockBox(start)
        let storage = MockLicenseStorage()
        let backend = MockLicensingTestBackend(validateHandler: { _, _ in
            RemoteLicenseResult(
                valid: true,
                tier: "pro",
                licenseKey: "BTZ-REMOTE-PERSIST-1",
                expiresAt: expiresAt
            )
        })

        let service1 = LicensingService(
            storage: storage,
            publicKeyData: testPublicKeyData,
            backendClient: backend,
            accessPolicy: .production,
            clock: { clockBox.now },
            userDefaults: defaults
        )
        try await service1.activateLicense(key: "BTZ-REMOTE-PERSIST-1")
        XCTAssertEqual(service1.currentTier, .pro)
        XCTAssertEqual(service1.activeLicense?.licenseId, "BTZ-REMOTE-PERSIST-1")
        XCTAssertEqual(service1.activeLicense?.expiresAt, expiresAt.timeIntervalSince1970)

        // Wipe UserDefaults before restarting offline to prove expiry lives inside storage, not UserDefaults.
        defaults.removePersistentDomain(forName: suite)

        // Simulate app restart offline before expiration: Pro entitlement & metadata remain intact.
        let service2 = LicensingService(
            storage: storage,
            publicKeyData: testPublicKeyData,
            backendClient: nil,
            accessPolicy: .production,
            clock: { clockBox.now },
            userDefaults: defaults
        )
        XCTAssertEqual(service2.currentTier, .pro)
        XCTAssertEqual(service2.activeLicense?.licenseId, "BTZ-REMOTE-PERSIST-1")
        XCTAssertEqual(service2.activeLicense?.expiresAt, expiresAt.timeIntervalSince1970)

        // Advance clock past expiresAt and restart offline: expired remote license must purge.
        clockBox.now = expiresAt.addingTimeInterval(60)
        let service3 = LicensingService(
            storage: storage,
            publicKeyData: testPublicKeyData,
            backendClient: nil,
            accessPolicy: .production,
            clock: { clockBox.now },
            userDefaults: defaults
        )
        XCTAssertEqual(service3.currentTier, .free)
        XCTAssertNil(service3.activeLicense)
        XCTAssertNil(storage.loadLicenseToken())
    }

    @MainActor
    func testMalformedTwoLineRemoteTokenPurgesOnStartup() throws {
        let (defaults, suite) = makeIsolatedDefaults("MalformedTwoLineToken")
        defer { defaults.removePersistentDomain(forName: suite) }

        let now = Date(timeIntervalSince1970: 1_800_000_000)

        // 1) Corrupt base64 payload in a 2-line BTZ- token must fail closed and purge storage.
        let malformedStorage = MockLicenseStorage(token: "BTZ-MALFORMED-1\nnot_valid_base64!!!")
        let malformedService = LicensingService(
            storage: malformedStorage,
            publicKeyData: testPublicKeyData,
            backendClient: nil,
            accessPolicy: .production,
            clock: { now },
            userDefaults: defaults
        )
        XCTAssertEqual(malformedService.currentTier, .free)
        XCTAssertNil(malformedService.activeLicense)
        XCTAssertNil(malformedStorage.loadLicenseToken())

        // 2) Mismatched outer/inner licenseId in a 2-line BTZ- token must fail closed and purge storage.
        let innerPayload = LicensePayload(
            tier: "pro",
            licenseId: "BTZ-INNER-2",
            issuedAt: now.timeIntervalSince1970,
            expiresAt: now.addingTimeInterval(3600).timeIntervalSince1970
        )
        let encodedPayload = LicensingService.base64URLEncode(try JSONEncoder().encode(innerPayload))
        let mismatchStorage = MockLicenseStorage(token: "BTZ-OUTER-1\n\(encodedPayload)")
        let mismatchService = LicensingService(
            storage: mismatchStorage,
            publicKeyData: testPublicKeyData,
            backendClient: nil,
            accessPolicy: .production,
            clock: { now },
            userDefaults: defaults
        )
        XCTAssertEqual(mismatchService.currentTier, .free)
        XCTAssertNil(mismatchService.activeLicense)
        XCTAssertNil(mismatchStorage.loadLicenseToken())
    }

    @MainActor
    func testValidateActiveLicenseRemotelyClearsExpirationOnLifetimeUpgrade() async throws {
        let (defaults, suite) = makeIsolatedDefaults("RemoteLifetimeUpgrade")
        defer { defaults.removePersistentDomain(forName: suite) }

        final class Box<T>: @unchecked Sendable {
            private let lock = NSLock()
            private var _value: T
            init(_ value: T) { self._value = value }
            var value: T {
                get { lock.lock(); defer { lock.unlock() }; return _value }
                set { lock.lock(); _value = newValue; lock.unlock() }
            }
        }

        let start = Date(timeIntervalSince1970: 1_800_000_000)
        let originalExpiry = start.addingTimeInterval(3600)
        let clockBox = Box(start)
        let resultBox = Box(RemoteLicenseResult(
            valid: true,
            tier: "pro",
            licenseKey: "BTZ-UPGRADE-1",
            expiresAt: originalExpiry
        ))
        let storage = MockLicenseStorage()
        let backend = MockLicensingTestBackend(validateHandler: { _, _ in
            resultBox.value
        })

        let service1 = LicensingService(
            storage: storage,
            publicKeyData: testPublicKeyData,
            backendClient: backend,
            accessPolicy: .production,
            clock: { clockBox.value },
            userDefaults: defaults
        )
        try await service1.activateLicense(key: "BTZ-UPGRADE-1")
        XCTAssertEqual(service1.currentTier, .pro)
        XCTAssertEqual(service1.activeLicense?.expiresAt, originalExpiry.timeIntervalSince1970)

        // Backend upgrades the license to lifetime (expiresAt == nil).
        resultBox.value = RemoteLicenseResult(
            valid: true,
            tier: "pro",
            licenseKey: "BTZ-UPGRADE-1",
            expiresAt: nil
        )
        await service1.validateActiveLicenseRemotely()
        XCTAssertEqual(service1.currentTier, .pro)
        XCTAssertNil(service1.activeLicense?.expiresAt)

        // Advance past original expiry and restart offline: lifetime Pro must persist.
        clockBox.value = originalExpiry.addingTimeInterval(3600)
        let service2 = LicensingService(
            storage: storage,
            publicKeyData: testPublicKeyData,
            backendClient: nil,
            accessPolicy: .production,
            clock: { clockBox.value },
            userDefaults: defaults
        )
        XCTAssertEqual(service2.currentTier, .pro)
        XCTAssertEqual(service2.activeLicense?.licenseId, "BTZ-UPGRADE-1")
        XCTAssertNil(service2.activeLicense?.expiresAt)
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
