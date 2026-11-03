---
work_package_id: WP06
title: Settings Tab
dependencies: ['WP01', 'WP07']
requirement_refs:
- FR-001
- FR-007
- FR-009
- C-003
planning_base_branch: feat/20-on-device-ai-personality
merge_target_branch: feat/20-on-device-ai-personality
branch_strategy: Planning artifacts for this mission were generated on feat/20-on-device-ai-personality. During /spec-kitty.implement this WP may branch from a dependency-specific base, but completed changes must merge back into feat/20-on-device-ai-personality unless the human explicitly redirects the landing branch.
subtasks:
- T021
- T022
- T023
phase: Phase 4 - UI
history: []
authoritative_surface: src/Views/Settings/
execution_mode: code_change
create_intent:
- src/Views/Settings/PersonalitySettingsTabView.swift
- Tests/BitzTests/PersonalitySettingsTabTests.swift
owned_files:
- src/Views/Settings/PersonalitySettingsTabView.swift
- src/Views/Settings/SettingsRootView.swift
- Tests/BitzTests/PersonalitySettingsTabTests.swift
tags: []
task_type: implement
tracker_refs: []
---

# Work Package Prompt: WP06 – Settings Tab

## Objectives & Success Criteria
User-facing controls. Satisfies: FR-001, FR-007, FR-009, C-003 (see spec.md).

## Subtasks
- **T021**: `PersonalitySettingsTabView`: enable toggle (off by default), preset picker, interval and daily cap, availability note (Foundation Models status), and the watched-repo picker from WP07.
- **T022**: Register the tab in `SettingsRootView`; bindings persist through `PersonalitySettingsStore`.
- **T023**: Tests for two-way binding persistence; confirm the window still detaches on close.

## Notes & Risks
Follow AGENTS.md invariants (Swift 6, no new dependencies, isolated UserDefaults in tests, Xcode toolchain). Run `xcrun swift test` before finishing.
