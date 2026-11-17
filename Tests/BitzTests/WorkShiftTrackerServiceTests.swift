import XCTest
@testable import BitzCore

@MainActor
final class WorkShiftTrackerServiceTests: XCTestCase {
    private func makeDefaults() -> (suiteName: String, defaults: UserDefaults) {
        let suiteName = "com.bitz.tests.workshift.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        return (suiteName, defaults)
    }

    func testActiveTicksAccumulateOnlyWhenAwakeAndWithinIdleThreshold() {
        let (suiteName, defaults) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let now = Date(timeIntervalSince1970: 1_763_372_800) // fixed timestamp
        let tracker = WorkShiftTrackerService(userDefaults: defaults, nowProvider: { now })

        // Active tick (< 300s idle, awake)
        tracker.recordActivityTick(deltaSeconds: 5, idleSeconds: 10, isSystemAsleep: false, now: now)
        XCTAssertEqual(tracker.dailyActiveSeconds, 5, accuracy: 0.001)

        // Idle >= 300s should not accumulate
        tracker.recordActivityTick(deltaSeconds: 5, idleSeconds: 300, isSystemAsleep: false, now: now.addingTimeInterval(5))
        XCTAssertEqual(tracker.dailyActiveSeconds, 5, accuracy: 0.001)

        // System asleep should not accumulate
        tracker.recordActivityTick(deltaSeconds: 5, idleSeconds: 0, isSystemAsleep: true, now: now.addingTimeInterval(10))
        XCTAssertEqual(tracker.dailyActiveSeconds, 5, accuracy: 0.001)

        // Huge delta is clamped to 30s max per tick
        tracker.recordActivityTick(deltaSeconds: 3600, idleSeconds: 2, isSystemAsleep: false, now: now.addingTimeInterval(15))
        XCTAssertEqual(tracker.dailyActiveSeconds, 35, accuracy: 0.001)
    }

    func testPersistenceAndMidnightRollover() {
        let (suiteName, defaults) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }

        var current = Date(timeIntervalSince1970: 1_763_372_800)
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!

        let tracker = WorkShiftTrackerService(
            userDefaults: defaults,
            calendar: calendar,
            nowProvider: { current }
        )
        tracker.recordActivityTick(deltaSeconds: 25, idleSeconds: 0, isSystemAsleep: false, now: current)
        XCTAssertEqual(tracker.dailyActiveSeconds, 25, accuracy: 0.001)

        // Reload on same day restores progress
        let reloadedSameDay = WorkShiftTrackerService(
            userDefaults: defaults,
            calendar: calendar,
            nowProvider: { current.addingTimeInterval(60) }
        )
        XCTAssertEqual(reloadedSameDay.dailyActiveSeconds, 25, accuracy: 0.001)

        // Advance past midnight
        current = current.addingTimeInterval(86_400)
        reloadedSameDay.recordActivityTick(deltaSeconds: 5, idleSeconds: 0, isSystemAsleep: false, now: current)
        XCTAssertEqual(reloadedSameDay.dailyActiveSeconds, 5, accuracy: 0.001)
        XCTAssertEqual(reloadedSameDay.weeklyHistory.count, 7)
        // Yesterday's 25s is preserved in the 7-day history
        let yesterdayRecord = reloadedSameDay.weeklyHistory[reloadedSameDay.weeklyHistory.count - 2]
        XCTAssertEqual(yesterdayRecord.activeSeconds, 25, accuracy: 0.001)
    }

    func testGoalReachedTriggersAlertSnoozeAndLogOff() {
        let (suiteName, defaults) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }

        var current = Date(timeIntervalSince1970: 1_763_372_800)
        let tracker = WorkShiftTrackerService(userDefaults: defaults, nowProvider: { current })
        tracker.workdayGoalHours = 4.0 // 14,400 seconds

        var goalReachedCount = 0
        tracker.onGoalReached = { goalReachedCount += 1 }

        // Accumulate 14,400s in 30s chunks
        for _ in 0..<480 {
            tracker.recordActivityTick(deltaSeconds: 30, idleSeconds: 5, isSystemAsleep: false, now: current)
            current = current.addingTimeInterval(30)
        }

        XCTAssertTrue(tracker.isGoalReachedToday)
        XCTAssertNotNil(tracker.activeAlert)
        XCTAssertEqual(goalReachedCount, 1)

        // Snooze for 30 minutes
        tracker.snooze(minutes: 30, now: current)
        XCTAssertNil(tracker.activeAlert)
        XCTAssertNotNil(tracker.snoozeUntil)

        // Tick 10 minutes later: still snoozed
        current = current.addingTimeInterval(600)
        tracker.recordActivityTick(deltaSeconds: 5, idleSeconds: 0, isSystemAsleep: false, now: current)
        XCTAssertNil(tracker.activeAlert)

        // Tick 21 minutes later (total 31m): re-alerts
        current = current.addingTimeInterval(1260)
        tracker.recordActivityTick(deltaSeconds: 5, idleSeconds: 0, isSystemAsleep: false, now: current)
        XCTAssertNotNil(tracker.activeAlert)
        XCTAssertEqual(goalReachedCount, 2)

        // Log off for today
        tracker.logOffForToday(now: current)
        XCTAssertNil(tracker.activeAlert)
        XCTAssertTrue(tracker.isLoggedOffToday)
        XCTAssertEqual(tracker.weeklyHistory.last?.completed, true)

        // Subsequent ticks today do not re-trigger
        current = current.addingTimeInterval(3600)
        tracker.recordActivityTick(deltaSeconds: 5, idleSeconds: 0, isSystemAsleep: false, now: current)
        XCTAssertNil(tracker.activeAlert)
        XCTAssertEqual(goalReachedCount, 2)
    }

    func testSpeechBubbleContentPrioritizesWorkShiftAndIsInteractive() {
        let (suiteName, defaults) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let now = Date(timeIntervalSince1970: 1_763_372_800)
        let tracker = WorkShiftTrackerService(userDefaults: defaults, nowProvider: { now })
        tracker.workdayGoalHours = 4.0
        for i in 0..<480 {
            tracker.recordActivityTick(
                deltaSeconds: 30,
                idleSeconds: 0,
                isSystemAsleep: false,
                now: now.addingTimeInterval(Double(i) * 30)
            )
        }

        let engine = WellnessPointEngine(userDefaults: defaults)
        let agentMonitor = AgentMonitorService(adapters: [], userDefaults: defaults)
        let updateStore = AppUpdateStore(userDefaults: defaults)
        let telemetrySettings = TelemetrySettingsStore(userDefaults: defaults)
        let telemetryDashboard = TelemetryDashboardService(settingsStore: telemetrySettings)

        let content = SpeechBubbleContent.current(
            engine: engine,
            agentMonitor: agentMonitor,
            updateStore: updateStore,
            telemetryDashboard: telemetryDashboard,
            telemetrySettings: telemetrySettings,
            workShiftTracker: tracker
        )

        if case .workShift(let alert) = content {
            XCTAssertTrue(alert.isInteractive)
            XCTAssertFalse(alert.message.isEmpty)
        } else {
            XCTFail("Expected .workShift speech bubble content")
        }
        XCTAssertEqual(content?.isInteractive, true)
    }

    func testActivityMonitorServiceIntegrationRespectsSleepAndIdle() {
        let (suiteName, defaults) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }

        final class FakeTelemetry: ActivityTelemetryProviding {
            var currentDate = Date(timeIntervalSince1970: 1_763_372_800)
            var idleSeconds: TimeInterval = 5
            func frontmostBundleIdentifier() -> String? { "com.apple.dt.Xcode" }
            func frontmostApplicationName() -> String? { "Xcode" }
            func activeBrowserTab() -> (url: String?, title: String?) { (nil, nil) }
            func secondsSinceLastInput() -> TimeInterval { idleSeconds }
            func thermalState() -> ProcessInfo.ThermalState { .nominal }
            func cpuTemperatureCelsius() -> Double? { 45.0 }
            func cpuLoadPercentage() -> Double? { 10.0 }
            func isVideoPlaybackActive() -> Bool { false }
            func now() -> Date { currentDate }
        }

        let fakeTelemetry = FakeTelemetry()
        let engine = WellnessPointEngine(userDefaults: defaults)
        let tracker = WorkShiftTrackerService(userDefaults: defaults, nowProvider: { fakeTelemetry.currentDate })
        let monitor = ActivityMonitorService(
            engine: engine,
            telemetry: fakeTelemetry,
            workShiftTracker: tracker
        )

        // First tick establishes baseline (0 delta)
        monitor.performSampleTick()
        XCTAssertEqual(tracker.dailyActiveSeconds, 0, accuracy: 0.001)

        // Second tick 5s later accumulates 5s
        fakeTelemetry.currentDate = fakeTelemetry.currentDate.addingTimeInterval(5)
        monitor.performSampleTick()
        XCTAssertEqual(tracker.dailyActiveSeconds, 5, accuracy: 0.001)

        // Sleep pauses accumulation and wake does not credit sleep gap
        monitor.handleSystemSleepOrLock()
        fakeTelemetry.currentDate = fakeTelemetry.currentDate.addingTimeInterval(3600)
        monitor.handleSystemWakeOrUnlock()
        XCTAssertEqual(tracker.dailyActiveSeconds, 5, accuracy: 0.001)

        // Next active tick 5s after wake resumes accumulation
        fakeTelemetry.currentDate = fakeTelemetry.currentDate.addingTimeInterval(5)
        monitor.performSampleTick()
        XCTAssertEqual(tracker.dailyActiveSeconds, 10, accuracy: 0.001)
    }
}
