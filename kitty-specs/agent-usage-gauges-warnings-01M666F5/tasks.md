---
description: "Work package task list for agent usage gauges, almost-done milestones and agent warnings"
---

# Work Packages: Agent Usage Gauges, "Almost Done" Milestones & Critical Warnings

**Inputs**: Design documents from `/kitty-specs/agent-usage-gauges-warnings-01M666F5/`
**Prerequisites**: plan.md, spec.md, research.md, data-model.md, contracts/agent-event-contract.md, quickstart.md

**Tests**: Required. The charter mandates TDD (`tdd-red-green-refactor`) and ≥ 80% coverage on core services; AGENTS.md §3.2 requires isolated `UserDefaults(suiteName:)` domains with cleanup.

**Definition of Done (every code WP)**: no new compiler warnings in a clean build (`xcrun swift build --scratch-path "$(mktemp -d)"`; incremental builds hide warnings) and a green `xcrun swift test`. Baseline on 2026-10-30 (clean build): 3 pre-existing Swift 6 warnings at `src/Views/MascotOverlayView.swift:142` from #61; WP06 removes them, so the merged result has 0 (charter quality gate; SwiftLint is not configured in the repo).

**Organization**: Fine-grained subtasks (`Txxx`) roll up into work packages (`WPxx`). Each work package is independently deliverable and testable.

**Prompt Files**: Each work package references a matching prompt file in `/tasks/`. Deep implementation detail lives in the prompt files.

## Subtask Format: `[Txxx] [P?] Description`

- **[P]** = can proceed in parallel (different files/components).
- Subtasks are reference rows; record completion with `spec-kitty agent tasks mark-status <Txxx> --status done`.

## Dependency Graph

```
WP01 ──┬──► WP02 ──┬──► WP06 ◄── WP04 ◄──┐
       │           ├──► WP07              │
       │           └──► WP08              │
       └──► WP03 ──┬──────────────────────┘
                   └──► WP05
WP01…WP08 ──► WP09
```

## Subtask Index

| ID | Description | WP | Parallel |
|----|-------------|----|----------|
| T001 | Extend `AgentEventKind` + `AgentEvent.metadata` with lenient decoding | WP01 | |
| T002 | Metadata keys + typed accessors on `AgentEvent` | WP01 | |
| T003 | `AgentWarningReason`, `AgentWarning`, `AgentContextReading`, `AgentSignalSettings` | WP01 | |
| T004 | Keep exhaustive switches compiling (placeholder cases) | WP01 | |
| T005 | Update `docs/agent-dropbox-event.schema.json` to contract v2 | WP01 | [P] |
| T006 | Model + drop-box decoding tests | WP01 | |
| T007 | Inject `UserDefaults` into `AgentMonitorService`; persist `signalSettings` | WP02 | |
| T008 | Per-agent session state + context readings + threshold crossing | WP02 | |
| T009 | Warning slot: raise, replace, acknowledge, clear rules | WP02 | |
| T010 | Popup priority: almost-done, approval override + restoration, popups-disabled | WP02 | |
| T011 | Stall sweep task + `evaluateStalls()` | WP02 | |
| T012 | Disabled agent clears warning/context/session state | WP02 | |
| T013 | Policy tests (`AgentSignalPolicyTests`) + existing monitor tests green | WP02 | |
| T044 | `ProcessAgentAdapter` tags `source = process`; app-presence `done` never clears warnings or ends turns | WP02 | |
| T014 | `SessionLogTail` incremental reader + 256 KB seed | WP03 | [P] |
| T015 | Session selection with idle-switch hysteresis | WP03 | [P] |
| T016 | `SessionLogEntry` + `AgentSessionTracker` (turns, pending tools, loop streak) | WP03 | [P] |
| T017 | Tool-call fingerprint (canonical JSON + SHA-256) | WP03 | [P] |
| T018 | `SessionLogTail` tests | WP03 | |
| T019 | `AgentSessionTracker` tests | WP03 | |
| T020 | Claude Code line parser → `SessionLogEntry` | WP04 | |
| T021 | `ClaudeCodeTranscriptAdapter` discovery, polling, seeding | WP04 | |
| T022 | Claude Code adapter fixture tests | WP04 | |
| T023 | Antigravity line parser → `SessionLogEntry` (tokens, `{name,args}` calls) | WP05 | [P] |
| T024 | Antigravity adapter on shared tail + tracker, existing behaviour kept | WP05 | |
| T025 | Antigravity tests (existing updated + usage/loop/pending) | WP05 | |
| T026 | Warning bubble with GOT IT + almost-done style + interactivity | WP06 | |
| T027 | Warning visor through `WellnessPointEngine` (Rive input + drawn visor match) | WP06 | [P] |
| T028 | App wiring: Claude adapter, injected defaults, monitor into overlay | WP06 | |
| T029 | Fixture helpers + layout tests for new bubbles | WP06 | |
| T030 | Click-through test for warning bubble acknowledgement | WP06 | |
| T031 | Presentation + engine unit tests (visor mapping, Rive input, content interactivity) | WP06 | |
| T045 | Menu bar "Dismiss Agent Warning" item | WP06 | |
| T046 | End-to-end replay test: Claude session → adapter → monitor (SC-002) | WP06 | |
| T032 | `AgentTelemetry` context reading + rendering in badge/summary/title | WP07 | |
| T033 | `TelemetryDashboardService` passes active agent's context reading | WP07 | |
| T034 | Telemetry tests for context text | WP07 | |
| T035 | Agent Signals card: per-signal toggles | WP08 | |
| T036 | Threshold + stall timeout steppers | WP08 | |
| T037 | Per-agent context window picker (200k / 1M / custom) | WP08 | |
| T038 | Settings view tests | WP08 | |
| T039 | `docs/ARCHITECTURE.md` update | WP09 | [P] |
| T040 | `docs/STATE_MACHINE.md` agent-warning visor override | WP09 | [P] |
| T041 | `docs/ACCEPTANCE_CRITERIA.md` rows for this mission | WP09 | [P] |
| T042 | Zero-warnings build + full test suite run | WP09 | |
| T043 | Release package run, quickstart walkthrough incl. timed latency step (NFR-003), resource check | WP09 | |

---

## Work Package WP01: Event Model & Drop-box Contract (Priority: P0)

**Goal**: Extend the shared event vocabulary and value types every other package builds on, without breaking old drop-box payloads.
**Independent Test**: Decoding an old payload yields the same `AgentEvent`; decoding a v2 payload with `metadata` (strings or numbers) yields typed accessors; the build stays green.
**Prompt**: `/tasks/WP01-event-model-and-dropbox-contract.md`
**Requirement Refs**: FR-001, FR-002, FR-003, C-001
**Estimated prompt size**: ~227 lines

### Included Subtasks

T001 Extend `AgentEventKind` + `AgentEvent.metadata` with lenient decoding (WP01)
T002 Metadata keys + typed accessors on `AgentEvent` (WP01)
T003 `AgentWarningReason`, `AgentWarning`, `AgentContextReading`, `AgentSignalSettings` (WP01)
T004 Keep exhaustive switches compiling (placeholder cases) (WP01)
T005 [P] Update `docs/agent-dropbox-event.schema.json` to contract v2 (WP01)
T006 Model + drop-box decoding tests (WP01)

### Dependencies

- None (starting package).

### Risks & Mitigations

- Adding enum cases breaks two exhaustive switches (`AgentMonitorService.handleEvent`, `SpeechBubbleView.agentPopupColors`): T004 adds minimal placeholder cases, replaced in WP02/WP06.

### Out-of-map edits (declared)

- `src/Services/AgentMonitorService.swift` (owned by WP02): one placeholder `case .almostDone, .warning, .usage: break`.
- `src/Views/SpeechBubbleView.swift` (owned by WP06): placeholder colour mapping for the three new kinds.
- Both are required to keep the build green after T001; WP02 T010 and WP06 T026 replace them. Reviewers of WP02/WP06 confirm no placeholder remains.

---

## Work Package WP02: Monitor Policy & Signal Settings (Priority: P1)

**Goal**: Make `AgentMonitorService` the single owner of signal policy: settings persistence, context crossing, stall sweep, the warning slot with approval override, and acknowledgement.
**Independent Test**: Synthetic events + injected clock reproduce every acceptance scenario of User Stories 1–4 without files or UI.
**Prompt**: `/tasks/WP02-monitor-policy-and-signal-settings.md`
**Requirement Refs**: FR-001, FR-002, FR-005, FR-007, FR-009, FR-010, FR-012, FR-013, FR-014, NFR-003, NFR-005
**Estimated prompt size**: ~267 lines

### Included Subtasks

T007 Inject `UserDefaults` into `AgentMonitorService`; persist `signalSettings` (WP02)
T008 Per-agent session state + context readings + threshold crossing (WP02)
T009 Warning slot: raise, replace, acknowledge, clear rules (WP02)
T010 Popup priority: almost-done, approval override + restoration, popups-disabled (WP02)
T011 Stall sweep task + `evaluateStalls()` (WP02)
T012 Disabled agent clears warning/context/session state (WP02)
T013 Policy tests (`AgentSignalPolicyTests`) + existing monitor tests green (WP02)
T044 `ProcessAgentAdapter` tags `source = process`; app-presence `done` never clears warnings or ends turns (WP02)

### Dependencies

- Depends on WP01.

### Risks & Mitigations

- Regressing existing working/needsApproval/done popup behaviour: keep every existing `AgentMonitorServiceTests` case green unchanged.

---

## Work Package WP03: Shared Session-Log Foundation (Priority: P1)

**Goal**: Pure, file-agnostic building blocks for session-log adapters: incremental tail reading with a bounded seed, stable session selection, and a tracker that turns parsed entries into events (turns, pending tools, loop streak).
**Independent Test**: Tail and tracker tests pass with temp files and in-memory entries; no adapter needed.
**Prompt**: `/tasks/WP03-shared-session-log-foundation.md`
**Requirement Refs**: FR-008, FR-009, FR-014, NFR-001, NFR-002, NFR-004, NFR-006
**Estimated prompt size**: ~237 lines

### Included Subtasks

T014 [P] `SessionLogTail` incremental reader + 256 KB seed (WP03)
T015 [P] Session selection with idle-switch hysteresis (WP03)
T016 [P] `SessionLogEntry` + `AgentSessionTracker` (turns, pending tools, loop streak) (WP03)
T017 [P] Tool-call fingerprint (canonical JSON + SHA-256) (WP03)
T018 `SessionLogTail` tests (WP03)
T019 `AgentSessionTracker` tests (WP03)

### Dependencies

- Depends on WP01.

### Risks & Mitigations

- Partial trailing lines double-counted as activity: track file size separately from parse offset.

---

## Work Package WP04: Claude Code Transcript Adapter (Priority: P1)

**Goal**: Follow the active top-level Claude Code session log and emit working/done/loop-warning/usage events.
**Independent Test**: Fixture replays in a temp `projects/` dir produce the expected event sequence; subagent files and sidechain lines are ignored; startup seeds the gauge silently.
**Prompt**: `/tasks/WP04-claude-code-transcript-adapter.md`
**Requirement Refs**: FR-004, FR-005, FR-008, FR-014, C-003, NFR-004
**Estimated prompt size**: ~171 lines

### Included Subtasks

T020 Claude Code line parser → `SessionLogEntry` (WP04)
T021 `ClaudeCodeTranscriptAdapter` discovery, polling, seeding (WP04)
T022 Claude Code adapter fixture tests (WP04)

### Dependencies

- Depends on WP03.

### Risks & Mitigations

- Undocumented, evolving log format: unknown lines and fields are skipped; fixtures mirror verified structure from research.md.

---

## Work Package WP05: Antigravity Usage & Loop Signals (Priority: P2)

**Goal**: Move `AntigravityTranscriptAdapter` onto the shared tail + tracker so it reports context usage, loop warnings and pending tools while keeping today's working/done/needs-input behaviour.
**Independent Test**: Existing Antigravity test passes (filtering `usage` events); new fixtures yield usage tokens and one loop warning after four identical `{name,args}` calls.
**Prompt**: `/tasks/WP05-antigravity-usage-and-loop-signals.md`
**Requirement Refs**: FR-005, FR-008, FR-014
**Estimated prompt size**: ~131 lines

### Included Subtasks

T023 [P] Antigravity line parser → `SessionLogEntry` (tokens, `{name,args}` calls) (WP05)
T024 Antigravity adapter on shared tail + tracker, existing behaviour kept (WP05)
T025 Antigravity tests (existing updated + usage/loop/pending) (WP05)

### Dependencies

- Depends on WP03.

### Risks & Mitigations

- Conflicts with the separate #63 fix: keep the `ask_question` check byte-for-byte as is (still `function.name`); #63 changes it.

---

## Work Package WP06: Warning Bubble, Amber Visor & App Wiring (Priority: P2)

**Goal**: Present warnings (persistent bubble with GOT IT, amber visor through the engine so the drawn visor and Rive input match, menu bar Dismiss Agent Warning), a distinct almost-done bubble, wire the Claude Code adapter + injected defaults into the app, and prove the pipeline with an end-to-end replay.
**Independent Test**: Layout tests keep new bubbles inside their window at max scale; the bubble panel takes clicks only while GOT IT shows; the engine's Rive `visorColor` and the drawn visor are both amber for warnings except while overheating; a replayed Claude session raises exactly one context warning per crossing.
**Prompt**: `/tasks/WP06-warning-bubble-amber-visor-and-wiring.md`
**Requirement Refs**: FR-001, FR-010, FR-011, C-002, C-005, C-006
**Estimated prompt size**: ~232 lines

### Included Subtasks

T026 Warning bubble with GOT IT + almost-done style + interactivity (WP06)
T027 [P] Warning visor through `WellnessPointEngine` (Rive input + drawn visor match) (WP06)
T028 App wiring: Claude adapter, injected defaults, monitor into overlay (WP06)
T029 Fixture helpers + layout tests for new bubbles (WP06)
T030 Click-through test for warning bubble acknowledgement (WP06)
T031 Presentation + engine unit tests (visor mapping, Rive input, content interactivity) (WP06)
T045 Menu bar "Dismiss Agent Warning" item (WP06)
T046 End-to-end replay test: Claude session → adapter → monitor (SC-002) (WP06)

### Dependencies

- Depends on WP02, WP04.

### Risks & Mitigations

- Bubble with a button clipped at large scale: layout test at `AvatarScaleStore.maxScaleFactor`.

---

## Work Package WP07: Context Gauge on the AI Agents Metric (Priority: P2)

**Goal**: Show the active agent's context as `Claude ctx 148k · 74%` through the existing HUD badge, carousel and menu bar title placements.
**Independent Test**: A snapshot with an active agent and a reading renders the context text in all three placements; without a reading, output is unchanged.
**Prompt**: `/tasks/WP07-context-gauge-on-agents-metric.md`
**Requirement Refs**: FR-006
**Estimated prompt size**: ~120 lines

### Included Subtasks

T032 `AgentTelemetry` context reading + rendering in badge/summary/title (WP07)
T033 `TelemetryDashboardService` passes active agent's context reading (WP07)
T034 Telemetry tests for context text (WP07)

### Dependencies

- Depends on WP02.

---

## Work Package WP08: Agent Signals Settings Card (Priority: P3)

**Goal**: Let users toggle each signal and tune the context threshold, stall timeout and per-agent context window in Settings → AI Agents.
**Independent Test**: Changing a control updates `agentMonitor.signalSettings`, persists to the injected defaults, and a fresh monitor reads it back.
**Prompt**: `/tasks/WP08-agent-signals-settings-card.md`
**Requirement Refs**: FR-012, FR-013
**Estimated prompt size**: ~136 lines

### Included Subtasks

T035 Agent Signals card: per-signal toggles (WP08)
T036 Threshold + stall timeout steppers (WP08)
T037 Per-agent context window picker (200k / 1M / custom) (WP08)
T038 Settings view tests (WP08)

### Dependencies

- Depends on WP02.

---

## Work Package WP09: Living Docs & Release Verification (Priority: P3)

**Goal**: Sync living docs (charter DIR-005) and verify the whole mission end to end.
**Independent Test**: `xcrun swift build` has zero warnings and `xcrun swift test` passes with zero failures; release build runs; quickstart steps behave as documented; the timed latency step measures ≤ 5 s (NFR-003); Activity Monitor shows < 2% CPU and < 70 MB RAM.
**Prompt**: `/tasks/WP09-living-docs-and-release-verification.md`
**Requirement Refs**: NFR-001, NFR-002, NFR-003, C-004, C-005
**Estimated prompt size**: ~130 lines

### Included Subtasks

T039 [P] `docs/ARCHITECTURE.md` update (WP09)
T040 [P] `docs/STATE_MACHINE.md` agent-warning visor override (WP09)
T041 [P] `docs/ACCEPTANCE_CRITERIA.md` rows for this mission (WP09)
T042 Zero-warnings build + full test suite run (WP09)
T043 Release package run, quickstart walkthrough incl. timed latency step (NFR-003), resource check (WP09)

### Dependencies

- Depends on WP01, WP02, WP03, WP04, WP05, WP06, WP07, WP08.

---

## MVP Scope

WP01 + WP02 + WP03 + WP04 + WP06 deliver the P1 stories for Claude Code (gauge data, context/loop/stall warnings, presentation). WP05, WP07, WP08 add Antigravity signals, the visible gauge text and tuning.
