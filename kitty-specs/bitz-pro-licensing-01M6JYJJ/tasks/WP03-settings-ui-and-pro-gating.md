---
work_package_id: WP03
title: Settings UI & Pro Gating Controls
dependencies:
- WP01
- WP02
requirement_refs:
- FR-005
- FR-006
- NFR-001
planning_base_branch: feat/issue-117-bitz-pro-licensing
merge_target_branch: feat/issue-117-bitz-pro-licensing
branch_strategy: Planning artifacts for this mission were generated on feat/issue-117-bitz-pro-licensing. During /spec-kitty.implement this WP may branch from a dependency-specific base, but completed changes must merge back into feat/issue-117-bitz-pro-licensing unless the human explicitly redirects the landing branch.
base_branch: kitty/mission-bitz-pro-licensing-01M6JYJJ
base_commit: 9e4df6da3255e8f94465d8e6f5e7000103f9875b
created_at: '2026-11-04T10:21:49.827445+00:00'
subtasks:
- T007
- T008
- T009
phase: Phase 3 - Presentation Layer
history: []
authoritative_surface: src/Views/
create_intent:
- src/Views/Components/ProBadgeView.swift
- src/Views/Settings/BitzProSettingsTabView.swift
execution_mode: code_change
owned_files:
- src/Views/Components/ProBadgeView.swift
- src/Views/Settings/BitzProSettingsTabView.swift
- src/Views/Settings/SettingsRootView.swift
tags: []
task_type: implement
tracker_refs: []
---

# Work Package Prompt: WP03 – Settings UI & Pro Gating Controls

## Objectives & Success Criteria
Satisfies: FR-005, FR-006, NFR-001 (see spec.md).
Create `ProBadgeView.swift`, `BitzProSettingsTabView.swift`, and integrate the Bitz Pro tab into `SettingsRootView.swift`.

## Subtasks
- **T007**: Create `src/Views/Components/ProBadgeView.swift` with neon badge and `.proFeatureGated(...)`.
- **T008**: Create `src/Views/Settings/BitzProSettingsTabView.swift` with plan status badge, key input field, activation feedback, Pro perks preview cards, and web checkout link.
- **T009**: Integrate `BitzProSettingsTabView` into `src/Views/Settings/SettingsRootView.swift` with tab navigation.
