import XCTest
import SwiftUI
import AppKit
@testable import BitzCore

@MainActor
final class PersonalitySettingsTabTests: XCTestCase {

    private func makeIsolatedDefaults() -> (UserDefaults, String) {
        let suiteName = "PersonalitySettingsTabTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        OverlayFixture.resetAgentMonitorDefaults()
        return (defaults, suiteName)
    }

    // MARK: - Two-way Binding & Persistence Tests

    func testPersonalitySettingsTwoWayBindingsPersist() {
        let (defaults, suite) = makeIsolatedDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }

        let store = PersonalitySettingsStore(userDefaults: defaults)

        // Initial defaults
        XCTAssertFalse(store.isEnabled)
        XCTAssertEqual(store.preset, .snarky)
        XCTAssertEqual(store.minIntervalMinutes, PersonalitySettingsStore.defaultMinIntervalMinutes)
        XCTAssertEqual(store.dailyCap, PersonalitySettingsStore.defaultDailyCap)

        // Mutate through store setters (mirrored by SwiftUI bindings)
        store.setEnabled(true)
        store.setPreset(.supportive)
        store.setMinIntervalMinutes(15)
        store.setDailyCap(50)
        store.addWatchedRepoPath("/Users/test/project")

        // Re-read from a completely new store instance backed by same UserDefaults suite
        let reloadedStore = PersonalitySettingsStore(userDefaults: defaults)
        XCTAssertTrue(reloadedStore.isEnabled)
        XCTAssertEqual(reloadedStore.preset, .supportive)
        XCTAssertEqual(reloadedStore.minIntervalMinutes, 15)
        XCTAssertEqual(reloadedStore.dailyCap, 50)
        XCTAssertEqual(reloadedStore.watchedRepoPaths, ["/Users/test/project"])
    }

    func testPersonalitySettingsTabViewRenders() {
        let (defaults, suite) = makeIsolatedDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }

        let store = PersonalitySettingsStore(userDefaults: defaults)
        let tabView = PersonalitySettingsTabView(settingsStore: store)

        // Verify availability computation evaluates safely without crashing
        _ = tabView.isFoundationModelsAvailable
        XCTAssertNotNil(tabView.body)
    }

    // MARK: - Tab Router Registration

    func testSettingsTabEnumerationIncludesPersonality() {
        XCTAssertTrue(SettingsTab.allCases.contains(.personality))
        XCTAssertEqual(SettingsTab.personality.rawValue, "Personality")
        XCTAssertEqual(SettingsTab.personality.icon, "sparkles")
    }

    func testSettingsRootViewIncludesPersonalityTabAndStore() {
        let (defaults, suite) = makeIsolatedDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }

        let fixture = OverlayFixture(defaults: defaults)
        let personalityStore = PersonalitySettingsStore(userDefaults: defaults)
        personalityStore.setEnabled(true)

        let rootView = SettingsRootView(
            engine: fixture.engine,
            activityMonitor: ActivityMonitorService(engine: fixture.engine, telemetry: MockActivityTelemetryProvider()),
            scaleStore: fixture.scaleStore,
            opacityStore: fixture.opacityStore,
            positionStore: fixture.positionStore,
            displayStore: DisplayPreferenceStore(userDefaults: defaults),
            agentMonitor: fixture.agentMonitor,
            updateStore: fixture.updateStore,
            telemetryDashboard: fixture.telemetryDashboard,
            telemetrySettings: fixture.telemetrySettings,
            personalitySettings: personalityStore,
            meetingRecorder: .stub(defaults: defaults)
        )

        XCTAssertNotNil(rootView.body)
        XCTAssertTrue(rootView.personalitySettings.isEnabled)
    }

    // MARK: - Window Detachment Invariant (#70)

    func testSettingsWindowDetachesHostedContentOnClose() throws {
        let (defaults, suite) = makeIsolatedDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }

        let fixture = OverlayFixture(defaults: defaults)
        let personalityStore = PersonalitySettingsStore(userDefaults: defaults)

        let manager = SettingsWindowManager()
        let rootView = SettingsRootView(
            engine: fixture.engine,
            activityMonitor: ActivityMonitorService(engine: fixture.engine, telemetry: MockActivityTelemetryProvider()),
            scaleStore: fixture.scaleStore,
            opacityStore: fixture.opacityStore,
            positionStore: fixture.positionStore,
            displayStore: DisplayPreferenceStore(userDefaults: defaults),
            agentMonitor: fixture.agentMonitor,
            updateStore: fixture.updateStore,
            telemetryDashboard: fixture.telemetryDashboard,
            telemetrySettings: fixture.telemetrySettings,
            personalitySettings: personalityStore,
            meetingRecorder: .stub(defaults: defaults)
        )

        manager.showSettingsWindow(rootView: rootView)
        XCTAssertTrue(manager.isWindowOpen)
        let window = try XCTUnwrap(manager.window)
        XCTAssertNotNil(window.contentViewController)

        // Close window and verify complete detachment
        manager.closeSettingsWindow()
        XCTAssertFalse(manager.isWindowOpen)
        XCTAssertNil(window.contentViewController, "Closing Settings MUST detach contentViewController (invariant #70)")
    }
}

private struct MockActivityTelemetryProvider: ActivityTelemetryProviding {
    func secondsSinceLastInput() -> Double { 0.0 }
    func frontmostBundleIdentifier() -> String? { nil }
    func frontmostApplicationName() -> String? { nil }
    func activeBrowserTab() -> (title: String?, url: String?) { (nil, nil) }
    func isVideoPlaybackActive() -> Bool { false }
    func cpuTemperatureCelsius() -> Double? { nil }
    func cpuLoadPercentage() -> Double? { nil }
    func thermalState() -> ProcessInfo.ThermalState { .nominal }
    func now() -> Date { Date() }
}
