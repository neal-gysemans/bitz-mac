import Foundation
import CryptoKit
import IOKit

// MARK: - Remote Licensing Models

/// Result returned from remote licensing operations (Supabase / Lemon Squeezy).
public struct RemoteLicenseResult: Codable, Sendable, Equatable {
    public let valid: Bool
    public let tier: String?
    public let licenseKey: String?
    public let status: String?
    public let expiresAt: Date?
    public let customerEmail: String?
    public let error: String?
    public let message: String?

    enum CodingKeys: String, CodingKey {
        case valid
        case tier
        case licenseKey = "license_key"
        case status
        case expiresAt = "expires_at"
        case customerEmail = "customer_email"
        case error
        case message
    }

    public init(
        valid: Bool,
        tier: String? = nil,
        licenseKey: String? = nil,
        status: String? = nil,
        expiresAt: Date? = nil,
        customerEmail: String? = nil,
        error: String? = nil,
        message: String? = nil
    ) {
        self.valid = valid
        self.tier = tier
        self.licenseKey = licenseKey
        self.status = status
        self.expiresAt = expiresAt
        self.customerEmail = customerEmail
        self.error = error
        self.message = message
    }
}

/// Result of registering or updating a customer email for a license.
public struct RemoteEmailResult: Codable, Sendable, Equatable {
    public let success: Bool
    public let customerEmail: String?
    public let error: String?

    enum CodingKeys: String, CodingKey {
        case success
        case customerEmail = "customer_email"
        case error
    }

    public init(success: Bool, customerEmail: String? = nil, error: String? = nil) {
        self.success = success
        self.customerEmail = customerEmail
        self.error = error
    }
}

/// Result of deactivating a device slot.
public struct RemoteDeactivateResult: Codable, Sendable, Equatable {
    public let success: Bool
    public let deactivated: Bool
    public let error: String?

    public init(success: Bool, deactivated: Bool, error: String? = nil) {
        self.success = success
        self.deactivated = deactivated
        self.error = error
    }
}

// MARK: - Licensing Backend Client Protocol

/// Protocol decoupling remote licensing communication so the app can swap cleanly
/// from the temporary Supabase Beta controller to Lemon Squeezy for GA.
public protocol LicensingBackendClient: Sendable {
    func activateBeta(
        deviceId: String,
        deviceName: String,
        customerEmail: String?
    ) async throws -> RemoteLicenseResult

    func validate(
        licenseKey: String,
        deviceId: String
    ) async throws -> RemoteLicenseResult

    func registerEmail(
        licenseKey: String,
        customerEmail: String
    ) async throws -> RemoteEmailResult

    func deactivate(
        licenseKey: String,
        deviceId: String
    ) async throws -> RemoteDeactivateResult
}

// MARK: - Device Hardware Identifier

/// Secure hardware identification for device binding.
/// Never sends raw serials or unhashed UUIDs to the server.
public enum DeviceHardwareIdentifier {
    /// Reads the Mac hardware UUID from IOKit.
    public static func rawPlatformUUID() -> String? {
        let platformExpert = IOServiceGetMatchingService(
            kIOMainPortDefault,
            IOServiceMatching("IOPlatformExpertDevice")
        )
        guard platformExpert != 0 else { return nil }
        defer { IOObjectRelease(platformExpert) }

        guard let uuidAsCFString = IORegistryEntryCreateCFProperty(
            platformExpert,
            kIOPlatformUUIDKey as CFString,
            kCFAllocatorDefault,
            0
        ) else { return nil }

        return (uuidAsCFString.takeRetainedValue() as? String)
    }

    /// Computes a salted SHA-256 hash of the motherboard UUID.
    public static func hashedDeviceID(
        salt: String = "bitz:",
        fallbackUUID: String = "00000000-0000-0000-0000-000000000000"
    ) -> String {
        let rawUUID = rawPlatformUUID() ?? fallbackUUID
        let data = Data((salt + rawUUID).utf8)
        let hash = SHA256.hash(data: data)
        return hash.compactMap { String(format: "%02x", $0) }.joined()
    }

    /// Returns a friendly user-visible machine name (e.g. "MacBook Pro").
    public static func deviceName() -> String {
        Host.current().localizedName ?? "Mac"
    }
}
