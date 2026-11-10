---
work_package_id: WP04
title: App Wiring, Deterministic Tests & Live CPU Verification
dependencies:
- WP01
- WP02
- WP03
requirement_refs:
- FR-001
- FR-002
- FR-003
- FR-004
- FR-005
- FR-006
- NFR-001
- NFR-002
- NFR-003
planning_base_branch: feat/issue-30-multi-mascot-roster
merge_target_branch: feat/issue-30-multi-mascot-roster
branch_strategy: Planning artifacts for this mission were generated on feat/issue-30-multi-mascot-roster. During /spec-kitty.implement this WP may branch from a dependency-specific base, but completed changes must merge back into feat/issue-30-multi-mascot-roster unless the human explicitly redirects the landing branch.
base_branch: kitty/mission-multi-mascot-roster-01M6Y9GH
base_commit: 02b9b9b285dbb56098d8dec8a2a37130c392fa7e
created_at: '2026-11-08T19:31:42.389191+00:00'
subtasks:
- T007
- T008
- T009
phase: Phase 4 - App Wiring & Tests
history: []
authoritative_surface: src/App/
create_intent:
- Tests/BitzTests/MascotCharacterTests.swift
execution_mode: code_change
owned_files:
- src/App/BitzApp.swift
- Tests/BitzTests/MascotCharacterTests.swift
- Tests/BitzTests/MascotOverlayLayoutTests.swift
tags: []
task_type: implement
tracker_refs: []
---

# Work Package Prompt: WP04 – App Wiring, Deterministic Tests & Live CPU Verification

## Objectives & Success Criteria
Satisfies: FR-001, FR-002, FR-003, FR-004, FR-005, FR-006, NFR-001, NFR-002, NFR-003 (see spec.md).
Wire `AvatarCharacterStore` into `BitzAppDelegate`, `BitzMenuBarContentView`, and `BitzMenuBarLabel`, add deterministic tests for all 5 characters, and verify `< 2%` idle CPU.

## Subtasks
- **T007**: Wire `AvatarCharacterStore`, `"Companion Character"` Menu Bar submenu, dynamic status item icon, and character-tailored pet reaction bubbles in `src/App/BitzApp.swift`.
- **T008**: Create `Tests/BitzTests/MascotCharacterTests.swift` and extend `Tests/BitzTests/MascotOverlayLayoutTests.swift` to verify all 5 characters.
- **T009**: Run `xcrun swift test` and `./Scripts/package_and_run.sh release` to verify `< 2%` desktop idle CPU.
