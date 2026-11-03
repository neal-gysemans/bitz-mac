import XCTest
@testable import BitzCore

@MainActor
final class FlowShieldServiceTests: XCTestCase {

    func testDefaultDisabledNeverInvokesShortcutsAcrossWorkAndBreaks() async {
        let suiteName = "FlowShieldServiceTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let settings = FlowShieldSettingsStore(userDefaults: defaults)
        let spy = SpyShortcutsRunner()
        let engine = WellnessPointEngine(initialPoints: 60.0, initialContinuousWorkMinutes: 0.0)
        let service = FlowShieldService(settingsStore: settings, shortcutsRunner: spy)
        service.observe(wellnessEngine: engine)

        XCTAssertFalse(settings.isEnabled)
        XCTAssertEqual(service.currentStatus, .disabled)

        engine.evaluateWorkTick(isProductiveApp: true, tickDurationMinutes: 25.0)
        engine.setChargingState(true)
        engine.applyOfflineBreak(minutes: 5.0)
        await service.waitForPendingShortcuts()

        XCTAssertFalse(service.isFlowShieldActive)
        XCTAssertTrue(spy.invokedShortcutNames.isEmpty)
    }

    func testReachingStreakThresholdTriggersStartShortcutOnceAcrossRepeatedTicks() async {
        let suiteName = "FlowShieldServiceTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let settings = FlowShieldSettingsStore(userDefaults: defaults)
        settings.setEnabled(true)
        settings.setStreakMinutesThreshold(20.0)
        settings.setStartFocusShortcutName("Engage Focus")
        settings.setStopFocusShortcutName("End Focus")

        let spy = SpyShortcutsRunner()
        let engine = WellnessPointEngine(initialPoints: 60.0, initialContinuousWorkMinutes: 0.0)
        let service = FlowShieldService(settingsStore: settings, shortcutsRunner: spy)
        service.observe(wellnessEngine: engine)

        XCTAssertEqual(service.currentStatus, .standby)

        // Below threshold (19 min): must not trigger
        engine.evaluateWorkTick(isProductiveApp: true, tickDurationMinutes: 19.0)
        await service.waitForPendingShortcuts()
        XCTAssertFalse(service.isFlowShieldActive)
        XCTAssertTrue(spy.invokedShortcutNames.isEmpty)

        // Cross threshold (20 min): triggers Start Shortcut once
        engine.evaluateWorkTick(isProductiveApp: true, tickDurationMinutes: 1.0)
        await service.waitForPendingShortcuts()
        XCTAssertTrue(service.isFlowShieldActive)
        XCTAssertEqual(service.currentStatus, .active)
        XCTAssertEqual(spy.invokedShortcutNames, ["Engage Focus"])

        // Subsequent 5s productive ticks (and even a brief unproductive dip + recovery) must NOT re-trigger
        for _ in 0..<10 {
            engine.evaluateWorkTick(isProductiveApp: true, tickDurationMinutes: 5.0 / 60.0)
        }
        engine.evaluateWorkTick(isProductiveApp: false) // drops 20.8 -> 15.8 without a break
        engine.evaluateWorkTick(isProductiveApp: true, tickDurationMinutes: 6.0) // climbs back > 20
        await service.waitForPendingShortcuts()

        XCTAssertTrue(service.isFlowShieldActive)
        XCTAssertEqual(spy.invokedShortcutNames, ["Engage Focus"], "Start Shortcut must fire only once per streak")
    }

    func testBreakCompletionViaChargingAndOfflineBreakTriggersStopShortcutAndReArms() async {
        let suiteName = "FlowShieldServiceTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let settings = FlowShieldSettingsStore(userDefaults: defaults)
        settings.setEnabled(true)
        settings.setStreakMinutesThreshold(20.0)

        let spy = SpyShortcutsRunner()
        let engine = WellnessPointEngine(initialPoints: 60.0, initialContinuousWorkMinutes: 0.0)
        let service = FlowShieldService(settingsStore: settings, shortcutsRunner: spy)
        service.observe(wellnessEngine: engine)

        // 1) Reach first streak -> Start Focus
        engine.evaluateWorkTick(isProductiveApp: true, tickDurationMinutes: 22.0)
        await service.waitForPendingShortcuts()
        XCTAssertTrue(service.isFlowShieldActive)
        XCTAssertEqual(spy.invokedShortcutNames, ["Start Focus"])

        // 2) Step away (.charging) -> stays armed until break completes
        engine.setChargingState(true)
        await service.waitForPendingShortcuts()
        XCTAssertEqual(engine.currentState, .charging)
        XCTAssertEqual(spy.invokedShortcutNames, ["Start Focus"])

        // 3) Return from break (applyOfflineBreak resets streak to 0 and exits .charging) -> Stop Focus
        engine.applyOfflineBreak(minutes: 5.0)
        await service.waitForPendingShortcuts()
        XCTAssertFalse(service.isFlowShieldActive)
        XCTAssertEqual(service.currentStatus, .standby)
        XCTAssertEqual(spy.invokedShortcutNames, ["Start Focus", "Stop Focus"])

        // 4) New deep-work streak reaches 20m -> Start Focus again; direct sleep/wake offline break -> Stop Focus
        engine.evaluateWorkTick(isProductiveApp: true, tickDurationMinutes: 20.0)
        await service.waitForPendingShortcuts()
        XCTAssertTrue(service.isFlowShieldActive)
        XCTAssertEqual(spy.invokedShortcutNames, ["Start Focus", "Stop Focus", "Start Focus"])

        engine.applyOfflineBreak(minutes: 4.0)
        await service.waitForPendingShortcuts()
        XCTAssertFalse(service.isFlowShieldActive)
        XCTAssertEqual(spy.invokedShortcutNames, ["Start Focus", "Stop Focus", "Start Focus", "Stop Focus"])
    }

    func testBreakShieldOverrideImmediatelyStopsFocusAndSuppressesReactivation() async {
        let suiteName = "FlowShieldServiceTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let settings = FlowShieldSettingsStore(userDefaults: defaults)
        settings.setEnabled(true)
        settings.setStreakMinutesThreshold(15.0)

        let spy = SpyShortcutsRunner()
        let engine = WellnessPointEngine(initialPoints: 70.0, initialContinuousWorkMinutes: 0.0)
        let service = FlowShieldService(settingsStore: settings, shortcutsRunner: spy)
        service.observe(wellnessEngine: engine)

        engine.evaluateWorkTick(isProductiveApp: true, tickDurationMinutes: 16.0)
        await service.waitForPendingShortcuts()
        XCTAssertTrue(service.isFlowShieldActive)
        XCTAssertEqual(spy.invokedShortcutNames, ["Start Focus"])

        // Activate Break Shield override -> immediately runs Stop Focus
        service.activateBreakShieldOverride()
        await service.waitForPendingShortcuts()
        XCTAssertFalse(service.isFlowShieldActive)
        XCTAssertTrue(settings.isBreakShieldOverrideActive)
        XCTAssertEqual(service.currentStatus, .breakShieldOverride)
        XCTAssertEqual(spy.invokedShortcutNames, ["Start Focus", "Stop Focus"])

        // Further productive work ticks while override is active must NOT re-trigger Start Focus
        engine.evaluateWorkTick(isProductiveApp: true, tickDurationMinutes: 10.0)
        engine.evaluateWorkTick(isProductiveApp: true, tickDurationMinutes: 10.0)
        await service.waitForPendingShortcuts()
        XCTAssertFalse(service.isFlowShieldActive)
        XCTAssertEqual(spy.invokedShortcutNames, ["Start Focus", "Stop Focus"])

        // Clearing Break Shield override via toggle allows subsequent work ticks to engage Focus
        service.toggleBreakShieldOverride()
        XCTAssertFalse(settings.isBreakShieldOverrideActive)
        engine.evaluateWorkTick(isProductiveApp: true, tickDurationMinutes: 1.0)
        await service.waitForPendingShortcuts()
        XCTAssertTrue(service.isFlowShieldActive)
        XCTAssertEqual(spy.invokedShortcutNames, ["Start Focus", "Stop Focus", "Start Focus"])
    }

    func testDisablingMasterToggleWhileActiveImmediatelyStopsFocus() async {
        let suiteName = "FlowShieldServiceTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let settings = FlowShieldSettingsStore(userDefaults: defaults)
        settings.setEnabled(true)
        settings.setStreakMinutesThreshold(10.0)

        let spy = SpyShortcutsRunner()
        let engine = WellnessPointEngine(initialPoints: 75.0, initialContinuousWorkMinutes: 0.0)
        let service = FlowShieldService(settingsStore: settings, shortcutsRunner: spy)
        service.observe(wellnessEngine: engine)

        engine.evaluateWorkTick(isProductiveApp: true, tickDurationMinutes: 12.0)
        await service.waitForPendingShortcuts()
        XCTAssertTrue(service.isFlowShieldActive)
        XCTAssertEqual(spy.invokedShortcutNames, ["Start Focus"])

        // Disabling master toggle while active must run Stop Focus immediately
        settings.setEnabled(false)
        await service.waitForPendingShortcuts()
        XCTAssertFalse(service.isFlowShieldActive)
        XCTAssertEqual(service.currentStatus, .disabled)
        XCTAssertEqual(spy.invokedShortcutNames, ["Start Focus", "Stop Focus"])
    }

    func testFailedStartShortcutRecordsErrorRevertsActiveAndPreventsRetryStorm() async {
        let suiteName = "FlowShieldServiceTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let settings = FlowShieldSettingsStore(userDefaults: defaults)
        settings.setEnabled(true)
        settings.setStreakMinutesThreshold(20.0)

        let spy = SpyShortcutsRunner(
            simulatedError: FlowShieldShortcutError.executionFailed(
                shortcutName: "Start Focus",
                exitCode: 1,
                stderr: "Shortcut not found"
            )
        )
        let engine = WellnessPointEngine(initialPoints: 65.0, initialContinuousWorkMinutes: 0.0)
        let service = FlowShieldService(settingsStore: settings, shortcutsRunner: spy)
        service.observe(wellnessEngine: engine)

        engine.evaluateWorkTick(isProductiveApp: true, tickDurationMinutes: 20.0)
        await service.waitForPendingShortcuts()

        XCTAssertFalse(service.isFlowShieldActive)
        XCTAssertNotNil(service.lastErrorMessage)
        XCTAssertEqual(spy.invokedShortcutNames.count, 1)

        // Next 5s ticks must NOT retry every tick during the same streak
        engine.evaluateWorkTick(isProductiveApp: true, tickDurationMinutes: 1.0)
        engine.evaluateWorkTick(isProductiveApp: true, tickDurationMinutes: 1.0)
        await service.waitForPendingShortcuts()
        XCTAssertEqual(spy.invokedShortcutNames.count, 1)

        // Manual test button clears error when Shortcut starts succeeding
        spy.simulatedError = nil
        await service.testStartShortcut()
        XCTAssertNil(service.lastErrorMessage)
        await service.testStopShortcut()
        XCTAssertEqual(spy.invokedShortcutNames, ["Start Focus", "Start Focus", "Stop Focus"])
    }

    func testProcessShortcutsRunnerValidationWithoutShellExecution() async {
        let runner = ProcessShortcutsRunner(
            executableURL: URL(fileURLWithPath: "/nonexistent/bitz-shortcuts-binary"),
            timeoutSeconds: 1.0
        )

        do {
            try await runner.runShortcut(named: "   ")
            XCTFail("Expected emptyShortcutName error")
        } catch let error as FlowShieldShortcutError {
            XCTAssertEqual(error, .emptyShortcutName)
        } catch {
            XCTFail("Unexpected error: \(error)")
        }

        do {
            try await runner.runShortcut(named: "Start Focus")
            XCTFail("Expected executableNotFound error")
        } catch let error as FlowShieldShortcutError {
            XCTAssertEqual(error, .executableNotFound("/nonexistent/bitz-shortcuts-binary"))
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }
}
