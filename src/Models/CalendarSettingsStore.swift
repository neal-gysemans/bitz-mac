import Foundation

/// `@MainActor` observable preferences store for the macOS Calendar Agenda & Meeting Alerts feature (#186).
///
/// Follows the established Bitz store architecture, backed by `UserDefaults` with isolated suite support
/// for fully deterministic unit testing.
///
/// Defaults to **OFF** (`isEnabled = false`) to guarantee zero behavioral deviation or resource usage
/// until explicitly opted in by the user.
@MainActor
public final class CalendarSettingsStore: ObservableObject {
    public static let keyPrefix = "bitz.calendar."
    public static let isEnabledKey = "\(keyPrefix)isEnabled"
    public static let reminderOffsetMinutesKey = "\(keyPrefix)reminderOffsetMinutes"
    public static let isMorningBriefEnabledKey = "\(keyPrefix)isMorningBriefEnabled"
    public static let isEveningPreviewEnabledKey = "\(keyPrefix)isEveningPreviewEnabled"
    public static let showMeetingURLQuickJoinKey = "\(keyPrefix)showMeetingURLQuickJoin"

    public static let defaultReminderOffsetMinutes: Int = 10
    public static let allowedReminderOffsets: [Int] = [5, 10, 15]

    @Published public private(set) var isEnabled: Bool
    @Published public private(set) var reminderOffsetMinutes: Int
    @Published public private(set) var isMorningBriefEnabled: Bool
    @Published public private(set) var isEveningPreviewEnabled: Bool
    @Published public private(set) var showMeetingURLQuickJoin: Bool

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

        // Reminder offset in minutes
        let savedOffset = userDefaults.integer(forKey: Self.reminderOffsetMinutesKey)
        self.reminderOffsetMinutes = savedOffset > 0 ? savedOffset : Self.defaultReminderOffsetMinutes

        // Morning brief: defaults to true
        if userDefaults.object(forKey: Self.isMorningBriefEnabledKey) != nil {
            self.isMorningBriefEnabled = userDefaults.bool(forKey: Self.isMorningBriefEnabledKey)
        } else {
            self.isMorningBriefEnabled = true
        }

        // Evening preview: defaults to true
        if userDefaults.object(forKey: Self.isEveningPreviewEnabledKey) != nil {
            self.isEveningPreviewEnabled = userDefaults.bool(forKey: Self.isEveningPreviewEnabledKey)
        } else {
            self.isEveningPreviewEnabled = true
        }

        // 1-Click Join button: defaults to true
        if userDefaults.object(forKey: Self.showMeetingURLQuickJoinKey) != nil {
            self.showMeetingURLQuickJoin = userDefaults.bool(forKey: Self.showMeetingURLQuickJoinKey)
        } else {
            self.showMeetingURLQuickJoin = true
        }
    }

    // MARK: - Mutators

    public func setEnabled(_ enabled: Bool) {
        isEnabled = enabled
        userDefaults.set(enabled, forKey: Self.isEnabledKey)
        onSettingsChanged?()
    }

    public func setReminderOffsetMinutes(_ minutes: Int) {
        let sanitized = max(1, min(60, minutes))
        reminderOffsetMinutes = sanitized
        userDefaults.set(sanitized, forKey: Self.reminderOffsetMinutesKey)
        onSettingsChanged?()
    }

    public func setMorningBriefEnabled(_ enabled: Bool) {
        isMorningBriefEnabled = enabled
        userDefaults.set(enabled, forKey: Self.isMorningBriefEnabledKey)
        onSettingsChanged?()
    }

    public func setEveningPreviewEnabled(_ enabled: Bool) {
        isEveningPreviewEnabled = enabled
        userDefaults.set(enabled, forKey: Self.isEveningPreviewEnabledKey)
        onSettingsChanged?()
    }

    public func setShowMeetingURLQuickJoin(_ show: Bool) {
        showMeetingURLQuickJoin = show
        userDefaults.set(show, forKey: Self.showMeetingURLQuickJoinKey)
        onSettingsChanged?()
    }
}
