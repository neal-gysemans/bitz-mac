import XCTest
import SwiftUI
@testable import BitzCore

@MainActor
final class SettingsViewsTests: XCTestCase {
    func testSettingsRootViewAndTabsCanBeInstantiated() {
        let suiteName = "SettingsViewsTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        UserDefaults.standard.removeObject(forKey: "Bitz.AgentMonitor.PopupsEnabled")
        defer { UserDefaults.standard.removeObject(forKey: "Bitz.AgentMonitor.PopupsEnabled") }

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
            telemetrySettings: telemetrySettings
        )

        // Verify body evaluation
        _ = rootView.body

        // Verify General Tab interactions
        scaleStore.stepUp()
        XCTAssertEqual(scaleStore.scaleFactor, 1.10, accuracy: 0.001)

        opacityStore.stepDown()
        XCTAssertEqual(opacityStore.opacityFactor, 0.75, accuracy: 0.001)

        positionStore.unlockPosition()
        XCTAssertTrue(positionStore.isPositionUnlocked)
        positionStore.lockPosition()
        XCTAssertFalse(positionStore.isPositionUnlocked)

        // Verify Agent Tab interactions
        XCTAssertTrue(agentMonitor.popupsEnabled)
        agentMonitor.popupsEnabled = false
        XCTAssertFalse(agentMonitor.popupsEnabled)

        // Verify Telemetry Tab interactions
        XCTAssertTrue(telemetrySettings.isMetricEnabled(.ram))
        telemetrySettings.setMetric(.ram, enabled: false)
        XCTAssertFalse(telemetrySettings.isMetricEnabled(.ram))

        // Verify Behavior State override
        activityMonitor.isManualOverrideActive = true
        engine.setPoints(90.0, continuousWorkMinutes: 10.0)
        XCTAssertEqual(engine.currentPoints, 90.0)
    }

    func testAgentSignalsCardSettingsPersistAndClamp() {
        let suiteName = "AgentSignalsCardTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let monitor = AgentMonitorService(adapters: [], userDefaults: defaults)
        let tab = AgentsSettingsTabView(agentMonitor: monitor)
        _ = tab.body

        // Toggles and steppers bind `$agentMonitor.signalSettings.<field>`; this checks persistence of those fields,
        // not the SwiftUI controls themselves. The window picker goes through its real binding.
        monitor.signalSettings.loopWarningEnabled = false
        monitor.signalSettings.contextThresholdPercent = 95
        tab.windowBinding("claude").wrappedValue = 1_000_000

        let reloaded = AgentMonitorService(adapters: [], userDefaults: defaults)
        XCTAssertEqual(reloaded.signalSettings, monitor.signalSettings)
        XCTAssertFalse(reloaded.signalSettings.loopWarningEnabled)
        XCTAssertEqual(reloaded.signalSettings.contextThresholdPercent, 95)
        XCTAssertEqual(reloaded.signalSettings.contextWindow(for: "claude"), 1_000_000)

        monitor.signalSettings.contextThresholdPercent = 120
        XCTAssertEqual(monitor.signalSettings.contextThresholdPercent, 99)
    }

    func testContextWindowBindingsIgnoreInvalidTokensAndDeriveCustom() {
        let suiteName = "AgentSignalsWindowTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let monitor = AgentMonitorService(adapters: [], userDefaults: defaults)
        let tab = AgentsSettingsTabView(agentMonitor: monitor)

        // Custom field: typing 0 or a negative value never reaches the store.
        tab.windowBinding("claude").wrappedValue = 0
        tab.windowBinding("claude").wrappedValue = -5
        XCTAssertEqual(monitor.signalSettings.contextWindow(for: "claude"), 200_000)

        // Picker: presets select themselves, anything else reads as Custom.
        XCTAssertEqual(tab.windowPresetBinding("claude").wrappedValue, 200_000)
        XCTAssertEqual(tab.windowPresetBinding("antigravity").wrappedValue, 1_000_000)
        tab.windowBinding("claude").wrappedValue = 150_000
        XCTAssertEqual(tab.windowPresetBinding("claude").wrappedValue, AgentsSettingsTabView.customWindowTag)

        tab.windowPresetBinding("claude").wrappedValue = 1_000_000
        XCTAssertEqual(monitor.signalSettings.contextWindow(for: "claude"), 1_000_000)
    }

    func testGeneralSettingsTabViewInteractions() {
        let suiteName = "GeneralSettingsTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let scaleStore = AvatarScaleStore(userDefaults: defaults)
        let opacityStore = AvatarOpacityStore(userDefaults: defaults)
        let positionStore = AvatarPositionStore(userDefaults: defaults)
        let displayStore = DisplayPreferenceStore(userDefaults: defaults)

        let tab = GeneralSettingsTabView(
            scaleStore: scaleStore,
            opacityStore: opacityStore,
            positionStore: positionStore,
            displayStore: displayStore
        )

        _ = tab.body

        scaleStore.selectPreset(.medium)
        XCTAssertEqual(scaleStore.scaleFactor, 0.80, accuracy: 0.001)

        opacityStore.selectPreset(.ghost)
        XCTAssertEqual(opacityStore.opacityFactor, 0.40, accuracy: 0.001)

        displayStore.selectMode(.followActive)
        XCTAssertEqual(displayStore.targetMode, .followActive)
    }

    func testBitzCharacterViewAndRealMascotPreview() {
        for state in BitzState.allCases {
            let characterView = BitzCharacterView(state: state)
            _ = characterView.body

            let rgb = BitzCharacterView.visorRGB(for: state)
            let mascotRGB = MascotOverlayView.visorRGB(for: state)
            XCTAssertEqual(rgb.red, mascotRGB.red, accuracy: 0.001)
            XCTAssertEqual(rgb.green, mascotRGB.green, accuracy: 0.001)
            XCTAssertEqual(rgb.blue, mascotRGB.blue, accuracy: 0.001)
        }

        let animatedView = AnimatedBitzCharacterView(state: .balanced, showParticles: true)
        _ = animatedView.body

        let suiteName = "RealMascotPreviewTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let riveController = ProductionRiveController()
        let engine = WellnessPointEngine(riveController: riveController, userDefaults: defaults)
        let scaleStore = AvatarScaleStore(userDefaults: defaults)
        let opacityStore = AvatarOpacityStore(userDefaults: defaults)
        let positionStore = AvatarPositionStore(userDefaults: defaults)
        let displayStore = DisplayPreferenceStore(userDefaults: defaults)

        let tabWithEngine = GeneralSettingsTabView(
            scaleStore: scaleStore,
            opacityStore: opacityStore,
            positionStore: positionStore,
            displayStore: displayStore,
            engine: engine
        )
        _ = tabWithEngine.body
    }
}
