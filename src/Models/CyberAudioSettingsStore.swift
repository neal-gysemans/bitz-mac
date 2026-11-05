import Foundation

/// `@MainActor` observable store managing user preferences for the Cyber Audio system.
///
/// Follows the established Bitz store pattern (like `AvatarOpacityStore` and `DisplayPreferenceStore`),
/// backed by `UserDefaults` with isolated suite support for deterministic testing.
///
/// Defaults to **OFF** (`isEnabled = false`) to guarantee zero unwanted noise for existing users.
@MainActor
public final class CyberAudioSettingsStore: ObservableObject {
    public static let keyPrefix = "bitz.audio."
    public static let isEnabledKey = "\(keyPrefix)isEnabled"
    public static let volumeKey = "\(keyPrefix)volume"
    public static let isPurrEnabledKey = "\(keyPrefix)isPurrEnabled"
    public static let isBurnoutEnabledKey = "\(keyPrefix)isBurnoutEnabled"
    public static let isOverheatEnabledKey = "\(keyPrefix)isOverheatEnabled"
    public static let isChargingEnabledKey = "\(keyPrefix)isChargingEnabled"
    public static let isAgentChimeEnabledKey = "\(keyPrefix)isAgentChimeEnabled"
    public static let isAllDoneFanfareEnabledKey = "\(keyPrefix)isAllDoneFanfareEnabled"
    public static let isMeetingStartChimeEnabledKey = "\(keyPrefix)isMeetingStartChimeEnabled"
    public static let isMeetingSavedChimeEnabledKey = "\(keyPrefix)isMeetingSavedChimeEnabled"
    public static let isFocusDNDSuppressionEnabledKey = "\(keyPrefix)isFocusDNDSuppressionEnabled"
    // New key so the default-on value every earlier install persisted no longer applies (#95)
    public static let isCallSuppressionEnabledKey = "\(keyPrefix)isMicInUseSuppressionEnabled"

    public static let defaultVolume: Double = 0.30
    public static let minVolume: Double = 0.00
    public static let maxVolume: Double = 1.00

    @Published public private(set) var isEnabled: Bool
    @Published public private(set) var volume: Double
    @Published public private(set) var isPurrEnabled: Bool
    @Published public private(set) var isBurnoutEnabled: Bool
    @Published public private(set) var isOverheatEnabled: Bool
    @Published public private(set) var isChargingEnabled: Bool
    @Published public private(set) var isAgentChimeEnabled: Bool
    @Published public private(set) var isAllDoneFanfareEnabled: Bool
    @Published public private(set) var isMeetingStartChimeEnabled: Bool
    @Published public private(set) var isMeetingSavedChimeEnabled: Bool
    @Published public private(set) var isFocusDNDSuppressionEnabled: Bool
    @Published public private(set) var isCallSuppressionEnabled: Bool

    private let userDefaults: UserDefaults
    public var onSettingsChanged: (() -> Void)?

    public init(userDefaults: UserDefaults = .standard) {
        self.userDefaults = userDefaults

        // Master toggle: default OFF (false)
        if userDefaults.object(forKey: Self.isEnabledKey) != nil {
            self.isEnabled = userDefaults.bool(forKey: Self.isEnabledKey)
        } else {
            self.isEnabled = false
            userDefaults.set(false, forKey: Self.isEnabledKey)
        }

        // Volume: default 0.30 (30%)
        if let storedVolumeObj = userDefaults.object(forKey: Self.volumeKey) {
            let raw = (storedVolumeObj as? Double) ?? userDefaults.double(forKey: Self.volumeKey)
            self.volume = Self.sanitizeVolume(raw)
        } else {
            self.volume = Self.defaultVolume
            userDefaults.set(Self.defaultVolume, forKey: Self.volumeKey)
        }

        // Per-event toggles: default ON (true) once master audio is enabled
        self.isPurrEnabled = Self.readBool(userDefaults, key: Self.isPurrEnabledKey, defaultVal: true)
        self.isBurnoutEnabled = Self.readBool(userDefaults, key: Self.isBurnoutEnabledKey, defaultVal: true)
        self.isOverheatEnabled = Self.readBool(userDefaults, key: Self.isOverheatEnabledKey, defaultVal: true)
        self.isChargingEnabled = Self.readBool(userDefaults, key: Self.isChargingEnabledKey, defaultVal: true)
        self.isAgentChimeEnabled = Self.readBool(userDefaults, key: Self.isAgentChimeEnabledKey, defaultVal: true)
        self.isAllDoneFanfareEnabled = Self.readBool(userDefaults, key: Self.isAllDoneFanfareEnabledKey, defaultVal: true)
        self.isMeetingStartChimeEnabled = Self.readBool(userDefaults, key: Self.isMeetingStartChimeEnabledKey, defaultVal: true)
        self.isMeetingSavedChimeEnabled = Self.readBool(userDefaults, key: Self.isMeetingSavedChimeEnabledKey, defaultVal: true)
        self.isFocusDNDSuppressionEnabled = Self.readBool(userDefaults, key: Self.isFocusDNDSuppressionEnabledKey, defaultVal: true)
        // Opt-in: any app holding the mic open (not just calls) would otherwise mute every sound (#95)
        self.isCallSuppressionEnabled = Self.readBool(userDefaults, key: Self.isCallSuppressionEnabledKey, defaultVal: false)
    }

    private static func readBool(_ defaults: UserDefaults, key: String, defaultVal: Bool) -> Bool {
        if defaults.object(forKey: key) != nil {
            return defaults.bool(forKey: key)
        } else {
            defaults.set(defaultVal, forKey: key)
            return defaultVal
        }
    }

    public static func sanitizeVolume(_ rawValue: Double) -> Double {
        guard !rawValue.isNaN else {
            return defaultVolume
        }
        if rawValue.isInfinite {
            return rawValue > 0 ? maxVolume : minVolume
        }
        let clamped = min(max(rawValue, minVolume), maxVolume)
        return (clamped * 100.0).rounded() / 100.0
    }

    public var volumePercentageInt: Int {
        Int((volume * 100.0).rounded())
    }

    public var formattedVolumeSummary: String {
        "\(volumePercentageInt)%"
    }

    public func setEnabled(_ enabled: Bool) {
        isEnabled = enabled
        userDefaults.set(enabled, forKey: Self.isEnabledKey)
        onSettingsChanged?()
    }

    public func setVolume(_ newVolume: Double) {
        let sanitized = Self.sanitizeVolume(newVolume)
        volume = sanitized
        userDefaults.set(sanitized, forKey: Self.volumeKey)
        onSettingsChanged?()
    }

    public func setPurrEnabled(_ enabled: Bool) {
        isPurrEnabled = enabled
        userDefaults.set(enabled, forKey: Self.isPurrEnabledKey)
        onSettingsChanged?()
    }

    public func setBurnoutEnabled(_ enabled: Bool) {
        isBurnoutEnabled = enabled
        userDefaults.set(enabled, forKey: Self.isBurnoutEnabledKey)
        onSettingsChanged?()
    }

    public func setOverheatEnabled(_ enabled: Bool) {
        isOverheatEnabled = enabled
        userDefaults.set(enabled, forKey: Self.isOverheatEnabledKey)
        onSettingsChanged?()
    }

    public func setChargingEnabled(_ enabled: Bool) {
        isChargingEnabled = enabled
        userDefaults.set(enabled, forKey: Self.isChargingEnabledKey)
        onSettingsChanged?()
    }

    public func setAgentChimeEnabled(_ enabled: Bool) {
        isAgentChimeEnabled = enabled
        userDefaults.set(enabled, forKey: Self.isAgentChimeEnabledKey)
        onSettingsChanged?()
    }

    public func setAllDoneFanfareEnabled(_ enabled: Bool) {
        isAllDoneFanfareEnabled = enabled
        userDefaults.set(enabled, forKey: Self.isAllDoneFanfareEnabledKey)
        onSettingsChanged?()
    }

    public func setMeetingStartChimeEnabled(_ enabled: Bool) {
        isMeetingStartChimeEnabled = enabled
        userDefaults.set(enabled, forKey: Self.isMeetingStartChimeEnabledKey)
        onSettingsChanged?()
    }

    public func setMeetingSavedChimeEnabled(_ enabled: Bool) {
        isMeetingSavedChimeEnabled = enabled
        userDefaults.set(enabled, forKey: Self.isMeetingSavedChimeEnabledKey)
        onSettingsChanged?()
    }

    public func setFocusDNDSuppressionEnabled(_ enabled: Bool) {
        isFocusDNDSuppressionEnabled = enabled
        userDefaults.set(enabled, forKey: Self.isFocusDNDSuppressionEnabledKey)
        onSettingsChanged?()
    }

    public func setCallSuppressionEnabled(_ enabled: Bool) {
        isCallSuppressionEnabled = enabled
        userDefaults.set(enabled, forKey: Self.isCallSuppressionEnabledKey)
        onSettingsChanged?()
    }

    public func isEventEnabled(_ event: CyberSoundEvent) -> Bool {
        guard isEnabled else { return false }
        switch event {
        case .purr:
            return isPurrEnabled
        case .burnout:
            return isBurnoutEnabled
        case .overheating:
            return isOverheatEnabled
        case .charging:
            return isChargingEnabled
        case .agentNeedsApproval:
            return isAgentChimeEnabled
        case .allAgentsDone:
            return isAllDoneFanfareEnabled
        case .meetingRecordingStarted:
            return isMeetingStartChimeEnabled
        case .meetingRecordingSaved:
            return isMeetingSavedChimeEnabled
        }
    }

    public func setEventEnabled(_ event: CyberSoundEvent, enabled: Bool) {
        switch event {
        case .purr:
            setPurrEnabled(enabled)
        case .burnout:
            setBurnoutEnabled(enabled)
        case .overheating:
            setOverheatEnabled(enabled)
        case .charging:
            setChargingEnabled(enabled)
        case .agentNeedsApproval:
            setAgentChimeEnabled(enabled)
        case .allAgentsDone:
            setAllDoneFanfareEnabled(enabled)
        case .meetingRecordingStarted:
            setMeetingStartChimeEnabled(enabled)
        case .meetingRecordingSaved:
            setMeetingSavedChimeEnabled(enabled)
        }
    }
}
