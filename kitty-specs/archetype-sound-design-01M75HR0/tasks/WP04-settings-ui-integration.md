---
work_package_id: WP04
title: Settings UI Integration (Audio Tab & Roster Audition)
dependencies:
- WP02
- WP03
requirement_refs:
- FR-004
- FR-005
- C-004
planning_base_branch: feat/issue-150-archetype-sound-design
merge_target_branch: feat/issue-150-archetype-sound-design
branch_strategy: Planning artifacts for this mission were generated on feat/issue-150-archetype-sound-design. During /spec-kitty.implement this WP may branch from a dependency-specific base, but completed changes must merge back into feat/issue-150-archetype-sound-design unless the human explicitly redirects the landing branch.
subtasks:
- T015
- T016
- T017
- T018
phase: Phase 4 - UI Integration
history:
- timestamp: '2026-11-12T00:00:00Z'
  agent: system
  action: Prompt generated via plan
authoritative_surface: src/Views/Settings/
create_intent: []
execution_mode: code_change
owned_files:
- src/Views/Settings/AppearanceCharacterRosterSectionView.swift
- src/Views/Settings/AppearanceSettingsTabView.swift
- src/Views/Settings/AudioSettingsTabView.swift
- src/Views/Settings/SettingsRootView.swift
tags: []
tracker_refs: []
---

# Work Package Prompt: WP04 – Settings UI Integration (Audio Tab & Roster Audition)

## Objectives
Surface active companion reaction sound dynamically in Settings → Audio, and provide companion sound audition preview buttons on each card in Settings → Appearance → Character Roster (including locked Pro companions).

## Files to Create / Modify
- `src/Views/Settings/AudioSettingsTabView.swift`
- `src/Views/Settings/AppearanceCharacterRosterSectionView.swift`
- `src/Views/Settings/AppearanceSettingsTabView.swift`
- `src/Views/Settings/SettingsRootView.swift`
- `Tests/BitzTests/AudioSettingsViewsTests.swift`
