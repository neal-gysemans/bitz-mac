---
work_package_id: WP08
title: Agent Signals Settings Card
dependencies:
- WP02
requirement_refs:
- FR-012
- FR-013
planning_base_branch: feat/issue-38-agent-gauges-warnings
merge_target_branch: feat/issue-38-agent-gauges-warnings
branch_strategy: Planning artifacts for this mission were generated on feat/issue-38-agent-gauges-warnings. During /spec-kitty.implement this WP may branch from a dependency-specific base, but completed changes must merge back into feat/issue-38-agent-gauges-warnings unless the human explicitly redirects the landing branch.
subtasks:
- T035
- T036
- T037
- T038
phase: Phase 3 - Presentation
history:
- !!omap
  - at: '2026-10-30T13:37:15Z'
  - actor: system
  - action: Prompt generated via /spec-kitty.tasks
agent_profile: implementer-ivan
authoritative_surface: src/Views/Settings/
create_intent: []
execution_mode: code_change
model: ''
owned_files:
- src/Views/Settings/AgentsSettingsTabView.swift
- Tests/BitzTests/SettingsViewsTests.swift
role: implementer
tags: []
task_type: implement
tracker_refs: []
---

# Work Package Prompt: WP08 – Agent Signals Settings Card

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

FR-012 / SC-005: Settings → AI Agents gets an **Agent Signals & Warnings** card where each signal is one click to toggle, and thresholds/windows are tunable. Done when every control binds to `agentMonitor.signalSettings`, changes apply immediately and persist (WP02 handles persistence + clamping), and view tests prove the bindings.

Definition of Done also includes:
- No new compiler warnings, measured with a clean build (`xcrun swift build --scratch-path "$(mktemp -d)" 2>&1 | grep 'warning:' | sort -u`): the only allowed lines are the 3 pre-existing Swift 6 warnings at `src/Views/MascotOverlayView.swift:142` (from #61), which WP06 removes. Incremental builds hide warnings, so don't use them for this check (charter quality gate; SwiftLint is not configured in this repo).

## Context & Constraints

- File: `src/Views/Settings/AgentsSettingsTabView.swift`. Reuse its private `settingsCard(title:systemImage:content:)` helper and the visual language of the existing cards (caption `info.circle` hints).
- Place the new card **after** "Agent Notifications & Alerts" and before "Monitored AI Agents".
- Bind through `$agentMonitor.signalSettings.<field>`; WP02's `didSet` clamps and persists — the view never writes `UserDefaults`.
- FR-013 note to show as a caption: "Turning off Agent Speech Bubbles hides bubbles only; the amber visor and context gauge keep working."

## Branch Strategy

- **Planning base branch**: `feat/issue-38-agent-gauges-warnings`
- **Merge target branch**: `feat/issue-38-agent-gauges-warnings`
- Execution worktrees are allocated per computed lane from `lanes.json`.
- Implementation command: `spec-kitty agent action implement WP08 --agent claude`

## Subtasks & Detailed Guidance

### Subtask T035 – Per-signal toggles

- Card: `settingsCard(title: "Agent Signals & Warnings", systemImage: "exclamationmark.triangle.fill")`.
- Four `Toggle`s:
  - "Almost Done Heads-Up" → `almostDoneEnabled`
  - "Context Window Warnings" → `contextWarningEnabled`
  - "Tool Loop Warnings (4 identical calls)" → `loopWarningEnabled`
  - "Stall Warnings" → `stallWarningEnabled`
- Caption hint (FR-013 note above).

### Subtask T036 – Threshold + stall timeout

- `Stepper("Warn at \(threshold)% context", value: $agentMonitor.signalSettings.contextThresholdPercent, in: 50...99, step: 5)` — disabled when context warnings are off.
- `Stepper("Stall after \(minutes) min without output", value: $agentMonitor.signalSettings.stallTimeoutMinutes, in: 1...30)` — disabled when stall warnings are off.

### Subtask T037 – Per-agent context window

- For agents `claude` ("Claude Code") and `antigravity` ("Antigravity"), one row each:
  - `Picker` with options `200k`, `1M`, `Custom`; selection derives from the stored value (`200_000`, `1_000_000`, else Custom).
  - When Custom: `TextField("Tokens", value: binding, format: .number)` with `.frame(width: 110)`; the binding ignores values `<= 0`.
  - Binding helper:
    ```swift
    private func windowBinding(_ id: String) -> Binding<Int> {
        Binding(get: { agentMonitor.signalSettings.contextWindow(for: id) },
                set: { if $0 > 0 { agentMonitor.signalSettings.contextWindowTokens[id] = $0 } })
    }
    ```
- Caption: "Bitz can't read the model's window size from session logs. Pick 1M if you use a 1M-context model."

### Subtask T038 – Tests

- **File**: `Tests/BitzTests/SettingsViewsTests.swift`
- Add `testAgentSignalsCardBindsAndPersists`:
  1. Isolated suite; `AgentMonitorService(adapters: [], userDefaults: defaults)`; `_ = AgentsSettingsTabView(agentMonitor: monitor).body`.
  2. Mutate through the same key paths the view binds (`monitor.signalSettings.loopWarningEnabled = false`, threshold `95`, window `1_000_000`).
  3. New `AgentMonitorService(adapters: [], userDefaults: defaults)` reads identical `signalSettings`.
  4. Threshold `120` → stored `99` (clamp).
- Keep the existing `testSettingsRootViewAndTabsCanBeInstantiated` passing.

## Test Strategy

- Run `xcrun swift test --filter SettingsViewsTests`, then the full suite.

## Risks & Mitigations

- **Custom field writes 0 while typing**: binding ignores `<= 0`.
- **Card height** in the Settings window: the AI Agents tab is scrollable; verify visually.

## Review Guidance

- One click per signal toggle (SC-005).
- No direct `UserDefaults` access in the view.

## Activity Log

- 2026-10-30T13:37:15Z – system – Prompt created.
