import XCTest
import SwiftUI
@testable import BitzCore

@MainActor
final class MenuBarContentViewTests: XCTestCase {
    func testMenuBarContentViewCanBeInstantiatedWithStores() {
        let suiteName = "MenuBarTests.\(UUID().uuidString)"
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
            telemetrySettings: telemetrySettings
        )

        // Verify view body can be evaluated without crashing
        _ = menuView.body
        XCTAssertEqual(scaleStore.scaleFactor, 1.0)
        XCTAssertEqual(opacityStore.opacityFactor, 0.85, accuracy: 0.001)
        XCTAssertFalse(positionStore.isPositionUnlocked)
    }

    func testMenuBarContentViewReflectsUnlockedState() {
        let suiteName = "MenuBarUnlockedTests.\(UUID().uuidString)"
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

        positionStore.unlockPosition()
        XCTAssertTrue(positionStore.isPositionUnlocked)

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
            telemetrySettings: telemetrySettings
        )

        _ = menuView.body
        positionStore.lockPosition()
        XCTAssertFalse(positionStore.isPositionUnlocked)
    }

    func testMenuBarSettingsTriggerOpensSettingsWindow() {
        let suiteName = "MenuBarSettingsTests.\(UUID().uuidString)"
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
            telemetrySettings: telemetrySettings
        )

        _ = menuView.body

        SettingsWindowManager.shared.showSettingsWindow(
            rootView: SettingsRootView(
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
        )

        XCTAssertTrue(SettingsWindowManager.shared.isWindowOpen)
        SettingsWindowManager.shared.closeSettingsWindow()
        XCTAssertFalse(SettingsWindowManager.shared.isWindowOpen)
    }

    /// FR-010 / US3 scenario 7: an active agent warning can be dismissed from the menu bar.
    func testMenuBarShowsDismissForActiveWarning() {
        let suiteName = "MenuBarWarningTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let engine = WellnessPointEngine(riveController: ProductionRiveController(), userDefaults: defaults)
        let telemetrySettings = TelemetrySettingsStore(userDefaults: defaults)
        let agentMonitor = AgentMonitorService(adapters: [], userDefaults: defaults)
        let menuView = BitzMenuBarContentView(
            engine: engine,
            activityMonitor: ActivityMonitorService(engine: engine, telemetry: MockTelemetryProvider()),
            scaleStore: AvatarScaleStore(userDefaults: defaults),
            opacityStore: AvatarOpacityStore(userDefaults: defaults),
            positionStore: AvatarPositionStore(userDefaults: defaults),
            displayStore: DisplayPreferenceStore(userDefaults: defaults),
            agentMonitor: agentMonitor,
            updateStore: AppUpdateStore(userDefaults: defaults),
            telemetryDashboard: TelemetryDashboardService(settingsStore: telemetrySettings),
            telemetrySettings: telemetrySettings
        )
        XCTAssertFalse(String(describing: menuView.body).contains("Dismiss Agent Warning"), "No warning, no dismiss item")

        agentMonitor.handleEvent(AgentEvent(
            agentID: "claude", agentName: "Claude", kind: .warning, message: "⚠️ Claude may be stuck",
            metadata: [AgentEvent.MetadataKey.reason: "reported"]
        ))
        XCTAssertNotNil(agentMonitor.activeWarning)
        XCTAssertTrue(String(describing: menuView.body).contains("Dismiss Agent Warning"))

        // The Dismiss Agent Warning button's action
        agentMonitor.acknowledgeWarning()
        XCTAssertNil(agentMonitor.activeWarning)
        XCTAssertNil(agentMonitor.activePopup, "Dismissing also clears the warning bubble")
        XCTAssertFalse(String(describing: menuView.body).contains("Dismiss Agent Warning"))
    }
}
