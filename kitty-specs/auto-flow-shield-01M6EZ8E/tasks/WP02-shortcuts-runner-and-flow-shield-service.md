---
work_package_id: WP02
title: Shortcuts Runner & FlowShieldService Coordinator
dependencies:
- WP01
requirement_refs:
- FR-002
- FR-003
- FR-004
- FR-005
- NFR-001
- NFR-002
- C-003
planning_base_branch: feat/issue-22-auto-flow-shield
merge_target_branch: feat/issue-22-auto-flow-shield
branch_strategy: Planning artifacts for this mission were generated on feat/issue-22-auto-flow-shield. During /spec-kitty.implement this WP may branch from a dependency-specific base, but completed changes must merge back into feat/issue-22-auto-flow-shield unless the human explicitly redirects the landing branch.
base_branch: kitty/mission-auto-flow-shield-01M6EZ8E
base_commit: 5833ec24b19cfb51ef6ab3d0527e5ad7f6cffa63
created_at: '2026-11-02T20:36:17.121218+00:00'
subtasks:
- T004
- T005
- T006
phase: Phase 2 - Service & Runner
history: []
authoritative_surface: src/Services/
create_intent:
- src/Services/FlowShieldService.swift
- Tests/BitzTests/FlowShieldServiceTests.swift
execution_mode: code_change
owned_files:
- src/Services/FlowShieldService.swift
- Tests/BitzTests/FlowShieldServiceTests.swift
tags: []
task_type: implement
tracker_refs: []
---

# Work Package Prompt: WP02 – Shortcuts Runner & FlowShieldService Coordinator

## Objectives & Success Criteria
Satisfies: FR-002, FR-003, FR-004, FR-005, NFR-001, NFR-002, C-003 (see spec.md, refs #22).

## Subtasks
- **T004**: Implement `ShortcutsRunning` protocol, `ProcessShortcutsRunner` (`/usr/bin/shortcuts run <name>` off `@MainActor`, zero shell interpolation, trimmed name validation, timeout guard), and `SpyShortcutsRunner` in `src/Services/FlowShieldService.swift`.
- **T005**: Implement `@MainActor public final class FlowShieldService: ObservableObject` in `src/Services/FlowShieldService.swift` observing `WellnessPointEngine` for once-per-streak Start Focus, break-completion Stop Focus, Break Shield override, master opt-out handling, and Settings test actions.
- **T006**: Write comprehensive unit tests in `Tests/BitzTests/FlowShieldServiceTests.swift` verifying default-off, once-per-streak execution across repeated 5s ticks, break completion deactivation, Break Shield override suppression, master toggle disable while active, and error handling.

## Notes & Risks
Zero additional polling timers (`< 2%` CPU). Serialize async Shortcut execution so rapid Start -> Stop never races out of order, and mark failed streaks as attempted to prevent 5-second retry storms.
