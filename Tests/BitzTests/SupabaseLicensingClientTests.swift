import XCTest
@testable import BitzCore

// MARK: - Mock URL Protocol for Deterministic Networking Tests

private final class MockLicensingURLProtocol: URLProtocol {
    nonisolated(unsafe) static var requestHandler: ((URLRequest) throws -> (HTTPURLResponse, Data))?

    override class func canInit(with request: URLRequest) -> Bool {
        return true
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        return request
    }

    override func startLoading() {
        guard let handler = Self.requestHandler else {
            XCTFail("MockLicensingURLProtocol handler not set")
            return
        }

        do {
            let (response, data) = try handler(request)
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}
}

// MARK: - Supabase Licensing Client Tests

final class SupabaseLicensingClientTests: XCTestCase {
    private var session: URLSession!

    override func setUp() {
        super.setUp()
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MockLicensingURLProtocol.self]
        session = URLSession(configuration: config)
    }

    override func tearDown() {
        MockLicensingURLProtocol.requestHandler = nil
        session = nil
        super.tearDown()
    }

    func testHashedDeviceIDIsDeterministicAndNonEmpty() {
        let hash1 = DeviceHardwareIdentifier.hashedDeviceID(salt: "bitz:", fallbackUUID: "12345678-ABCD-EF00")
        let hash2 = DeviceHardwareIdentifier.hashedDeviceID(salt: "bitz:", fallbackUUID: "12345678-ABCD-EF00")
        XCTAssertEqual(hash1, hash2)
        XCTAssertEqual(hash1.count, 64) // SHA-256 hex string

        // Different salt yields different hash
        let hashDifferentSalt = DeviceHardwareIdentifier.hashedDeviceID(salt: "other:", fallbackUUID: "12345678-ABCD-EF00")
        XCTAssertNotEqual(hash1, hashDifferentSalt)
    }

    func testDeviceNameReturnsNonEmptyString() {
        let name = DeviceHardwareIdentifier.deviceName()
        XCTAssertFalse(name.isEmpty)
    }

    func testActivateBetaSuccess() async throws {
        let jsonResponse = """
        {
            "valid": true,
            "tier": "pro",
            "license_key": "BTZ-BETA-ABCD-1234",
            "status": "active",
            "expires_at": "2026-12-31T23:59:59Z",
            "customer_email": "test@example.com"
        }
        """.data(using: .utf8)!

        MockLicensingURLProtocol.requestHandler = { request in
            XCTAssertEqual(request.url?.path, "/rest/v1/rpc/activate_beta_license")
            XCTAssertEqual(request.httpMethod, "POST")
            XCTAssertEqual(request.value(forHTTPHeaderField: "apikey"), "test-key")

            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: 200,
                httpVersion: nil,
                headerFields: ["Content-Type": "application/json"]
            )!
            return (response, jsonResponse)
        }

        let client = SupabaseLicensingClient(
            projectRef: "test-ref",
            apiKey: "test-key",
            urlSession: session
        )

        let result = try await client.activateBeta(
            deviceId: "hash123",
            deviceName: "MacBook Pro",
            customerEmail: "test@example.com"
        )

        XCTAssertTrue(result.valid)
        XCTAssertEqual(result.tier, "pro")
        XCTAssertEqual(result.licenseKey, "BTZ-BETA-ABCD-1234")
        XCTAssertEqual(result.customerEmail, "test@example.com")
    }

    func testValidateRejectsWhenDeviceLimitReached() async throws {
        let jsonResponse = """
        {
            "valid": false,
            "error": "activation_limit_reached",
            "message": "This license is already active on 2 Macs."
        }
        """.data(using: .utf8)!

        MockLicensingURLProtocol.requestHandler = { request in
            XCTAssertEqual(request.url?.path, "/rest/v1/rpc/validate_license")

            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: 200,
                httpVersion: nil,
                headerFields: ["Content-Type": "application/json"]
            )!
            return (response, jsonResponse)
        }

        let client = SupabaseLicensingClient(
            projectRef: "test-ref",
            apiKey: "test-key",
            urlSession: session
        )

        let result = try await client.validate(
            licenseKey: "BTZ-BETA-ABCD-1234",
            deviceId: "mac-3"
        )

        XCTAssertFalse(result.valid)
        XCTAssertEqual(result.error, "activation_limit_reached")
        XCTAssertEqual(result.message, "This license is already active on 2 Macs.")
    }

    func testRegisterEmailSuccess() async throws {
        let jsonResponse = """
        {
            "success": true,
            "customer_email": "updated@example.com"
        }
        """.data(using: .utf8)!

        MockLicensingURLProtocol.requestHandler = { request in
            XCTAssertEqual(request.url?.path, "/rest/v1/rpc/register_beta_email")

            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: 200,
                httpVersion: nil,
                headerFields: ["Content-Type": "application/json"]
            )!
            return (response, jsonResponse)
        }

        let client = SupabaseLicensingClient(
            projectRef: "test-ref",
            apiKey: "test-key",
            urlSession: session
        )

        let result = try await client.registerEmail(
            licenseKey: "BTZ-BETA-ABCD-1234",
            customerEmail: "updated@example.com"
        )

        XCTAssertTrue(result.success)
        XCTAssertEqual(result.customerEmail, "updated@example.com")
    }

    func testDeactivateSuccess() async throws {
        let jsonResponse = """
        {
            "success": true,
            "deactivated": true
        }
        """.data(using: .utf8)!

        MockLicensingURLProtocol.requestHandler = { request in
            XCTAssertEqual(request.url?.path, "/rest/v1/rpc/deactivate_license")

            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: 200,
                httpVersion: nil,
                headerFields: ["Content-Type": "application/json"]
            )!
            return (response, jsonResponse)
        }

        let client = SupabaseLicensingClient(
            projectRef: "test-ref",
            apiKey: "test-key",
            urlSession: session
        )

        let result = try await client.deactivate(
            licenseKey: "BTZ-BETA-ABCD-1234",
            deviceId: "device-1"
        )

        XCTAssertTrue(result.success)
        XCTAssertTrue(result.deactivated)
    }
}
