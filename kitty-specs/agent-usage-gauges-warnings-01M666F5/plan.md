# Implementation Plan: Agent Usage Gauges, "Almost Done" Milestones & Critical Warnings

**Branch**: `feat/issue-38-agent-gauges-warnings` | **Date**: 2026-10-30 | **Spec**: [spec.md](spec.md)
**Input**: Feature specification from `/kitty-specs/agent-usage-gauges-warnings-01M666F5/spec.md` (Tracks GitHub issue #38)

## Summary

Add three agent signals to Bitz: a context usage gauge (tokens + % per agent), "almost done" milestones, and persistent agent warnings (context threshold, tool-call loop, stall). Session-log adapters stay pure parsers that emit events and a new never-shown `usage` reading; `AgentMonitorService` owns all policy (thresholds, stall timer, single warning slot, acknowledgement, toggles). Presentation reuses existing surfaces: the speech bubble (new interactive warning style with **Got it**), the visor (amber override), the AI Agents telemetry metric (context text), and the AI Agents settings tab.

## Technical Context

**Language/Version**: Swift 6.0 (swift-tools-version 6.0, strict concurrency)  
**Primary Dependencies**: SwiftUI, AppKit, Foundation, CryptoKit (system framework, for tool-input fingerprints); no third-party dependencies  
**Storage**: `UserDefaults` (new `AgentSignalSettings` JSON blob under `Bitz.AgentMonitor.SignalSettings`, injected defaults domain); session logs read-only from `~/.claude/projects/<project>/<session>.jsonl` and `~/.gemini/antigravity/brain/<id>/.system_generated/logs/transcript.jsonl`  
**Testing**: XCTest in `Tests/BitzTests/` via `xcrun swift test`; policy tested with synthetic events + injected clock; parsers tested with JSONL fixtures written to temp dirs; isolated `UserDefaults(suiteName:)` per test  
**Target Platform**: macOS 14.0+, Apple Silicon  
**Project Type**: Single Swift package (`BitzCore` library + `Bitz` executable)  
**Performance Goals**: poll ≤ every 1.5 s per adapter; a poll with no new bytes reads 0 bytes; ≤ 256 KB read on startup/session switch; signals reach the mascot ≤ 5 s  
**Constraints**: charter < 2% CPU / < 70 MB RAM; overlay click-through and no focus stealing (AGENTS.md §2); nothing drawn outside its window; no new hooks; no transcript text retained  
**Scale/Scope**: 1 new adapter (`ClaudeCodeTranscriptAdapter`), 1 shared log-tail helper, 1 pure session tracker, monitor policy extension, 4 view touch points, 1 settings card, drop-box schema update, ~8 test files touched/added

## Charter Check

- **DIR-001 Click-through**: PASS. Only `SpeechBubblePanel` toggles clicks, and only while the warning bubble's **Got it** button is on screen, via the existing `SpeechBubbleContent.isInteractive` → `updatePanelsInteractivity()` path. `MascotOverlayPanel` unchanged.
- **DIR-002 Wallpaper**: PASS. Not touched.
- **DIR-003 Resource budget**: PASS by design. Incremental reads (`SessionLogTail`), 1.5 s polls, 256 KB seed cap, one `usage` event per poll with new bytes, 5 s stall sweep. Verified manually in WP09 with Activity Monitor during `./Scripts/package_and_run.sh release`.
- **DIR-004 Rive contract**: PASS. Wellness thresholds and `BitzState` are untouched. The amber warning visor is a `WellnessPointEngine` input (`setWarningVisor(active:)`): `syncWithRive()` pushes `visorColor = amber` while it is active (red wins when overheating), and `MascotOverlayView` reads the same engine flag, so the drawn visor and the Rive `visorColor` input always match.
- **DIR-005 Living docs**: Planned. `docs/ARCHITECTURE.md` (new adapter + policy), `docs/STATE_MACHINE.md` (agent-warning visor input), `docs/ACCEPTANCE_CRITERIA.md` (new FR rows), `docs/agent-dropbox-event.schema.json` (new kinds + metadata).
- **Quality gate: static analysis / zero compiler warnings**: Planned. Every code WP's Definition of Done forbids new warnings in a clean build (`--scratch-path`; incremental builds hide warnings). Clean-build baseline on 2026-10-30: 3 pre-existing Swift 6 warnings at `src/Views/MascotOverlayView.swift:142` from #61 (an earlier "0" was an incremental-build artifact, caught in WP01 review); WP06 removes them and WP09 T042 checks 0 on the merged result. SwiftLint is not configured in the repo or CI (`.github/workflows/ci.yml` runs `swift test` only), so the gate is enforced as zero compiler warnings; adding SwiftLint is out of scope for this mission.
- **Testing policy (TDD, ≥ 80% on core services)**: Planned. Every IC lists its tests; policy and parsers are pure enough to test without UI or real files.
- **DIRECTIVE_001 Separation of concerns**: PASS. Parse (adapters) → policy (monitor) → present (views); interfaces documented in [data-model.md](data-model.md) and [contracts/agent-event-contract.md](contracts/agent-event-contract.md).
- **DIRECTIVE_010 Spec fidelity**: One recorded deviation, see Complexity Tracking.

## Design Decisions

Full rationale and alternatives in [research.md](research.md).

1. **Monitor owns policy** (decision `policy_placement`). Adapters emit `working` / `done` / `warning(loop)` plus a `usage` reading; `AgentMonitorService` applies settings, thresholds, the stall timer and the warning slot. Drop-box integrators get gauges and stall detection for free.
2. **New `usage` event kind**, never shown, carrying `contextTokens`, `pendingTools`, `turnActive`, `seed`. Emitted at most once per poll that saw new bytes, so "activity" = bytes appended (FR-009).
3. **Loop detection stays in the adapter-side tracker**: the threshold is fixed at 4 (FR-008), so it needs no settings; the monitor only applies the loop toggle.
4. **Turn boundaries (Claude Code)**: `working` is emitted on the first assistant line after a prompt (avoids false turns from local slash commands); the turn ends on `stop_reason == end_turn` (emits `done`), or silently on `turn_duration` / `stop_hook_summary` system lines or a `[Request interrupted` marker. `compact_boundary` resets the loop streak.
5. **Single warning slot + approval override** (decision `cross_agent_priority`): another agent's needs-approval takes the bubble; the warning stays active (amber visor) and its bubble returns on that agent's next lifecycle event (not `usage`). The menu bar dropdown offers **Dismiss Agent Warning** whenever a warning is active, so it can always be acknowledged even when its bubble is hidden.
6. **Settings live on `AgentMonitorService`** next to `popupsEnabled`, persisted through an injected `UserDefaults` (default `.standard`) so tests use isolated suites (NFR-005).
7. **Visor through the engine**: `WellnessPointEngine` gains `isWarningVisorActive` + `setWarningVisor(active:)`; `syncWithRive()` pushes Amber for `visorColor` while active (red wins when overheating); `MascotOverlayView` renders `visorColor(for:warningVisorActive:)` from the same engine flag. `BitzAppDelegate` maps `agentMonitor.$activeWarning` to the flag. The engine knows only "warning visor on/off", not agent policy (DIRECTIVE_001).
8. **Gauge**: `AgentTelemetry` gains an optional `AgentContextReading`; `formattedSummary` / `compactBadge` render `Claude ctx 148k · 74%` through existing placements.
9. **App-presence events never clear warnings**: `ProcessAgentAdapter` tags its events with metadata `source = process`; the monitor ignores `done` events with that source for warning clearing and turn state (the Claude desktop app shares the agent ID `claude` with Claude Code).

## Project Structure

### Documentation (this mission)

```
kitty-specs/agent-usage-gauges-warnings-01M666F5/
├── spec.md
├── plan.md              # This file
├── research.md          # Verified session-log facts + design decisions
├── data-model.md        # Types, state machines, invariants
├── quickstart.md        # Manual verification via drop-box events
├── contracts/
│   └── agent-event-contract.md   # Drop-box / adapter event contract v2
└── tasks.md             # Generated by /spec-kitty.tasks
```

### Source Code (repository root)

```
src/
├── Models/
│   ├── AgentModels.swift              # + almostDone/warning/usage kinds, metadata, AgentSignalSettings, AgentWarning, AgentContextReading
│   └── TelemetryModels.swift          # AgentTelemetry + context reading text
├── Services/
│   ├── AgentMonitorService.swift      # policy: usage, context crossing, stall sweep, warning slot, settings (injected defaults)
│   ├── SessionLogTail.swift           # NEW shared incremental reader (offsets, partial lines, truncation, 256 KB seed)
│   ├── AgentSessionTracker.swift      # NEW pure tracker (turn state, pending tools, loop streak, latest tokens)
│   ├── ClaudeCodeTranscriptAdapter.swift  # NEW Claude Code session-log adapter
│   ├── AntigravityTranscriptAdapter.swift # usage/loop/pending via shared tail + tracker
│   ├── ProcessAgentAdapter.swift      # tags events with metadata source=process
│   ├── WellnessPointEngine.swift      # warning visor input (isWarningVisorActive, setWarningVisor)
│   └── TelemetryDashboardService.swift    # pass context reading into AgentTelemetry
├── Views/
│   ├── SpeechBubbleView.swift         # warning bubble with GOT IT, almost-done style, isInteractive
│   ├── MascotOverlayView.swift        # visor from the engine's warning visor flag
│   └── Settings/AgentsSettingsTabView.swift  # signals & thresholds card
└── App/BitzApp.swift                  # wire Claude adapter + injected defaults; warning → engine visor; menu "Dismiss Agent Warning"
docs/
├── agent-dropbox-event.schema.json    # new kinds + metadata
├── ARCHITECTURE.md, STATE_MACHINE.md, ACCEPTANCE_CRITERIA.md
Tests/BitzTests/
├── AgentModelsTests.swift             # NEW event/metadata decoding, value types, settings clamp
├── AgentMonitorServiceTests.swift     # lifecycle for almostDone / warning / usage
├── AgentSignalPolicyTests.swift       # NEW context crossing, stall sweep, slot priority, settings persistence
├── ProcessAgentAdapterTests.swift     # source=process tag
├── SessionLogTailTests.swift          # NEW incremental reads, partial lines, truncation, seed cap, hysteresis
├── AgentSessionTrackerTests.swift     # NEW loop streak, pending tools, turn boundaries
├── ClaudeCodeTranscriptAdapterTests.swift  # NEW fixture replays (subagent skip, sidechain skip, seed)
├── AntigravityTranscriptAdapterTests.swift # usage + loop fixtures
├── DropboxAgentAdapterTests.swift     # decode new kinds + metadata, old payloads unchanged
├── AgentSignalIntegrationTests.swift  # NEW replayed Claude session → adapter → monitor (SC-002)
├── AgentWarningPresentationTests.swift # NEW visor mapping, bubble interactivity
├── WellnessPointEngineTests.swift     # warning visor Rive input
├── MenuBarContentViewTests.swift      # Dismiss Agent Warning item
├── MascotOverlayLayoutTests.swift, SpeechBubblePanelTests.swift, OverlayTestFixtures.swift
├── TelemetryDashboardServiceTests.swift, SettingsViewsTests.swift
```

**Structure Decision**: Existing single-package layout; new files sit beside their peers (`Services/` for adapters and helpers). No new targets.

## Complexity Tracking

| Deviation | Why needed | Simpler alternative rejected because |
|-----------|------------|--------------------------------------|
| Seventh event kind `usage` beyond the six kinds named in the spec's Key Entities | Context readings and activity heartbeats must reach the monitor without showing a bubble | Overloading `working` with metadata would trigger "is working…" popups on every poll; a second adapter callback would change the `AgentAdapter` protocol and every mock. Spec Key Entities amended in the same commit. |
| `WellnessPointEngine` gains a "warning visor" input | Drawn visor and Rive `visorColor` input must match (charter DIR-004, analysis finding C2) | A view-only override in `MascotOverlayView` made the drawn visor diverge from the engine's Rive input. The engine receives only a boolean, never agent policy (DIRECTIVE_001). |
| `ProcessAgentAdapter` events carry `metadata.source = process` | The Claude desktop app and Claude Code share agent ID `claude`; an app-quit `done` must not clear Claude Code warnings (finding I2) | Splitting the agent ID would change the user-visible catalog and per-agent toggles. |

## Implementation Concern Map

### IC-01 — Event Model & Drop-box Contract
- **Purpose**: Extend the event vocabulary (`almostDone`, `warning`, `usage`), add optional `metadata`, keep old drop-box payloads decoding unchanged, publish the v2 contract.
- **Relevant requirements**: FR-001, FR-002, FR-003, C-001
- **Affected surfaces**: `src/Models/AgentModels.swift`, `docs/agent-dropbox-event.schema.json`, `Tests/BitzTests/DropboxAgentAdapterTests.swift`
- **Sequencing/depends-on**: none
- **Risks**: exhaustive `switch` on `AgentEventKind` in `AgentMonitorService` and `SpeechBubbleView` must be updated in the same change to keep the build green.

### IC-02 — Monitor Policy & Signal Settings
- **Purpose**: Context readings and threshold crossing per agent, stall sweep, single warning slot with approval override and restoration, acknowledgement, toggles, disabled-agent clearing, quiet seeding, settings persistence via injected defaults.
- **Relevant requirements**: FR-001, FR-002, FR-005, FR-007, FR-009, FR-010, FR-012 (model), FR-013, FR-014, NFR-003, NFR-005
- **Affected surfaces**: `src/Services/AgentMonitorService.swift`, `src/Services/ProcessAgentAdapter.swift` (source tag), `src/Models/AgentModels.swift` (settings/value types), `Tests/BitzTests/AgentMonitorServiceTests.swift`, `Tests/BitzTests/AgentSignalPolicyTests.swift`, `Tests/BitzTests/ProcessAgentAdapterTests.swift`
- **Sequencing/depends-on**: IC-01
- **Risks**: popup-priority regressions for existing working/needsApproval/done behaviour; existing tests write `UserDefaults.standard` — keep them working while new tests use isolated suites.

### IC-03 — Session-Log Reading (Claude Code + Antigravity)
- **Purpose**: Shared incremental tail reader, pure session tracker (turns, pending tools, loop streak, latest tokens), new Claude Code adapter (top-level sessions only, sidechain lines skipped), Antigravity adapter emitting usage/loop/pending.
- **Relevant requirements**: FR-004, FR-005, FR-008, FR-009 (activity + pending inputs), FR-014, NFR-001, NFR-002, NFR-004, NFR-006, C-003
- **Affected surfaces**: `src/Services/SessionLogTail.swift`, `src/Services/AgentSessionTracker.swift`, `src/Services/ClaudeCodeTranscriptAdapter.swift`, `src/Services/AntigravityTranscriptAdapter.swift`, matching tests
- **Sequencing/depends-on**: IC-01
- **Risks**: undocumented, evolving session-log formats (mitigated: skip unknown lines, fixtures from verified structure); `AntigravityTranscriptAdapter` also receives the separate #63 fix — keep edits local to avoid conflicts.

### IC-04 — Mascot Presentation (Bubble, Visor, Gauge)
- **Purpose**: Interactive warning bubble with **Got it**, distinct almost-done bubble, amber warning visor through the engine, menu bar **Dismiss Agent Warning**, context text on the AI Agents metric, app wiring (Claude adapter, injected defaults, warning → engine visor), and an end-to-end replay test (adapter → monitor).
- **Relevant requirements**: FR-006, FR-010 (presentation), FR-011, C-002, C-005, SC-002
- **Affected surfaces**: `src/Views/SpeechBubbleView.swift`, `src/Views/MascotOverlayView.swift`, `src/Services/WellnessPointEngine.swift`, `src/App/BitzApp.swift`, `src/Models/TelemetryModels.swift`, `src/Services/TelemetryDashboardService.swift`, `Tests/BitzTests/MascotOverlayLayoutTests.swift`, `Tests/BitzTests/SpeechBubblePanelTests.swift`, `Tests/BitzTests/OverlayTestFixtures.swift`, `Tests/BitzTests/WellnessPointEngineTests.swift`, `Tests/BitzTests/MenuBarContentViewTests.swift`, `Tests/BitzTests/AgentSignalIntegrationTests.swift`, `Tests/BitzTests/TelemetryDashboardServiceTests.swift`
- **Sequencing/depends-on**: IC-02, IC-03
- **Risks**: warning bubble with button must stay inside its window at every scale (layout test); click-through must revert immediately after **Got it**; engine visor input must not change wellness state or thresholds.

### IC-05 — Signal Settings UI
- **Purpose**: AI Agents tab card: per-signal toggles, context threshold (50–99%), stall timeout (1–30 min), per-agent context window (200k / 1M / custom).
- **Relevant requirements**: FR-012, SC-005
- **Affected surfaces**: `src/Views/Settings/AgentsSettingsTabView.swift`, `Tests/BitzTests/SettingsViewsTests.swift`
- **Sequencing/depends-on**: IC-02
- **Risks**: custom window input validation (positive integers only).

### IC-06 — Living Docs & Verification
- **Purpose**: Sync living docs (DIR-005), zero-warnings build + full suite, package and run the release build, manual quickstart pass with a timed signal-latency step (NFR-003), Activity Monitor resource check.
- **Relevant requirements**: SC-001…SC-006, NFR-001, NFR-003, C-005, charter zero-warnings gate
- **Affected surfaces**: `docs/ARCHITECTURE.md`, `docs/STATE_MACHINE.md`, `docs/ACCEPTANCE_CRITERIA.md`
- **Sequencing/depends-on**: IC-01…IC-05
- **Risks**: none beyond flaky UI layout timing on CI (existing `spinRunLoop` helper).
