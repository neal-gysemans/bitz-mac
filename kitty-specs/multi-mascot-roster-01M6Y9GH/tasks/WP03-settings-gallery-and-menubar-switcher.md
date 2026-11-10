---
work_package_id: WP03
title: Settings Character Gallery & Menu Bar Switcher
dependencies:
- WP01
- WP02
requirement_refs:
- FR-004
- FR-005
- C-002
planning_base_branch: feat/issue-30-multi-mascot-roster
merge_target_branch: feat/issue-30-multi-mascot-roster
branch_strategy: Planning artifacts for this mission were generated on feat/issue-30-multi-mascot-roster. During /spec-kitty.implement this WP may branch from a dependency-specific base, but completed changes must merge back into feat/issue-30-multi-mascot-roster unless the human explicitly redirects the landing branch.
base_branch: kitty/mission-multi-mascot-roster-01M6Y9GH
base_commit: 02b9b9b285dbb56098d8dec8a2a37130c392fa7e
created_at: '2026-11-08T19:29:39.141428+00:00'
subtasks:
- T005
- T006
phase: Phase 3 - Settings & Menu Bar UI
history: []
authoritative_surface: src/Views/Settings/
create_intent:
- src/Views/Settings/AppearanceCharacterRosterSectionView.swift
execution_mode: code_change
owned_files:
- src/Views/Settings/AppearanceCharacterRosterSectionView.swift
- src/Views/Settings/AppearanceSettingsTabView.swift
- src/Views/Settings/SettingsRootView.swift
tags: []
task_type: implement
tracker_refs: []
---

# Work Package Prompt: WP03 – Settings Character Gallery & Menu Bar Switcher

## Objectives & Success Criteria
Satisfies: FR-004, FR-005, C-002 (see spec.md).
Build the visual Character Gallery in `AppearanceSettingsTabView` and integrate `AvatarCharacterStore` into `SettingsRootView`.

## Subtasks
- **T005**: Create `src/Views/Settings/AppearanceCharacterRosterSectionView.swift` and wire it into `AppearanceSettingsTabView.swift` and `SettingsRootView.swift`.
- **T006**: Prepare Menu Bar character switcher integration points.
