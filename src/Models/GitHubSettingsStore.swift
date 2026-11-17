import Foundation

/// `@MainActor` observable preferences store for GitHub Notifications & PR/CI Watcher (#188).
///
/// Follows the established Bitz store architecture, backed by `UserDefaults` with isolated suite support
/// for fully deterministic unit testing.
///
/// Defaults to **OFF** (`isEnabled = false`) to guarantee zero network traffic or battery impact
/// until explicitly enabled by the user.
@MainActor
public final class GitHubSettingsStore: ObservableObject {
    public static let keyPrefix = "bitz.github."
    public static let isEnabledKey = "\(keyPrefix)isEnabled"
    public static let authModeKey = "\(keyPrefix)authMode"
    public static let pollIntervalSecondsKey = "\(keyPrefix)pollIntervalSeconds"
    public static let notifyReviewRequestsKey = "\(keyPrefix)notifyReviewRequests"
    public static let notifyCIFailuresKey = "\(keyPrefix)notifyCIFailures"
    public static let notifyCIPassesKey = "\(keyPrefix)notifyCIPasses"
    public static let notifyPRStatusKey = "\(keyPrefix)notifyPRStatus"
    public static let notifyGitActivityKey = "\(keyPrefix)notifyGitActivity"

    public static let defaultPollIntervalSeconds: Int = 60
    public static let allowedPollIntervals: [Int] = [30, 60, 120]

    @Published public private(set) var isEnabled: Bool
    @Published public private(set) var authMode: GitHubAuthMode
    @Published public private(set) var pollIntervalSeconds: Int
    @Published public private(set) var notifyReviewRequests: Bool
    @Published public private(set) var notifyCIFailures: Bool
    @Published public private(set) var notifyCIPasses: Bool
    @Published public private(set) var notifyPRStatus: Bool
    @Published public private(set) var notifyGitActivity: Bool

    private let userDefaults: UserDefaults
    public var onSettingsChanged: (() -> Void)?

    public init(userDefaults: UserDefaults = .standard) {
        self.userDefaults = userDefaults

        // Master toggle: defaults to false (OFF)
        if userDefaults.object(forKey: Self.isEnabledKey) != nil {
            self.isEnabled = userDefaults.bool(forKey: Self.isEnabledKey)
        } else {
            self.isEnabled = false
        }

        // Auth mode: defaults to .auto
        if let rawMode = userDefaults.string(forKey: Self.authModeKey),
           let mode = GitHubAuthMode(rawValue: rawMode) {
            self.authMode = mode
        } else {
            self.authMode = .auto
        }

        // Polling interval: defaults to 60s
        let savedInterval = userDefaults.integer(forKey: Self.pollIntervalSecondsKey)
        self.pollIntervalSeconds = Self.allowedPollIntervals.contains(savedInterval) ? savedInterval : Self.defaultPollIntervalSeconds

        // Review requests: defaults to true
        if userDefaults.object(forKey: Self.notifyReviewRequestsKey) != nil {
            self.notifyReviewRequests = userDefaults.bool(forKey: Self.notifyReviewRequestsKey)
        } else {
            self.notifyReviewRequests = true
        }

        // CI failures: defaults to true
        if userDefaults.object(forKey: Self.notifyCIFailuresKey) != nil {
            self.notifyCIFailures = userDefaults.bool(forKey: Self.notifyCIFailuresKey)
        } else {
            self.notifyCIFailures = true
        }

        // CI passes: defaults to true
        if userDefaults.object(forKey: Self.notifyCIPassesKey) != nil {
            self.notifyCIPasses = userDefaults.bool(forKey: Self.notifyCIPassesKey)
        } else {
            self.notifyCIPasses = true
        }

        // PR status: defaults to true
        if userDefaults.object(forKey: Self.notifyPRStatusKey) != nil {
            self.notifyPRStatus = userDefaults.bool(forKey: Self.notifyPRStatusKey)
        } else {
            self.notifyPRStatus = true
        }

        // Notify git push & activity across all repos: defaults to true
        if userDefaults.object(forKey: Self.notifyGitActivityKey) != nil {
            self.notifyGitActivity = userDefaults.bool(forKey: Self.notifyGitActivityKey)
        } else {
            self.notifyGitActivity = true
        }
    }

    // MARK: - Mutators

    public func setEnabled(_ enabled: Bool) {
        isEnabled = enabled
        userDefaults.set(enabled, forKey: Self.isEnabledKey)
        onSettingsChanged?()
    }

    public func setAuthMode(_ mode: GitHubAuthMode) {
        authMode = mode
        userDefaults.set(mode.rawValue, forKey: Self.authModeKey)
        onSettingsChanged?()
    }

    public func setPollIntervalSeconds(_ seconds: Int) {
        let sanitized = Self.allowedPollIntervals.contains(seconds) ? seconds : Self.defaultPollIntervalSeconds
        pollIntervalSeconds = sanitized
        userDefaults.set(sanitized, forKey: Self.pollIntervalSecondsKey)
        onSettingsChanged?()
    }

    public func setNotifyReviewRequests(_ enabled: Bool) {
        notifyReviewRequests = enabled
        userDefaults.set(enabled, forKey: Self.notifyReviewRequestsKey)
        onSettingsChanged?()
    }

    public func setNotifyCIFailures(_ enabled: Bool) {
        notifyCIFailures = enabled
        userDefaults.set(enabled, forKey: Self.notifyCIFailuresKey)
        onSettingsChanged?()
    }

    public func setNotifyCIPasses(_ enabled: Bool) {
        notifyCIPasses = enabled
        userDefaults.set(enabled, forKey: Self.notifyCIPassesKey)
        onSettingsChanged?()
    }

    public func setNotifyPRStatus(_ enabled: Bool) {
        notifyPRStatus = enabled
        userDefaults.set(enabled, forKey: Self.notifyPRStatusKey)
        onSettingsChanged?()
    }

    public func setNotifyGitActivity(_ enabled: Bool) {
        notifyGitActivity = enabled
        userDefaults.set(enabled, forKey: Self.notifyGitActivityKey)
        onSettingsChanged?()
    }
}
