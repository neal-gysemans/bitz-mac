import XCTest
@testable import BitzCore

@MainActor
final class FlowShieldSettingsStoreTests: XCTestCase {

    func testInitialDefaultsAreOptOutAndSafe() {
        let suiteName = "FlowShieldSettingsStoreTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let store = FlowShieldSettingsStore(userDefaults: defaults)

        XCTAssertFalse(store.isEnabled, "Auto Flow Shield must default to OFF")
        XCTAssertEqual(store.streakMinutesThreshold, 20.0, accuracy: 0.001)
        XCTAssertEqual(store.streakMinutesInt, 20)
        XCTAssertEqual(store.formattedStreakSummary, "20 min")
        XCTAssertEqual(store.startFocusShortcutName, "Start Focus")
        XCTAssertEqual(store.stopFocusShortcutName, "Stop Focus")
        XCTAssertFalse(store.isBreakShieldOverrideActive)
    }

    func testStreakMinutesClampingAndNonFiniteSanitization() {
        let suiteName = "FlowShieldSettingsStoreTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let store = FlowShieldSettingsStore(userDefaults: defaults)

        store.setStreakMinutesThreshold(35.0)
        XCTAssertEqual(store.streakMinutesThreshold, 35.0, accuracy: 0.001)

        // Lower bound clamping (5 min)
        store.setStreakMinutesThreshold(1.0)
        XCTAssertEqual(store.streakMinutesThreshold, 5.0, accuracy: 0.001)

        // Upper bound clamping (120 min)
        store.setStreakMinutesThreshold(240.0)
        XCTAssertEqual(store.streakMinutesThreshold, 120.0, accuracy: 0.001)

        // Non-finite sanitization
        store.setStreakMinutesThreshold(.nan)
        XCTAssertEqual(store.streakMinutesThreshold, 20.0, accuracy: 0.001)

        store.setStreakMinutesThreshold(.infinity)
        XCTAssertEqual(store.streakMinutesThreshold, 120.0, accuracy: 0.001)

        store.setStreakMinutesThreshold(-.infinity)
        XCTAssertEqual(store.streakMinutesThreshold, 5.0, accuracy: 0.001)
    }

    func testShortcutNameTrimmingAndEmptyFallback() {
        let suiteName = "FlowShieldSettingsStoreTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let store = FlowShieldSettingsStore(userDefaults: defaults)

        store.setStartFocusShortcutName("  Deep Work On  \n")
        store.setStopFocusShortcutName("  Deep Work Off ")
        XCTAssertEqual(store.startFocusShortcutName, "Deep Work On")
        XCTAssertEqual(store.stopFocusShortcutName, "Deep Work Off")

        // Blank/whitespace names fall back safely to canonical defaults
        store.setStartFocusShortcutName("   ")
        store.setStopFocusShortcutName("\n\t ")
        XCTAssertEqual(store.startFocusShortcutName, "Start Focus")
        XCTAssertEqual(store.stopFocusShortcutName, "Stop Focus")
    }

    func testPersistenceAcrossReinstantiationAndNewSessionOverrideReset() {
        let suiteName = "FlowShieldSettingsStoreTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let store1 = FlowShieldSettingsStore(userDefaults: defaults)
        var changeCount = 0
        store1.onSettingsChanged = { changeCount += 1 }

        store1.setEnabled(true)
        store1.setStreakMinutesThreshold(45.0)
        store1.setStartFocusShortcutName("Engage Cyber Shield")
        store1.setStopFocusShortcutName("Release Cyber Shield")
        store1.setBreakShieldOverrideActive(true)
        XCTAssertEqual(changeCount, 5)

        let store2 = FlowShieldSettingsStore(userDefaults: defaults)
        XCTAssertTrue(store2.isEnabled)
        XCTAssertEqual(store2.streakMinutesThreshold, 45.0, accuracy: 0.001)
        XCTAssertEqual(store2.startFocusShortcutName, "Engage Cyber Shield")
        XCTAssertEqual(store2.stopFocusShortcutName, "Release Cyber Shield")
        XCTAssertTrue(store2.isBreakShieldOverrideActive)

        // Turning off and starting a new opted-in session resets Break Shield override
        store2.setEnabled(false)
        XCTAssertFalse(store2.isEnabled)
        store2.setEnabled(true)
        XCTAssertTrue(store2.isEnabled)
        XCTAssertFalse(store2.isBreakShieldOverrideActive)
    }

    func testFlowShieldModelsDisplayMetadataAndErrorDescriptions() {
        for status in FlowShieldStatus.allCases {
            XCTAssertFalse(status.displayTitle.isEmpty)
            XCTAssertFalse(status.systemImage.isEmpty)
        }

        XCTAssertEqual(
            FlowShieldShortcutError.emptyShortcutName.errorDescription,
            "Shortcut name cannot be empty."
        )
        XCTAssertTrue(
            FlowShieldShortcutError.executableNotFound("/missing/shortcuts")
                .localizedDescription
                .contains("/missing/shortcuts")
        )
        XCTAssertTrue(
            FlowShieldShortcutError.executionFailed(shortcutName: "Start Focus", exitCode: 1, stderr: "Not found")
                .localizedDescription
                .contains("Not found")
        )
        XCTAssertTrue(
            FlowShieldShortcutError.timedOut(shortcutName: "Start Focus")
                .localizedDescription
                .contains("timed out")
        )
    }
}
