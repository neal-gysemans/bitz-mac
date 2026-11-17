import Foundation

/// Persisted active work summary for a single local calendar day (`yyyy-MM-dd`).
public struct WorkShiftDayRecord: Codable, Equatable, Identifiable, Sendable {
    public let dateKey: String
    public var activeSeconds: TimeInterval
    public var goalHours: Double
    public var completed: Bool

    public var id: String { dateKey }

    public init(
        dateKey: String,
        activeSeconds: TimeInterval = 0,
        goalHours: Double = 8.0,
        completed: Bool = false
    ) {
        self.dateKey = dateKey
        self.activeSeconds = max(0, activeSeconds)
        self.goalHours = goalHours
        self.completed = completed
    }
}

/// Interactive clock-out milestone alert surfaced in `SpeechBubbleView`.
public struct WorkShiftAlert: Equatable, Sendable {
    public let message: String
    public let clockedHoursText: String

    public var isInteractive: Bool { true }

    public init(message: String, clockedHoursText: String) {
        self.message = message
        self.clockedHoursText = clockedHoursText
    }
}

/// Humorous cyber-cat dialogue bank for the daily clock-out milestone (#187).
public enum WorkShiftDialogueBank {
    public static func randomMessage(goalHours: Double) -> String {
        let hourText = formatHours(goalHours)
        let lines = [
            "Human, you've clocked \(hourText) today! Terminal closed, brain reboot required. Go touch grass before your circuits melt! 🐾🌿",
            "\(hourText) of continuous commits! Your pull requests are stellar, but your biological battery is at 1%. Step away from the keyboard! ⚡️",
            "Meow-day completed! \(hourText) logged. Any code written after this contains 400% more bugs. Go home! 🛑"
        ]
        return lines.randomElement() ?? lines[0]
    }

    public static func formatHours(_ hours: Double) -> String {
        let rounded = (hours * 2).rounded() / 2
        if rounded.truncatingRemainder(dividingBy: 1) == 0 {
            return "\(Int(rounded)) hours"
        }
        return String(format: "%.1f hours", rounded)
    }

    public static func formatDuration(_ seconds: TimeInterval) -> String {
        let clamped = max(0, Int(seconds.rounded(.down)))
        let hours = clamped / 3600
        let minutes = (clamped % 3600) / 60
        return "\(hours)h \(String(format: "%02d", minutes))m"
    }
}
