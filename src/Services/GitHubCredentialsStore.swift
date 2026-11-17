import Foundation
import Security

/// Errors that can occur during GitHub credential resolution and Keychain persistence.
public enum GitHubCredentialsError: Error, Sendable, Equatable {
    case ghCliNotFound
    case ghCommandFailed(Int32)
    case tokenNotFound
    case emptyToken
    case storageFailed(String)
}

/// Abstract storage protocol for persisting GitHub Personal Access Tokens (PAT).
public protocol GitHubTokenStorageProtocol: AnyObject, Sendable {
    func loadToken() -> String?
    func saveToken(_ token: String) throws
    func deleteToken() throws
}

/// Production Keychain storage for GitHub Personal Access Tokens (`kSecClassGenericPassword`).
public final class KeychainGitHubTokenStorage: GitHubTokenStorageProtocol, @unchecked Sendable {
    private let service: String
    private let account: String
    private let lock = NSLock()

    public init(
        service: String = "com.akramks.bitz.github",
        account: String = "pat_token"
    ) {
        self.service = service
        self.account = account
    }

    public func loadToken() -> String? {
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

    public func saveToken(_ token: String) throws {
        lock.lock()
        defer { lock.unlock() }

        guard let tokenData = token.data(using: .utf8) else {
            throw GitHubCredentialsError.storageFailed("Failed to encode token to UTF-8")
        }

        // Delete existing item first for clean idempotent write
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
            throw GitHubCredentialsError.storageFailed("Keychain save failed: \(message)")
        }
    }

    public func deleteToken() throws {
        lock.lock()
        defer { lock.unlock() }

        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]

        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            let message = SecCopyErrorMessageString(status, nil) as String? ?? "OSStatus \(status)"
            throw GitHubCredentialsError.storageFailed("Keychain delete failed: \(message)")
        }
    }
}

/// In-memory storage for deterministic unit testing.
public final class InMemoryGitHubTokenStorage: GitHubTokenStorageProtocol, @unchecked Sendable {
    private var token: String?
    private let lock = NSLock()

    public init(initialToken: String? = nil) {
        self.token = initialToken
    }

    public func loadToken() -> String? {
        lock.lock()
        defer { lock.unlock() }
        return token
    }

    public func saveToken(_ token: String) throws {
        lock.lock()
        defer { lock.unlock() }
        self.token = token
    }

    public func deleteToken() throws {
        lock.lock()
        defer { lock.unlock() }
        self.token = nil
    }
}

/// Closure type for executing GitHub CLI commands asynchronously.
public typealias GHCommandRunner = @Sendable () async throws -> String

/// Service that coordinates zero-config `gh` CLI token auto-detection and secure Keychain PAT storage.
public final class GitHubCredentialsStore: @unchecked Sendable {
    public static let defaultCLITokenTTL: TimeInterval = 300.0 // 5 minutes cache to preserve < 2% CPU

    private let tokenStorage: any GitHubTokenStorageProtocol
    private let ghRunner: GHCommandRunner
    private let clock: @Sendable () -> Date
    private let ttlSeconds: TimeInterval

    private let lock = NSLock()
    private var cachedCLIToken: String?
    private var lastCLIFetchDate: Date?

    public init(
        tokenStorage: any GitHubTokenStorageProtocol = KeychainGitHubTokenStorage(),
        ghRunner: @escaping GHCommandRunner = GitHubCredentialsStore.defaultGHCommandRunner,
        clock: @escaping @Sendable () -> Date = Date.init,
        ttlSeconds: TimeInterval = defaultCLITokenTTL
    ) {
        self.tokenStorage = tokenStorage
        self.ghRunner = ghRunner
        self.clock = clock
        self.ttlSeconds = ttlSeconds
    }

    /// Resolves the currently active GitHub token based on `mode`.
    /// In `.auto` mode: checks `gh` CLI first; falls back to manual Keychain PAT.
    /// In `.manualPAT` mode: checks Keychain PAT only.
    public func activeToken(mode: GitHubAuthMode) async -> (token: String, source: GitHubAuthSource)? {
        switch mode {
        case .auto:
            if let cliToken = await resolveCLIToken() {
                return (cliToken, .ghCLI)
            }
            if let patToken = tokenStorage.loadToken(), !patToken.isEmpty {
                return (patToken, .personalAccessToken)
            }
            return nil

        case .manualPAT:
            if let patToken = tokenStorage.loadToken(), !patToken.isEmpty {
                return (patToken, .personalAccessToken)
            }
            return nil
        }
    }

    private func getCachedCLIToken(now: Date) -> String? {
        lock.lock()
        defer { lock.unlock() }
        if let cached = cachedCLIToken, let lastFetch = lastCLIFetchDate, now.timeIntervalSince(lastFetch) < ttlSeconds {
            return cached
        }
        return nil
    }

    private func setCachedCLIToken(_ token: String, date: Date) {
        lock.lock()
        defer { lock.unlock() }
        self.cachedCLIToken = token
        self.lastCLIFetchDate = date
    }

    /// Caches and queries token via `gh auth token` off the main thread.
    public func resolveCLIToken() async -> String? {
        let now = clock()
        if let cached = getCachedCLIToken(now: now) {
            return cached
        }

        do {
            let token = try await ghRunner()
            let trimmed = token.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return nil }

            setCachedCLIToken(trimmed, date: now)
            return trimmed
        } catch {
            return nil
        }
    }

    /// Saves a manual Personal Access Token to Keychain.
    public func saveManualPAT(_ token: String) throws {
        let trimmed = token.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw GitHubCredentialsError.emptyToken
        }
        try tokenStorage.saveToken(trimmed)
    }

    /// Removes manual Personal Access Token from Keychain.
    public func deleteManualPAT() throws {
        try tokenStorage.deleteToken()
    }

    /// Checks if a manual PAT exists in Keychain.
    public func hasManualPAT() -> Bool {
        guard let token = tokenStorage.loadToken() else { return false }
        return !token.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// Clears the cached `gh` CLI token.
    public func clearCLICache() {
        lock.lock()
        cachedCLIToken = nil
        lastCLIFetchDate = nil
        lock.unlock()
    }

    /// Production GitHub CLI runner executing `gh auth token`.
    public static func defaultGHCommandRunner() async throws -> String {
        try await Task.detached(priority: .utility) {
            let candidates = [
                "/opt/homebrew/bin/gh",
                "/usr/local/bin/gh",
                "/usr/bin/gh"
            ]
            let fileManager = FileManager.default
            guard let ghPath = candidates.first(where: { fileManager.isExecutableFile(atPath: $0) }) else {
                throw GitHubCredentialsError.ghCliNotFound
            }

            let process = Process()
            process.executableURL = URL(fileURLWithPath: ghPath)
            process.arguments = ["auth", "token"]

            let (stdoutData, _) = try process.runCollectingOutput()

            guard process.terminationStatus == 0 else {
                throw GitHubCredentialsError.ghCommandFailed(process.terminationStatus)
            }

            let token = String(data: stdoutData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            guard !token.isEmpty else {
                throw GitHubCredentialsError.tokenNotFound
            }

            return token
        }.value
    }
}
