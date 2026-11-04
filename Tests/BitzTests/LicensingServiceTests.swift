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
}
