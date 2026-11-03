---
work_package_id: WP04
title: Safe Hook Approval & AgentApprovalHUDView Integration
dependencies:
- WP01
- WP03
requirement_refs:
- FR-006
- FR-007
- FR-008
- NFR-002
- NFR-004
- C-003
planning_base_branch: feat/issue-19-agent-wake-up-alert
merge_target_branch: feat/issue-19-agent-wake-up-alert
branch_strategy: Planning artifacts for this mission were generated on feat/issue-19-agent-wake-up-alert. During /spec-kitty.implement this WP may branch from a dependency-specific base, but completed changes must merge back into feat/issue-19-agent-wake-up-alert unless the human explicitly redirects the landing branch.
base_branch: kitty/mission-agent-wake-up-alert-01M6GVWW
base_commit: 68d8510296f33d47fe1e5f407979142cffaf9882
created_at: '2026-11-03T14:57:34.467733+00:00'
subtasks:
- T015
- T016
- T017
- T018
- T019
phase: Phase 4 - Hook Approval
history: []
authoritative_surface: src/Models/
create_intent:
- src/Models/AgentApprovalStore.swift
- src/Views/AgentApprovalHUDView.swift
- Tests/BitzTests/AgentApprovalStoreTests.swift
execution_mode: code_change
owned_files:
- src/Models/AgentApprovalStore.swift
- src/Views/AgentApprovalHUDView.swift
- src/App/BitzApp.swift
- Tests/BitzTests/AgentApprovalStoreTests.swift
tags: []
task_type: implement
tracker_refs:
- '#19'
---

# Work Package Prompt: WP04 – Safe Hook Approval & AgentApprovalHUDView Integration

## Objectives & Success Criteria
Satisfies: FR-006, FR-007, FR-008, NFR-002, NFR-004, C-003 (see spec.md, refs #19).

## Subtasks
- **T015**: Implement `@MainActor public final class AgentApprovalStore: ObservableObject` in `src/Models/AgentApprovalStore.swift` with TTL expiry (default 300s) and single-use decision writing.
- **T016**: Connect `AgentApprovalStore` to `AgentMonitorService` registering incoming approval requests from `AgentEvent.metadata` and dismissing popups on approval.
- **T017**: Implement `AgentApprovalHUDView` in `src/Views/AgentApprovalHUDView.swift` displaying `"APPROVE"`, `"JUMP"`, and `"DIFF"` HUD buttons with tool/command summary when `approvalRequestID` is present; gate `"APPROVE"` visibility so agents without hook channels only see `"JUMP"` and `"DIFF"`.
- **T018**: Wire `approvalStore` into `BitzApp.swift` / `BitzAppDelegate` and verify window click-through and non-activating invariants.
- **T019**: Write comprehensive unit tests in `Tests/BitzTests/AgentApprovalStoreTests.swift` verifying token registration, single-use invalidation, expiry rejection, decision dispatch, and zero keystroke injection.
