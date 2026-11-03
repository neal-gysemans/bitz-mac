---
work_package_id: WP01
title: Agent Failure Event (.failed) & Monitor State
dependencies: []
requirement_refs:
- FR-001
- FR-002
- NFR-004
planning_base_branch: feat/issue-19-agent-wake-up-alert
merge_target_branch: feat/issue-19-agent-wake-up-alert
branch_strategy: Planning artifacts for this mission were generated on feat/issue-19-agent-wake-up-alert. During /spec-kitty.implement this WP may branch from a dependency-specific base, but completed changes must merge back into feat/issue-19-agent-wake-up-alert unless the human explicitly redirects the landing branch.
subtasks:
- T001
- T002
- T003
- T004
phase: Phase 1 - Failure Event
agent: implement-command
shell_pid: 53629
shell_pid_created_at: '1793610951.319796'
history: []
authoritative_surface: src/Models/
create_intent:
- Tests/BitzTests/AgentEventFailedTests.swift
execution_mode: code_change
owned_files:
- src/Models/AgentModels.swift
- src/Services/AgentMonitorService.swift
- src/Services/AgentHookInstaller.swift
- src/Views/SpeechBubbleView.swift
- Tests/BitzTests/AgentEventFailedTests.swift
tags: []
task_type: implement
tracker_refs:
- '#19'
---

# Work Package Prompt: WP01 – Agent Failure Event (.failed) & Monitor State

## Objectives & Success Criteria
Satisfies: FR-001, FR-002, NFR-004 (see spec.md, refs #19).

## Subtasks
- **T001**: Add `case failed` to `AgentEventKind` and extend `MetadataKey` in `src/Models/AgentModels.swift`.
- **T002**: Update `AgentMonitorService.handleEvent(_:)` to process `.failed`: remove agent from `activeAgents`, clear pending turn, present crimson popup (`"❌ <Name> failed: <message>"`), and auto-dismiss after 6.0 seconds.
- **T003**: Update `SpeechBubbleView.agentPopupColors(for:)` to render `.failed` with crimson background (`Color(red: 0.65, green: 0.08, blue: 0.12).opacity(0.96)`) and red stroke (`Color.red`).
- **T004**: Update `AgentHookInstaller.swift` and `DropboxAgentAdapter.swift` to handle `.failed` events cleanly.
- **T005**: Write unit tests in `Tests/BitzTests/AgentEventFailedTests.swift` validating `.failed` event decoding, monitor service state transitions, and bubble styling.
