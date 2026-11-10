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
        XCTAssertFalse(service.isFeatureUnlocked(.multiMascot))
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

        // Advance time past expiration while session is running
        currentTime = currentTime.addingTimeInterval(120)
        XCTAssertFalse(service.isFeatureUnlocked(.multiMascot))
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
}
