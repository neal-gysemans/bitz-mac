---
work_package_id: WP02
title: Sound Assets & Low-Latency Audio Engine
dependencies:
- WP01
requirement_refs:
- FR-002
- FR-003
- FR-005
- FR-010
- NFR-001
- NFR-002
- NFR-004
- C-003
planning_base_branch: feat/issue-21-cyber-audio
merge_target_branch: feat/issue-21-cyber-audio
branch_strategy: Planning artifacts for this mission were generated on feat/issue-21-cyber-audio. During /spec-kitty.implement this WP may branch from a dependency-specific base, but completed changes must merge back into feat/issue-21-cyber-audio unless the human explicitly redirects the landing branch.
subtasks:
- T005
- T006
- T007
- T008
phase: Phase 2 - Engine & Assets
history: []
authoritative_surface: src/Services/
create_intent:
- Resources/Sounds/LICENSE.md
- Resources/Sounds/purr_loop.wav
- Resources/Sounds/burnout_glitch.wav
- Resources/Sounds/overheat_alarm.wav
- Resources/Sounds/agent_chime.wav
- Resources/Sounds/all_done_fanfare.wav
- src/Services/CyberAudioService.swift
- Tests/BitzTests/CyberAudioServiceTests.swift
execution_mode: code_change
owned_files:
- Package.swift
- Scripts/package_and_run.sh
- Resources/Sounds/LICENSE.md
- Resources/Sounds/purr_loop.wav
- Resources/Sounds/burnout_glitch.wav
- Resources/Sounds/overheat_alarm.wav
- Resources/Sounds/agent_chime.wav
- Resources/Sounds/all_done_fanfare.wav
- src/Services/CyberAudioService.swift
- Tests/BitzTests/CyberAudioServiceTests.swift
tags: []
task_type: implement
tracker_refs: []
---

# Work Package Prompt: WP02 – Sound Assets & Low-Latency Audio Engine

## Objectives & Success Criteria
Satisfies: FR-002, FR-003, FR-005, FR-010, NFR-001, NFR-002, NFR-004, C-003 (see spec.md).

## Subtasks
- **T005**: Create license-clean sound assets under `Resources/Sounds/` (`purr_loop.wav`, `burnout_glitch.wav`, `overheat_alarm.wav`, `agent_chime.wav`, `all_done_fanfare.wav`) and license document `Resources/Sounds/LICENSE.md`.
- **T006**: Configure `Package.swift` resource processing and `Scripts/package_and_run.sh` bundle copying for sound assets.
- **T007**: Implement `@MainActor public final class CyberAudioService: ObservableObject, CyberAudioPlaying` in `src/Services/CyberAudioService.swift` with preloaded `AVAudioPCMBuffer`s, looping purr with fade in/out gain ramp, and auto-pause when idle.
- **T008**: Write unit tests in `Tests/BitzTests/CyberAudioServiceTests.swift` covering buffer decoding, engine state management, and mock audio fallback.

## Notes & Risks
Assets must be small (< 300 KB total) and license-clean CC0 / generated. Idle CPU must be 0% when no sound is playing.
