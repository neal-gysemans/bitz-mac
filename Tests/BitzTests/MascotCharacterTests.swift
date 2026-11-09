import AppKit
import SwiftUI
import XCTest
@testable import BitzCore

@MainActor
final class MascotCharacterTests: XCTestCase {
    private var defaults: UserDefaults!
    private var suiteName: String!

    override func setUp() async throws {
        suiteName = "MascotCharacterTests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
    }

    override func tearDown() async throws {
        defaults.removePersistentDomain(forName: suiteName)
    }

    // MARK: - 1. Roster Enum & Metadata Tests

    func testMascotCharacterRosterMetadata() {
        XCTAssertEqual(MascotCharacter.allCases.count, 6)
        XCTAssertEqual(MascotCharacter.defaultCharacter, .cyberCat)

        XCTAssertEqual(MascotCharacter.cyberCat.rawValue, "cyber_cat")
        XCTAssertEqual(MascotCharacter.cyberDragon.rawValue, "cyber_dragon")
        XCTAssertEqual(MascotCharacter.cyberDog.rawValue, "cyber_dog")
        XCTAssertEqual(MascotCharacter.hoverDrone.rawValue, "hover_drone")
        XCTAssertEqual(MascotCharacter.retroMech.rawValue, "retro_mech")
        XCTAssertEqual(MascotCharacter.cyberBunny.rawValue, "cyber_bunny")

        XCTAssertEqual(MascotCharacter.cyberCat.name, "Bitz")
        XCTAssertEqual(MascotCharacter.cyberDragon.name, "Drako")
        XCTAssertEqual(MascotCharacter.cyberDog.name, "Byte")
        XCTAssertEqual(MascotCharacter.hoverDrone.name, "Aero")
        XCTAssertEqual(MascotCharacter.retroMech.name, "Pixel")
        XCTAssertEqual(MascotCharacter.cyberBunny.name, "Volt")

        XCTAssertFalse(MascotCharacter.cyberCat.isPro, "Bitz the Cyber Cat must always be Free")
        XCTAssertTrue(MascotCharacter.cyberDragon.isPro)
        XCTAssertTrue(MascotCharacter.cyberDog.isPro)
        XCTAssertTrue(MascotCharacter.hoverDrone.isPro)
        XCTAssertTrue(MascotCharacter.retroMech.isPro)
        XCTAssertTrue(MascotCharacter.cyberBunny.isPro)

        for character in MascotCharacter.allCases {
            XCTAssertFalse(character.archetype.isEmpty)
            XCTAssertTrue(character.title.contains(character.name))
            XCTAssertFalse(character.bio.isEmpty)
            XCTAssertFalse(character.menuBarSymbolName.isEmpty)
            XCTAssertFalse(character.petVisorText.isEmpty)
            XCTAssertFalse(character.petReactionBubble.isEmpty)
        }
    }

    // MARK: - 2. AvatarCharacterStore Persistence & Fallback Tests

    func testAvatarCharacterStorePersistenceAndFallback() {
        let store = AvatarCharacterStore(userDefaults: defaults)
        XCTAssertEqual(store.selectedCharacter, .cyberCat)

        var callbackValues: [MascotCharacter] = []
        store.onCharacterChanged = { character in
            callbackValues.append(character)
        }

        for character in MascotCharacter.allCases {
            XCTAssertTrue(store.selectCharacter(character))
            XCTAssertEqual(store.selectedCharacter, character)
            XCTAssertEqual(defaults.string(forKey: AvatarCharacterStore.selectedCharacterKey), character.rawValue)

            let reloaded = AvatarCharacterStore(userDefaults: defaults)
            XCTAssertEqual(reloaded.selectedCharacter, character)
        }

        XCTAssertEqual(callbackValues, [.cyberDragon, .cyberDog, .hoverDrone, .retroMech, .cyberBunny])

        store.resetToDefault()
        XCTAssertEqual(store.selectedCharacter, .cyberCat)

        // Unknown raw value falls back safely to .cyberCat
        defaults.set("unknown_mascot_xyz", forKey: AvatarCharacterStore.selectedCharacterKey)
        let fallbackStore = AvatarCharacterStore(userDefaults: defaults)
        XCTAssertEqual(fallbackStore.selectedCharacter, .cyberCat)
    }

    // MARK: - 3. Pro Tier Gating & Entitlement Validation Tests

    func testAvatarCharacterStoreProLicensingGating() {
        let mockLicensing = MockCharacterLicensingService(unlockedFeatures: [])
        let store = AvatarCharacterStore(userDefaults: defaults, licensingService: mockLicensing)

        XCTAssertTrue(store.isCharacterUnlocked(.cyberCat))
        XCTAssertFalse(store.isCharacterUnlocked(.cyberDragon))
        XCTAssertFalse(store.isCharacterUnlocked(.cyberDog))
        XCTAssertFalse(store.isCharacterUnlocked(.hoverDrone))
        XCTAssertFalse(store.isCharacterUnlocked(.retroMech))
        XCTAssertFalse(store.isCharacterUnlocked(.cyberBunny))

        // Selecting Pro characters while locked fails and preserves .cyberCat
        XCTAssertFalse(store.selectCharacter(.cyberDog))
        XCTAssertEqual(store.selectedCharacter, .cyberCat)

        // Unlocking .multiMascot allows selecting any companion
        mockLicensing.unlockedFeatures = [.multiMascot]
        mockLicensing.currentTier = .pro
        XCTAssertTrue(store.isCharacterUnlocked(.cyberDog))
        XCTAssertTrue(store.selectCharacter(.hoverDrone))
        XCTAssertEqual(store.selectedCharacter, .hoverDrone)

        // Downgrading / deactivating license reverts to .cyberCat on validateTierEntitlement()
        mockLicensing.unlockedFeatures = []
        mockLicensing.currentTier = .free
        store.validateTierEntitlement()
        XCTAssertEqual(store.selectedCharacter, .cyberCat)
        XCTAssertEqual(defaults.string(forKey: AvatarCharacterStore.selectedCharacterKey), MascotCharacter.cyberCat.rawValue)

        // Launching on Free tier with a Pro character saved in UserDefaults falls back to .cyberCat
        defaults.set(MascotCharacter.retroMech.rawValue, forKey: AvatarCharacterStore.selectedCharacterKey)
        let gatedLaunchStore = AvatarCharacterStore(userDefaults: defaults, licensingService: mockLicensing)
        XCTAssertEqual(gatedLaunchStore.selectedCharacter, .cyberCat)
    }

    // MARK: - 4. Procedural Vector Rendering & Silhouette Distinctness Tests

    func testAllCharactersRenderDistinctSilhouettesAndSupportAllStates() throws {
        let catImage = try renderCharacter(.cyberCat, state: .balanced)

        for character in MascotCharacter.allCases where character != .cyberCat {
            let otherImage = try renderCharacter(character, state: .balanced)
            let diff = differingPixelCount(catImage, otherImage)
            XCTAssertGreaterThan(
                diff,
                80,
                "\(character.title) must render a visually distinct silhouette compared to Bitz the Cyber Cat"
            )
        }

        // Verify all 5 characters render across all 7 BitzStates, petting, blinking, loaf posture, and custom palettes
        var customPalette = AvatarThemePreset.tokyoNight.palette
        customPalette.trimHex = "#00F0FF"

        for character in MascotCharacter.allCases {
            for state in BitzState.allCases {
                let view = BitzCharacterView(
                    state: state,
                    time: 0.5,
                    isBlinking: state == .balanced,
                    isPetReactionActive: false,
                    showParticles: true,
                    palette: customPalette,
                    character: character
                )
                let image = try render(view)
                XCTAssertGreaterThan(image.width, 0)
            }

            let petView = BitzCharacterView(
                state: .balanced,
                time: 0,
                isPetReactionActive: true,
                showParticles: false,
                palette: customPalette,
                character: character
            )
            let petImage = try render(petView)
            XCTAssertGreaterThan(petImage.width, 0)

            let liveView = LiveBitzCharacterView(
                state: .balanced,
                isPetReactionActive: false,
                isPaused: true,
                palette: customPalette,
                isAttentionCueActive: true,
                character: character
            )
            XCTAssertEqual(liveView.character, character)

            let animatedView = AnimatedBitzCharacterView(
                state: .superCharged,
                isPaused: true,
                palette: customPalette,
                character: character
            )
            XCTAssertEqual(animatedView.character, character)
        }
    }

    // MARK: - 5. Settings Gallery & Menu Bar Integration Tests

    func testSettingsGalleryAndMenuBarCharacterSelection() {
        let characterStore = AvatarCharacterStore(userDefaults: defaults)
        let paletteStore = AvatarPaletteStore(userDefaults: defaults)
        let scaleStore = AvatarScaleStore(userDefaults: defaults)
        let opacityStore = AvatarOpacityStore(userDefaults: defaults)
        let engine = WellnessPointEngine(riveController: ProductionRiveController(), userDefaults: defaults)

        let rosterSection = AppearanceCharacterRosterSectionView(
            characterStore: characterStore,
            paletteStore: paletteStore,
            engine: engine
        )
        XCTAssertNotNil(rosterSection.body)

        let appearanceTab = AppearanceSettingsTabView(
            scaleStore: scaleStore,
            opacityStore: opacityStore,
            engine: engine,
            paletteStore: paletteStore,
            characterStore: characterStore
        )
        XCTAssertNotNil(appearanceTab.body)

        characterStore.selectCharacter(.cyberBunny)
        let telemetrySettings = TelemetrySettingsStore(userDefaults: defaults)
        let menuBarView = BitzMenuBarContentView(
            engine: engine,
            activityMonitor: ActivityMonitorService(engine: engine, telemetry: MockTelemetryProvider()),
            positionStore: AvatarPositionStore(userDefaults: defaults),
            agentMonitor: AgentMonitorService(adapters: [], userDefaults: defaults),
            updateStore: AppUpdateStore(userDefaults: defaults),
            telemetryDashboard: TelemetryDashboardService(settingsStore: telemetrySettings),
            telemetrySettings: telemetrySettings,
            paletteStore: paletteStore,
            characterStore: characterStore
        )
        let renderedMenu = String(describing: menuBarView.body)
        XCTAssertTrue(renderedMenu.contains("Companion Character"))
    }

    // MARK: - Helpers

    private func renderCharacter(_ character: MascotCharacter, state: BitzState) throws -> CGImage {
        let view = BitzCharacterView(state: state, time: 0, showParticles: false, character: character)
        return try render(view)
    }

    private func render<V: View>(_ view: V) throws -> CGImage {
        let renderer = ImageRenderer(content: view)
        renderer.scale = 2.0
        return try XCTUnwrap(renderer.cgImage)
    }

    private func differingPixelCount(_ first: CGImage, _ second: CGImage) -> Int {
        guard first.width == second.width, first.height == second.height else { return -1 }
        let width = first.width
        let height = first.height
        var a = [UInt8](repeating: 0, count: width * height * 4)
        var b = [UInt8](repeating: 0, count: width * height * 4)
        let space = CGColorSpaceCreateDeviceRGB()
        let info = CGImageAlphaInfo.premultipliedLast.rawValue

        let ctxA = CGContext(data: &a, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4, space: space, bitmapInfo: info)
        let ctxB = CGContext(data: &b, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4, space: space, bitmapInfo: info)
        ctxA?.draw(first, in: CGRect(x: 0, y: 0, width: width, height: height))
        ctxB?.draw(second, in: CGRect(x: 0, y: 0, width: width, height: height))

        var diff = 0
        for idx in stride(from: 0, to: a.count, by: 4) {
            if abs(Int(a[idx]) - Int(b[idx])) > 16 ||
               abs(Int(a[idx + 1]) - Int(b[idx + 1])) > 16 ||
               abs(Int(a[idx + 2]) - Int(b[idx + 2])) > 16 ||
               abs(Int(a[idx + 3]) - Int(b[idx + 3])) > 16 {
                diff += 1
            }
        }
        return diff
    }
}

@MainActor
private final class MockCharacterLicensingService: LicensingServiceProtocol {
    @Published var currentTier: BitzTier = .free
    @Published var activeLicense: LicensePayload? = nil
    var unlockedFeatures: Set<BitzFeature>

    init(unlockedFeatures: Set<BitzFeature>) {
        self.unlockedFeatures = unlockedFeatures
    }

    func isFeatureUnlocked(_ feature: BitzFeature) -> Bool {
        unlockedFeatures.contains(feature)
    }

    func activateLicense(key: String) throws {
        let payload = LicensePayload(tier: "pro", licenseId: "TEST", issuedAt: 0)
        currentTier = .pro
        activeLicense = payload
        unlockedFeatures = Set(BitzFeature.allCases)
    }

    func deactivateLicense() throws {
        currentTier = .free
        activeLicense = nil
        unlockedFeatures = []
    }
}
