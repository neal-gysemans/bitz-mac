---
work_package_id: WP09
title: Living Docs & Release Verification
dependencies:
- WP01
- WP02
- WP03
- WP04
- WP05
- WP06
- WP07
- WP08
requirement_refs:
- C-004
- C-005
- NFR-001
- NFR-002
- NFR-003
planning_base_branch: feat/issue-38-agent-gauges-warnings
merge_target_branch: feat/issue-38-agent-gauges-warnings
branch_strategy: Planning artifacts for this mission were generated on feat/issue-38-agent-gauges-warnings. During /spec-kitty.implement this WP may branch from a dependency-specific base, but completed changes must merge back into feat/issue-38-agent-gauges-warnings unless the human explicitly redirects the landing branch.
subtasks:
- T039
- T040
- T041
- T042
- T043
phase: Phase 4 - Verification
history:
- !!omap
  - at: '2026-10-30T13:37:15Z'
  - actor: system
  - action: Prompt generated via /spec-kitty.tasks
agent_profile: implementer-ivan
authoritative_surface: docs/
create_intent: []
execution_mode: code_change
model: ''
owned_files:
- docs/ARCHITECTURE.md
- docs/STATE_MACHINE.md
- docs/ACCEPTANCE_CRITERIA.md
role: implementer
tags: []
task_type: implement
tracker_refs: []
---

# Work Package Prompt: WP09 – Living Docs & Release Verification

## ⚡ Do This First: Load Agent Profile

Use the `/ad-hoc-profile-load` skill to load the agent profile specified in the frontmatter, and behave according to its guidance before parsing the rest of this prompt.

- **Profile**: `implementer-ivan`
- **Role**: `implementer`
- **Agent/tool**: `claude`

If no profile is specified, run `spec-kitty agent profile list` and select the best match for this work package's `task_type` and `authoritative_surface`.

---

## ⚠️ IMPORTANT: Review Feedback

- **Has review feedback?**: Check the `review_ref` field in the event log or the Activity Log below.
- **You must address all feedback** before your work is complete.

---

## Objectives & Success Criteria

Charter DIR-005 requires the living docs to match the shipped behaviour; AGENTS.md §3 requires a green full suite and a local release run. Done when:
- `docs/ARCHITECTURE.md`, `docs/STATE_MACHINE.md`, `docs/ACCEPTANCE_CRITERIA.md` describe the new adapter, policy and visor override accurately (no invented numbers).
- A clean build (`xcrun swift build --scratch-path "$(mktemp -d)" 2>&1 | grep -c 'warning:'`) prints `0` on the merged result (charter quality gate; WP06 removed the 3 pre-existing warnings; SwiftLint is not configured in this repo).
- `xcrun swift test` passes with zero failures (output captured in the Activity Log: totals line).
- `./Scripts/package_and_run.sh release` launches; the `quickstart.md` walkthrough behaves as written; the timed latency step (quickstart §3) measures ≤ 5 s on every run (NFR-003); Activity Monitor readings recorded (CPU %, memory MB) over ~5 minutes with an active Claude Code session.

## Context & Constraints

- Only describe what WP01–WP08 actually shipped; read their final code, not this prompt's assumptions.
- C-004: docs must not claim cost, rate-limit or CPU alerts.
- Record measured values as measured, with the date; if a check could not be performed (e.g. no Antigravity session available), say so explicitly.

## Branch Strategy

- **Planning base branch**: `feat/issue-38-agent-gauges-warnings`
- **Merge target branch**: `feat/issue-38-agent-gauges-warnings`
- Execution worktrees are allocated per computed lane from `lanes.json`.
- Implementation command: `spec-kitty agent action implement WP09 --agent claude`

## Subtasks & Detailed Guidance

### Subtask T039 – `docs/ARCHITECTURE.md` [P]

- Layer 3 mermaid diagram: add `ClaudeAdapt["ClaudeCodeTranscriptAdapter (session log tail)"]` and edge `AgentMgr --> ClaudeAdapt`; mention `SessionLogTail` / `AgentSessionTracker` as shared helpers.
- Component table: extend "Agent Coordination" (policy: usage readings, context crossing, stall sweep, single warning slot with approval override, signal settings) and "Agent Adapters" (Claude Code adapter; Antigravity usage/loop).
- Mention the `source = process` tag on `ProcessAgentAdapter` events (app-presence `done` never clears warnings) and the engine's warning visor input.
- One sentence on privacy: session logs read locally, only token counts / tool names / fingerprints kept in memory.

### Subtask T040 – `docs/STATE_MACHINE.md` [P]

- New subsection "Agent Warning Visor": while an agent warning is unacknowledged, `WellnessPointEngine.setWarningVisor(active:)` makes `syncWithRive()` send `visorColor = 2.0` (Amber `#FFB000`) and the drawn visor shows the same colour; overheating red keeps priority; wellness state, points and thresholds are unchanged.

### Subtask T041 – `docs/ACCEPTANCE_CRITERIA.md` [P]

- Add a section for mission `agent-usage-gauges-warnings-01M666F5` (#38) with one row per FR-001…FR-014: requirement, source files, covering tests (real test names from the merged code), status.

### Subtask T042 – Full test suite

- `xcrun swift build --scratch-path "$(mktemp -d)" 2>&1 | grep 'warning:'` must print nothing (clean build; incremental builds hide warnings; charter gate); record the count in the Activity Log.
- `xcrun swift test 2>&1 | tail -30`; zero failures required. If anything fails, stop and report the failing test + output; do not mark done.

### Subtask T043 – Release run, quickstart, resources

- `./Scripts/package_and_run.sh release`.
- Walk `kitty-specs/agent-usage-gauges-warnings-01M666F5/quickstart.md` §1–§5; note each step pass/fail.
- §3 is the timed latency step (NFR-003): run it three times, record each measured latency in seconds; any run > 5 s is a failure to report.
- §6: Activity Monitor (or `top -l 6 -s 10 -pid <pid>`) CPU and memory for Bitz during an active Claude Code session; record numbers against the charter budget (< 2% CPU, < 70 MB).

## Risks & Mitigations

- **Budget miss**: if CPU or memory exceeds the budget, record it and raise it in review rather than tuning silently.

## Review Guidance

- Docs reflect code (spot-check two claims against source).
- Activity Log contains the test totals line and measured resource numbers.

## Activity Log

- 2026-10-30T13:37:15Z – system – Prompt created.
