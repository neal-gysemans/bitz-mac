---
work_package_id: WP07
title: Opt-in Git Activity Signal
dependencies: [WP01]
requirement_refs:
- FR-012
planning_base_branch: feat/20-on-device-ai-personality
merge_target_branch: feat/20-on-device-ai-personality
branch_strategy: Planning artifacts for this mission were generated on feat/20-on-device-ai-personality. During /spec-kitty.implement this WP may branch from a dependency-specific base, but completed changes must merge back into feat/20-on-device-ai-personality unless the human explicitly redirects the landing branch.
base_branch: kitty/mission-on-device-ai-personality-01M6GG7J
base_commit: ec3e9de8fdd6d019d1e7f9dd935944b257a4da68
created_at: '2026-11-03T11:42:41.100730+00:00'
subtasks:
- T024
- T025
- T026
phase: Phase 4 - Optional Signal
history: []
authoritative_surface: src/Services/
create_intent:
- src/Services/GitActivityProvider.swift
- src/Views/Settings/GitReposPickerView.swift
- Tests/BitzTests/GitActivityProviderTests.swift
execution_mode: code_change
owned_files:
- src/Services/GitActivityProvider.swift
- src/Views/Settings/GitReposPickerView.swift
- Tests/BitzTests/GitActivityProviderTests.swift
tags: []
task_type: implement
tracker_refs: []
---

# Work Package Prompt: WP07 – Opt-in Git Activity Signal

## Objectives & Success Criteria
Local, opt-in commit counts. Satisfies: FR-012 (see spec.md).

## Subtasks
- **T024**: `GitActivityProvider` conforming to `GitActivityProviding`: `git log --since` per chosen repo, off-main, TTL-cached, injectable process runner.
- **T025**: `GitReposPickerView` (folder picker list) embedded by the Settings tab.
- **T026**: Tests: no repos means no process spawned; counts aggregate; cache TTL honored.

## Notes & Risks
Follow AGENTS.md invariants (Swift 6, no new dependencies, isolated UserDefaults in tests, Xcode toolchain). Run `xcrun swift test` before finishing.
