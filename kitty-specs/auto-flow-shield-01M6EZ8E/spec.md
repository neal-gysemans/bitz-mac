# Mission Specification: Auto Flow-State Shield (macOS Focus & Break Integration)

**Mission Branch**: `feat/issue-22-auto-flow-shield`  
**Created**: 2026-11-02  
**Status**: Approved  
**Input**: GitHub Issue #22 — "[Feature]: Auto Flow-State Shield (macOS Focus & Break Integration)" (refs #22)

## User Scenarios & Testing *(mandatory)*

### User Story 1 - Opt-In Flow Shield Preferences & Shortcut Configuration (Priority: P1)

Users have complete control over Auto Flow-State Shield preferences through `FlowShieldSettingsStore` and the Settings (`Behaviors` tab) UI. Auto Flow Shield defaults to **OFF** (`isEnabled = false`) so existing users never experience unexpected macOS Shortcut invocations. When enabled, users can configure their deep-work streak threshold (default `20` minutes, clamped `5...120` minutes) and specify the target macOS Shortcut names for starting and stopping Focus (`"Start Focus"` and `"Stop Focus"` by default), along with test buttons to verify Shortcut setup.

**Why this priority**: Provides the opt-in persistence foundation and user configuration required before any automated Shortcut execution occurs.

**Independent Test**: Instantiate `FlowShieldSettingsStore` on a clean `UserDefaults(suiteName:)` domain, verify `isEnabled == false` by default, update streak threshold and Shortcut names, re-instantiate from the same suite, and verify exact persistence and clamping.

**Acceptance Scenarios**:

1. **Given** a fresh Bitz launch, **When** inspecting `FlowShieldSettingsStore.isEnabled`, **Then** it defaults to `false` and `streakMinutesThreshold` defaults to `20.0`.
2. **Given** the Settings window `Behaviors` tab, **When** the user enables `"Auto Flow Shield"`, sets the streak threshold to `30` minutes, and enters custom Shortcut names, **Then** all preferences persist across relaunches in `UserDefaults`.
3. **Given** configured Shortcut names, **When** the user clicks `"Test Start Shortcut"` or `"Test Stop Shortcut"`, **Then** `FlowShieldService` invokes the corresponding Shortcut once off the main thread and surfaces any error cleanly.

---

### User Story 2 - Automated Deep-Work Streak Activation & Post-Break Deactivation (Priority: P1)

When Auto Flow Shield is enabled and not overridden, `FlowShieldService` observes `WellnessPointEngine` and triggers the configured `"Start Focus"` macOS Shortcut **once per deep-work streak** as soon as `continuousWorkMinutes` reaches `streakMinutesThreshold` (while not in `.charging`). When the user completes a break (transitioning out of `.charging` or completing an offline break that resets `continuousWorkMinutes`), `FlowShieldService` automatically triggers `"Stop Focus"` and resets `isFlowShieldActive` to `false`.

**Why this priority**: Delivers the core automated Focus shield workflow tied directly to Bitz's existing deep-work and recharge state machine without duplicating `.charging` or Focus Point recovery logic.

**Independent Test**: Inject a `SpyShortcutsRunner` into `FlowShieldService` observing `WellnessPointEngine`; advance productive work ticks across the streak threshold, verify `"Start Focus"` runs exactly once (not on subsequent 5s ticks), simulate a break and return, and verify `"Stop Focus"` runs once.

**Acceptance Scenarios**:

1. **Given** `isEnabled == true` and `streakMinutesThreshold == 20.0`, **When** `engine.continuousWorkMinutes` crosses `20.0` outside `.charging`, **Then** `startFocusShortcutName` runs once and `isFlowShieldActive` becomes `true`.
2. **Given** `isFlowShieldActive == true`, **When** subsequent 5-second productive work ticks increment `continuousWorkMinutes` (`20.1`, `25.0`, `45.0`), **Then** `startFocusShortcutName` is NOT invoked again during the same streak.
3. **Given** `isFlowShieldActive == true`, **When** the user steps away into `.charging` and returns from the break (or `applyOfflineBreak` resets `continuousWorkMinutes` to `0`), **Then** `stopFocusShortcutName` runs once and `isFlowShieldActive` becomes `false`.

---

### User Story 3 - Menu Bar & Settings "Break Shield" Manual Override (Priority: P2)

Users can immediately break out of Focus mode at any time via a 1-click `"Break Shield"` override in the Menu Bar (`BitzMenuBarContentView`) or Settings (`BehaviorSettingsTabView`). Activating Break Shield (or turning master `isEnabled` off while active) immediately runs `"Stop Focus"` if `isFlowShieldActive == true`, marks `isFlowShieldActive = false`, and suppresses automatic re-activation until the user clears the override or starts a new opted-in session.

**Why this priority**: Guarantees instant user agency and escape hatch so automated Focus never traps the user when expecting urgent notifications.

**Independent Test**: Activate Flow Shield via `WellnessPointEngine`, invoke `activateBreakShieldOverride()`, verify `"Stop Focus"` runs immediately, advance additional productive work ticks, and verify `"Start Focus"` remains suppressed until override is cleared.

**Acceptance Scenarios**:

1. **Given** `isFlowShieldActive == true`, **When** the user triggers `"Break Shield"` from the Menu Bar or Settings, **Then** `stopFocusShortcutName` runs immediately, `isFlowShieldActive` becomes `false`, and `isBreakShieldOverrideActive` becomes `true`.
2. **Given** `isBreakShieldOverrideActive == true`, **When** `continuousWorkMinutes` continues above `streakMinutesThreshold`, **Then** Flow Shield does not re-activate until the user clears Break Shield or toggles a fresh opted-in session.
3. **Given** `isFlowShieldActive == true`, **When** the user disables master `"Auto Flow Shield"` (`isEnabled = false`), **Then** `stopFocusShortcutName` runs immediately and `isFlowShieldActive` becomes `false`.

---

### Edge Cases

- **Default Opt-Out Guarantee**: When `isEnabled == false`, zero `/usr/bin/shortcuts` processes are ever spawned regardless of `continuousWorkMinutes` or break transitions.
- **Missing or Failing Shortcut**: If `/usr/bin/shortcuts` exits non-zero (e.g., user has not created `"Start Focus"` yet), `FlowShieldService` records `lastErrorMessage`, sets `isFlowShieldActive = false`, and marks the current streak as attempted so Bitz never retries every 5 seconds in a background process storm.
- **Command Injection / Empty Name Safety**: Shortcut execution invokes `/usr/bin/shortcuts` directly via `Process.arguments = ["run", trimmedName]` with zero shell interpolation, rejecting blank/whitespace-only names before process launch.
- **Hung Shortcut Process**: `ProcessShortcutsRunner` runs off the main thread with a non-blocking `terminationHandler` and timeout guard so the AppKit UI thread never stalls.

## Requirements *(mandatory)*

### Functional Requirements

| ID | Title | User Story | Priority | Status |
|----|-------|------------|----------|--------|
| FR-001 | FlowShieldSettingsStore Persistence | As a user, I want opt-in Auto Flow Shield preferences (`isEnabled` default `false`, `streakMinutesThreshold` default `20.0`, `startFocusShortcutName`, `stopFocusShortcutName`, `isBreakShieldOverrideActive`) persisted in injectable `UserDefaults` so my setup survives app restarts. | High | Open |
| FR-002 | Safe Non-Blocking Shortcuts Runner | As a developer, I want an injectable `ShortcutsRunning` protocol and production `ProcessShortcutsRunner` executing `/usr/bin/shortcuts run <name>` off the main thread without shell interpolation so Shortcuts run safely and are deterministically testable. | High | Open |
| FR-003 | Once-Per-Streak Focus Activation | As a user, I want `FlowShieldService` to trigger `startFocusShortcutName` once per streak when `WellnessPointEngine.continuousWorkMinutes` reaches `streakMinutesThreshold` (while not `.charging`) so macOS Focus engages automatically during deep work. | High | Open |
| FR-004 | Post-Break Focus Deactivation | As a user, I want `FlowShieldService` to automatically trigger `stopFocusShortcutName` and clear `isFlowShieldActive` when returning from a completed break so notifications resume after recharging. | High | Open |
| FR-005 | Break Shield Manual Override | As a user, I want activating Break Shield override (or disabling `isEnabled`) to immediately run `stopFocusShortcutName` when active and suppress re-triggering until cleared or next opted-in session so I always retain manual control. | High | Open |
| FR-006 | Settings Card & Menu Bar Controls | As a user, I want an `"Auto Flow Shield (macOS Focus)"` card in `BehaviorSettingsTabView` (with Shortcut helper guidance and test buttons) and quick status + `"Break Shield"` actions in `BitzMenuBarContentView` while preserving default-parameter backward compatibility. | Medium | Open |

### Non-Functional Requirements

| ID | Title | Requirement | Category | Priority | Status |
|----|-------|-------------|----------|----------|--------|
| NFR-001 | Desktop Idle CPU & RAM Budget | Idle CPU must remain `< 2%` (`0%` additional polling timers; driven purely by existing `WellnessPointEngine` Combine state updates) and RAM `< 70 MB`. | Performance | High | Open |
| NFR-002 | Zero Shell Interpolation & Main-Thread Stalls | Shortcut execution must pass arguments directly to `/usr/bin/shortcuts` (`0` shell invocations) and complete asynchronously off `@MainActor` with a bounded timeout (`<= 15s`). | Security | High | Open |
| NFR-003 | Deterministic Headless Test Suite | 100% of unit tests in `FlowShieldSettingsStoreTests` and `FlowShieldServiceTests` must execute deterministically in `< 2s` using `SpyShortcutsRunner` and isolated `UserDefaults(suiteName:)` without invoking `/usr/bin/shortcuts`. | Reliability | High | Open |

### Constraints

| ID | Title | Constraint | Category | Priority | Status |
|----|-------|------------|----------|----------|--------|
| C-001 | Backward-Compatible Initializers | All new parameters on `BehaviorSettingsTabView.init`, `SettingsRootView.init`, `BitzMenuBarContentView.init`, and `BitzAppDelegate.init` MUST provide default values (`= nil`) so existing tests and parallel PRs compile unchanged. | Technical | High | Open |
| C-002 | Window & Click-Through Invariants | `MascotOverlayPanel` and `SpeechBubblePanel` click-through (`ignoresMouseEvents = true`), `.nonactivatingPanel` focus rules, and detached closed Settings window (`contentViewController = nil`) must remain completely intact. | Technical | High | Open |
| C-003 | Public macOS API Only | Must integrate with macOS Focus strictly via user-configured `/usr/bin/shortcuts` CLI actions without private entitlements or TCC Full Disk Access. | Regulatory | High | Open |

### Key Entities

- **`FlowShieldSettingsStore`**: `@MainActor` observable `UserDefaults`-backed store managing `isEnabled`, `streakMinutesThreshold`, `startFocusShortcutName`, `stopFocusShortcutName`, and `isBreakShieldOverrideActive`.
- **`ShortcutsRunning` / `ProcessShortcutsRunner`**: Sendable protocol seam and off-main-thread `/usr/bin/shortcuts` process runner with validation and timeout protection.
- **`FlowShieldService`**: `@MainActor` coordinator observing `WellnessPointEngine` to manage `isFlowShieldActive`, once-per-streak activation, post-break deactivation, Break Shield override, and `lastErrorMessage`.

## Success Criteria *(mandatory)*

### Measurable Outcomes

- **SC-001**: Reaching `streakMinutesThreshold` while opted-in invokes `startFocusShortcutName` exactly `1` time per streak (`0` duplicate calls across subsequent 5-second work ticks) and returning from a break invokes `stopFocusShortcutName` `1` time.
- **SC-002**: Toggling `"Break Shield"` or disabling `"Auto Flow Shield"` while active immediately triggers `stopFocusShortcutName` and suppresses re-activation across subsequent work ticks (`0` unintended activations).
- **SC-003**: 100% pass rate across all existing and new XCTest suites via `xcrun swift test` and clean release compilation via `xcrun swift build -c release` with zero warnings or errors introduced.
