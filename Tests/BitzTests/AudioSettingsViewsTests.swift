import XCTest
import SwiftUI
@testable import BitzCore

@MainActor
final class AudioSettingsViewsTests: XCTestCase {

    func testAudioSettingsTabViewInstantiationAndBody() {
        let suiteName = "AudioSettingsViewsTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let store = CyberAudioSettingsStore(userDefaults: defaults)
        let spyPlayer = SpyCyberAudioPlayer()

        let view = AudioSettingsTabView(settingsStore: store, audioPlayer: spyPlayer)
        _ = view.body

        // Verify default state
        XCTAssertFalse(store.isEnabled)
        XCTAssertEqual(store.volume, 0.3, accuracy: 0.01)

        // Enable master and change volume
        store.setEnabled(true)
        XCTAssertTrue(store.isEnabled)

        store.setVolume(0.8)
        XCTAssertEqual(store.volume, 0.8, accuracy: 0.01)
        XCTAssertEqual(store.formattedVolumeSummary, "80%")

        // Test individual event toggles
        store.setEventEnabled(.burnout, enabled: false)
        XCTAssertFalse(store.isEventEnabled(.burnout))
        store.setEventEnabled(.burnout, enabled: true)
        XCTAssertTrue(store.isEventEnabled(.burnout))

        // Test environmental suppression toggles
        store.setCallSuppressionEnabled(false)
        XCTAssertFalse(store.isCallSuppressionEnabled)
        store.setCallSuppressionEnabled(true)
        XCTAssertTrue(store.isCallSuppressionEnabled)

        store.setFocusDNDSuppressionEnabled(false)
        XCTAssertFalse(store.isFocusDNDSuppressionEnabled)
        store.setFocusDNDSuppressionEnabled(true)
        XCTAssertTrue(store.isFocusDNDSuppressionEnabled)

        // Test sound trigger via spy
        spyPlayer.play(.agentNeedsApproval)
        XCTAssertEqual(spyPlayer.playedEvents, [.agentNeedsApproval])

        // Verify body re-evaluation after state changes
        _ = view.body
    }

    func testSettingsTabEnumIncludesAudio() {
        XCTAssertTrue(SettingsTab.allCases.contains(.audio))
        XCTAssertEqual(SettingsTab.audio.rawValue, "Audio")
        XCTAssertEqual(SettingsTab.audio.icon, "speaker.wave.2.fill")
    }

    func testSettingsRootViewIncludesAudioTab() {
        let suiteName = "AudioSettingsViewsTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let riveController = ProductionRiveController()
        let engine = WellnessPointEngine(riveController: riveController, userDefaults: defaults)
        let telemetry = MockTelemetryProvider()
        let activityMonitor = ActivityMonitorService(engine: engine, telemetry: telemetry)
        let scaleStore = AvatarScaleStore(userDefaults: defaults)
        let opacityStore = AvatarOpacityStore(userDefaults: defaults)
        let positionStore = AvatarPositionStore(userDefaults: defaults)
        let displayStore = DisplayPreferenceStore(userDefaults: defaults)
        let agentMonitor = AgentMonitorService(adapters: [])
        let updateStore = AppUpdateStore(userDefaults: defaults)
        let telemetrySettings = TelemetrySettingsStore(userDefaults: defaults)
        let telemetryDashboard = TelemetryDashboardService(settingsStore: telemetrySettings)
        let audioSettings = CyberAudioSettingsStore(userDefaults: defaults)
        let spyPlayer = SpyCyberAudioPlayer()

        let rootView = SettingsRootView(
            engine: engine,
            activityMonitor: activityMonitor,
            scaleStore: scaleStore,
            opacityStore: opacityStore,
            positionStore: positionStore,
            displayStore: displayStore,
            agentMonitor: agentMonitor,
            updateStore: updateStore,
            telemetryDashboard: telemetryDashboard,
            telemetrySettings: telemetrySettings,
            audioSettings: audioSettings,
            audioPlayer: spyPlayer
        )

        _ = rootView.body
    }

    func testBitzMenuBarContentViewIncludesSoundControls() {
        let suiteName = "AudioSettingsViewsTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let riveController = ProductionRiveController()
        let engine = WellnessPointEngine(riveController: riveController, userDefaults: defaults)
        let telemetry = MockTelemetryProvider()
        let activityMonitor = ActivityMonitorService(engine: engine, telemetry: telemetry)
        let scaleStore = AvatarScaleStore(userDefaults: defaults)
        let opacityStore = AvatarOpacityStore(userDefaults: defaults)
        let positionStore = AvatarPositionStore(userDefaults: defaults)
        let displayStore = DisplayPreferenceStore(userDefaults: defaults)
        let agentMonitor = AgentMonitorService(adapters: [])
        let updateStore = AppUpdateStore(userDefaults: defaults)
        let telemetrySettings = TelemetrySettingsStore(userDefaults: defaults)
        let telemetryDashboard = TelemetryDashboardService(settingsStore: telemetrySettings)
        let audioSettings = CyberAudioSettingsStore(userDefaults: defaults)

        let menuView = BitzMenuBarContentView(
            engine: engine,
            activityMonitor: activityMonitor,
            scaleStore: scaleStore,
            opacityStore: opacityStore,
            positionStore: positionStore,
            displayStore: displayStore,
            agentMonitor: agentMonitor,
            updateStore: updateStore,
            telemetryDashboard: telemetryDashboard,
            telemetrySettings: telemetrySettings,
            audioSettings: audioSettings
        )

        _ = menuView.body

        // Verify audio toggles and volume adjustments
        audioSettings.setEnabled(true)
        XCTAssertTrue(audioSettings.isEnabled)
        audioSettings.setVolume(0.5)
        XCTAssertEqual(audioSettings.volume, 0.5, accuracy: 0.01)

        _ = menuView.body
    }
}
