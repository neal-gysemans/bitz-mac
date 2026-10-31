---
work_package_id: WP04
title: Settings Window Tab & Menu Bar UI Integration
dependencies:
- WP01
- WP02
- WP03
requirement_refs:
- FR-008
planning_base_branch: feat/issue-21-cyber-audio
merge_target_branch: feat/issue-21-cyber-audio
branch_strategy: Planning artifacts for this mission were generated on feat/issue-21-cyber-audio. During /spec-kitty.implement this WP may branch from a dependency-specific base, but completed changes must merge back into feat/issue-21-cyber-audio unless the human explicitly redirects the landing branch.
subtasks:
- T013
- T014
- T015
- T016
phase: Phase 4 - UI Integration
history: []
authoritative_surface: src/Views/
create_intent:
- src/Views/Settings/AudioSettingsTabView.swift
- Tests/BitzTests/AudioSettingsViewsTests.swift
execution_mode: code_change
owned_files:
- src/Views/Settings/AudioSettingsTabView.swift
- src/Views/Settings/SettingsRootView.swift
- src/App/BitzApp.swift
- Tests/BitzTests/AudioSettingsViewsTests.swift
tags: []
task_type: implement
tracker_refs: []
---

# Work Package Prompt: WP04 – Settings Window Tab & Menu Bar UI Integration

## Objectives & Success Criteria
Satisfies: FR-008, SC-001 (see spec.md).

## Subtasks
- **T013**: Implement `AudioSettingsTabView` in `src/Views/Settings/AudioSettingsTabView.swift` with master toggle, volume slider, per-event checkboxes, and "Test Sound" preview buttons.
- **T014**: Add the "Audio" tab to `SettingsRootView` in `src/Views/Settings/SettingsRootView.swift`.
- **T015**: Add a "Sound" submenu in `BitzMenuBarContentView` in `src/App/BitzApp.swift` for quick mute/unmute and volume adjustments.
- **T016**: Unit tests in `Tests/BitzTests/AudioSettingsViewsTests.swift` verifying UI bindings and settings modifications.

## Notes & Risks
Follow the existing `GeneralSettingsTabView` / `BehaviorSettingsTabView` design system and SF Symbols.
