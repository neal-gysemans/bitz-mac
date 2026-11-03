---
work_package_id: WP03
title: Behavior Settings Card, App Wiring & Menu Bar Integration
dependencies:
- WP01
- WP02
requirement_refs:
- FR-006
- C-001
- C-002
planning_base_branch: feat/issue-22-auto-flow-shield
merge_target_branch: feat/issue-22-auto-flow-shield
branch_strategy: Planning artifacts for this mission were generated on feat/issue-22-auto-flow-shield. During /spec-kitty.implement this WP may branch from a dependency-specific base, but completed changes must merge back into feat/issue-22-auto-flow-shield unless the human explicitly redirects the landing branch.
base_branch: kitty/mission-auto-flow-shield-01M6EZ8E
base_commit: 5833ec24b19cfb51ef6ab3d0527e5ad7f6cffa63
created_at: '2026-11-02T20:39:56.579164+00:00'
subtasks:
- T007
- T008
- T009
- T010
phase: Phase 3 - UI & App Integration
history: []
authoritative_surface: src/Views/
create_intent:
- Tests/BitzTests/FlowShieldViewsTests.swift
execution_mode: code_change
owned_files:
- src/Views/Settings/BehaviorSettingsTabView.swift
- src/Views/Settings/SettingsRootView.swift
- src/App/BitzApp.swift
- Tests/BitzTests/FlowShieldViewsTests.swift
tags: []
task_type: implement
tracker_refs: []
---

# Work Package Prompt: WP03 – Behavior Settings Card, App Wiring & Menu Bar Integration

## Objectives & Success Criteria
Satisfies: FR-006, C-001, C-002 (see spec.md, refs #22).

## Subtasks
- **T007**: Add the `"Auto Flow Shield (macOS Focus)"` settings card to `src/Views/Settings/BehaviorSettingsTabView.swift` with default `= nil` initializer parameters, streak threshold controls, Shortcut fields + Test buttons, `Shortcuts.app` setup helper text, and Break Shield toggle.
- **T008**: Forward optional `flowShieldSettings` and `flowShieldService` (default `= nil`) in `src/Views/Settings/SettingsRootView.swift`.
- **T009**: Wire `flowShieldSettings` and `flowShieldService.observe(wellnessEngine: engine)` in `BitzAppDelegate` and add Flow Shield status + 1-click `"Break Shield (Disable Focus)"` override controls in `BitzMenuBarContentView` (`src/App/BitzApp.swift`) with default `= nil` initializer parameters.
- **T010**: Write UI and backward-compatibility integration tests in `Tests/BitzTests/FlowShieldViewsTests.swift`.

## Notes & Risks
All new initializer parameters on `BehaviorSettingsTabView.init`, `SettingsRootView.init`, `BitzMenuBarContentView.init`, and `BitzAppDelegate.init` MUST default to `nil` so existing unit/layout tests and parallel PRs compile without changes.
