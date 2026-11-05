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
        let positionStore = AvatarPositionStore(userDefaults: defaults)
        let displayStore = DisplayPreferenceStore(userDefaults: defaults)
        let agentMonitor = AgentMonitorService(adapters: [])
        let updateStore = AppUpdateStore(userDefaults: defaults)
        let telemetrySettings = TelemetrySettingsStore(userDefaults: defaults)
        let telemetryDashboard = TelemetryDashboardService(settingsStore: telemetrySettings)

        let menuView = BitzMenuBarContentView(
            engine: engine,
            activityMonitor: activityMonitor,
            positionStore: positionStore,
            agentMonitor: agentMonitor,
            updateStore: updateStore,
            telemetryDashboard: telemetryDashboard,
            telemetrySettings: telemetrySettings
        )

        // Verify view body can be evaluated without crashing
        _ = menuView.body
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
            positionStore: AvatarPositionStore(userDefaults: defaults),
            agentMonitor: AgentMonitorService(adapters: [], userDefaults: defaults),
            updateStore: updateStore,
            telemetryDashboard: telemetryDashboard,
            telemetrySettings: telemetrySettings
        )
        let stats = telemetryDashboard.snapshot.menuBarItems(enabledMetrics: [.ram]).joined(separator: " | ")
        XCTAssertFalse(stats.isEmpty)

        let telemetrySection = MenuBarTelemetrySectionView(
            telemetryDashboard: telemetryDashboard,
            telemetrySettings: telemetrySettings
        )
        XCTAssertTrue(String(describing: menuView.body).contains(updateStore.statusMessage))
        XCTAssertTrue(String(describing: telemetrySection.body).contains(stats))
        telemetrySettings.displayInMenuBarMenu = false
        XCTAssertFalse(String(describing: telemetrySection.body).contains(stats))
    }

    /// #94 D1 / AGENTS.md §2.5: root BitzMenuBarContentView must not observe polling TelemetryDashboardService directly.
    func testMenuBarRootViewIsolatesTelemetryDashboardObserverToLeafSubview() {
        let suiteName = "MenuBarLeafObserverTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let engine = WellnessPointEngine(riveController: ProductionRiveController(), userDefaults: defaults)
        let telemetrySettings = TelemetrySettingsStore(userDefaults: defaults)
        let telemetryDashboard = TelemetryDashboardService(settingsStore: telemetrySettings)
        let menuView = BitzMenuBarContentView(
            engine: engine,
            activityMonitor: ActivityMonitorService(engine: engine, telemetry: MockTelemetryProvider()),
            positionStore: AvatarPositionStore(userDefaults: defaults),
            agentMonitor: AgentMonitorService(adapters: [], userDefaults: defaults),
            updateStore: AppUpdateStore(userDefaults: defaults),
            telemetryDashboard: telemetryDashboard,
            telemetrySettings: telemetrySettings
        )

        let rootObservedTypes = Mirror(reflecting: menuView).children.map { String(describing: type(of: $0.value)) }
        XCTAssertFalse(
            rootObservedTypes.contains { $0.contains("ObservedObject<TelemetryDashboardService>") },
            "Root BitzMenuBarContentView must not hold @ObservedObject on polling TelemetryDashboardService"
        )
    }

    /// #94 WP2 (B1–B8): lean menu bar layout with single header line, fixed Show Mascot label,
    /// plain Resume Live Sensors button, single Break Shield action, and no duplicated shortcut strings.
    func testMenuBarWP2LeanLayoutAndCleanLabels() {
        let suiteName = "MenuBarWP2Tests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let engine = WellnessPointEngine(riveController: ProductionRiveController(), userDefaults: defaults)
        engine.setPoints(72.0, continuousWorkMinutes: 25.0)
        let activityMonitor = ActivityMonitorService(engine: engine, telemetry: MockTelemetryProvider())
        let positionStore = AvatarPositionStore(userDefaults: defaults)
        positionStore.unlockPosition()
        let flowSettings = FlowShieldSettingsStore(userDefaults: defaults)
        flowSettings.setEnabled(true)
        let flowService = FlowShieldService(settingsStore: flowSettings, shortcutsRunner: SpyShortcutsRunner())
        let audioSettings = CyberAudioSettingsStore(userDefaults: defaults)
        let telemetrySettings = TelemetrySettingsStore(userDefaults: defaults)
        let telemetryDashboard = TelemetryDashboardService(settingsStore: telemetrySettings)

        let menuView = BitzMenuBarContentView(
            engine: engine,
            activityMonitor: activityMonitor,
            positionStore: positionStore,
            agentMonitor: AgentMonitorService(adapters: [], userDefaults: defaults),
            updateStore: AppUpdateStore(userDefaults: defaults),
            telemetryDashboard: telemetryDashboard,
            telemetrySettings: telemetrySettings,
            audioSettings: audioSettings,
            flowShieldSettings: flowSettings,
            flowShieldService: flowService
        )

        activityMonitor.startSimulation(points: 72.0, continuousWorkMinutes: 25.0)
        let rendered = String(describing: menuView.body)

        // B6: single header line with state, PTS, and streak (no duplicate "Focus: X / 100" line)
        XCTAssertTrue(rendered.contains("Bitz — Balanced · 72 PTS · 25 min streak"))
        XCTAssertFalse(rendered.contains("Focus:"))

        // B1 & B2: no embedded shortcut text in titles
        XCTAssertFalse(rendered.contains("(⌘=)"))
        XCTAssertFalse(rendered.contains("(⌘[)"))
        XCTAssertFalse(rendered.contains("[⎋ Esc"))
        XCTAssertTrue(rendered.contains("Lock Position"))

        // B3: fixed "Show Mascot" toggle label
        XCTAssertTrue(rendered.contains("Show Mascot"))
        XCTAssertFalse(rendered.contains("Mascot Visible on Screen"))
        XCTAssertFalse(rendered.contains("Mascot Hidden"))

        // B7: plain "Resume Live Sensors" button when override is active
        XCTAssertTrue(rendered.contains("Resume Live Sensors"))

        // B5 & B8: single Break Shield action when enabled, master Sound toggle, Theme submenu,
        // and no duplicated per-sound / volume / size-opacity submenus in the dropdown
        XCTAssertTrue(rendered.contains("Break Shield (Disable Focus)"))
        XCTAssertTrue(rendered.contains("Sound"))
        XCTAssertTrue(rendered.contains("Theme"))
        XCTAssertFalse(rendered.contains("Size & Opacity"))
        XCTAssertFalse(rendered.contains("Soothing Purr"))
        XCTAssertFalse(rendered.contains("Volume: 25%"))
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
