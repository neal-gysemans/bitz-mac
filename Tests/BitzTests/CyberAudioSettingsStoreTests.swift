import XCTest
@testable import BitzCore

@MainActor
final class CyberAudioSettingsStoreTests: XCTestCase {

    func testLegacyPersistedCallSuppressionDefaultIsIgnored() {
        let suiteName = "BitzAudioDefaultsTest.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        // Every pre-#95 install persisted the old default-on value under this key
        defaults.set(true, forKey: "bitz.audio.isCallSuppressionEnabled")

        let store = CyberAudioSettingsStore(userDefaults: defaults)
        XCTAssertFalse(store.isCallSuppressionEnabled)

        store.setCallSuppressionEnabled(true)
        XCTAssertTrue(CyberAudioSettingsStore(userDefaults: defaults).isCallSuppressionEnabled, "Opting in persists")
    }

    func testInitialDefaultsAreSafeAndDefaultOff() {
        let suiteName = "BitzAudioDefaultsTest.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let store = CyberAudioSettingsStore(userDefaults: defaults)

        // Critical invariant: audio must default to OFF for zero noise out of the box
        XCTAssertFalse(store.isEnabled)
        XCTAssertEqual(store.volume, 0.30, accuracy: 0.001)
        XCTAssertEqual(store.volumePercentageInt, 30)
        XCTAssertEqual(store.formattedVolumeSummary, "30%")

        // Per-event defaults should be true once master is enabled
        XCTAssertTrue(store.isPurrEnabled)
        XCTAssertTrue(store.isBurnoutEnabled)
        XCTAssertTrue(store.isOverheatEnabled)
        XCTAssertTrue(store.isChargingEnabled)
        XCTAssertTrue(store.isAgentChimeEnabled)
        XCTAssertTrue(store.isAllDoneFanfareEnabled)
        XCTAssertTrue(store.isFocusDNDSuppressionEnabled)
        XCTAssertFalse(store.isCallSuppressionEnabled, "Mic-in-use suppression is opt-in (#95)")

        // But isEventEnabled must return false for all events when master is disabled, except the start chime (#43 A2)
        XCTAssertTrue(store.isEventEnabled(.meetingRecordingStarted))
        for event in CyberSoundEvent.allCases where !event.ignoresMasterAndFocus {
            XCTAssertFalse(store.isEventEnabled(event), "Event \(event) should not be enabled while master is off")
        }
    }

    func testEnablingMasterActivatesEnabledEvents() {
        let suiteName = "BitzAudioDefaultsTest.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let store = CyberAudioSettingsStore(userDefaults: defaults)
        var callbackFired = false
        store.onSettingsChanged = { callbackFired = true }

        store.setEnabled(true)
        XCTAssertTrue(store.isEnabled)
        XCTAssertTrue(callbackFired)

        // Now events should report active
        XCTAssertTrue(store.isEventEnabled(.purr))
        XCTAssertTrue(store.isEventEnabled(.burnout))
        XCTAssertTrue(store.isEventEnabled(.overheating))
        XCTAssertTrue(store.isEventEnabled(.charging))
        XCTAssertTrue(store.isEventEnabled(.agentNeedsApproval))
        XCTAssertTrue(store.isEventEnabled(.allAgentsDone))
    }

    func testIndividualEventToggles() {
        let suiteName = "BitzAudioDefaultsTest.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let store = CyberAudioSettingsStore(userDefaults: defaults)
        store.setEnabled(true)

        store.setPurrEnabled(false)
        XCTAssertFalse(store.isPurrEnabled)
        XCTAssertFalse(store.isEventEnabled(.purr))
        XCTAssertTrue(store.isEventEnabled(.burnout))

        store.setEventEnabled(.burnout, enabled: false)
        XCTAssertFalse(store.isBurnoutEnabled)
        XCTAssertFalse(store.isEventEnabled(.burnout))

        store.setOverheatEnabled(false)
        XCTAssertFalse(store.isOverheatEnabled)
        XCTAssertFalse(store.isEventEnabled(.overheating))

        store.setChargingEnabled(false)
        XCTAssertFalse(store.isChargingEnabled)
        XCTAssertFalse(store.isEventEnabled(.charging))

        store.setAgentChimeEnabled(false)
        XCTAssertFalse(store.isAgentChimeEnabled)
        XCTAssertFalse(store.isEventEnabled(.agentNeedsApproval))

        store.setAllDoneFanfareEnabled(false)
        XCTAssertFalse(store.isAllDoneFanfareEnabled)
        XCTAssertFalse(store.isEventEnabled(.allAgentsDone))

        store.setFocusDNDSuppressionEnabled(false)
        XCTAssertFalse(store.isFocusDNDSuppressionEnabled)

        store.setCallSuppressionEnabled(false)
        XCTAssertFalse(store.isCallSuppressionEnabled)
    }

    func testVolumeSanitizationAndFormatting() {
        let suiteName = "BitzAudioDefaultsTest.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let store = CyberAudioSettingsStore(userDefaults: defaults)

        store.setVolume(0.75)
        XCTAssertEqual(store.volume, 0.75, accuracy: 0.001)
        XCTAssertEqual(store.volumePercentageInt, 75)
        XCTAssertEqual(store.formattedVolumeSummary, "75%")

        // Clamping upper bound
        store.setVolume(1.8)
        XCTAssertEqual(store.volume, 1.0, accuracy: 0.001)
        XCTAssertEqual(store.volumePercentageInt, 100)

        // Clamping lower bound
        store.setVolume(-0.5)
        XCTAssertEqual(store.volume, 0.0, accuracy: 0.001)
        XCTAssertEqual(store.volumePercentageInt, 0)

        // Non-finite fallbacks to default
        store.setVolume(.nan)
        XCTAssertEqual(store.volume, 0.30, accuracy: 0.001)

        store.setVolume(.infinity)
        XCTAssertEqual(store.volume, 1.0, accuracy: 0.001)
    }

    func testSettingsPersistenceAcrossReinstantiation() {
        let suiteName = "BitzAudioDefaultsTest.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        // Configure first store
        let store1 = CyberAudioSettingsStore(userDefaults: defaults)
        store1.setEnabled(true)
        store1.setVolume(0.65)
        store1.setAgentChimeEnabled(false)
        store1.setPurrEnabled(false)

        // Create second store pointing to same defaults
        let store2 = CyberAudioSettingsStore(userDefaults: defaults)
        XCTAssertTrue(store2.isEnabled)
        XCTAssertEqual(store2.volume, 0.65, accuracy: 0.001)
        XCTAssertFalse(store2.isAgentChimeEnabled)
        XCTAssertFalse(store2.isPurrEnabled)
        XCTAssertTrue(store2.isBurnoutEnabled)
    }

    func testCyberSoundEventProperties() {
        for event in CyberSoundEvent.allCases {
            XCTAssertFalse(event.id.isEmpty)
            XCTAssertFalse(event.displayName.isEmpty)
            XCTAssertTrue(event.assetFileName.hasSuffix(".wav"))
        }

        XCTAssertTrue(CyberSoundEvent.purr.isLooping)
        XCTAssertFalse(CyberSoundEvent.burnout.isLooping)
        XCTAssertFalse(CyberSoundEvent.agentNeedsApproval.isLooping)

        XCTAssertEqual(CyberSoundEvent.agentNeedsApproval.defaultCooldown, 10.0)
        XCTAssertEqual(CyberSoundEvent.allAgentsDone.defaultCooldown, 60.0)
    }

    func testSpyAudioPlayerTracksCalls() {
        let spy = SpyCyberAudioPlayer()
        XCTAssertFalse(spy.isPurring)
        XCTAssertTrue(spy.playedEvents.isEmpty)
        XCTAssertEqual(spy.stopAllCallCount, 0)

        spy.play(.agentNeedsApproval)
        spy.play(.burnout)
        XCTAssertEqual(spy.playedEvents, [.agentNeedsApproval, .burnout])

        spy.setPurring(true)
        XCTAssertTrue(spy.isPurring)
        XCTAssertEqual(spy.purrHistory, [true])

        spy.stopAll()
        XCTAssertFalse(spy.isPurring)
        XCTAssertEqual(spy.stopAllCallCount, 1)

        spy.reset()
        XCTAssertTrue(spy.playedEvents.isEmpty)
        XCTAssertTrue(spy.purrHistory.isEmpty)
        XCTAssertEqual(spy.stopAllCallCount, 0)
    }
}
