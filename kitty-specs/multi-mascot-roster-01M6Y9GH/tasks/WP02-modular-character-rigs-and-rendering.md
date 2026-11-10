---
work_package_id: WP02
title: Modular Character Rigs & CoreAnimation Rendering
dependencies:
- WP01
requirement_refs:
- FR-003
- FR-006
- NFR-001
- NFR-002
- C-001
- C-002
planning_base_branch: feat/issue-30-multi-mascot-roster
merge_target_branch: feat/issue-30-multi-mascot-roster
branch_strategy: Planning artifacts for this mission were generated on feat/issue-30-multi-mascot-roster. During /spec-kitty.implement this WP may branch from a dependency-specific base, but completed changes must merge back into feat/issue-30-multi-mascot-roster unless the human explicitly redirects the landing branch.
base_branch: kitty/mission-multi-mascot-roster-01M6Y9GH
base_commit: 02b9b9b285dbb56098d8dec8a2a37130c392fa7e
created_at: '2026-11-08T19:24:51.475880+00:00'
subtasks:
- T003
- T004
phase: Phase 2 - Character Rigs
history: []
authoritative_surface: src/Views/
create_intent: []
execution_mode: code_change
owned_files:
- src/Views/BitzCharacterView.swift
- src/Views/MascotOverlayView.swift
tags: []
task_type: implement
tracker_refs: []
---

# Work Package Prompt: WP02 – Modular Character Rigs & CoreAnimation Rendering

## Objectives & Success Criteria
Satisfies: FR-003, FR-006, NFR-001, NFR-002, C-001, C-002 (see spec.md).
Implement deterministic SwiftUI and CoreAnimation-offloaded rigs for all 5 `MascotCharacter` companions in `BitzCharacterView`, `LiveBitzCharacterView`, `AnimatedBitzCharacterView`, and `MascotOverlayView`.

## Subtasks
- **T003**: Update `src/Views/BitzCharacterView.swift` to support all 5 `MascotCharacter` rigs with custom head/ear/antenna geometry, torso emblems, tail/thruster animations, custom palettes, petting visors, and accurate `earOverflow(for:isLoafPosture:)`.
- **T004**: Update `src/Views/MascotOverlayView.swift` to observe `AvatarCharacterStore` and pass the active character to `LiveBitzCharacterView` and `earOverflow`.
