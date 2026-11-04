---
work_package_id: WP04
title: App Wiring, CPU Verification & Contributor Docs
dependencies:
- WP01
- WP02
- WP03
requirement_refs:
- NFR-001
planning_base_branch: feat/issue-117-bitz-pro-licensing
merge_target_branch: feat/issue-117-bitz-pro-licensing
branch_strategy: Planning artifacts for this mission were generated on feat/issue-117-bitz-pro-licensing. During /spec-kitty.implement this WP may branch from a dependency-specific base, but completed changes must merge back into feat/issue-117-bitz-pro-licensing unless the human explicitly redirects the landing branch.
base_branch: kitty/mission-bitz-pro-licensing-01M6JYJJ
base_commit: 9e4df6da3255e8f94465d8e6f5e7000103f9875b
created_at: '2026-11-04T10:27:04.076872+00:00'
subtasks:
- T010
- T011
- T012
phase: Phase 4 - App Wiring & Verification
history: []
authoritative_surface: src/App/
create_intent:
- docs/LICENSING.md
execution_mode: code_change
owned_files:
- src/App/BitzApp.swift
- docs/LICENSING.md
tags: []
task_type: implement
tracker_refs: []
---

# Work Package Prompt: WP04 – App Wiring, CPU Verification & Contributor Docs

## Objectives & Success Criteria
Satisfies: NFR-001 (see spec.md).
Wire `LicensingService` into `BitzApp`, author `docs/LICENSING.md`, and verify desktop idle CPU remains `< 2%`.

## Subtasks
- **T010**: Wire `LicensingService` into `BitzApp.swift` and pass to `SettingsWindowManager`.
- **T011**: Create `docs/LICENSING.md` documenting key structure, cryptographic verification, web checkout webhook flow, and dev key generation snippet.
- **T012**: Run `./Scripts/package_and_run.sh release` and verify desktop idle CPU remains strictly `< 2%` and RAM `< 70 MB`.
