# Research: Auto Flow-State Shield (GitHub Issue #22)

## Context & Existing Capabilities in `main`
- **Idle & Break Recharge (`WellnessPointEngine` & `ActivityMonitorService`)**: Stepping away triggers `BitzState.charging` (`⚡ Z Z`), charging sound (`CyberAudioService`), and Focus Point recovery (`applyOfflineBreak(minutes:)` / `setChargingState(_:)`).
- **macOS Focus Public API Boundary (`AudioEnvironmentDetector`)**: macOS 14+ provides no public non-entitled framework API to toggle Focus / Do Not Disturb directly without private entitlements. However, macOS ships `/usr/bin/shortcuts` as a first-party system CLI capable of running any user-created 1-action `"Set Focus"` Shortcut (`shortcuts run "Start Focus"` / `shortcuts run "Stop Focus"`).

## Key Architectural Findings
1. **Zero Extra Timers (`< 2%` Idle CPU)**: `FlowShieldService` piggybacks on `WellnessPointEngine.$continuousWorkMinutes`, `$currentState`, and `$lastTickWasProductive` Combine publishers—requiring zero new timers or polling loops.
2. **Once-Per-Streak & Failure Backoff**: Updating `hasTriggeredForCurrentStreak` synchronously on `@MainActor` before launching the async Shortcut runner prevents both multi-publisher double-triggers and 5-second retry storms if a user's Shortcut is missing.
3. **Serialized Shortcut Dispatch**: Chaining Shortcut executions sequentially ensures a rapid `"Start Focus"` followed immediately by `"Break Shield"` (`"Stop Focus"`) executes strictly in order (`Start` -> `Stop`) rather than racing two detached processes.
