import Foundation

/// `@MainActor` observable store managing user preferences and rate quotas for the On-Device AI Personality feature.
///
/// Follows the established Bitz store architecture, backed by `UserDefaults` with isolated suite support
/// for fully deterministic unit testing.
///
/// Defaults to **OFF** (`isEnabled = false`) to guarantee zero behavioral deviation or resource usage
/// until explicitly opted in by the user.
@MainActor
public final class PersonalitySettingsStore: ObservableObject {
    public static let keyPrefix = "bitz.personality."
    public static let isEnabledKey = "\(keyPrefix)isEnabled"
    public static let presetKey = "\(keyPrefix)preset"
    public static let minIntervalMinutesKey = "\(keyPrefix)minIntervalMinutes"
    public static let dailyCapKey = "\(keyPrefix)dailyCap"
    public static let watchedRepoPathsKey = "\(keyPrefix)watchedRepoPaths"
    public static let commentsGeneratedTodayKey = "\(keyPrefix)commentsGeneratedToday"
    public static let lastRecordedDateKey = "\(keyPrefix)lastRecordedDate"

    public static let defaultMinIntervalMinutes: Int = 10
    public static let defaultDailyCap: Int = 20

    @Published public private(set) var isEnabled: Bool
    @Published public private(set) var preset: PersonalityPreset
    @Published public private(set) var minIntervalMinutes: Int
    @Published public private(set) var dailyCap: Int
    @Published public private(set) var watchedRepoPaths: [String]
    @Published public private(set) var commentsGeneratedToday: Int

    private let userDefaults: UserDefaults
    private let calendar: Calendar
    public var onSettingsChanged: (() -> Void)?

    public init(userDefaults: UserDefaults = .standard, calendar: Calendar = .current) {
        self.userDefaults = userDefaults
        self.calendar = calendar

        // Master toggle: defaults to false (OFF)
        self.isEnabled = userDefaults.bool(forKey: Self.isEnabledKey)

        // Preset: defaults to .snarky
        if let rawPreset = userDefaults.string(forKey: Self.presetKey),
           let savedPreset = PersonalityPreset(rawValue: rawPreset) {
            self.preset = savedPreset
        } else {
            self.preset = .snarky
        }

        // Minimum interval minutes
        let savedInterval = userDefaults.integer(forKey: Self.minIntervalMinutesKey)
        self.minIntervalMinutes = savedInterval > 0 ? savedInterval : Self.defaultMinIntervalMinutes

        // Daily cap
        let savedCap = userDefaults.integer(forKey: Self.dailyCapKey)
        self.dailyCap = savedCap > 0 ? savedCap : Self.defaultDailyCap

        // Watched repositories
        self.watchedRepoPaths = userDefaults.stringArray(forKey: Self.watchedRepoPathsKey) ?? []

        // Daily comments count
        self.commentsGeneratedToday = userDefaults.integer(forKey: Self.commentsGeneratedTodayKey)

        // Check if date has rolled over since last run
        self.normalizeDailyCounter(for: Date())
    }

    // MARK: - Mutators

    public func setEnabled(_ enabled: Bool) {
        guard isEnabled != enabled else { return }
        isEnabled = enabled
        userDefaults.set(enabled, forKey: Self.isEnabledKey)
        onSettingsChanged?()
    }

    public func setPreset(_ newPreset: PersonalityPreset) {
        guard preset != newPreset else { return }
        preset = newPreset
        userDefaults.set(newPreset.rawValue, forKey: Self.presetKey)
        onSettingsChanged?()
    }

    public func setMinIntervalMinutes(_ minutes: Int) {
        let clamped = max(1, min(180, minutes))
        guard minIntervalMinutes != clamped else { return }
        minIntervalMinutes = clamped
        userDefaults.set(clamped, forKey: Self.minIntervalMinutesKey)
        onSettingsChanged?()
    }

    public func setDailyCap(_ cap: Int) {
        let clamped = max(1, min(500, cap))
        guard dailyCap != clamped else { return }
        dailyCap = clamped
        userDefaults.set(clamped, forKey: Self.dailyCapKey)
        onSettingsChanged?()
    }

    public func setWatchedRepoPaths(_ paths: [String]) {
        let unique = Array(Set(paths)).sorted()
        guard watchedRepoPaths != unique else { return }
        watchedRepoPaths = unique
        userDefaults.set(unique, forKey: Self.watchedRepoPathsKey)
        onSettingsChanged?()
    }

    public func addWatchedRepoPath(_ path: String) {
        guard !watchedRepoPaths.contains(path) else { return }
        var updated = watchedRepoPaths
        updated.append(path)
        setWatchedRepoPaths(updated)
    }

    public func removeWatchedRepoPath(_ path: String) {
        var updated = watchedRepoPaths
        updated.removeAll { $0 == path }
        setWatchedRepoPaths(updated)
    }

    // MARK: - Quota Management

    /// Normalizes the daily counter against the current local calendar day.
    public func normalizeDailyCounter(for date: Date = Date()) {
        let todayString = dateKey(for: date)
        let lastDateString = userDefaults.string(forKey: Self.lastRecordedDateKey)

        if lastDateString != todayString {
            commentsGeneratedToday = 0
            userDefaults.set(0, forKey: Self.commentsGeneratedTodayKey)
            userDefaults.set(todayString, forKey: Self.lastRecordedDateKey)
        }
    }

    /// Returns `true` if the daily quota allows another comment generation.
    public func canGenerateCommentToday(for date: Date = Date()) -> Bool {
        normalizeDailyCounter(for: date)
        return commentsGeneratedToday < dailyCap
    }

    /// Increments the comment counter for today.
    public func recordCommentGenerated(on date: Date = Date()) {
        normalizeDailyCounter(for: date)
        commentsGeneratedToday += 1
        userDefaults.set(commentsGeneratedToday, forKey: Self.commentsGeneratedTodayKey)
        onSettingsChanged?()
    }

    public func resetDailyCounter() {
        commentsGeneratedToday = 0
        userDefaults.set(0, forKey: Self.commentsGeneratedTodayKey)
        onSettingsChanged?()
    }

    private func dateKey(for date: Date) -> String {
        let components = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", components.year ?? 0, components.month ?? 0, components.day ?? 0)
    }
}
