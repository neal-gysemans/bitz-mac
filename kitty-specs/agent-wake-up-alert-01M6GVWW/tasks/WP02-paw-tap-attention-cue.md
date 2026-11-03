---
work_package_id: WP02
title: Paw-Tap Attention Cue on .needsApproval (CoreAnimation Offloaded)
dependencies: []
requirement_refs:
- FR-003
- NFR-001
- NFR-004
- C-002
planning_base_branch: feat/issue-19-agent-wake-up-alert
merge_target_branch: feat/issue-19-agent-wake-up-alert
branch_strategy: Planning artifacts for this mission were generated on feat/issue-19-agent-wake-up-alert. During /spec-kitty.implement this WP may branch from a dependency-specific base, but completed changes must merge back into feat/issue-19-agent-wake-up-alert unless the human explicitly redirects the landing branch.
base_branch: kitty/mission-agent-wake-up-alert-01M6GVWW
base_commit: 68d8510296f33d47fe1e5f407979142cffaf9882
created_at: '2026-11-03T14:35:04.413109+00:00'
subtasks:
- T006
- T007
- T008
- T009
phase: Phase 2 - Attention Cue
history: []
authoritative_surface: src/Views/
create_intent:
- Tests/BitzTests/PawTapAttentionTests.swift
execution_mode: code_change
owned_files:
- src/Views/BitzCharacterView.swift
- src/Views/MascotOverlayView.swift
- Tests/BitzTests/PawTapAttentionTests.swift
tags: []
task_type: implement
tracker_refs:
- '#19'
---

# Work Package Prompt: WP02 – Paw-Tap Attention Cue on .needsApproval (CoreAnimation Offloaded)

## Objectives & Success Criteria
Satisfies: FR-003, NFR-001, NFR-004, C-002 (see spec.md, refs #19).

## Subtasks
- **T006**: Add `.pawTap(amplitude: Double, halfPeriod: Double)` to `CALayerMotionBridge.Kind` in `src/Views/BitzCharacterView.swift` creating rapid vertical translation on front paw layers via `CABasicAnimation`.
- **T007**: Wire `isAttentionCueActive` state in `LiveBitzCharacterView` and `MascotOverlayView` observing `AgentMonitorService.activePopup?.kind == .needsApproval`.
- **T008**: Verify paw-tap stops immediately when approval popup is cleared or dismissed and verify layout invariant tests pass.
- **T009**: Write unit tests in `Tests/BitzTests/PawTapAttentionTests.swift` validating attention cue state propagation and motion bridge configuration.
