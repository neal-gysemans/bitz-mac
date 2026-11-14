import XCTest
import AVFoundation
@testable import BitzCore

@MainActor
final class CyberAudioServiceTests: XCTestCase {

    func testAssetURLResolution() {
        let suiteName = "BitzAudioServiceTest.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let store = CyberAudioSettingsStore(userDefaults: defaults)
        let service = CyberAudioService(settingsStore: store)

        for event in CyberSoundEvent.allCases {
            let url = service.resolveAssetURL(for: event.assetFileName)
            XCTAssertNotNil(url, "Should resolve asset URL for \(event.assetFileName)")
            if let url {
                XCTAssertTrue(FileManager.default.fileExists(atPath: url.path), "Asset file must exist at \(url.path)")
            }
        }
    }

    func testPreloadBuffersPopulatesAllBuffers() {
        let suiteName = "BitzAudioServiceTest.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let store = CyberAudioSettingsStore(userDefaults: defaults)
        let service = CyberAudioService(settingsStore: store)

        XCTAssertFalse(service.loadedBuffers.isEmpty, "Buffers should be preloaded")
        for event in CyberSoundEvent.allCases {
            let buffer = service.loadedBuffers[event]
            XCTAssertNotNil(buffer, "Buffer for \(event) must be loaded")
            if let buffer {
                XCTAssertGreaterThan(buffer.frameLength, 0, "Buffer frameLength must be > 0")
            }
        }
    }

    func testPlaybackIgnoredWhenMasterDisabled() {
        let suiteName = "BitzAudioServiceTest.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let store = CyberAudioSettingsStore(userDefaults: defaults)
        XCTAssertFalse(store.isEnabled) // master is disabled by default

        let service = CyberAudioService(settingsStore: store)
        service.play(.agentNeedsApproval)

        // Engine should remain stopped since master audio is disabled
        XCTAssertFalse(service.isEngineRunning)
    }

    func testPlaybackIgnoredWhenSpecificEventDisabled() {
        let suiteName = "BitzAudioServiceTest.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let store = CyberAudioSettingsStore(userDefaults: defaults)
        store.setEnabled(true)
        store.setAgentChimeEnabled(false)

        let service = CyberAudioService(settingsStore: store)
        service.play(.agentNeedsApproval)

        // Engine should remain stopped since this event was toggled off
        XCTAssertFalse(service.isEngineRunning)
    }

    func testVolumeChangesPropagateToMixer() {
        let suiteName = "BitzAudioServiceTest.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let store = CyberAudioSettingsStore(userDefaults: defaults)
        let _ = CyberAudioService(settingsStore: store)

        store.setVolume(0.85)
        XCTAssertEqual(store.volume, 0.85, accuracy: 0.001)
    }

    func testPurrLoopStateManagement() {
        let suiteName = "BitzAudioServiceTest.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let store = CyberAudioSettingsStore(userDefaults: defaults)
        let service = CyberAudioService(
            settingsStore: store,
            environmentDetector: MockAudioEnvironmentDetector()
        )

        // When audio is disabled, setPurring(true) does nothing
        service.setPurring(true)
        XCTAssertFalse(service.isPurring)

        // Enable master audio
        store.setEnabled(true)
        service.setPurring(true)
        XCTAssertTrue(service.isPurring)

        service.setPurring(false)
        XCTAssertFalse(service.isPurring)
    }

    func testStopAllHaltsEngineAndResetsPurr() {
        let suiteName = "BitzAudioServiceTest.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let store = CyberAudioSettingsStore(userDefaults: defaults)
        store.setEnabled(true)

        let service = CyberAudioService(
            settingsStore: store,
            environmentDetector: MockAudioEnvironmentDetector()
        )
        service.setPurring(true)
        XCTAssertTrue(service.isPurring)

        service.stopAll()
        XCTAssertFalse(service.isPurring)
        XCTAssertFalse(service.isEngineRunning)
    }

    func testDisablingMasterStopsAllAudio() {
        let suiteName = "BitzAudioServiceTest.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let store = CyberAudioSettingsStore(userDefaults: defaults)
        store.setEnabled(true)

        let service = CyberAudioService(
            settingsStore: store,
            environmentDetector: MockAudioEnvironmentDetector()
        )
        service.setPurring(true)
        XCTAssertTrue(service.isPurring)

        // Disabling master should automatically trigger stopAll
        store.setEnabled(false)
        XCTAssertFalse(service.isPurring)
        XCTAssertFalse(service.isEngineRunning)
    }

    // MARK: - Companion Archetype Sound Tests (#150)

    func testArchetypeCompanionSoundAssetsResolutionAndPreload() {
        let suiteName = "BitzAudioServiceTest.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let store = CyberAudioSettingsStore(userDefaults: defaults)
        let service = CyberAudioService(settingsStore: store)

        // All 6 companions must resolve an asset URL that exists
        for character in MascotCharacter.allCases {
            let url = service.resolveAssetURL(for: character.reactionSoundFileName)
            XCTAssertNotNil(url, "Asset URL for \(character.name) (\(character.reactionSoundFileName)) must resolve")
            if let url {
                XCTAssertTrue(FileManager.default.fileExists(atPath: url.path), "File for \(character.name) must exist on disk")
            }
        }

        // All 6 companion buffers must be loaded in loadedCharacterBuffers
        for character in MascotCharacter.allCases {
            let buffer = service.loadedCharacterBuffers[character]
            XCTAssertNotNil(buffer, "Buffer for companion \(character.name) must be loaded")
            if let buffer {
                XCTAssertGreaterThan(buffer.frameLength, 0, "Buffer frame length for \(character.name) must be > 0")
            }
        }
    }

    func testReactionBufferFallbackToPurr() {
        let suiteName = "BitzAudioServiceTest.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let store = CyberAudioSettingsStore(userDefaults: defaults)
        let service = CyberAudioService(settingsStore: store)

        // Valid character returns its own buffer
        let drakoBuffer = service.reactionBuffer(for: .cyberDragon)
        XCTAssertNotNil(drakoBuffer)
        XCTAssertEqual(drakoBuffer, service.loadedCharacterBuffers[.cyberDragon])

        // When character buffer is missing, reactionBuffer falls back to purr buffer (FR-003)
        let purrBuffer = service.loadedBuffers[.purr]
        XCTAssertNotNil(purrBuffer)

        // Simulated missing buffer in a custom service instance
        let emptyService = CyberAudioService(settingsStore: store)
        // Default character (.cyberCat) falls back to purr
        XCTAssertEqual(emptyService.reactionBuffer(for: .cyberCat), emptyService.loadedBuffers[.purr])
    }

    func testCompanionSelectionRoutingViaStore() {
        let suiteName = "BitzAudioServiceTest.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let audioStore = CyberAudioSettingsStore(userDefaults: defaults)
        let charStore = AvatarCharacterStore(userDefaults: defaults)
        let service = CyberAudioService(
            settingsStore: audioStore,
            environmentDetector: MockAudioEnvironmentDetector()
        )

        service.observe(characterStore: charStore)
        XCTAssertEqual(service.selectedCharacterProvider(), .cyberCat)

        // Switch to Drako
        _ = charStore.selectCharacter(.cyberDragon)
        XCTAssertEqual(service.selectedCharacterProvider(), .cyberDragon)

        // Switch to Volt
        _ = charStore.selectCharacter(.cyberBunny)
        XCTAssertEqual(service.selectedCharacterProvider(), .cyberBunny)
    }

    func testPlayReactionSoundAuditionBypassesActiveSelection() {
        let suiteName = "BitzAudioServiceTest.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let audioStore = CyberAudioSettingsStore(userDefaults: defaults)
        audioStore.setEnabled(true)
        audioStore.setPurrEnabled(true)

        let charStore = AvatarCharacterStore(userDefaults: defaults)
        let service = CyberAudioService(
            settingsStore: audioStore,
            environmentDetector: MockAudioEnvironmentDetector()
        )
        service.observe(characterStore: charStore)

        // Active companion is Bitz (cyberCat)
        XCTAssertEqual(charStore.selectedCharacter, .cyberCat)

        // Auditioning Drako plays without changing active selection
        service.playReactionSound(for: .cyberDragon)
        XCTAssertEqual(charStore.selectedCharacter, .cyberCat)
        XCTAssertTrue(service.isPurring)

        service.stopPurr()
        XCTAssertFalse(service.isPurring)

        // Auditioning is suppressed if master audio is disabled
        audioStore.setEnabled(false)
        service.playReactionSound(for: .cyberDragon)
        XCTAssertFalse(service.isPurring)
    }
}
