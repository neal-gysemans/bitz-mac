---
work_package_id: WP02
title: Companion Sound Metadata & Protocol Architecture
dependencies: []
requirement_refs:
- FR-001
- FR-006
- NFR-005
planning_base_branch: feat/issue-150-archetype-sound-design
merge_target_branch: feat/issue-150-archetype-sound-design
branch_strategy: Planning artifacts for this mission were generated on feat/issue-150-archetype-sound-design. During /spec-kitty.implement this WP may branch from a dependency-specific base, but completed changes must merge back into feat/issue-150-archetype-sound-design unless the human explicitly redirects the landing branch.
subtasks:
- T005
- T006
- T007
- T008
phase: Phase 2 - Domain Models
history:
- timestamp: '2026-11-12T00:00:00Z'
  agent: system
  action: Prompt generated via plan
authoritative_surface: src/
create_intent: []
execution_mode: code_change
owned_files:
- src/Models/MascotCharacterModels.swift
- src/Services/CyberAudioPlaying.swift
tags: []
tracker_refs: []
---

# Work Package Prompt: WP02 – Companion Sound Metadata & Protocol Architecture

## Objectives
Extend `MascotCharacter` with reaction sound metadata (`reactionSoundDisplayName`, `reactionSoundFileName`), update `CyberAudioPlaying` protocol and `SpyCyberAudioPlayer` with `playReactionSound(for:)`, and test all mappings.

## Files to Create / Modify
- `src/Models/MascotCharacterModels.swift`
- `src/Services/CyberAudioPlaying.swift`
- `Tests/BitzTests/MascotCharacterTests.swift`
