import Foundation

/// `@MainActor` observable preferences store for Auto Flow-State Shield (`#22`).
///
/// Strictly opt-in (`isEnabled = false` by default) so existing users experience zero
/// unexpected macOS Shortcut executions out of the box.
@MainActor
public final class FlowShieldSettingsStore: ObservableObject {
    public static let keyPrefix = "bitz.flowShield."
    public static let isEnabledKey = "\(keyPrefix)isEnabled"
    public static let streakMinutesThresholdKey = "\(keyPrefix)streakMinutesThreshold"
    public static let startFocusShortcutNameKey = "\(keyPrefix)startFocusShortcutName"
    public static let stopFocusShortcutNameKey = "\(keyPrefix)stopFocusShortcutName"
    public static let isBreakShieldOverrideActiveKey = "\(keyPrefix)isBreakShieldOverrideActive"

    public static let defaultStreakMinutesThreshold: Double = 20.0
    public static let minStreakMinutesThreshold: Double = 5.0
    public static let maxStreakMinutesThreshold: Double = 120.0
    public static let defaultStartFocusShortcutName = "Start Focus"
    public static let defaultStopFocusShortcutName = "Stop Focus"

    @Published public private(set) var isEnabled: Bool
    @Published public private(set) var streakMinutesThreshold: Double
    @Published public private(set) var startFocusShortcutName: String
    @Published public private(set) var stopFocusShortcutName: String
    @Published public private(set) var isBreakShieldOverrideActive: Bool

    private let userDefaults: UserDefaults
    public var onSettingsChanged: (() -> Void)?

    public init(userDefaults: UserDefaults = .standard) {
        self.userDefaults = userDefaults

        if userDefaults.object(forKey: Self.isEnabledKey) != nil {
            self.isEnabled = userDefaults.bool(forKey: Self.isEnabledKey)
        } else {
            self.isEnabled = false
        }

        if let storedThresholdObj = userDefaults.object(forKey: Self.streakMinutesThresholdKey) {
            let raw = (storedThresholdObj as? Double) ?? userDefaults.double(forKey: Self.streakMinutesThresholdKey)
            self.streakMinutesThreshold = Self.sanitizeStreakMinutes(raw)
        } else {
            self.streakMinutesThreshold = Self.defaultStreakMinutesThreshold
        }

        if let storedStart = userDefaults.string(forKey: Self.startFocusShortcutNameKey) {
            self.startFocusShortcutName = Self.sanitizeShortcutName(
                storedStart,
                fallback: Self.defaultStartFocusShortcutName
            )
        } else {
            self.startFocusShortcutName = Self.defaultStartFocusShortcutName
        }

        if let storedStop = userDefaults.string(forKey: Self.stopFocusShortcutNameKey) {
            self.stopFocusShortcutName = Self.sanitizeShortcutName(
                storedStop,
                fallback: Self.defaultStopFocusShortcutName
            )
        } else {
            self.stopFocusShortcutName = Self.defaultStopFocusShortcutName
        }

        if userDefaults.object(forKey: Self.isBreakShieldOverrideActiveKey) != nil {
            self.isBreakShieldOverrideActive = userDefaults.bool(forKey: Self.isBreakShieldOverrideActiveKey)
        } else {
            self.isBreakShieldOverrideActive = false
        }
    }

    public static func sanitizeStreakMinutes(_ rawValue: Double) -> Double {
        guard !rawValue.isNaN else {
            return defaultStreakMinutesThreshold
        }
        if rawValue.isInfinite {
            return rawValue > 0 ? maxStreakMinutesThreshold : minStreakMinutesThreshold
        }
        return min(max(rawValue, minStreakMinutesThreshold), maxStreakMinutesThreshold)
    }

    public static func sanitizeShortcutName(_ rawValue: String, fallback: String) -> String {
        let trimmed = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? fallback : trimmed
    }

    public var streakMinutesInt: Int {
        Int(streakMinutesThreshold.rounded())
    }

    public var formattedStreakSummary: String {
        "\(streakMinutesInt) min"
    }

    public func setEnabled(_ enabled: Bool) {
        let wasDisabled = !isEnabled
        isEnabled = enabled
        userDefaults.set(enabled, forKey: Self.isEnabledKey)
        // Starting a fresh opted-in session clears any stale manual Break Shield override.
        if enabled && wasDisabled && isBreakShieldOverrideActive {
            isBreakShieldOverrideActive = false
            userDefaults.set(false, forKey: Self.isBreakShieldOverrideActiveKey)
        }
        onSettingsChanged?()
    }

    public func setStreakMinutesThreshold(_ minutes: Double) {
        let sanitized = Self.sanitizeStreakMinutes(minutes)
        streakMinutesThreshold = sanitized
        userDefaults.set(sanitized, forKey: Self.streakMinutesThresholdKey)
        onSettingsChanged?()
    }

    public func setStartFocusShortcutName(_ name: String) {
        let sanitized = Self.sanitizeShortcutName(name, fallback: Self.defaultStartFocusShortcutName)
        startFocusShortcutName = sanitized
        userDefaults.set(sanitized, forKey: Self.startFocusShortcutNameKey)
        onSettingsChanged?()
    }

    public func setStopFocusShortcutName(_ name: String) {
        let sanitized = Self.sanitizeShortcutName(name, fallback: Self.defaultStopFocusShortcutName)
        stopFocusShortcutName = sanitized
        userDefaults.set(sanitized, forKey: Self.stopFocusShortcutNameKey)
        onSettingsChanged?()
    }

    public func setBreakShieldOverrideActive(_ active: Bool) {
        isBreakShieldOverrideActive = active
        userDefaults.set(active, forKey: Self.isBreakShieldOverrideActiveKey)
        onSettingsChanged?()
    }
}
