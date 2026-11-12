import Foundation
import Security

/// Production storage implementation persisting cryptographic license tokens
/// into the macOS Keychain (`kSecClassGenericPassword`).
public final class KeychainLicenseStorage: LicenseStorageProtocol, @unchecked Sendable {
    private let service: String
    private let account: String
    private let lock = NSLock()

    public init(
        service: String = "com.akramks.bitz.licensing",
        account: String = "active_license"
    ) {
        self.service = service
        self.account = account
    }

    public func loadLicenseToken() -> String? {
        lock.lock()
        defer { lock.unlock() }

        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]

        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)

        if status == errSecSuccess,
           let data = item as? Data,
           let token = String(data: data, encoding: .utf8),
           !token.isEmpty {
            return token
        }

        return nil
    }

    public func saveLicenseToken(_ token: String) throws {
        lock.lock()
        defer { lock.unlock() }

        guard let tokenData = token.data(using: .utf8) else {
            throw LicensingError.storageFailed("Failed to encode license token to UTF-8 data")
        }

        // Delete existing item first to ensure clean idempotent insert
        let deleteQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        SecItemDelete(deleteQuery as CFDictionary)

        let addQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock,
            kSecValueData as String: tokenData
        ]

        let status = SecItemAdd(addQuery as CFDictionary, nil)
        guard status == errSecSuccess else {
            let message = SecCopyErrorMessageString(status, nil) as String? ?? "OSStatus \(status)"
            throw LicensingError.storageFailed("Keychain save failed: \(message)")
        }
    }

    public func deleteLicenseToken() throws {
        lock.lock()
        defer { lock.unlock() }

        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]

        let status = SecItemDelete(query as CFDictionary)
        // If not found, deleting is idempotent and succeeds
        guard status == errSecSuccess || status == errSecItemNotFound else {
            let message = SecCopyErrorMessageString(status, nil) as String? ?? "OSStatus \(status)"
            throw LicensingError.storageFailed("Keychain delete failed: \(message)")
        }
    }
}
