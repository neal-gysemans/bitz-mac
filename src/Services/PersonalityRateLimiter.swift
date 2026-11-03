import Foundation

/// Outcome of evaluating commentary rate limiter conditions.
public enum RateLimitDecision: Equatable, Sendable {
    case allowed
    case rateLimited

    public var isAllowed: Bool { self == .allowed }
}

/// Rate limiter enforcing minimum cooldown intervals and daily volume caps.
public struct PersonalityRateLimiter: Sendable {
    public private(set) var lastGenerationDate: Date?
    public private(set) var commentsGeneratedToday: Int
    private var lastRecordedDayString: String?

    public init(
        lastGenerationDate: Date? = nil,
        commentsGeneratedToday: Int = 0,
        lastRecordedDayString: String? = nil
    ) {
        self.lastGenerationDate = lastGenerationDate
        self.commentsGeneratedToday = commentsGeneratedToday
        self.lastRecordedDayString = lastRecordedDayString
    }

    /// Evaluates if generation is permitted at `now` under given minimum interval and daily cap.
    public mutating func evaluate(
        now: Date,
        minIntervalMinutes: Int,
        dailyCap: Int,
        calendar: Calendar = .current
    ) -> RateLimitDecision {
        normalizeDay(now: now, calendar: calendar)

        if commentsGeneratedToday >= dailyCap {
            return .rateLimited
        }

        if let last = lastGenerationDate {
            let minGapSeconds = Double(max(1, minIntervalMinutes)) * 60.0
            let elapsed = now.timeIntervalSince(last)
            if elapsed < minGapSeconds {
                return .rateLimited
            }
        }

        return .allowed
    }

    /// Records a successful generation at `now`.
    public mutating func recordGeneration(now: Date, calendar: Calendar = .current) {
        normalizeDay(now: now, calendar: calendar)
        lastGenerationDate = now
        commentsGeneratedToday += 1
    }

    /// Resets rate limiter state.
    public mutating func reset() {
        lastGenerationDate = nil
        commentsGeneratedToday = 0
        lastRecordedDayString = nil
    }

    private mutating func normalizeDay(now: Date, calendar: Calendar) {
        let components = calendar.dateComponents([.year, .month, .day], from: now)
        let currentDayString = String(format: "%04d-%02d-%02d", components.year ?? 0, components.month ?? 0, components.day ?? 0)

        if lastRecordedDayString != currentDayString {
            commentsGeneratedToday = 0
            lastRecordedDayString = currentDayString
        }
    }
}
