---
work_package_id: WP03
title: Quick-Action Activators & Diff Viewer
dependencies: []
requirement_refs:
- FR-004
- FR-005
- FR-008
- NFR-003
- C-002
planning_base_branch: feat/issue-19-agent-wake-up-alert
merge_target_branch: feat/issue-19-agent-wake-up-alert
branch_strategy: Planning artifacts for this mission were generated on feat/issue-19-agent-wake-up-alert. During /spec-kitty.implement this WP may branch from a dependency-specific base, but completed changes must merge back into feat/issue-19-agent-wake-up-alert unless the human explicitly redirects the landing branch.
base_branch: kitty/mission-agent-wake-up-alert-01M6GVWW
base_commit: 68d8510296f33d47fe1e5f407979142cffaf9882
created_at: '2026-11-03T14:46:09.362697+00:00'
subtasks:
- T010
- T011
- T012
- T013
phase: Phase 3 - Quick Actions
history: []
authoritative_surface: src/Services/
create_intent:
- src/Services/AppActivator.swift
- src/Services/DiffViewer.swift
- Tests/BitzTests/QuickActionHUDTests.swift
execution_mode: code_change
owned_files:
- src/Services/AppActivator.swift
- src/Services/DiffViewer.swift
- src/App/Window/SpeechBubblePanel.swift
- Tests/BitzTests/QuickActionHUDTests.swift
tags: []
task_type: implement
tracker_refs:
- '#19'
---

# Work Package Prompt: WP03 – Quick-Action Activators & Diff Viewer

## Objectives & Success Criteria
Satisfies: FR-004, FR-005, FR-008, NFR-003, C-002 (see spec.md, refs #19).

## Subtasks
- **T010**: Implement `AppActivating` protocol and `WorkspaceAppActivator` in `src/Services/AppActivator.swift` activating owning terminal / IDE by PID (`NSRunningApplication`) or bundle identifier without stealing keyboard focus.
- **T011**: Implement `DiffViewing` protocol and `SystemDiffViewer` in `src/Services/DiffViewer.swift` executing git diff for the agent's working directory off the main thread.
- **T012**: Update `SpeechBubblePanel.swift` and `SpeechBubbleContent.isInteractive` to support quick action click handling.
- **T013**: Write unit tests in `Tests/BitzTests/QuickActionHUDTests.swift` verifying mock app activation, mock diff launching, and bubble click routing.
