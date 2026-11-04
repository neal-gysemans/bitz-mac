import XCTest
import SwiftUI
@testable import BitzCore

@MainActor
final class FlowShieldViewsTests: XCTestCase {

    func testBehaviorSettingsTabViewDefaultAndExplicitFlowShieldWiring() async {
        let suiteName = "FlowShieldViewsTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let engine = WellnessPointEngine(userDefaults: defaults)
        let activityMonitor = ActivityMonitorService(engine: engine, telemetry: MockTelemetryProvider())

        // Legacy 2-argument call site must still compile and evaluate cleanly
        let legacyBehaviorView = BehaviorSettingsTabView(engine: engine, activityMonitor: activityMonitor)
        _ = legacyBehaviorView.body

        let flowSettings = FlowShieldSettingsStore(userDefaults: defaults)
        let spy = SpyShortcutsRunner()
        let flowService = FlowShieldService(settingsStore: flowSettings, shortcutsRunner: spy)
        flowService.observe(wellnessEngine: engine)

        let explicitBehaviorView = BehaviorSettingsTabView(
            engine: engine,
            activityMonitor: activityMonitor,
            flowShieldSettings: flowSettings,
            flowShieldService: flowService
        )
        _ = explicitBehaviorView.body

        flowSettings.setEnabled(true)
        flowSettings.setStreakMinutesThreshold(25.0)
        _ = explicitBehaviorView.body

        engine.evaluateWorkTick(isProductiveApp: true, tickDurationMinutes: 25.0)
        await flowService.waitForPendingShortcuts()
        XCTAssertTrue(flowService.isFlowShieldActive)
        _ = explicitBehaviorView.body

        flowService.activateBreakShieldOverride()
        await flowService.waitForPendingShortcuts()
        XCTAssertFalse(flowService.isFlowShieldActive)
        XCTAssertTrue(flowSettings.isBreakShieldOverrideActive)
        _ = explicitBehaviorView.body

        XCTAssertEqual(spy.invokedShortcutNames, ["Start Focus", "Stop Focus"])
    }

    func testSettingsRootViewMenuBarAndAppDelegateFlowShieldIntegration() async {
        let suiteName = "FlowShieldViewsTests.App.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let spy = SpyShortcutsRunner()
        let flowSettings = FlowShieldSettingsStore(userDefaults: defaults)
        let flowService = FlowShieldService(settingsStore: flowSettings, shortcutsRunner: spy)

        let delegate = BitzAppDelegate(
            telemetryProvider: MockTelemetryProvider(),
            scaleStore: AvatarScaleStore(userDefaults: defaults),
            opacityStore: AvatarOpacityStore(userDefaults: defaults),
            positionStore: AvatarPositionStore(userDefaults: defaults),
            displayStore: DisplayPreferenceStore(userDefaults: defaults),
            updateStore: AppUpdateStore(userDefaults: defaults),
            flowShieldSettings: flowSettings,
            flowShieldService: flowService,
            userDefaults: defaults
        )

        let rootView = SettingsRootView(
            engine: delegate.engine,
            activityMonitor: delegate.activityMonitor,
            scaleStore: delegate.scaleStore,
            opacityStore: delegate.opacityStore,
            positionStore: delegate.positionStore,
            displayStore: delegate.displayStore,
            agentMonitor: delegate.agentMonitor,
            updateStore: delegate.updateStore,
            telemetryDashboard: delegate.telemetryDashboard,
            telemetrySettings: delegate.telemetrySettings,
            audioSettings: delegate.audioSettings,
            audioPlayer: delegate.audioService,
            flowShieldSettings: delegate.flowShieldSettings,
            flowShieldService: delegate.flowShieldService
        )
        _ = rootView.body

        let menuBarView = BitzMenuBarContentView(
            engine: delegate.engine,
            activityMonitor: delegate.activityMonitor,
            scaleStore: delegate.scaleStore,
            opacityStore: delegate.opacityStore,
            positionStore: delegate.positionStore,
            agentMonitor: delegate.agentMonitor,
            updateStore: delegate.updateStore,
            telemetryDashboard: delegate.telemetryDashboard,
            telemetrySettings: delegate.telemetrySettings,
            audioSettings: delegate.audioSettings,
            audioService: delegate.audioService,
            flowShieldSettings: delegate.flowShieldSettings,
            flowShieldService: delegate.flowShieldService
        )
        _ = menuBarView.body

        // Verify BitzAppDelegate wired flowShieldService.observe(wellnessEngine: engine)
        delegate.flowShieldSettings.setEnabled(true)
        delegate.flowShieldSettings.setStreakMinutesThreshold(20.0)
        delegate.engine.evaluateWorkTick(isProductiveApp: true, tickDurationMinutes: 20.0)
        await delegate.flowShieldService.waitForPendingShortcuts()

        XCTAssertTrue(delegate.flowShieldService.isFlowShieldActive)
        XCTAssertEqual(spy.invokedShortcutNames, ["Start Focus"])
        _ = menuBarView.body

        // Menu Bar Break Shield override disables Focus immediately
        delegate.flowShieldService.activateBreakShieldOverride()
        await delegate.flowShieldService.waitForPendingShortcuts()
        XCTAssertFalse(delegate.flowShieldService.isFlowShieldActive)
        XCTAssertEqual(spy.invokedShortcutNames, ["Start Focus", "Stop Focus"])
    }
}
