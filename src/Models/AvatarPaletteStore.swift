import Foundation

/// `@MainActor` store for the mascot theme: preset selection, per-slot overrides, glow, and the live
/// "Preview Emotion" simulator. Persisted in `UserDefaults`.
@MainActor
public final class AvatarPaletteStore: ObservableObject {
    public static let themeIdKey = "avatarSelectedThemeId"
    public static let chassisKey = "avatarChassisHexOverride"
    public static let trimKey = "avatarTrimHexOverride"
    public static let glowKey = "avatarGlowIntensity"
    public static let emotionOverridesKey = "avatarEmotionHexOverrides"

    private let userDefaults: UserDefaults
    private let licensingService: (any LicensingServiceProtocol)?

    @Published public private(set) var selectedPreset: AvatarThemePreset
    @Published public private(set) var chassisOverride: String?
    @Published public private(set) var trimOverride: String?
    @Published public private(set) var glowIntensity: Double
    @Published public private(set) var emotionOverrides: [AvatarEmotionColorSlot: String]
    /// Slot currently being previewed on the mascot (auto-clears).
    @Published public private(set) var previewSlot: AvatarEmotionColorSlot?
    @Published public private(set) var resolvedPalette: AvatarResolvedPalette

    private var previewTask: Task<Void, Never>?

    public init(
        userDefaults: UserDefaults = .standard,
        licensingService: (any LicensingServiceProtocol)? = nil
    ) {
        self.userDefaults = userDefaults
        self.licensingService = licensingService
        var preset = userDefaults.string(forKey: Self.themeIdKey).flatMap(AvatarThemePreset.init(rawValue:)) ?? .defaultPreset
        var chassis = userDefaults.string(forKey: Self.chassisKey).flatMap(AvatarHex.normalize)
        var trim = userDefaults.string(forKey: Self.trimKey).flatMap(AvatarHex.normalize)
        var glow: Double
        if let stored = userDefaults.object(forKey: Self.glowKey) as? Double, stored.isFinite {
            glow = min(max(stored, AvatarResolvedPalette.glowRange.lowerBound), AvatarResolvedPalette.glowRange.upperBound)
        } else {
            glow = 1.0
        }
        var overrides: [AvatarEmotionColorSlot: String] = [:]
        if let raw = userDefaults.dictionary(forKey: Self.emotionOverridesKey) as? [String: String] {
            for (key, value) in raw {
                if let slot = AvatarEmotionColorSlot(rawValue: key), let hex = AvatarHex.normalize(value) {
                    overrides[slot] = hex
                }
            }
        }

        // Gate Pro themes and custom overrides for Free tier
        if let licensingService, !licensingService.isFeatureUnlocked(.customThemes) {
            if preset.isPro {
                preset = .defaultPreset
            }
            chassis = nil
            trim = nil
            glow = 1.0
            overrides = [:]
        }

        self.selectedPreset = preset
        self.chassisOverride = chassis
        self.trimOverride = trim
        self.glowIntensity = glow
        self.emotionOverrides = overrides
        self.resolvedPalette = Self.resolve(preset: preset, chassis: chassis, trim: trim, glow: glow, overrides: overrides)
    }

    private static func resolve(
        preset: AvatarThemePreset,
        chassis: String?,
        trim: String?,
        glow: Double,
        overrides: [AvatarEmotionColorSlot: String]
    ) -> AvatarResolvedPalette {
        var palette = preset.palette
        if let chassis { palette.chassisHex = chassis }
        palette.trimHex = trim
        palette = AvatarResolvedPalette(
            chassisHex: palette.chassisHex,
            chassisDeepHex: palette.chassisDeepHex,
            trimHex: trim,
            glowIntensity: glow,
            emotionHex: palette.emotionHex.merging(overrides) { _, new in new }
        )
        return palette
    }

    private func refresh() {
        let next = Self.resolve(
            preset: selectedPreset, chassis: chassisOverride, trim: trimOverride,
            glow: glowIntensity, overrides: emotionOverrides
        )
        if next != resolvedPalette { resolvedPalette = next }
        persist()
    }

    private func persist() {
        userDefaults.set(selectedPreset.rawValue, forKey: Self.themeIdKey)
        setOrRemove(chassisOverride, key: Self.chassisKey)
        setOrRemove(trimOverride, key: Self.trimKey)
        userDefaults.set(glowIntensity, forKey: Self.glowKey)
        if emotionOverrides.isEmpty {
            userDefaults.removeObject(forKey: Self.emotionOverridesKey)
        } else {
            userDefaults.set(Dictionary(uniqueKeysWithValues: emotionOverrides.map { ($0.key.rawValue, $0.value) }),
                             forKey: Self.emotionOverridesKey)
        }
    }

    private func setOrRemove(_ value: String?, key: String) {
        if let value { userDefaults.set(value, forKey: key) } else { userDefaults.removeObject(forKey: key) }
    }

    // MARK: Mutations

    /// Selecting a preset clears all custom overrides so the preset shows exactly as designed.
    /// Returns false if preset is a Pro theme and the user has not unlocked custom themes.
    @discardableResult
    public func selectPreset(_ preset: AvatarThemePreset) -> Bool {
        if preset.isPro, let licensingService, !licensingService.isFeatureUnlocked(.customThemes) {
            return false
        }
        selectedPreset = preset
        chassisOverride = nil
        trimOverride = nil
        emotionOverrides = [:]
        glowIntensity = 1.0
        refresh()
        return true
    }

    /// Returns false (and changes nothing) when `hex` is not a valid `#RRGGBB` value or custom themes are locked.
    @discardableResult
    public func setChassisHex(_ hex: String) -> Bool {
        if let licensingService, !licensingService.isFeatureUnlocked(.customThemes) {
            return false
        }
        guard let normalized = AvatarHex.normalize(hex) else { return false }
        chassisOverride = normalized
        refresh()
        return true
    }

    @discardableResult
    public func setTrimHex(_ hex: String) -> Bool {
        if let licensingService, !licensingService.isFeatureUnlocked(.customThemes) {
            return false
        }
        guard let normalized = AvatarHex.normalize(hex) else { return false }
        trimOverride = normalized
        refresh()
        return true
    }

    public func resetTrim() {
        trimOverride = nil
        refresh()
    }

    public func resetChassis() {
        chassisOverride = nil
        refresh()
    }

    @discardableResult
    public func setGlowIntensity(_ value: Double) -> Bool {
        if let licensingService, !licensingService.isFeatureUnlocked(.customThemes) {
            return false
        }
        guard value.isFinite else { return false }
        glowIntensity = min(max(value, AvatarResolvedPalette.glowRange.lowerBound), AvatarResolvedPalette.glowRange.upperBound)
        refresh()
        return true
    }

    @discardableResult
    public func setEmotionHex(_ hex: String, for slot: AvatarEmotionColorSlot) -> Bool {
        if let licensingService, !licensingService.isFeatureUnlocked(.customThemes) {
            return false
        }
        guard let normalized = AvatarHex.normalize(hex) else { return false }
        emotionOverrides[slot] = normalized
        refresh()
        return true
    }

    /// Re-evaluates tier entitlement (e.g. after license activation or deactivation).
    public func validateTierEntitlement() {
        guard let licensingService, !licensingService.isFeatureUnlocked(.customThemes) else { return }
        if selectedPreset.isPro {
            selectedPreset = .defaultPreset
        }
        chassisOverride = nil
        trimOverride = nil
        glowIntensity = 1.0
        emotionOverrides = [:]
        refresh()
    }

    /// Row reset: returns the slot to the active preset's color.
    public func resetSlot(_ slot: AvatarEmotionColorSlot) {
        emotionOverrides[slot] = nil
        refresh()
    }

    public func isSlotCustomized(_ slot: AvatarEmotionColorSlot) -> Bool {
        emotionOverrides[slot] != nil
    }

    /// Master reset back to Cyberpunk Classic with no overrides.
    public func resetToDefaultTheme() {
        selectPreset(.defaultPreset)
    }

    // MARK: Preview simulator

    /// Shows `slot` on the mascot for `duration` seconds, then returns to the live engine state.
    public func triggerPreview(for slot: AvatarEmotionColorSlot, duration: TimeInterval = 4.0) {
        previewSlot = slot
        previewTask?.cancel()
        previewTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(duration))
            guard !Task.isCancelled else { return }
            self?.previewSlot = nil
        }
    }

    public func cancelPreview() {
        previewTask?.cancel()
        previewTask = nil
        previewSlot = nil
    }
}
