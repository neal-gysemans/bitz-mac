import AppKit
import SwiftUI
import XCTest
@testable import BitzCore

@MainActor
final class AvatarPaletteStoreTests: XCTestCase {
    private var defaults: UserDefaults!
    private var suiteName: String!

    override func setUp() async throws {
        suiteName = "AvatarPaletteStoreTests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
    }

    override func tearDown() async throws {
        defaults.removePersistentDomain(forName: suiteName)
    }

    // MARK: - AvatarHex Tests

    func testAvatarHexNormalizationAndValidation() {
        XCTAssertEqual(AvatarHex.normalize("#00f0ff"), "#00F0FF")
        XCTAssertEqual(AvatarHex.normalize("00F0FF"), "#00F0FF")
        XCTAssertEqual(AvatarHex.normalize("  #AABBCC  "), "#AABBCC")
        XCTAssertNil(AvatarHex.normalize("12345"))
        XCTAssertNil(AvatarHex.normalize("#GGFFFF"))
        XCTAssertNil(AvatarHex.normalize("#1234567"))
        XCTAssertNil(AvatarHex.normalize(""))
    }

    func testAvatarHexRgbAndColorConversion() {
        let rgb = AvatarHex.rgb("#FF8000")
        XCTAssertNotNil(rgb)
        if let (r, g, b) = rgb {
            XCTAssertEqual(r, 1.0, accuracy: 0.01)
            XCTAssertEqual(g, 128.0 / 255.0, accuracy: 0.01)
            XCTAssertEqual(b, 0.0, accuracy: 0.01)
        }

        let hex = AvatarHex.hex(from: Color(red: 1.0, green: 0.0, blue: 0.5))
        XCTAssertEqual(hex, "#FF0080")
    }

    // MARK: - Presets & Resolved Palette Tests

    func testAllThemePresetsHaveAllEmotionSlotsDefined() {
        XCTAssertEqual(AvatarThemePreset.allCases.count, 9)
        XCTAssertEqual(AvatarThemePreset.defaultPreset, .cyberpunkClassic)

        for preset in AvatarThemePreset.allCases {
            XCTAssertFalse(preset.title.isEmpty)
            let palette = preset.palette
            XCTAssertNotNil(AvatarHex.normalize(palette.chassisHex))
            XCTAssertNotNil(AvatarHex.normalize(palette.chassisDeepHex))
            for slot in AvatarEmotionColorSlot.allCases {
                let hex = palette.hex(for: slot)
                XCTAssertNotNil(AvatarHex.normalize(hex), "\(preset.rawValue) missing valid hex for slot \(slot.rawValue)")
            }
        }
    }

    func testResolvedPaletteVisorColorAndTrim() {
        let palette = AvatarResolvedPalette.cyberpunkClassic
        // Balanced slot
        let balancedColor = palette.visorColor(for: .balanced, warningVisorActive: false)
        XCTAssertNotNil(balancedColor)

        // Warning visor active overrides to overworked unless overheating
        let warningColor = palette.visorColor(for: .balanced, warningVisorActive: true)
        let overworkedColor = palette.visorColor(for: .overworked, warningVisorActive: false)
        XCTAssertEqual(warningColor, overworkedColor)

        let overheatingWarning = palette.visorColor(for: .overheating, warningVisorActive: true)
        let overheatingNormal = palette.visorColor(for: .overheating, warningVisorActive: false)
        XCTAssertEqual(overheatingWarning, overheatingNormal)

        // Trim fallback to visor vs explicit trim
        let trimDefault = palette.trim(over: Color.cyan)
        XCTAssertEqual(trimDefault, Color.cyan)

        var customTrimPalette = palette
        customTrimPalette.trimHex = "#FF00AA"
        let trimExplicit = customTrimPalette.trim(over: Color.cyan)
        XCTAssertEqual(trimExplicit, AvatarHex.color("#FF00AA"))
    }

    // MARK: - Store Mutations & Persistence

    func testStoreInitializesWithDefaults() {
        let store = AvatarPaletteStore(userDefaults: defaults)
        XCTAssertEqual(store.selectedPreset, .cyberpunkClassic)
        XCTAssertNil(store.chassisOverride)
        XCTAssertNil(store.trimOverride)
        XCTAssertEqual(store.glowIntensity, 1.0)
        XCTAssertTrue(store.emotionOverrides.isEmpty)
        XCTAssertNil(store.previewSlot)
        XCTAssertEqual(store.resolvedPalette.chassisHex, "#1A1A1D")
    }

    func testStorePresetSelectionClearsCustomOverrides() {
        let store = AvatarPaletteStore(userDefaults: defaults)
        store.setChassisHex("#112233")
        store.setTrimHex("#445566")
        store.setEmotionHex("#778899", for: .balanced)
        store.setGlowIntensity(0.5)

        XCTAssertNotNil(store.chassisOverride)
        XCTAssertNotNil(store.trimOverride)
        XCTAssertFalse(store.emotionOverrides.isEmpty)

        store.selectPreset(.tokyoNight)
        XCTAssertEqual(store.selectedPreset, .tokyoNight)
        XCTAssertNil(store.chassisOverride)
        XCTAssertNil(store.trimOverride)
        XCTAssertTrue(store.emotionOverrides.isEmpty)
        XCTAssertEqual(store.glowIntensity, 1.0)
        XCTAssertEqual(store.resolvedPalette.chassisHex, "#1A1B26")
    }

    func testStoreSlotOverridesAndRowResets() {
        let store = AvatarPaletteStore(userDefaults: defaults)
        XCTAssertFalse(store.isSlotCustomized(.superCharged))

        let valid = store.setEmotionHex("#FF1122", for: .superCharged)
        XCTAssertTrue(valid)
        XCTAssertTrue(store.isSlotCustomized(.superCharged))
        XCTAssertEqual(store.resolvedPalette.hex(for: .superCharged), "#FF1122")

        let invalid = store.setEmotionHex("not-a-hex", for: .superCharged)
        XCTAssertFalse(invalid)
        XCTAssertEqual(store.resolvedPalette.hex(for: .superCharged), "#FF1122")

        store.resetSlot(.superCharged)
        XCTAssertFalse(store.isSlotCustomized(.superCharged))
        XCTAssertEqual(store.resolvedPalette.hex(for: .superCharged), "#FF007F")
    }

    func testStoreGlowClamping() {
        let store = AvatarPaletteStore(userDefaults: defaults)
        store.setGlowIntensity(-1.0)
        XCTAssertEqual(store.glowIntensity, 0.0)

        store.setGlowIntensity(3.5)
        XCTAssertEqual(store.glowIntensity, 1.5)

        store.setGlowIntensity(.nan)
        XCTAssertEqual(store.glowIntensity, 1.5)
    }

    func testStorePersistenceAcrossInstances() {
        let store1 = AvatarPaletteStore(userDefaults: defaults)
        store1.selectPreset(.catppuccinMocha)
        store1.setChassisHex("#121212")
        store1.setTrimHex("#343434")
        store1.setGlowIntensity(1.3)
        store1.setEmotionHex("#AABBCC", for: .dopamineSad)

        let store2 = AvatarPaletteStore(userDefaults: defaults)
        XCTAssertEqual(store2.selectedPreset, .catppuccinMocha)
        XCTAssertEqual(store2.chassisOverride, "#121212")
        XCTAssertEqual(store2.trimOverride, "#343434")
        XCTAssertEqual(store2.glowIntensity, 1.3, accuracy: 0.001)
        XCTAssertEqual(store2.emotionOverrides[.dopamineSad], "#AABBCC")
        XCTAssertEqual(store2.resolvedPalette.hex(for: .dopamineSad), "#AABBCC")

        store2.resetToDefaultTheme()
        XCTAssertEqual(store2.selectedPreset, .cyberpunkClassic)
        XCTAssertNil(store2.chassisOverride)
        XCTAssertNil(store2.trimOverride)

        let store3 = AvatarPaletteStore(userDefaults: defaults)
        XCTAssertEqual(store3.selectedPreset, .cyberpunkClassic)
        XCTAssertNil(store3.chassisOverride)
    }

    func testStorePreviewSimulatorTriggerAndCancel() {
        let store = AvatarPaletteStore(userDefaults: defaults)
        XCTAssertNil(store.previewSlot)

        store.triggerPreview(for: .overheating, duration: 2.0)
        XCTAssertEqual(store.previewSlot, .overheating)

        store.cancelPreview()
        XCTAssertNil(store.previewSlot)
    }
}
