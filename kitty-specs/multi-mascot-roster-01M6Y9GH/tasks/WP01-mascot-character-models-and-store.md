---
work_package_id: WP01
title: Mascot Character Models & Persistence Store
dependencies: []
requirement_refs:
- FR-001
- FR-002
- FR-006
- NFR-003
- C-001
- C-002
planning_base_branch: feat/issue-30-multi-mascot-roster
merge_target_branch: feat/issue-30-multi-mascot-roster
branch_strategy: Planning artifacts for this mission were generated on feat/issue-30-multi-mascot-roster. During /spec-kitty.implement this WP may branch from a dependency-specific base, but completed changes must merge back into feat/issue-30-multi-mascot-roster unless the human explicitly redirects the landing branch.
base_branch: kitty/mission-multi-mascot-roster-01M6Y9GH
base_commit: 02b9b9b285dbb56098d8dec8a2a37130c392fa7e
created_at: '2026-11-08T19:21:56.072957+00:00'
subtasks:
- T001
- T002
phase: Phase 1 - Models & Store
history: []
authoritative_surface: src/Models/
create_intent:
- src/Models/MascotCharacterModels.swift
- src/Models/AvatarCharacterStore.swift
execution_mode: code_change
owned_files:
- src/Models/MascotCharacterModels.swift
- src/Models/AvatarCharacterStore.swift
tags: []
task_type: implement
tracker_refs: []
---

# Work Package Prompt: WP01 – Mascot Character Models & Persistence Store

## Objectives & Success Criteria
Satisfies: FR-001, FR-002, FR-006, NFR-003, C-001, C-002 (see spec.md).
Define `MascotCharacter` (`cyberCat`, `cyberDog`, `hoverDrone`, `retroMech`, `cyberBunny`) and `AvatarCharacterStore` persisting `"avatarSelectedCharacter"` in `UserDefaults` with `BitzFeature.multiMascot` Pro licensing support.

## Subtasks
- **T001**: Create `src/Models/MascotCharacterModels.swift` defining `MascotCharacter` with metadata (`name`, `archetype`, `title`, `bio`, `menuBarSymbolName`, `isPro`, `petReactionBubble`, `petVisorText`).
- **T002**: Create `src/Models/AvatarCharacterStore.swift` implementing `@MainActor public final class AvatarCharacterStore: ObservableObject`.
