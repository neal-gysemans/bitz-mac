---
work_package_id: WP07
title: Context Gauge on the AI Agents Metric
dependencies:
- WP02
requirement_refs:
- FR-006
planning_base_branch: feat/issue-38-agent-gauges-warnings
merge_target_branch: feat/issue-38-agent-gauges-warnings
branch_strategy: Planning artifacts for this mission were generated on feat/issue-38-agent-gauges-warnings. During /spec-kitty.implement this WP may branch from a dependency-specific base, but completed changes must merge back into feat/issue-38-agent-gauges-warnings unless the human explicitly redirects the landing branch.
subtasks:
- T032
- T033
- T034
phase: Phase 3 - Presentation
history:
- !!omap
  - at: '2026-10-30T13:37:15Z'
  - actor: system
  - action: Prompt generated via /spec-kitty.tasks
agent_profile: implementer-ivan
authoritative_surface: src/Models/TelemetryModels.swift
create_intent: []
execution_mode: code_change
model: ''
owned_files:
- src/Models/TelemetryModels.swift
- src/Services/TelemetryDashboardService.swift
- Tests/BitzTests/TelemetryDashboardServiceTests.swift
role: implementer
tags: []
task_type: implement
tracker_refs: []
---

# Work Package Prompt: WP07 – Context Gauge on the AI Agents Metric

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

FR-006: the existing AI Agents telemetry metric shows the most recently active agent's context as tokens and percent (`Claude ctx 148k · 74%`) in its existing placements — HUD badge, speech-bubble carousel and menu bar title — refreshed within one telemetry interval. Done when snapshot rendering includes the reading only when present and that agent is active, output is byte-identical otherwise, and tests prove all three placements.

Definition of Done also includes:
- No new compiler warnings, measured with a clean build (`xcrun swift build --scratch-path "$(mktemp -d)" 2>&1 | grep 'warning:' | sort -u`): the only allowed lines are the 3 pre-existing Swift 6 warnings at `src/Views/MascotOverlayView.swift:142` (from #61), which WP06 removes. Incremental builds hide warnings, so don't use them for this check (charter quality gate; SwiftLint is not configured in this repo).

## Context & Constraints

- `AgentTelemetry` lives in `src/Models/TelemetryModels.swift:142-166`; it is rendered by `TelemetrySnapshot.menuBarTitle` (`"\(agents.activeCount) Agts"`, ~line 379), the HUD items (`agents.compactBadge`, ~line 422) and carousel (`"🤖 \(agents.formattedSummary)"`, ~line 456). All three are gated on `enabledMetrics.contains(.agents) && agents.activeCount > 0` — keep that gate (no stale gauge for inactive agents).
- `TelemetryDashboardService` builds `AgentTelemetry` from `agentMonitor` (~lines 521-531).
- `AgentContextReading.compactText` / `.percent` come from WP01; `agentMonitor.latestContext` from WP02.

## Branch Strategy

- **Planning base branch**: `feat/issue-38-agent-gauges-warnings`
- **Merge target branch**: `feat/issue-38-agent-gauges-warnings`
- Execution worktrees are allocated per computed lane from `lanes.json`.
- Implementation command: `spec-kitty agent action implement WP07 --agent claude`

## Subtasks & Detailed Guidance

### Subtask T032 – `AgentTelemetry` context rendering

- **Steps**:
  1. Add `public let context: AgentContextReading?` and init parameter `context: AgentContextReading? = nil` (last). `.empty` unchanged.
  2. `formattedSummary`: when `activeCount > 0` and `context != nil` append `" · \(context.compactText)"` → e.g. `2 active (Claude, Antigravity) · Claude ctx 148k · 74%`.
  3. `compactBadge`: `"\(activeCount) AGTS"` + `" · \(context.percent)%"` when present.
  4. `TelemetrySnapshot.menuBarTitle`: `"\(agents.activeCount) Agts"` + `" \(context.percent)%"` when present.
- **Notes**: Keep `Equatable`. No change when `context == nil` (existing tests must stay byte-identical).

### Subtask T033 – Dashboard service passes the reading

- In the sample tick, after computing `activeAgentIDs`:
  ```swift
  let context = agentMonitor?.latestContext.flatMap { activeAgentIDs.contains($0.agentID) ? $0 : nil }
  ```
  and pass `context:` into `AgentTelemetry(...)`. Also extend the `performSampleTickSync(agents:...)` test helper path only if needed (it already accepts a full `AgentTelemetry`).
- **Notes**: Refresh cadence stays the telemetry interval (FR-006 "within one telemetry interval").

### Subtask T034 – Tests

- **File**: `Tests/BitzTests/TelemetryDashboardServiceTests.swift`
- Cases:
  1. `testAgentsMetricShowsContextInBadgeSummaryAndTitle` — `AgentTelemetry(activeCount: 1, agentNames: ["Claude"], context: AgentContextReading(agentID: "claude", agentName: "Claude", tokens: 148_000, windowTokens: 200_000))` → badge `"1 AGTS · 74%"`, carousel contains `"Claude ctx 148k · 74%"`, title contains `"1 Agts 74%"`.
  2. `testAgentsMetricUnchangedWithoutContext` — existing strings exactly.
  3. `testDashboardIncludesContextOnlyForActiveAgent` — monitor with isolated defaults (`AgentMonitorService(adapters: [], userDefaults: defaults)`): `usage` for `claude` without `working` → no context; after `working` → context present. Use the service's sync tick helper.

## Test Strategy

- Run `xcrun swift test --filter TelemetryDashboardServiceTests`, then the full suite.

## Risks & Mitigations

- **Menu bar title width**: adds at most 4 characters (` 74%`).

## Review Guidance

- Confirm gating on `activeCount > 0` is unchanged.
- Confirm no output change when `context == nil`.

## Activity Log

- 2026-10-30T13:37:15Z – system – Prompt created.
