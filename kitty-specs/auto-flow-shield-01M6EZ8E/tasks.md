# Tasks: Auto Flow-State Shield (macOS Focus & Break Integration)

**Spec**: [spec.md](spec.md) | **Plan**: [plan.md](plan.md)

## Work Package WP01: Flow Shield Models & Settings Store

**Goal**: Establish Flow Shield domain models (`FlowShieldStatus`, `FlowShieldShortcutError`) and `@MainActor` `UserDefaults`-backed `FlowShieldSettingsStore` (defaulting to OFF) with deterministic unit tests.
**Prompt**: `/tasks/WP01-flow-shield-models-and-settings-store.md`
**Requirement Refs**: FR-001, NFR-003
**Dependencies**: none

### Included Subtasks
- T001: Implement `FlowShieldStatus` and `FlowShieldShortcutError` in `src/Models/FlowShieldModels.swift`.
- T002: Implement `@MainActor public final class FlowShieldSettingsStore: ObservableObject` in `src/Models/FlowShieldSettingsStore.swift` with injectable `UserDefaults`, opt-in default (`isEnabled = false`), clamped `streakMinutesThreshold` (`5...120`, default `20.0`), Shortcut names (`"Start Focus"`, `"Stop Focus"`), and `isBreakShieldOverrideActive`.
- T003: Write deterministic unit tests in `Tests/BitzTests/FlowShieldSettingsStoreTests.swift` using isolated `UserDefaults(suiteName:)` domains with cleanup.

---

## Work Package WP02: Shortcuts Runner & FlowShieldService Coordinator

**Goal**: Implement `ShortcutsRunning`, production `ProcessShortcutsRunner`, `SpyShortcutsRunner`, and `FlowShieldService` observing `WellnessPointEngine` for once-per-streak activation, post-break deactivation, and Break Shield override.
**Prompt**: `/tasks/WP02-shortcuts-runner-and-flow-shield-service.md`
**Requirement Refs**: FR-002, FR-003, FR-004, FR-005, NFR-001, NFR-002, C-003
**Dependencies**: WP01

### Included Subtasks
- T004: Implement `ShortcutsRunning` protocol, `ProcessShortcutsRunner` (`/usr/bin/shortcuts run <name>` off `@MainActor`, zero shell interpolation, trimmed name validation, timeout guard), and `SpyShortcutsRunner` in `src/Services/FlowShieldService.swift`.
- T005: Implement `@MainActor public final class FlowShieldService: ObservableObject` in `src/Services/FlowShieldService.swift` observing `WellnessPointEngine` for once-per-streak Start Focus, break-completion Stop Focus, Break Shield override, master opt-out handling, and Settings test actions.
- T006: Write comprehensive unit tests in `Tests/BitzTests/FlowShieldServiceTests.swift` verifying default-off, once-per-streak execution across repeated 5s ticks, break completion deactivation, Break Shield override suppression, master toggle disable while active, and error handling.

---

## Work Package WP03: Behavior Settings Card, App Wiring & Menu Bar Integration

**Goal**: Expose Auto Flow Shield configuration and Break Shield override in `BehaviorSettingsTabView` and `BitzMenuBarContentView` while preserving default-parameter initializer compatibility across `SettingsRootView` and `BitzAppDelegate`.
**Prompt**: `/tasks/WP03-settings-and-menu-bar-integration.md`
**Requirement Refs**: FR-006, C-001, C-002
**Dependencies**: WP01, WP02

### Included Subtasks
- T007: Add the `"Auto Flow Shield (macOS Focus)"` settings card to `src/Views/Settings/BehaviorSettingsTabView.swift` with default `= nil` initializer parameters, streak threshold controls, Shortcut fields + Test buttons, `Shortcuts.app` setup helper text, and Break Shield toggle.
- T008: Forward optional `flowShieldSettings` and `flowShieldService` (default `= nil`) in `src/Views/Settings/SettingsRootView.swift`.
- T009: Wire `flowShieldSettings` and `flowShieldService.observe(wellnessEngine: engine)` in `BitzAppDelegate` and add Flow Shield status + 1-click `"Break Shield (Disable Focus)"` override controls in `BitzMenuBarContentView` (`src/App/BitzApp.swift`) with default `= nil` initializer parameters.
- T010: Write UI and backward-compatibility integration tests in `Tests/BitzTests/FlowShieldViewsTests.swift`.
