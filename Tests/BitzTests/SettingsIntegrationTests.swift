import AppKit
import SwiftUI
import XCTest
@testable import BitzCore

@MainActor
final class SettingsIntegrationTests: XCTestCase {

    func testSettingsWindowCreationAndOverlayPanelInvariants() {
        defer { SettingsWindowManager.shared.closeSettingsWindow() }

        let suiteName = "SettingsIntegrationTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        UserDefaults.standard.removeObject(forKey: "Bitz.AgentMonitor.PopupsEnabled")
        defer { UserDefaults.standard.removeObject(forKey: "Bitz.AgentMonitor.PopupsEnabled") }

        // 1. Set up Mascot Overlay Panel and verify baseline invariants
        let panel = MascotOverlayPanel()
        XCTAssertTrue(panel.ignoresMouseEvents, "Overlay panel must ignore mouse events by default")
        XCTAssertFalse(panel.canBecomeKey, "Overlay panel must never steal keyboard focus")
        XCTAssertFalse(panel.canBecomeMain, "Overlay panel must never become main window")
        XCTAssertTrue(panel.styleMask.contains(.nonactivatingPanel), "Overlay panel must be non-activating")

        // 2. Set up Stores & Dependencies
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

        // 3. Open Settings Window via SettingsWindowManager
        SettingsWindowManager.shared.showSettingsWindow(rootView: rootView)

        XCTAssertTrue(SettingsWindowManager.shared.isWindowOpen, "Settings window must be marked open")
        guard let window = SettingsWindowManager.shared.window else {
            XCTFail("Settings window must be created")
            return
        }

        XCTAssertTrue(window.styleMask.contains(.titled), "Settings window must be titled")
        XCTAssertTrue(window.styleMask.contains(.closable), "Settings window must be closable")
        XCTAssertTrue(window.styleMask.contains(.miniaturizable), "Settings window must be miniaturizable")
        XCTAssertEqual(window.title, "Bitz Settings", "Settings window title must match")
        XCTAssertTrue(window.canBecomeKey, "Settings window can become key for user interactions")

        // 4. Invariant Assertion: MascotOverlayPanel invariants are completely unaffected
        XCTAssertTrue(panel.ignoresMouseEvents, "Overlay panel must remain click-through while settings window is open")
        XCTAssertFalse(panel.canBecomeKey, "Overlay panel must never steal key window state")
        XCTAssertFalse(panel.canBecomeMain, "Overlay panel must never become main window")

        // 5. Simulate settings modification (e.g. scale change)
        scaleStore.stepUp()
        XCTAssertEqual(scaleStore.scaleFactor, 1.10, accuracy: 0.001)

        // Overlay invariants still preserved
        XCTAssertTrue(panel.ignoresMouseEvents, "Overlay panel ignoresMouseEvents must stay true after setting mutations")
        XCTAssertFalse(panel.canBecomeKey)

        // 6. Close Settings Window
        SettingsWindowManager.shared.closeSettingsWindow()
        XCTAssertFalse(SettingsWindowManager.shared.isWindowOpen, "Settings window must be marked closed")
        XCTAssertTrue(panel.ignoresMouseEvents)
        XCTAssertFalse(panel.canBecomeKey)
    }

    func testSettingsWindowReopenReusesExistingWindowInstance() {
        defer { SettingsWindowManager.shared.closeSettingsWindow() }

        let suiteName = "SettingsReopenTests.\(UUID().uuidString)"
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

        // First open
        SettingsWindowManager.shared.showSettingsWindow(rootView: rootView)
        let firstWindow = SettingsWindowManager.shared.window
        XCTAssertNotNil(firstWindow)

        // Second call while open should reuse the same window
        SettingsWindowManager.shared.showSettingsWindow(rootView: rootView)
        let secondWindow = SettingsWindowManager.shared.window
        XCTAssertTrue(firstWindow === secondWindow, "Same window instance must be reused")

        // Close
        SettingsWindowManager.shared.closeSettingsWindow()
        XCTAssertFalse(SettingsWindowManager.shared.isWindowOpen)
    }

    func testAppDelegateApplicationShouldHandleReopenPresentsSettingsWindow() {
        defer { SettingsWindowManager.shared.closeSettingsWindow() }

        let suiteName = "SettingsAppDelegateReopenTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let riveController = ProductionRiveController()
        let telemetry = MockTelemetryProvider()
        let scaleStore = AvatarScaleStore(userDefaults: defaults)
        let opacityStore = AvatarOpacityStore(userDefaults: defaults)
        let positionStore = AvatarPositionStore(userDefaults: defaults)
        let displayStore = DisplayPreferenceStore(userDefaults: defaults)
        let updateStore = AppUpdateStore(userDefaults: defaults)

        let appDelegate = BitzAppDelegate(
            riveController: riveController,
            telemetryProvider: telemetry,
            scaleStore: scaleStore,
            opacityStore: opacityStore,
            positionStore: positionStore,
            displayStore: displayStore,
            updateStore: updateStore,
            userDefaults: defaults
        )

        // Ensure settings window starts closed
        SettingsWindowManager.shared.closeSettingsWindow()
        XCTAssertFalse(SettingsWindowManager.shared.isWindowOpen)

        // Calling applicationShouldHandleReopen must present settings window and return true
        let handled = appDelegate.applicationShouldHandleReopen(NSApplication.shared, hasVisibleWindows: false)
        XCTAssertTrue(handled, "applicationShouldHandleReopen must return true")
        XCTAssertTrue(SettingsWindowManager.shared.isWindowOpen, "Settings window must be opened upon reopen")

        // Calling again with visible windows flag true must keep/re-show window and return true
        let handledAgain = appDelegate.applicationShouldHandleReopen(NSApplication.shared, hasVisibleWindows: true)
        XCTAssertTrue(handledAgain, "applicationShouldHandleReopen must return true when already open")
        XCTAssertTrue(SettingsWindowManager.shared.isWindowOpen)

        SettingsWindowManager.shared.closeSettingsWindow()
        XCTAssertFalse(SettingsWindowManager.shared.isWindowOpen)
    }

    func testMascotOverlayViewOpenSettingsCallbackConfiguration() {
        let suiteName = "MascotOverlayViewSettingsTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let riveController = ProductionRiveController()
        let engine = WellnessPointEngine(riveController: riveController, userDefaults: defaults)
        let scaleStore = AvatarScaleStore(userDefaults: defaults)
        let opacityStore = AvatarOpacityStore(userDefaults: defaults)
        let positionStore = AvatarPositionStore(userDefaults: defaults)
        let telemetrySettings = TelemetrySettingsStore(userDefaults: defaults)
        let telemetryDashboard = TelemetryDashboardService(settingsStore: telemetrySettings)

        var settingsOpened = false
        let overlayView = MascotOverlayView(
            engine: engine,
            scaleStore: scaleStore,
            opacityStore: opacityStore,
            positionStore: positionStore,
            telemetryDashboard: telemetryDashboard,
            telemetrySettings: telemetrySettings,
            onOpenSettings: {
                settingsOpened = true
            }
        )

        XCTAssertNotNil(overlayView.onOpenSettings)
        overlayView.onOpenSettings?()
        XCTAssertTrue(settingsOpened, "onOpenSettings closure must be invokable and update state")
    }

    func testSettingsWindowCloseClearsSimulationOverride() {
        let suiteName = "SettingsWindowSimulationOverrideTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let riveController = ProductionRiveController()
        let telemetry = MockTelemetryProvider()
        let scaleStore = AvatarScaleStore(userDefaults: defaults)
        let opacityStore = AvatarOpacityStore(userDefaults: defaults)
        let positionStore = AvatarPositionStore(userDefaults: defaults)
        let displayStore = DisplayPreferenceStore(userDefaults: defaults)
        let updateStore = AppUpdateStore(userDefaults: defaults)

        let appDelegate = BitzAppDelegate(
            riveController: riveController,
            telemetryProvider: telemetry,
            scaleStore: scaleStore,
            opacityStore: opacityStore,
            positionStore: positionStore,
            displayStore: displayStore,
            updateStore: updateStore,
            userDefaults: defaults
        )

        // Simulate opening settings window
        appDelegate.showSettingsWindow()
        XCTAssertTrue(SettingsWindowManager.shared.isWindowOpen)

        // User starts simulation
        appDelegate.activityMonitor.startSimulation(points: 20.0, continuousWorkMinutes: 0.0)
        XCTAssertTrue(appDelegate.activityMonitor.isManualOverrideActive)
        XCTAssertEqual(appDelegate.engine.currentState, .dopamineSad)
        appDelegate.agentMonitor.hookActionMessage = "Failed to install hooks: test"
        appDelegate.agentMonitor.isHookActionError = true

        // Close settings window
        SettingsWindowManager.shared.closeSettingsWindow()
        XCTAssertFalse(SettingsWindowManager.shared.isWindowOpen)

        // Simulation override must be automatically cleared
        XCTAssertFalse(appDelegate.activityMonitor.isManualOverrideActive)
        XCTAssertNotEqual(appDelegate.engine.currentState, .dopamineSad)
        // A stale hook message must not contradict the live badge on reopen
        XCTAssertNil(appDelegate.agentMonitor.hookActionMessage)
        XCTAssertFalse(appDelegate.agentMonitor.isHookActionError)
    }

    /// #94 WP3 (C10 / D-3): Settings opens automatically only on the first launch, not on subsequent logins/launches.
    func testWP3SettingsOpensOnlyOnFirstLaunchAndReopen() {
        defer { SettingsWindowManager.shared.closeSettingsWindow() }

        let suiteName = "SettingsFirstLaunchTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        SettingsWindowManager.shared.closeSettingsWindow()
        XCTAssertFalse(SettingsWindowManager.shared.isWindowOpen)

        let firstDelegate = BitzAppDelegate(
            telemetryProvider: MockTelemetryProvider(),
            scaleStore: AvatarScaleStore(userDefaults: defaults),
            opacityStore: AvatarOpacityStore(userDefaults: defaults),
            positionStore: AvatarPositionStore(userDefaults: defaults),
            displayStore: DisplayPreferenceStore(userDefaults: defaults),
            updateStore: AppUpdateStore(userDefaults: defaults),
            userDefaults: defaults
        )

        XCTAssertTrue(firstDelegate.shouldOpenSettingsOnLaunch(), "First launch must open Settings")
        XCTAssertTrue(defaults.bool(forKey: BitzAppDelegate.hasCompletedInitialLaunchKey))
        XCTAssertFalse(firstDelegate.shouldOpenSettingsOnLaunch(), "Subsequent launches must not auto-open Settings")
    }
}
