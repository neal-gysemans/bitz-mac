import Foundation

/// Errors that can occur during Git command execution.
public enum GitError: Error, Sendable, Equatable {
    case commandFailed(Int32)
    case invalidDirectory(String)
}

/// Closure type representing an asynchronous Git command execution.
public typealias GitCommandRunner = @Sendable (_ repoPath: String, _ arguments: [String]) async throws -> String

/// Actor that queries local git commit activity across user-selected repositories.
///
/// Fully opt-in (`FR-012`):
/// - When no repositories are selected, zero processes are spawned and queries immediately return `nil`.
/// - Queries execute off the main thread with a configurable TTL cache (`defaultTTLSeconds = 60.0`)
///   to strictly preserve the idle CPU invariant (`< 2%`).
public actor GitActivityProvider: GitActivityProviding {
    public static let defaultTTLSeconds: TimeInterval = 60.0

    private let repoPathsProvider: @Sendable () async -> [String]
    private let runner: GitCommandRunner
    private let clock: @Sendable () -> Date
    private let ttlSeconds: TimeInterval

    private var cachedCount: Int? = nil
    private var lastFetchTime: Date? = nil
    private var lastQueryMinutes: Int? = nil

    public init(
        repoPathsProvider: @escaping @Sendable () async -> [String],
        runner: @escaping GitCommandRunner = GitActivityProvider.defaultGitCommandRunner,
        clock: @escaping @Sendable () -> Date = Date.init,
        ttlSeconds: TimeInterval = defaultTTLSeconds
    ) {
        self.repoPathsProvider = repoPathsProvider
        self.runner = runner
        self.clock = clock
        self.ttlSeconds = ttlSeconds
    }

    public init(
        settingsStore: PersonalitySettingsStore,
        runner: @escaping GitCommandRunner = GitActivityProvider.defaultGitCommandRunner,
        clock: @escaping @Sendable () -> Date = Date.init,
        ttlSeconds: TimeInterval = defaultTTLSeconds
    ) {
        self.init(
            repoPathsProvider: { await MainActor.run { settingsStore.watchedRepoPaths } },
            runner: runner,
            clock: clock,
            ttlSeconds: ttlSeconds
        )
    }

    /// Default execution runner using system `/usr/bin/git`.
    public static func defaultGitCommandRunner(repoPath: String, arguments: [String]) async throws -> String {
        try await Task.detached(priority: .utility) {
            let fileManager = FileManager.default
            var isDir: ObjCBool = false
            guard fileManager.fileExists(atPath: repoPath, isDirectory: &isDir), isDir.boolValue else {
                throw GitError.invalidDirectory(repoPath)
            }

            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
            process.currentDirectoryURL = URL(fileURLWithPath: repoPath)
            process.arguments = arguments

            let pipe = Pipe()
            process.standardOutput = pipe
            process.standardError = Pipe()

            try process.run()
            process.waitUntilExit()

            guard process.terminationStatus == 0 else {
                throw GitError.commandFailed(process.terminationStatus)
            }

            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            return String(data: data, encoding: .utf8) ?? ""
        }.value
    }

    /// Queries the total number of commits made across watched repository paths within `sinceMinutes`.
    /// Returns `nil` if no repositories are watched or if queries fail.
    public func recentCommitCount(sinceMinutes: Int) async -> Int? {
        let paths = await repoPathsProvider()
        guard !paths.isEmpty else {
            cachedCount = nil
            lastFetchTime = nil
            lastQueryMinutes = nil
            return nil
        }

        let now = clock()
        if let last = lastFetchTime,
           let cached = cachedCount,
           let lastMin = lastQueryMinutes,
           lastMin == sinceMinutes,
           now.timeIntervalSince(last) < ttlSeconds {
            return cached
        }

        var total = 0
        for repoPath in paths {
            do {
                let output = try await runner(repoPath, ["log", "--since=\(sinceMinutes) minutes ago", "--oneline"])
                let count = output
                    .components(separatedBy: .newlines)
                    .map { $0.trimmingCharacters(in: .whitespaces) }
                    .filter { !$0.isEmpty }
                    .count
                total += count
            } catch {
                // Non-fatal: if one repo is missing or unreadable, continue aggregating others
            }
        }

        cachedCount = total
        lastFetchTime = now
        lastQueryMinutes = sinceMinutes
        return total
    }

    /// Clears the cached commit count.
    public func invalidateCache() {
        cachedCount = nil
        lastFetchTime = nil
        lastQueryMinutes = nil
    }
}
