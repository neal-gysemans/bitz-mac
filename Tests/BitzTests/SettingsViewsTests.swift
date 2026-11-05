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
            positionStore: positionStore,
            displayStore: displayStore
        )
        let appearanceTab = AppearanceSettingsTabView(
            scaleStore: scaleStore,
            opacityStore: opacityStore,
            paletteStore: AvatarPaletteStore(userDefaults: defaults)
        )

        _ = tab.body
        _ = appearanceTab.body

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

        let tabWithEngine = AppearanceSettingsTabView(
            scaleStore: scaleStore,
            opacityStore: opacityStore,
            engine: engine,
            paletteStore: AvatarPaletteStore(userDefaults: defaults)
        )
        _ = tabWithEngine.body
    }

    func testBehaviorTabAndMenuBarRenderSimulationOverrideBanner() {
        let suiteName = "SimulationOverrideBannerTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let engine = WellnessPointEngine(userDefaults: defaults)
        let telemetry = MockTelemetryProvider()
        let activityMonitor = ActivityMonitorService(engine: engine, telemetry: telemetry)
        let behaviorTab = BehaviorSettingsTabView(engine: engine, activityMonitor: activityMonitor)

        // Renders without override
        _ = behaviorTab.body

        // Renders with override active
        activityMonitor.startChargingSimulation()
        XCTAssertTrue(activityMonitor.isManualOverrideActive)
        _ = behaviorTab.body

        let positionStore = AvatarPositionStore(userDefaults: defaults)
        let displayStore = DisplayPreferenceStore(userDefaults: defaults)
        let agentMonitor = AgentMonitorService(adapters: [], userDefaults: defaults)
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

        activityMonitor.clearManualOverride()
        XCTAssertFalse(activityMonitor.isManualOverrideActive)
        _ = menuView.body
    }

    /// #94 A6: the engine's per-tick deltas are shown per minute at the 5 s sample cadence.
    func testPointRateLabelIsPerMinute() {
        XCTAssertEqual(BehaviorSettingsTabView.pointRateLabel(isProductive: true), "+6 PTS / min")
        XCTAssertEqual(BehaviorSettingsTabView.pointRateLabel(isProductive: false), "-18 PTS / min")
    }

    /// #94 A10: states read as words, not enum cases.
    func testStateDisplayNamesAreHumanReadable() {
        XCTAssertEqual(BitzState.superCharged.displayName, "Super Charged")
        XCTAssertEqual(BitzState.dopamineSad.displayName, "Dopamine Sad")
    }

    /// #94 WP3 (C1, C2, C3, C4): footer drops Quit & hidden buttons; General splits out Appearance; hold hint is conditional.
    func testWP3FooterAndGeneralAppearanceSplit() {
        let suiteName = "WP3GeneralAppearanceTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        XCTAssertTrue(SettingsTab.allCases.contains(.appearance))
        XCTAssertEqual(SettingsTab.appearance.rawValue, "Appearance")

        let engine = WellnessPointEngine(userDefaults: defaults)
        let activityMonitor = ActivityMonitorService(engine: engine, telemetry: MockTelemetryProvider())
        let scaleStore = AvatarScaleStore(userDefaults: defaults)
        let opacityStore = AvatarOpacityStore(userDefaults: defaults)
        let positionStore = AvatarPositionStore(userDefaults: defaults)
        let displayStore = DisplayPreferenceStore(userDefaults: defaults)
        let interactionSettings = MascotInteractionSettingsStore(userDefaults: defaults)
        let paletteStore = AvatarPaletteStore(userDefaults: defaults)
        let telemetrySettings = TelemetrySettingsStore(userDefaults: defaults)
        let telemetryDashboard = TelemetryDashboardService(settingsStore: telemetrySettings)

        let rootView = SettingsRootView(
            engine: engine,
            activityMonitor: activityMonitor,
            scaleStore: scaleStore,
            opacityStore: opacityStore,
            positionStore: positionStore,
            displayStore: displayStore,
            agentMonitor: AgentMonitorService(adapters: [], userDefaults: defaults),
            updateStore: AppUpdateStore(userDefaults: defaults),
            telemetryDashboard: telemetryDashboard,
            telemetrySettings: telemetrySettings,
            interactionSettings: interactionSettings,
            paletteStore: paletteStore
        )
        let rootRendered = String(describing: rootView.body)
        XCTAssertTrue(rootRendered.contains("Show Mascot on Desktop"))
        XCTAssertTrue(rootRendered.contains("Close Settings"))
        XCTAssertFalse(rootRendered.contains("Quit Bitz"))

        let generalTab = GeneralSettingsTabView(
            positionStore: positionStore,
            displayStore: displayStore,
            interactionSettings: interactionSettings
        )
        let generalRendered = String(describing: generalTab.body)
        // C1 & C3: visibility toggle is in the footer, size/opacity/theme moved to AppearanceSettingsTabView
        XCTAssertFalse(generalRendered.contains("Desktop Mascot Visibility"))
        XCTAssertFalse(generalRendered.contains("Avatar Size & Scale"))
        XCTAssertTrue(generalRendered.contains("anytime to freely drag Bitz"))

        // C4: disabling hold-to-interact hides the hold-drag hint
        interactionSettings.isHoldToInteractEnabled = false
        let generalDisabledHold = String(describing: generalTab.body)
        XCTAssertFalse(generalDisabledHold.contains("anytime to freely drag Bitz"))

        // C3: Appearance tab hosts preview, size, opacity, and theme
        let appearanceTab = AppearanceSettingsTabView(
            scaleStore: scaleStore,
            opacityStore: opacityStore,
            engine: engine,
            paletteStore: paletteStore
        )
        let appearanceRendered = String(describing: appearanceTab.body)
        XCTAssertTrue(appearanceRendered.contains("Live Mascot Preview"))
        XCTAssertTrue(appearanceRendered.contains("Avatar Size & Scale"))
        XCTAssertTrue(appearanceRendered.contains("Mascot Opacity & Transparency"))
    }

    /// #94 WP3 (C1, C5, C11): Behaviors tab removes duplicate Pet/Override controls and distinguishes custom rule tags.
    func testWP3BehaviorTabCleanupAndCustomRuleTag() {
        let suiteName = "WP3BehaviorTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let engine = WellnessPointEngine(userDefaults: defaults)
        let activityMonitor = ActivityMonitorService(engine: engine, telemetry: MockTelemetryProvider())
        activityMonitor.startChargingSimulation()

        let behaviorTab = BehaviorSettingsTabView(engine: engine, activityMonitor: activityMonitor)
        let rendered = String(describing: behaviorTab.body)
        XCTAssertFalse(rendered.contains("Pet Bitz"))
        XCTAssertFalse(rendered.contains("Manual Simulation Override Active"))

        XCTAssertEqual(BehaviorSettingsTabView.customRuleTag(for: true), " (Custom: Productive)")
        XCTAssertEqual(BehaviorSettingsTabView.customRuleTag(for: false), " (Custom: Distraction)")
        XCTAssertEqual(BehaviorSettingsTabView.customRuleTag(for: nil), "")
    }

    /// #94 WP3 (C6, C7, C8, C9): Agent simulation in Advanced, scoped shortcut labels, Login Items button, and Claude hook state.
    func testWP3AdvancedAndAgentsTabsUXCleanup() throws {
        let suiteName = "WP3AdvancedAgentsTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("bitz-wp3-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }
        let settingsURL = tempDir.appendingPathComponent("settings.json")

        XCTAssertTrue(AgentHookInstaller.claudeHookStatus(at: settingsURL) == (false, false))
        try AgentHookInstaller.updateSettingsFile(at: settingsURL, AgentHookInstaller.installClaudeHooks)
        XCTAssertTrue(AgentHookInstaller.claudeHookStatus(at: settingsURL) == (true, true))

        // Partial install: one Bitz event missing reads as not fully installed but still uninstallable.
        var partial = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: settingsURL)) as? [String: Any])
        var partialHooks = try XCTUnwrap(partial["hooks"] as? [String: Any])
        partialHooks["Stop"] = nil
        partial["hooks"] = partialHooks
        let partialURL = tempDir.appendingPathComponent("partial.json")
        try JSONSerialization.data(withJSONObject: partial).write(to: partialURL)
        XCTAssertTrue(AgentHookInstaller.claudeHookStatus(at: partialURL) == (false, true))

        let monitor = AgentMonitorService(adapters: [], userDefaults: defaults)
        monitor.hookActionMessage = "Claude Code hooks successfully installed!"
        let agentsTab = AgentsSettingsTabView(agentMonitor: monitor, claudeSettingsURL: settingsURL)
        let agentsRendered = String(describing: agentsTab.body)
        // C9: simulation buttons moved out of Agents tab
        XCTAssertFalse(agentsRendered.contains("Question / Chime"))
        // C7: hook status & persisted message rendered
        XCTAssertTrue(agentsRendered.contains("Installed"))
        XCTAssertFalse(agentsRendered.contains("Not Installed"))
        XCTAssertTrue(agentsRendered.contains("Claude Code hooks successfully installed!"))

        let engine = WellnessPointEngine(userDefaults: defaults)
        let activityMonitor = ActivityMonitorService(engine: engine, telemetry: MockTelemetryProvider())
        let advancedTab = AdvancedSettingsTabView(
            engine: engine,
            activityMonitor: activityMonitor,
            updateStore: AppUpdateStore(userDefaults: defaults),
            agentMonitor: monitor
        )
        let advancedRendered = String(describing: advancedTab.body)
        // C9: agent simulation buttons present in Advanced tab
        XCTAssertTrue(advancedRendered.contains("Question / Chime"))
        XCTAssertTrue(advancedRendered.contains("All Done / Fanfare"))
        // C8: global vs focused shortcut headings
        XCTAssertTrue(advancedRendered.contains("Global (Works from Any App)"))
        XCTAssertTrue(advancedRendered.contains("When Bitz or Settings is Focused"))
        // C6: Open Login Items button
        XCTAssertTrue(advancedRendered.contains("Open Login Items"))
        XCTAssertNotNil(AdvancedSettingsTabView.launchAtLoginApprovalMessage(for: .requiresApproval))
        XCTAssertNil(AdvancedSettingsTabView.launchAtLoginApprovalMessage(for: .enabled))
    }
}
