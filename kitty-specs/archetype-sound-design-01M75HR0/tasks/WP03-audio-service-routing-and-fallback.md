---
work_package_id: WP03
title: Dynamic Companion Sound Routing & Audio Service
dependencies:
- WP01
- WP02
requirement_refs:
- FR-001
- FR-002
- FR-003
- NFR-001
- NFR-002
- NFR-004
- NFR-005
- C-001
planning_base_branch: feat/issue-150-archetype-sound-design
merge_target_branch: feat/issue-150-archetype-sound-design
branch_strategy: Planning artifacts for this mission were generated on feat/issue-150-archetype-sound-design. During /spec-kitty.implement this WP may branch from a dependency-specific base, but completed changes must merge back into feat/issue-150-archetype-sound-design unless the human explicitly redirects the landing branch.
subtasks:
- T009
- T010
- T011
- T012
- T013
- T014
phase: Phase 3 - Audio Service
history:
- timestamp: '2026-11-12T00:00:00Z'
  agent: system
  action: Prompt generated via plan
authoritative_surface: src/
create_intent: []
execution_mode: code_change
owned_files:
- src/App/BitzApp.swift
- src/Services/CyberAudioService.swift
tags: []
tracker_refs: []
---

# Work Package Prompt: WP03 – Dynamic Companion Sound Routing & Audio Service

## Objectives
Preload companion reaction audio buffers in `CyberAudioService`, wire dynamic character tracking from `AvatarCharacterStore`, implement fallback to `purr_loop.wav` (FR-003), implement `playReactionSound(for:)`, and wire observation in `BitzApp.swift`.

## Files to Create / Modify
- `src/Services/CyberAudioService.swift`
- `src/App/BitzApp.swift`
- `Tests/BitzTests/CyberAudioServiceTests.swift`
