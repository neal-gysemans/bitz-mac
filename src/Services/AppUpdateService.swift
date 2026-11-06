import AppKit
import Combine
import Foundation

/// Robust Semantic Version parser and comparator adhering to SemVer 2.0.0.
public struct SemanticVersion: Comparable, Equatable, Sendable, CustomStringConvertible {
    public let major: Int
    public let minor: Int
    public let patch: Int
    public let prerelease: String?
    public let rawString: String

    public init(_ versionString: String) {
        self.rawString = versionString.trimmingCharacters(in: .whitespacesAndNewlines)

        // Strip leading 'v' or 'V' (e.g. "v1.2.0" -> "1.2.0")
        var cleaned = rawString
        if cleaned.lowercased().hasPrefix("v") {
            cleaned.removeFirst()
        }

        // Split prerelease tag (e.g. "1.2.0-beta.1" -> ("1.2.0", "beta.1"))
        let components = cleaned.split(separator: "-", maxSplits: 1, omittingEmptySubsequences: true)
        if components.count == 2 {
            self.prerelease = String(components[1])
        } else {
            self.prerelease = nil
        }

        let numericParts = components[0].split(separator: ".")
        self.major = numericParts.indices.contains(0) ? (Int(numericParts[0]) ?? 0) : 0
        self.minor = numericParts.indices.contains(1) ? (Int(numericParts[1]) ?? 0) : 0
        self.patch = numericParts.indices.contains(2) ? (Int(numericParts[2]) ?? 0) : 0
    }

    public var description: String {
        if let prerelease {
            return "\(major).\(minor).\(patch)-\(prerelease)"
        }
        return "\(major).\(minor).\(patch)"
    }

    public static func < (lhs: SemanticVersion, rhs: SemanticVersion) -> Bool {
        if lhs.major != rhs.major {
            return lhs.major < rhs.major
        }
        if lhs.minor != rhs.minor {
            return lhs.minor < rhs.minor
        }
        if lhs.patch != rhs.patch {
            return lhs.patch < rhs.patch
        }

        // According to SemVer, a version with a prerelease is lower than the same version without one
        switch (lhs.prerelease, rhs.prerelease) {
        case (nil, nil):
            return false
        case (.some, nil):
            return true
        case (nil, .some):
            return false
        case let (.some(l), .some(r)):
            return l < r
        }
    }

    public static func == (lhs: SemanticVersion, rhs: SemanticVersion) -> Bool {
        lhs.major == rhs.major &&
        lhs.minor == rhs.minor &&
        lhs.patch == rhs.patch &&
        lhs.prerelease == rhs.prerelease
    }
}

/// Information about a GitHub release asset.
public struct GitHubReleaseAsset: Equatable, Sendable, Codable {
    public let name: String
    public let browserDownloadUrl: URL

    public init(name: String, browserDownloadUrl: URL) {
        self.name = name
        self.browserDownloadUrl = browserDownloadUrl
    }

    enum CodingKeys: String, CodingKey {
        case name
        case browserDownloadUrl = "browser_download_url"
    }
}

/// Parsed metadata from a GitHub Release.
public struct GitHubReleaseInfo: Equatable, Sendable {
    public let tagName: String
    public let name: String
    public let htmlUrl: URL
    public let body: String?
    public let publishedAt: Date?
    public let dmgAssetUrl: URL?

    public var semanticVersion: SemanticVersion {
        SemanticVersion(tagName)
    }

    public init(
        tagName: String,
        name: String,
        htmlUrl: URL,
        body: String? = nil,
        publishedAt: Date? = nil,
        dmgAssetUrl: URL? = nil
    ) {
        self.tagName = tagName
        self.name = name
        self.htmlUrl = htmlUrl
        self.body = body
        self.publishedAt = publishedAt
        self.dmgAssetUrl = dmgAssetUrl
    }
}

/// Raw GitHub API response DTO.
private struct GitHubReleaseDTO: Codable {
    let tagName: String
    let name: String?
    let htmlUrl: URL
    let body: String?
    let publishedAt: Date?
    let assets: [GitHubReleaseAsset]?

    enum CodingKeys: String, CodingKey {
        case tagName = "tag_name"
        case name
        case htmlUrl = "html_url"
        case body
        case publishedAt = "published_at"
        case assets
    }

    func toReleaseInfo() -> GitHubReleaseInfo {
        let dmgUrl = assets?.first(where: { $0.name.lowercased().hasSuffix(".dmg") })?.browserDownloadUrl
        return GitHubReleaseInfo(
            tagName: tagName,
            name: name ?? tagName,
            htmlUrl: htmlUrl,
            body: body,
            publishedAt: publishedAt,
            dmgAssetUrl: dmgUrl
        )
    }
}

/// Protocol abstracting the remote release checking network service for testing.
public protocol UpdateCheckingService: Sendable {
    func fetchLatestRelease() async throws -> GitHubReleaseInfo
}

/// Concrete implementation querying GitHub Releases REST API for Bitz.
public final class GitHubUpdateService: UpdateCheckingService {
    public let repository: String
    private let session: URLSession

    public init(
        repository: String = "AkramKs/bitz-releases",
        session: URLSession = .shared
    ) {
        self.repository = repository
        self.session = session
    }

    public func fetchLatestRelease() async throws -> GitHubReleaseInfo {
        guard let url = URL(string: "https://api.github.com/repos/\(repository)/releases/latest") else {
            throw URLError(.badURL)
        }
        var request = URLRequest(url: url)
        request.setValue("Bitz-Mac-App", forHTTPHeaderField: "User-Agent")
        request.setValue("application/vnd.github.v3+json", forHTTPHeaderField: "Accept")
        request.timeoutInterval = 10.0

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
            throw URLError(.badServerResponse)
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let dto = try decoder.decode(GitHubReleaseDTO.self, from: data)
        return dto.toReleaseInfo()
    }
}

/// `@MainActor` observable store managing application update status,
/// background check schedules, speech bubble notifications, and `UserDefaults` preferences.
@MainActor
public final class AppUpdateStore: ObservableObject {
    public static let autoCheckUserDefaultsKey = "bitzAutoCheckForUpdates"
    public static let skippedVersionUserDefaultsKey = "bitzSkippedVersionTag"
    public static let lastCheckDateUserDefaultsKey = "bitzLastUpdateCheckDate"

    @Published public private(set) var currentVersion: SemanticVersion
    @Published public private(set) var latestRelease: GitHubReleaseInfo?
    @Published public private(set) var isUpdateAvailable: Bool = false
    @Published public private(set) var isChecking: Bool = false
    @Published public private(set) var lastCheckDate: Date?
    @Published public private(set) var statusMessage: String = ""
    @Published public var isSpeechBubbleAlertActive: Bool = false
    @Published public var automaticallyCheckForUpdates: Bool {
        didSet {
            userDefaults.set(automaticallyCheckForUpdates, forKey: Self.autoCheckUserDefaultsKey)
        }
    }
    @Published public var skippedVersionTag: String? {
        didSet {
            if let skippedVersionTag {
                userDefaults.set(skippedVersionTag, forKey: Self.skippedVersionUserDefaultsKey)
            } else {
                userDefaults.removeObject(forKey: Self.skippedVersionUserDefaultsKey)
            }
        }
    }

    private let updateService: any UpdateCheckingService
    private let userDefaults: UserDefaults
    private var autoCheckTask: Task<Void, Never>?

    public var currentVersionString: String {
        currentVersion.description
    }

    public var latestVersionString: String {
        latestRelease?.semanticVersion.description ?? ""
    }

    public var updateBannerText: String {
        guard let latestRelease else { return "" }
        return "UPDATE READY: v\(latestRelease.semanticVersion) 🚀"
    }

    public init(
        currentVersionString: String? = nil,
        updateService: any UpdateCheckingService = GitHubUpdateService(),
        userDefaults: UserDefaults = .standard
    ) {
        self.updateService = updateService
        self.userDefaults = userDefaults

        let resolvedVersion: String
        if let currentVersionString {
            resolvedVersion = currentVersionString
        } else if let bundleVersion = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String {
            resolvedVersion = bundleVersion
        } else {
            resolvedVersion = "1.3.2"
        }
        self.currentVersion = SemanticVersion(resolvedVersion)

        let autoCheckObj = userDefaults.object(forKey: Self.autoCheckUserDefaultsKey)
        self.automaticallyCheckForUpdates = (autoCheckObj as? Bool) ?? true

        self.skippedVersionTag = userDefaults.string(forKey: Self.skippedVersionUserDefaultsKey)
        if let timestamp = userDefaults.object(forKey: Self.lastCheckDateUserDefaultsKey) as? Date {
            self.lastCheckDate = timestamp
        }

        self.statusMessage = "v\(self.currentVersionString)"
    }

    /// Checks for updates against the GitHub Releases API.
    /// - Parameter manual: If true, ignores `automaticallyCheckForUpdates` preference and updates `statusMessage` on completion.
    public func checkForUpdates(manual: Bool = false) async {
        guard manual || automaticallyCheckForUpdates else { return }
        guard !isChecking else { return }

        isChecking = true
        let previousStatusMessage = statusMessage
        statusMessage = "Checking for updates..."

        do {
            let release = try await updateService.fetchLatestRelease()
            latestRelease = release
            lastCheckDate = Date()
            userDefaults.set(lastCheckDate, forKey: Self.lastCheckDateUserDefaultsKey)

            if release.semanticVersion > currentVersion {
                isUpdateAvailable = true
                statusMessage = "Update v\(release.semanticVersion) available"

                // Show mascot speech bubble unless the user previously skipped this tag
                if skippedVersionTag != release.tagName {
                    isSpeechBubbleAlertActive = true
                }
            } else {
                isUpdateAvailable = false
                isSpeechBubbleAlertActive = false
                statusMessage = "You're on the latest version (v\(currentVersionString))"
            }
        } catch {
            // A silent background failure must not leave "Checking for updates..." showing in the menu (#94)
            statusMessage = manual ? "Could not check for updates" : previousStatusMessage
        }

        isChecking = false
    }

    /// Dismisses the mascot speech bubble notification without skipping future reminders.
    public func dismissAlert() {
        isSpeechBubbleAlertActive = false
    }

    /// Skips the currently detected update tag so it won't trigger notification alerts again.
    public func skipCurrentUpdate() {
        if let tag = latestRelease?.tagName {
            skippedVersionTag = tag
        }
        isSpeechBubbleAlertActive = false
    }

    /// Opens the latest release webpage or `.dmg` asset download in the default browser.
    public func openDownloadPage() {
        guard let url = latestRelease?.dmgAssetUrl ?? latestRelease?.htmlUrl else { return }
        NSWorkspace.shared.open(url)
        isSpeechBubbleAlertActive = false
    }

    /// Opens the full GitHub release notes webpage in the default browser.
    public func openReleaseNotes() {
        guard let url = latestRelease?.htmlUrl else { return }
        NSWorkspace.shared.open(url)
    }

    /// Schedules an initial delayed background update check (5 seconds after launch)
    /// and periodic background checks every 24 hours.
    public func startPeriodicChecks(interval: TimeInterval = 86400, delaySeconds: TimeInterval = 5.0) {
        autoCheckTask?.cancel()
        autoCheckTask = Task { @MainActor [weak self] in
            if delaySeconds > 0 {
                try? await Task.sleep(nanoseconds: UInt64(delaySeconds * 1_000_000_000))
            }
            guard !Task.isCancelled, let self else { return }
            await self.checkForUpdates(manual: false)

            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))
                guard !Task.isCancelled else { break }
                await self.checkForUpdates(manual: false)
            }
        }
    }

    public func stopPeriodicChecks() {
        autoCheckTask?.cancel()
        autoCheckTask = nil
    }
}
