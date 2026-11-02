---
work_package_id: WP05
title: Antigravity Usage & Loop Signals
dependencies:
- WP03
requirement_refs:
- FR-005
- FR-008
- FR-014
planning_base_branch: feat/issue-38-agent-gauges-warnings
merge_target_branch: feat/issue-38-agent-gauges-warnings
branch_strategy: Planning artifacts for this mission were generated on feat/issue-38-agent-gauges-warnings. During /spec-kitty.implement this WP may branch from a dependency-specific base, but completed changes must merge back into feat/issue-38-agent-gauges-warnings unless the human explicitly redirects the landing branch.
subtasks:
- T023
- T024
- T025
phase: Phase 2 - Adapters
history:
- !!omap
  - at: '2026-10-30T13:37:15Z'
  - actor: system
  - action: Prompt generated via /spec-kitty.tasks
agent_profile: implementer-ivan
authoritative_surface: src/Services/AntigravityTranscriptAdapter.swift
create_intent: []
execution_mode: code_change
model: ''
owned_files:
- src/Services/AntigravityTranscriptAdapter.swift
- Tests/BitzTests/AntigravityTranscriptAdapterTests.swift
role: implementer
tags: []
task_type: implement
tracker_refs: []
---

# Work Package Prompt: WP05 – Antigravity Usage & Loop Signals

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

Move `AntigravityTranscriptAdapter` onto WP03's `SessionLogTail` + `AgentSessionTracker` so it also reports context usage, pending tools and loop warnings (FR-005, FR-008), with a silent startup seed (FR-014). Existing behaviour stays: `working` on `USER_INPUT`, `needsApproval` on `ask_question` (unchanged lookup, see #63), `done` on a final `PLANNER_RESPONSE`. Done when the existing test passes (ignoring `usage`) and new fixtures pass.

Definition of Done also includes:
- No new compiler warnings, measured with a clean build (`xcrun swift build --scratch-path "$(mktemp -d)" 2>&1 | grep 'warning:' | sort -u`): the only allowed lines are the 3 pre-existing Swift 6 warnings at `src/Views/MascotOverlayView.swift:142` (from #61), which WP06 removes. Incremental builds hide warnings, so don't use them for this check (charter quality gate; SwiftLint is not configured in this repo).

## Context & Constraints

- Read: `research.md` (Antigravity facts, R3, R5, R6), `src/Services/AntigravityTranscriptAdapter.swift` (current parser, lines 155-190).
- Antigravity tool calls are `{name, args}` (5,656 observed) or `{name}`; they have **no ids** → anonymous pending (cleared by any later line).
- Context = `input_tokens + cache_read_tokens` of the latest line carrying tokens (R3).
- **Do not fix #63 here**: keep the `ask_question` check reading `function.name` exactly as today, so the #63 PR stays a one-line change. Leave a one-line comment `// Tool-call shape fix tracked in #63.`

## Branch Strategy

- **Planning base branch**: `feat/issue-38-agent-gauges-warnings`
- **Merge target branch**: `feat/issue-38-agent-gauges-warnings`
- Execution worktrees are allocated per computed lane from `lanes.json`.
- Implementation command: `spec-kitty agent action implement WP05 --agent claude`

## Subtasks & Detailed Guidance

### Subtask T023 – Antigravity line parser [P]

- ```swift
  /// Maps one Antigravity transcript line to tracker entries; unknown lines yield [.toolResult(id: nil)] only.
  public static func entries(fromLine data: Data) -> [SessionLogEntry]
  ```
- Rules (in order):
  1. Every parseable line starts with `.toolResult(id: nil)` — any later line means the previous anonymous tool calls finished (R5).
  2. `type == "USER_INPUT"` → `.prompt`.
  3. `type == "PLANNER_RESPONSE"`:
     - tokens: if `input_tokens` or `cache_read_tokens` present → `.assistantOutput(contextTokens: input + cacheRead)`; else `.assistantOutput(contextTokens: nil)`.
     - existing `ask_question` detection (unchanged `function.name` lookup) → `.approvalRequest`.
     - each tool call with a `name` → `.toolCall(id: nil, name:, fingerprint: AgentSessionTracker.fingerprint(name:input: call["args"]))`.
     - `status == "DONE"` and no tool calls → `.turnEnd(isDone: true)`.
  4. Unparseable JSON → `[]`.

### Subtask T024 – Adapter on shared tail + tracker

- Replace `currentTranscriptURL` / `lastOffset` / manual reading with `private var tail = SessionLogTail()` and `private var tracker = AgentSessionTracker(agentID: "antigravity", agentName: "Antigravity", startsTurnOnPrompt: true)`.
- Candidates: existing `findLatestTranscriptURL` logic becomes `sessionCandidates()` returning `(url, modified)` for each `<brain>/<id>/.system_generated/logs/transcript.jsonl`; choose with `SessionLogTail.pickSession(current:candidates:now:)`.
- `start`: attach + seed (emit one `usage` with `seed: true` when tokens are found in the seed; no other events), then poll every 1.5 s (unchanged).
- `checkForUpdates()` (public, used by tests): same flow as WP04 T021 step 3 — session switch → attach + reset + seed usage; else `readNew`, ingest, emit events, then `usage` when `grew`.
- Keep `public` API used elsewhere: `id`, `agentID`, `agentName`, `defaultBrainURL`, `init(baseBrainURL:clock:)`, `setHandlerForTesting`, `start`, `stop`, `checkForUpdates`, `findLatestTranscriptURL()` (keep as a thin wrapper if referenced; grep first).
- Keep message strings byte-identical: `"Antigravity is working..."`, `"Antigravity needs input!"`, `"Antigravity is done!"` (tracker produces the first and last; check `approvalRequest` message matches).

### Subtask T025 – Tests

- `Tests/BitzTests/AntigravityTranscriptAdapterTests.swift`:
  1. Update `testDetectsAntigravityTurnEvents` minimally: assert on `collector.snapshot.filter { $0.kind != .usage }` (usage events are new). Do not change its fixture lines (the `function`-shaped `ask_question` line stays; #63 changes it).
  2. `testReportsContextUsageFromPlannerTokens` — `{"type":"PLANNER_RESPONSE","input_tokens":1000,"cache_read_tokens":253000,...}` → `usage.contextTokens == 254000`.
  3. `testFourIdenticalNameArgsCallsEmitOneLoopWarning` — real `{name, args}` shape.
  4. `testPendingClearedByNextLine` — tool-call line → `usage.pendingTools == 1`; next line → `0`.
  5. `testStartupSeedIsSilent` — pre-existing file with tokens → one seed `usage`, no working/done.

## Test Strategy

- Run `xcrun swift test --filter AntigravityTranscriptAdapterTests`, then the full suite.

## Risks & Mitigations

- **#63 merge conflict**: keep the `ask_question` branch a small, isolated block so #63's change rebases cleanly.
- **Behaviour change at startup**: today the adapter starts at EOF; now it seeds from ≤ 256 KB without emitting lifecycle events — equivalent for users.

## Review Guidance

- Existing test's lifecycle assertions unchanged apart from the `usage` filter.
- `function.name` lookup still present and commented with #63.

## Activity Log

- 2026-10-30T13:37:15Z – system – Prompt created.
