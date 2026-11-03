import Foundation

/// High-level operational state of Bitz's Auto Flow-State Shield (`#22`).
public enum FlowShieldStatus: String, Sendable, Equatable, CaseIterable {
    /// Master toggle `isEnabled == false` (default opt-out).
    case disabled
    /// Master toggle is on, but user manually engaged Break Shield override.
    case breakShieldOverride
    /// Armed and waiting for `continuousWorkMinutes` to reach `streakMinutesThreshold`.
    case standby
    /// Deep-work streak threshold reached and macOS Focus Shortcut is active.
    case active

    public var displayTitle: String {
        switch self {
        case .disabled:
            return "Off"
        case .breakShieldOverride:
            return "Break Shield Override (Focus Off)"
        case .standby:
            return "Armed (Waiting for Streak)"
        case .active:
            return "Active (Focus Shield On)"
        }
    }

    public var systemImage: String {
        switch self {
        case .disabled:
            return "shield.slash"
        case .breakShieldOverride:
            return "shield.lefthalf.filled.slash"
        case .standby:
            return "shield"
        case .active:
            return "shield.checkered"
        }
    }
}

/// Errors surfaced when validating or running a user-configured macOS Shortcut via `/usr/bin/shortcuts`.
public enum FlowShieldShortcutError: Error, LocalizedError, Sendable, Equatable {
    case emptyShortcutName
    case executableNotFound(String)
    case executionFailed(shortcutName: String, exitCode: Int32, stderr: String)
    case timedOut(shortcutName: String)

    public var errorDescription: String? {
        switch self {
        case .emptyShortcutName:
            return "Shortcut name cannot be empty."
        case .executableNotFound(let path):
            return "macOS Shortcuts CLI was not found at \(path)."
        case .executionFailed(let shortcutName, let exitCode, let stderr):
            let trimmed = stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty {
                return "Shortcut \"\(shortcutName)\" exited with status \(exitCode). Verify it exists in Shortcuts.app."
            }
            return "Shortcut \"\(shortcutName)\" failed (\(exitCode)): \(trimmed)"
        case .timedOut(let shortcutName):
            return "Shortcut \"\(shortcutName)\" timed out before completing."
        }
    }
}
