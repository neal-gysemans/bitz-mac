import Foundation

/// Tracks cumulative active work time per calendar day across breaks and app restarts,
/// and surfaces Bitz's interactive clock-out dialogue when the daily goal is reached (#187).
@MainActor
public final class WorkShiftTrackerService: ObservableObject {
    public static let defaultGoalHours: Double = 8.0
    public static let minGoalHours: Double = 4.0
    public static let maxGoalHours: Double = 10.0
    /// Input idle threshold (5 minutes): periods longer than this do not count toward daily work.
    public static let activeIdleThresholdSeconds: TimeInterval = 300.0
    public static let defaultSnoozeMinutes: Double = 30.0
    public static let maxHistoryDays: Int = 7
    /// Cap single-tick delta so sleep/wake gaps or clock jumps never credit hours at once.
    private static let maxTickDeltaSeconds: TimeInterval = 30.0

    private enum Keys {
        static let goalHours = "bitz.workShift.goalHours"
        static let history = "bitz.workShift.history"
        static let snoozeUntil = "bitz.workShift.snoozeUntil"
        static let loggedOffDateKey = "bitz.workShift.loggedOffDateKey"
        static let lastActiveDateKey = "bitz.workShift.lastActiveDateKey"
    }

    @Published public private(set) var dailyActiveSeconds: TimeInterval = 0
    @Published public var workdayGoalHours: Double {
        didSet {
            let clamped = Self.clampGoalHours(workdayGoalHours)
            if workdayGoalHours != clamped {
                workdayGoalHours = clamped
                return
            }
            let now = nowProvider()
            rolloverIfNeeded(now: now)
            userDefaults.set(clamped, forKey: Keys.goalHours)
            var todayRecord = historyByDate[currentDateKey] ?? WorkShiftDayRecord(dateKey: currentDateKey, goalHours: clamped)
            todayRecord.goalHours = clamped
            historyByDate[currentDateKey] = todayRecord
            persistHistory()
            refreshWeeklyHistory()
            evaluateGoalState(now: now)
        }
    }
    @Published public private(set) var isGoalReachedToday: Bool = false
    @Published public private(set) var isLoggedOffToday: Bool = false
    @Published public private(set) var snoozeUntil: Date? = nil
    @Published public private(set) var activeAlert: WorkShiftAlert? = nil
    @Published public private(set) var weeklyHistory: [WorkShiftDayRecord] = []

    /// Fired once when the daily goal alert is newly surfaced (used to play `CyberSoundEvent`).
    public var onGoalReached: (() -> Void)?

    private let userDefaults: UserDefaults
    private let calendar: Calendar
    private let nowProvider: () -> Date
    private var currentDateKey: String
    private var historyByDate: [String: WorkShiftDayRecord] = [:]

    public init(
        userDefaults: UserDefaults = .standard,
        calendar: Calendar = .current,
        nowProvider: @escaping () -> Date = Date.init
    ) {
        self.userDefaults = userDefaults
        self.calendar = calendar
        self.nowProvider = nowProvider

        let storedGoal = userDefaults.object(forKey: Keys.goalHours) as? Double ?? Self.defaultGoalHours
        let initialGoal = Self.clampGoalHours(storedGoal)
        self.workdayGoalHours = initialGoal

        let now = nowProvider()
        self.currentDateKey = Self.dateKey(for: now, calendar: calendar)

        if let data = userDefaults.data(forKey: Keys.history),
           let decoded = try? JSONDecoder().decode([String: WorkShiftDayRecord].self, from: data) {
            self.historyByDate = decoded
        }

        let storedLastDate = userDefaults.string(forKey: Keys.lastActiveDateKey)
        if storedLastDate == currentDateKey {
            self.dailyActiveSeconds = max(0, historyByDate[currentDateKey]?.activeSeconds ?? 0)
            self.isLoggedOffToday = userDefaults.string(forKey: Keys.loggedOffDateKey) == currentDateKey
            if let snoozeTimestamp = userDefaults.object(forKey: Keys.snoozeUntil) as? TimeInterval {
                let date = Date(timeIntervalSince1970: snoozeTimestamp)
                self.snoozeUntil = date > now ? date : nil
            }
        } else {
            // New day on launch: reset daily state while keeping prior days in history.
            self.dailyActiveSeconds = 0
            self.isLoggedOffToday = false
            self.snoozeUntil = nil
            userDefaults.removeObject(forKey: Keys.snoozeUntil)
            userDefaults.removeObject(forKey: Keys.loggedOffDateKey)
        }

        userDefaults.set(currentDateKey, forKey: Keys.lastActiveDateKey)
        pruneHistory(relativeTo: now)
        refreshWeeklyHistory()
        evaluateGoalState(now: now)
    }

    public var goalSeconds: TimeInterval {
        workdayGoalHours * 3600.0
    }

    public var progressFraction: Double {
        guard goalSeconds > 0 else { return 0 }
        return min(1.0, max(0.0, dailyActiveSeconds / goalSeconds))
    }

    /// Processes a single activity sample tick from `ActivityMonitorService`.
    public func recordActivityTick(
        deltaSeconds: TimeInterval,
        idleSeconds: TimeInterval,
        isSystemAsleep: Bool,
        now: Date? = nil
    ) {
        let timestamp = now ?? nowProvider()
        rolloverIfNeeded(now: timestamp)

        if !isSystemAsleep,
           idleSeconds.isFinite,
           idleSeconds >= 0,
           idleSeconds < Self.activeIdleThresholdSeconds,
           deltaSeconds.isFinite,
           deltaSeconds > 0 {
            let safeDelta = min(deltaSeconds, Self.maxTickDeltaSeconds)
            dailyActiveSeconds += safeDelta
            var record = historyByDate[currentDateKey] ?? WorkShiftDayRecord(
                dateKey: currentDateKey,
                activeSeconds: 0,
                goalHours: workdayGoalHours,
                completed: isLoggedOffToday
            )
            record.activeSeconds = dailyActiveSeconds
            record.goalHours = workdayGoalHours
            historyByDate[currentDateKey] = record
            persistHistory()
            refreshWeeklyHistory()
        }

        evaluateGoalState(now: timestamp)
    }

    /// Checks for midnight rollover and resets daily counters if the calendar day changed.
    public func handleDayRolloverIfNeeded(now: Date? = nil) {
        let timestamp = now ?? nowProvider()
        rolloverIfNeeded(now: timestamp)
    }

    /// Silences the clock-out alert for `minutes` (default 30 minutes).
    public func snooze(minutes: Double = WorkShiftTrackerService.defaultSnoozeMinutes, now: Date? = nil) {
        let timestamp = now ?? nowProvider()
        let until = timestamp.addingTimeInterval(max(1.0, minutes) * 60.0)
        snoozeUntil = until
        activeAlert = nil
        userDefaults.set(until.timeIntervalSince1970, forKey: Keys.snoozeUntil)
    }

    /// Dismisses the clock-out alert and marks today's work shift as logged off / completed.
    public func logOffForToday(now: Date? = nil) {
        let timestamp = now ?? nowProvider()
        rolloverIfNeeded(now: timestamp)
        isLoggedOffToday = true
        snoozeUntil = nil
        activeAlert = nil

        var record = historyByDate[currentDateKey] ?? WorkShiftDayRecord(
            dateKey: currentDateKey,
            activeSeconds: dailyActiveSeconds,
            goalHours: workdayGoalHours,
            completed: true
        )
        record.completed = true
        historyByDate[currentDateKey] = record

        userDefaults.set(currentDateKey, forKey: Keys.loggedOffDateKey)
        userDefaults.removeObject(forKey: Keys.snoozeUntil)
        persistHistory()
        refreshWeeklyHistory()
    }

    public static func dateKey(for date: Date, calendar: Calendar = .current) -> String {
        let comps = calendar.dateComponents([.year, .month, .day], from: date)
        let year = comps.year ?? 1970
        let month = comps.month ?? 1
        let day = comps.day ?? 1
        return String(format: "%04d-%02d-%02d", year, month, day)
    }

    public static func clampGoalHours(_ hours: Double) -> Double {
        guard hours.isFinite else { return defaultGoalHours }
        return min(maxGoalHours, max(minGoalHours, hours))
    }

    // MARK: - Private

    private func rolloverIfNeeded(now: Date) {
        let newKey = Self.dateKey(for: now, calendar: calendar)
        guard newKey != currentDateKey else { return }

        currentDateKey = newKey
        dailyActiveSeconds = 0
        isGoalReachedToday = false
        isLoggedOffToday = false
        snoozeUntil = nil
        activeAlert = nil

        userDefaults.set(newKey, forKey: Keys.lastActiveDateKey)
        userDefaults.removeObject(forKey: Keys.snoozeUntil)
        userDefaults.removeObject(forKey: Keys.loggedOffDateKey)

        pruneHistory(relativeTo: now)
        persistHistory()
        refreshWeeklyHistory()
    }

    private func evaluateGoalState(now: Date) {
        let reached = dailyActiveSeconds >= goalSeconds
        isGoalReachedToday = reached

        guard reached else {
            activeAlert = nil
            return
        }
        guard !isLoggedOffToday else {
            activeAlert = nil
            return
        }
        if let snoozeUntil {
            if now < snoozeUntil {
                return
            }
            self.snoozeUntil = nil
            userDefaults.removeObject(forKey: Keys.snoozeUntil)
        }

        if activeAlert == nil {
            activeAlert = WorkShiftAlert(
                message: WorkShiftDialogueBank.randomMessage(goalHours: workdayGoalHours),
                clockedHoursText: WorkShiftDialogueBank.formatDuration(dailyActiveSeconds)
            )
            onGoalReached?()
        }
    }

    private func pruneHistory(relativeTo now: Date) {
        var validKeys = Set<String>()
        for offset in 0..<Self.maxHistoryDays {
            if let day = calendar.date(byAdding: .day, value: -offset, to: now) {
                validKeys.insert(Self.dateKey(for: day, calendar: calendar))
            }
        }
        historyByDate = historyByDate.filter { validKeys.contains($0.key) }
    }

    private func refreshWeeklyHistory() {
        let now = nowProvider()
        var result: [WorkShiftDayRecord] = []
        result.reserveCapacity(Self.maxHistoryDays)
        for offset in stride(from: Self.maxHistoryDays - 1, through: 0, by: -1) {
            guard let day = calendar.date(byAdding: .day, value: -offset, to: now) else { continue }
            let key = Self.dateKey(for: day, calendar: calendar)
            let record = historyByDate[key] ?? WorkShiftDayRecord(
                dateKey: key,
                activeSeconds: 0,
                goalHours: workdayGoalHours,
                completed: false
            )
            result.append(record)
        }
        weeklyHistory = result
    }

    private func persistHistory() {
        if let data = try? JSONEncoder().encode(historyByDate) {
            userDefaults.set(data, forKey: Keys.history)
        }
    }
}
