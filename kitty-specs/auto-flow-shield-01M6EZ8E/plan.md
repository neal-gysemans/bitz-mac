# Implementation Plan: Auto Flow-State Shield (macOS Focus & Break Integration)

**Branch**: `feat/issue-22-auto-flow-shield` | **Date**: 2026-11-02 | **Spec**: [spec.md](spec.md)  
**Input**: Feature specification from `/kitty-specs/auto-flow-shield-01M6EZ8E/spec.md` (Tracks GitHub issue #22)

## Summary

Implement the opt-in **Auto Flow-State Shield** integration with macOS Focus via `/usr/bin/shortcuts`. `FlowShieldSettingsStore` persists user preferences (`isEnabled` defaulting to `false`, `streakMinutesThreshold` defaulting to `20.0` min, `startFocusShortcutName`, `stopFocusShortcutName`, and `isBreakShieldOverrideActive`). `FlowShieldService` observes `WellnessPointEngine` with zero extra polling timers, invoking `startFocusShortcutName` once per deep-work streak via an off-main-thread `ShortcutsRunning` seam (`ProcessShortcutsRunner`) and invoking `stopFocusShortcutName` when returning from a completed break or when the user activates `"Break Shield"` from Settings (`Behaviors` tab) or the Menu Bar (`BitzMenuBarContentView`).

## Technical Context

**Language/Version**: Swift 6.0 (`swift-tools-version: 6.0`)  
**Primary Dependencies**: AppKit, SwiftUI, Combine, Foundation (`Process`) — zero external SwiftPM dependencies  
**Storage**: Injectable `UserDefaults` (`init(userDefaults: UserDefaults = .standard)`) with isolated suite cleanup in unit tests  
**Testing**: XCTest in `Tests/BitzTests/` (`FlowShieldSettingsStoreTests`, `FlowShieldServiceTests`, `FlowShieldViewsTests`)  
**Target Platform**: macOS 14.0+, Apple Silicon (`arm64`)  
**Project Type**: Single Swift package (`BitzCore` library + `Bitz` executable + `BitzTests` test suite)  
**Performance Goals**: `< 2%` desktop idle CPU (`0` extra timers; Combine-driven on `WellnessPointEngine` transitions), `< 70 MB` RAM, off-main-thread Shortcut execution with `<= 15s` timeout  
**Constraints**: Default `isEnabled = false`; zero shell interpolation (`Process.arguments = ["run", trimmedName]`); backward-compatible default `= nil` parameters on `BehaviorSettingsTabView.init`, `SettingsRootView.init`, `BitzMenuBarContentView.init`, and `BitzAppDelegate.init`; 100% click-through & detached closed Settings window invariants preserved  
**Scale/Scope**: 2 model/store files, 1 service + runner file, 3 UI/app integration files, and 3 XCTest suites

## Charter Check

- **Idle CPU & Memory (`< 2%` CPU, `< 70 MB` RAM)**: PASS. `FlowShieldService` introduces zero timers, zero `TimelineView` animations, and zero polling loops; it subscribes only to existing `WellnessPointEngine` `@Published` state changes and only spawns `/usr/bin/shortcuts` on discrete streak/break/override transitions when opted in.
- **100% Click-Through & Zero Focus Stealing**: PASS. Overlay panels (`MascotOverlayPanel`, `SpeechBubblePanel`) and `SettingsWindowManager` detachment (`contentViewController = nil`) remain untouched.
- **Backward Initializer Compatibility**: PASS. All modified initializers provide default `= nil` parameters.
- **Deterministic Headless Tests**: PASS. `SpyShortcutsRunner` and isolated `UserDefaults(suiteName:)` suites run deterministically without touching `/usr/bin/shortcuts` or `.standard`.

## Design Decisions

1. **Opt-In Settings Store (`FlowShieldSettingsStore`)**:
   - Keys under `bitz.flowShield.*`: `isEnabled` (default `false`), `streakMinutesThreshold` (default `20.0`, clamped `5.0...120.0`), `startFocusShortcutName` (default `"Start Focus"`), `stopFocusShortcutName` (default `"Stop Focus"`), and `isBreakShieldOverrideActive` (default `false`).
   - Reads defaults cleanly without mutating `UserDefaults` during `init`, writing only on explicit setter calls, and resets `isBreakShieldOverrideActive` when starting a new opted-in session (`false -> true` transition on `setEnabled`).

2. **Safe Off-Main-Thread Shortcuts Execution (`ShortcutsRunning` & `ProcessShortcutsRunner`)**:
   - `public protocol ShortcutsRunning: Sendable { func runShortcut(named name: String) async throws }`
   - `ProcessShortcutsRunner` validates trimmed non-empty Shortcut names, checks executable presence (`/usr/bin/shortcuts`), passes `["run", trimmedName]` directly via `Process.arguments` (zero shell interpolation), sets `standardInput = .nullDevice` and `standardOutput = .nullDevice`, captures bounded `stderr`, and awaits `terminationHandler` off `@MainActor` with a configurable timeout (`15.0s`).
   - `SpyShortcutsRunner` records invoked Shortcut names in order and supports simulated errors for deterministic unit testing.

3. **Streak & Break State Coordinator (`FlowShieldService`)**:
   - Tracks `isFlowShieldActive: Bool`, `lastErrorMessage: String?`, `hasTriggeredForCurrentStreak: Bool`, and `wasInChargingState: Bool`.
   - **Activation**: When `settings.isEnabled && !settings.isBreakShieldOverrideActive && !isFlowShieldActive && !hasTriggeredForCurrentStreak && engine.currentState != .charging && engine.continuousWorkMinutes >= settings.streakMinutesThreshold`, sets `isFlowShieldActive = true` and `hasTriggeredForCurrentStreak = true` synchronously before enqueuing `startFocusShortcutName`. If the Shortcut fails, records `lastErrorMessage` and reverts `isFlowShieldActive = false` while keeping `hasTriggeredForCurrentStreak = true` to prevent 5-second retry storms.
   - **Post-Break Deactivation**: Detects break completion either when `engine.currentState` transitions out of `.charging` (`wasInChargingState && engine.currentState != .charging`) or when an offline break resets `engine.continuousWorkMinutes == 0` with `engine.lastTickWasProductive == true`. When `isFlowShieldActive == true`, sets `isFlowShieldActive = false` and enqueues `stopFocusShortcutName`. Resets `hasTriggeredForCurrentStreak = false` whenever `engine.continuousWorkMinutes < settings.streakMinutesThreshold` while `!isFlowShieldActive`.
   - **Break Shield Override & Master Opt-Out**: `activateBreakShieldOverride()`, `toggleBreakShieldOverride()`, and `settings.$isEnabled` turning `false` immediately stop Focus if `isFlowShieldActive == true` and suppress re-activation until `clearBreakShieldOverride()` or the next opted-in session.
   - **Serialized Execution Queue**: Chains Shortcut tasks sequentially so rapid Start -> Stop transitions never race out of order.

4. **Settings & Menu Bar UX**:
   - `BehaviorSettingsTabView`: Adds `"Auto Flow Shield (macOS Focus)"` card with master toggle, streak threshold stepper/slider (`5–90 min` UI controls within `5–120 min` store bounds), `"Start Focus"` / `"Stop Focus"` text fields with `"Test"` buttons, 1-action `Shortcuts.app` setup helper caption, error banner if `lastErrorMessage != nil`, and `"Break Shield"` override control.
   - `BitzMenuBarContentView` & `BitzAppDelegate`: Wires `flowShieldSettings` and `flowShieldService.observe(wellnessEngine: engine)` and adds a concise `"Flow Shield"` Menu Bar section/submenu with live status, master toggle, and 1-click `"Break Shield (Disable Focus)"` override action.

## Project Structure

### Documentation (this mission)

```
kitty-specs/auto-flow-shield-01M6EZ8E/
├── checklists/
│   └── requirements.md
├── plan.md
├── research.md
├── spec.md
└── tasks.md
```

### Source Code (repository root)

```
src/
├── App/
│   └── BitzApp.swift                       # Wires FlowShieldSettingsStore & FlowShieldService + Menu Bar controls
├── Models/
│   ├── FlowShieldModels.swift              # FlowShieldStatus, FlowShieldShortcutError
│   └── FlowShieldSettingsStore.swift       # UserDefaults-backed opt-in preferences store
├── Services/
│   └── FlowShieldService.swift             # ShortcutsRunning, ProcessShortcutsRunner, SpyShortcutsRunner, FlowShieldService
└── Views/
    └── Settings/
        ├── BehaviorSettingsTabView.swift   # "Auto Flow Shield (macOS Focus)" configuration card
        └── SettingsRootView.swift          # Forwards flowShieldSettings & flowShieldService with default = nil

Tests/
└── BitzTests/
    ├── FlowShieldSettingsStoreTests.swift  # Defaults, clamping, persistence, override reset
    ├── FlowShieldServiceTests.swift        # Once-per-streak, break completion, Break Shield override, master opt-out, error backoff
    └── FlowShieldViewsTests.swift          # Settings card, RootView & MenuBar backward-compatible wiring
```

**Structure Decision**: Extends the single `BitzCore` SwiftPM target under `src/Models/`, `src/Services/`, `src/Views/Settings/`, and `src/App/` with matching unit tests in `Tests/BitzTests/`.

## Implementation Concern Map

### IC-01 — Flow Shield Domain Models & Settings Persistence
- **Purpose**: Provide `FlowShieldStatus`, `FlowShieldShortcutError`, and `FlowShieldSettingsStore` with opt-in defaults, threshold sanitization, and `UserDefaults` persistence.
- **Relevant requirements**: FR-001, NFR-003
- **Affected surfaces**: `src/Models/FlowShieldModels.swift`, `src/Models/FlowShieldSettingsStore.swift`, `Tests/BitzTests/FlowShieldSettingsStoreTests.swift`
- **Sequencing/depends-on**: none
- **Risks**: Must default `isEnabled` to `false` and avoid mutating `UserDefaults.standard` during default parameter instantiation.

### IC-02 — Safe Shortcuts Runner & FlowShieldService State Coordinator
- **Purpose**: Implement `ShortcutsRunning`, `ProcessShortcutsRunner`, `SpyShortcutsRunner`, and `FlowShieldService` observing `WellnessPointEngine` for once-per-streak activation, post-break deactivation, and Break Shield override.
- **Relevant requirements**: FR-002, FR-003, FR-004, FR-005, NFR-001, NFR-002, NFR-003, C-003, SC-001, SC-002
- **Affected surfaces**: `src/Services/FlowShieldService.swift`, `Tests/BitzTests/FlowShieldServiceTests.swift`
- **Sequencing/depends-on**: IC-01
- **Risks**: Prevent duplicate triggers on 5s ticks and prevent retry storms on missing Shortcuts.

### IC-03 — Behavior Settings Card, App Wiring & Menu Bar Override
- **Purpose**: Expose Auto Flow Shield configuration and test actions in `BehaviorSettingsTabView`, wire into `SettingsRootView` and `BitzAppDelegate`, and add Menu Bar Break Shield controls in `BitzMenuBarContentView`.
- **Relevant requirements**: FR-006, C-001, C-002, SC-003
- **Affected surfaces**: `src/Views/Settings/BehaviorSettingsTabView.swift`, `src/Views/Settings/SettingsRootView.swift`, `src/App/BitzApp.swift`, `Tests/BitzTests/FlowShieldViewsTests.swift`
- **Sequencing/depends-on**: IC-01, IC-02
- **Risks**: Maintain default `= nil` initializer parameters so existing tests compile unchanged.
