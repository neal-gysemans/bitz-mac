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
        let service = CyberAudioService(settingsStore: store)

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

        let service = CyberAudioService(settingsStore: store)
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

        let service = CyberAudioService(settingsStore: store)
        service.setPurring(true)
        XCTAssertTrue(service.isPurring)

        // Disabling master should automatically trigger stopAll
        store.setEnabled(false)
        XCTAssertFalse(service.isPurring)
        XCTAssertFalse(service.isEngineRunning)
    }
}
