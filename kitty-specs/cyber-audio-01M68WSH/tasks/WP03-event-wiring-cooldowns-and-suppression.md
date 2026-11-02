---
work_package_id: WP03
title: Event Wiring, Cooldowns, State Transitions & Context Suppression
dependencies:
- WP01
- WP02
requirement_refs:
- FR-004
- FR-006
- FR-007
- FR-009
planning_base_branch: feat/issue-21-cyber-audio
merge_target_branch: feat/issue-21-cyber-audio
branch_strategy: Planning artifacts for this mission were generated on feat/issue-21-cyber-audio. During /spec-kitty.implement this WP may branch from a dependency-specific base, but completed changes must merge back into feat/issue-21-cyber-audio unless the human explicitly redirects the landing branch.
subtasks:
- T009
- T010
- T011
- T012
phase: Phase 3 - Wiring & Suppression
history: []
authoritative_surface: src/Services/
create_intent:
- src/Services/AudioEnvironmentDetector.swift
- src/Services/CyberAudioService.swift
- Tests/BitzTests/AudioEnvironmentDetectorTests.swift
- Tests/BitzTests/CyberAudioIntegrationTests.swift
execution_mode: code_change
owned_files:
- src/Services/AudioEnvironmentDetector.swift
- src/Services/CyberAudioService.swift
- src/Services/AgentMonitorService.swift
- src/Services/WellnessPointEngine.swift
- Tests/BitzTests/AudioEnvironmentDetectorTests.swift
- Tests/BitzTests/CyberAudioIntegrationTests.swift
tags: []
task_type: implement
tracker_refs: []
---

# Work Package Prompt: WP03 – Event Wiring, Cooldowns, State Transitions & Context Suppression

## Objectives & Success Criteria
Satisfies: FR-004, FR-006, FR-007, FR-009, SC-001, SC-003 (see spec.md).

## Subtasks
- **T009**: Implement event cooldown and rate limiting logic (≥ 10s per agent, ≥ 60s all-done fanfare, ≥ 1.5s global rate limit, transition-only state sounds) with an injectable clock.
- **T010**: Implement `AudioEnvironmentDetector` in `src/Services/AudioEnvironmentDetector.swift` for checking system mute, active microphone/screen-sharing, and DND suppression.
- **T011**: Wire `CyberAudioService` to observe `WellnessPointEngine` state changes and `AgentMonitorService` agent lifecycle events.
- **T012**: Unit tests in `Tests/BitzTests/CyberAudioServiceTests.swift` and `Tests/BitzTests/AudioEnvironmentDetectorTests.swift` for state transition sounds, cooldown enforcement, and suppression behavior.

## Notes & Risks
State sounds must trigger only on transitions, never repeatedly on evaluation ticks. Cooldowns prevent audio spam.
