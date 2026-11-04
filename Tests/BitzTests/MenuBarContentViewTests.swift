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

    func testMenuBarThemePresetSubmenuCanBeRenderedAndSelectsPreset() {
        let suiteName = "MenuBarThemePresetTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let paletteStore = AvatarPaletteStore(userDefaults: defaults)
        let menuView = BitzMenuBarContentView(
            engine: WellnessPointEngine(riveController: ProductionRiveController(), userDefaults: defaults),
            activityMonitor: ActivityMonitorService(
                engine: WellnessPointEngine(riveController: ProductionRiveController(), userDefaults: defaults),
                telemetry: MockTelemetryProvider()
            ),
            scaleStore: AvatarScaleStore(userDefaults: defaults),
            opacityStore: AvatarOpacityStore(userDefaults: defaults),
            positionStore: AvatarPositionStore(userDefaults: defaults),
            agentMonitor: AgentMonitorService(adapters: []),
            updateStore: AppUpdateStore(userDefaults: defaults),
            telemetryDashboard: TelemetryDashboardService(settingsStore: TelemetrySettingsStore(userDefaults: defaults)),
            telemetrySettings: TelemetrySettingsStore(userDefaults: defaults),
            paletteStore: paletteStore
        )

        _ = menuView.body
        XCTAssertEqual(paletteStore.selectedPreset, .cyberpunkClassic)
        paletteStore.selectPreset(.nord)
        XCTAssertEqual(paletteStore.selectedPreset, .nord)
    }

    /// #94 A2 / A3: the update status and, when enabled, the stats line are rendered in the dropdown.
    func testMenuShowsUpdateStatusAndGatedStatsLine() {
        let suiteName = "MenuBarStatsTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let engine = WellnessPointEngine(riveController: ProductionRiveController(), userDefaults: defaults)
        let telemetrySettings = TelemetrySettingsStore(userDefaults: defaults)
        telemetrySettings.enabledMetrics = [.ram]
        let telemetryDashboard = TelemetryDashboardService(settingsStore: telemetrySettings)
        let updateStore = AppUpdateStore(userDefaults: defaults)
        let menuView = BitzMenuBarContentView(
            engine: engine,
            activityMonitor: ActivityMonitorService(engine: engine, telemetry: MockTelemetryProvider()),
            scaleStore: AvatarScaleStore(userDefaults: defaults),
            opacityStore: AvatarOpacityStore(userDefaults: defaults),
            positionStore: AvatarPositionStore(userDefaults: defaults),
            agentMonitor: AgentMonitorService(adapters: [], userDefaults: defaults),
            updateStore: updateStore,
            telemetryDashboard: telemetryDashboard,
            telemetrySettings: telemetrySettings
        )
        let stats = telemetryDashboard.snapshot.menuBarItems(enabledMetrics: [.ram]).joined(separator: " | ")
        XCTAssertFalse(stats.isEmpty)

        XCTAssertTrue(String(describing: menuView.body).contains(updateStore.statusMessage))
        XCTAssertTrue(String(describing: menuView.body).contains(stats))
        telemetrySettings.displayInMenuBarMenu = false
        XCTAssertFalse(String(describing: menuView.body).contains(stats))
    }

    /// #94 A4: the status item label observes the delegate, so a title change must publish.
    func testDelegatePublishesMenuBarTitleChanges() {
        let suiteName = "MenuBarTitleTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let delegate = BitzAppDelegate(userDefaults: defaults)
        var changes = 0
        let cancellable = delegate.objectWillChange.sink { changes += 1 }
        defer { cancellable.cancel() }

        delegate.telemetrySettings.enabledMetrics = [.ram]
        delegate.telemetrySettings.displayInMenuBarTitle = true
        XCTAssertNotEqual(delegate.menuBarTitle, "Bitz")
        XCTAssertGreaterThan(changes, 0)
    }
}
