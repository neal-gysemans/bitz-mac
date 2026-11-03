---
work_package_id: WP01
title: Flow Shield Models & Settings Store
dependencies: []
requirement_refs:
- FR-001
- NFR-003
planning_base_branch: feat/issue-22-auto-flow-shield
merge_target_branch: feat/issue-22-auto-flow-shield
branch_strategy: Planning artifacts for this mission were generated on feat/issue-22-auto-flow-shield. During /spec-kitty.implement this WP may branch from a dependency-specific base, but completed changes must merge back into feat/issue-22-auto-flow-shield unless the human explicitly redirects the landing branch.
base_branch: kitty/mission-auto-flow-shield-01M6EZ8E
base_commit: 5833ec24b19cfb51ef6ab3d0527e5ad7f6cffa63
created_at: '2026-11-02T20:33:58.888106+00:00'
subtasks:
- T001
- T002
- T003
phase: Phase 1 - Models & Persistence
history: []
authoritative_surface: src/Models/
create_intent:
- src/Models/FlowShieldModels.swift
- src/Models/FlowShieldSettingsStore.swift
- Tests/BitzTests/FlowShieldSettingsStoreTests.swift
execution_mode: code_change
owned_files:
- src/Models/FlowShieldModels.swift
- src/Models/FlowShieldSettingsStore.swift
- Tests/BitzTests/FlowShieldSettingsStoreTests.swift
tags: []
task_type: implement
tracker_refs: []
---

# Work Package Prompt: WP01 – Flow Shield Models & Settings Store

## Objectives & Success Criteria
Satisfies: FR-001, NFR-003 (see spec.md, refs #22).

## Subtasks
- **T001**: Implement `FlowShieldStatus` and `FlowShieldShortcutError` in `src/Models/FlowShieldModels.swift`.
- **T002**: Implement `@MainActor public final class FlowShieldSettingsStore: ObservableObject` in `src/Models/FlowShieldSettingsStore.swift` with injectable `UserDefaults`, opt-in default (`isEnabled = false`), clamped `streakMinutesThreshold` (`5...120`, default `20.0`), Shortcut names (`"Start Focus"`, `"Stop Focus"`), and `isBreakShieldOverrideActive`.
- **T003**: Write deterministic unit tests in `Tests/BitzTests/FlowShieldSettingsStoreTests.swift` using isolated `UserDefaults(suiteName:)` domains with cleanup.

## Notes & Risks
`isEnabled` MUST default to `false` so existing users never experience unexpected Shortcut runs. `init` must read fallback defaults cleanly without mutating `.standard` prior to explicit setter calls.
