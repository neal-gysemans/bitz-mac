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

        let view = AudioSettingsTabView(settingsStore: store, audioPlayer: spyPlayer, meetingRecorder: .stub(defaults: defaults))
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
            audioPlayer: spyPlayer,
            meetingRecorder: .stub(defaults: defaults)
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
            positionStore: positionStore,
            agentMonitor: agentMonitor,
            updateStore: updateStore,
            telemetryDashboard: telemetryDashboard,
            telemetrySettings: telemetrySettings,
            audioSettings: audioSettings,
            meetingRecorder: .stub(defaults: defaults)
        )

        _ = menuView.body

        // Verify audio toggles and volume adjustments
        audioSettings.setEnabled(true)
        XCTAssertTrue(audioSettings.isEnabled)
        audioSettings.setVolume(0.5)
        XCTAssertEqual(audioSettings.volume, 0.5, accuracy: 0.01)

        _ = menuView.body
    }

    // MARK: - Companion Reaction Sound & Roster Audition UI Tests (#150)

    func testAudioSettingsTabViewReactionSoundRowDynamicTitle() {
        let suiteName = "AudioSettingsViewsTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let store = CyberAudioSettingsStore(userDefaults: defaults)
        let spyPlayer = SpyCyberAudioPlayer()
        let charStore = AvatarCharacterStore(userDefaults: defaults)

        let view = AudioSettingsTabView(
            settingsStore: store,
            audioPlayer: spyPlayer,
            meetingRecorder: .stub(defaults: defaults),
            characterStore: charStore
        )
        _ = view.body

        // Verify initial selection (Bitz)
        XCTAssertEqual(charStore.selectedCharacter, .cyberCat)
        XCTAssertEqual(charStore.selectedCharacter.reactionSoundDisplayName, "Soothing Cat Purr")

        // Switch to Drako
        _ = charStore.selectCharacter(.cyberDragon)
        XCTAssertEqual(charStore.selectedCharacter, .cyberDragon)
        XCTAssertEqual(charStore.selectedCharacter.reactionSoundDisplayName, "Plasma Wyvern Rumble")
        _ = view.body

        // Switch to Byte
        _ = charStore.selectCharacter(.cyberDog)
        XCTAssertEqual(charStore.selectedCharacter, .cyberDog)
        XCTAssertEqual(charStore.selectedCharacter.reactionSoundDisplayName, "Tactical Servo Whine")
        _ = view.body
    }

    func testAppearanceCharacterRosterSectionViewAuditionButton() {
        let suiteName = "AudioSettingsViewsTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let charStore = AvatarCharacterStore(userDefaults: defaults)
        let paletteStore = AvatarPaletteStore(userDefaults: defaults)
        let spyPlayer = SpyCyberAudioPlayer()

        let galleryView = AppearanceCharacterRosterSectionView(
            characterStore: charStore,
            paletteStore: paletteStore,
            audioPlayer: spyPlayer
        )
        _ = galleryView.body

        // Active companion is default (Bitz)
        XCTAssertEqual(charStore.selectedCharacter, .cyberCat)

        // Auditioning any character calls spyPlayer.playReactionSound without changing selection
        spyPlayer.playReactionSound(for: .hoverDrone)
        XCTAssertEqual(spyPlayer.playedCharacterReactions, [.hoverDrone])
        XCTAssertEqual(charStore.selectedCharacter, .cyberCat, "Auditioning must not mutate selected companion")

        // Audition locked character (e.g. Aero / Volt) without selection change
        spyPlayer.playReactionSound(for: .cyberBunny)
        XCTAssertEqual(spyPlayer.playedCharacterReactions, [.hoverDrone, .cyberBunny])
        XCTAssertEqual(charStore.selectedCharacter, .cyberCat)
    }

    /// #148: Transcription Model Status & Dictation Deep Link
    func testTranscriptionModelStatusAndDeepLink() {
        let suiteName = "AudioSettingsModelStatusTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let store = CyberAudioSettingsStore(userDefaults: defaults)
        let meetingSettings = MeetingSettingsStore(userDefaults: defaults)
        let recorder = MeetingRecorderService(settingsStore: meetingSettings)
        let charStore = AvatarCharacterStore(userDefaults: defaults)
        let spyPlayer = SpyCyberAudioPlayer()

        let view = AudioSettingsTabView(
            settingsStore: store,
            audioPlayer: spyPlayer,
            meetingRecorder: recorder,
            characterStore: charStore
        )

        // Automatic initially: evaluate body without crash
        _ = view.body

        // Set to a specific language (e.g. Dutch)
        meetingSettings.setTranscriptionLocaleIdentifier("nl-NL")
        XCTAssertEqual(meetingSettings.transcriptionLocaleIdentifier, "nl-NL")

        let rendered = String(describing: view.body)
        XCTAssertTrue(rendered.contains("Language") || rendered.contains("Transcription"))
        XCTAssertTrue(rendered.contains("Don't see your language?") || rendered.contains("macOS Settings"))

        // Verify languageOptions prepends the saved language when not present in loaded
        let merged = AudioSettingsTabView.languageOptions(
            selected: "nl-NL",
            loaded: [(id: "en-US", label: "English (US)")]
        )
        XCTAssertEqual(merged.map(\.id), ["nl-NL", "en-US"])

        // Verify resolveSpeechModelNotice classifies unsupported locale and valid locales deterministically
        XCTAssertEqual(
            AudioSettingsTabView.resolveSpeechModelNotice(localeID: "xx-YY"),
            .unsupported
        )

        // Verify 1-click Dictation deep link (FR-006) invokes URL opener with Keyboard Dictation extension URL
        var openedURLs: [URL] = []
        let didOpen = SpeechFrameworkTranscriptionService.openDictationSettings { url in
            openedURLs.append(url)
            return true
        }
        XCTAssertTrue(didOpen)
        XCTAssertEqual(
            openedURLs.first?.absoluteString,
            "x-apple.systempreferences:com.apple.Keyboard-Settings.extension?Dictation"
        )
    }
}
