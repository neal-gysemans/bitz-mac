---
work_package_id: WP01
title: In-App Update Service Adaptation
dependencies: []
requirement_refs:
- FR-004
- NFR-001
- NFR-004
planning_base_branch: feat/issue-105-private-repo-release-pipeline
merge_target_branch: feat/issue-105-private-repo-release-pipeline
branch_strategy: Planning artifacts for this mission were generated on feat/issue-105-private-repo-release-pipeline. During /spec-kitty.implement this WP may branch from a dependency-specific base, but completed changes must merge back into feat/issue-105-private-repo-release-pipeline unless the human explicitly redirects the landing branch.
subtasks:
- T001
- T002
- T003
phase: Phase 1 - Update Service
history: []
authoritative_surface: src/Services/
create_intent: []
execution_mode: code_change
owned_files:
- src/Services/AppUpdateService.swift
- Tests/BitzTests/AppUpdateServiceTests.swift
tags: []
task_type: implement
tracker_refs: []
---

# Work Package Prompt: WP01 – In-App Update Service Adaptation

## Objectives & Success Criteria
Satisfies: FR-004, NFR-001, NFR-004 (see spec.md).
Configure `AppUpdateService` default repository to target `AkramKs/bitz-releases` instead of `AkramKs/bitz-mac`.

## Subtasks
- **T001**: Update default repository constant in `GitHubUpdateService` (`src/Services/AppUpdateService.swift`) to `"AkramKs/bitz-releases"`.
- **T002**: Update existing unit tests in `Tests/BitzTests/AppUpdateServiceTests.swift` to assert default repository is `"AkramKs/bitz-releases"`.
- **T003**: Run deterministic test suite (`xcrun swift test`) to verify all update parsing and comparison tests pass.

## Notes & Risks
Zero change to idle CPU or memory usage.
