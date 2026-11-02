---
affected_files: []
cycle_number: 2
mission_slug: agent-usage-gauges-warnings-01M666F5
reproduction_command:
reviewed_at: '2026-10-30T16:02:02Z'
reviewer_agent: user
wp_id: WP03
---

# WP03 – review cycle 2 feedback (reopened after approval)

**Reason**: the WP04 and WP05 reviews found that the first turn of a session that starts while Bitz runs (and the turn in progress when Bitz launches) is silent. The adapter attaches between the first `user` line and the first `assistant` line, the seed is not ingested, so `awaitingFirstOutput` stays false and neither `working` nor `done` is emitted. The spec was amended (commit `9a70647`, FR-014 + Edge Cases, research R7, data-model "Adapter-side tracker"): a turn already in progress at attach time must be tracked from then on.

## Required change (`src/Services/AgentSessionTracker.swift`)

1. Add:
   ```swift
   /// Restores turn state from the startup / session-switch seed without emitting events (FR-014):
   /// a turn already in progress is tracked from now on; the loop streak starts fresh.
   public mutating func prime(fromSeed entries: [SessionLogEntry])
   ```
   Semantics: equivalent to silently ingesting `entries` (discard the returned events), then clearing the loop streak (fingerprint, count, fired). Turn state (`turnActive`, `awaitingFirstOutput`), pending tools (ids + anonymous) and `latestContextTokens` end up exactly as if those lines had been observed. Callers call it right after `reset()`.
2. Keep every existing public signature unchanged.

## Required tests (`Tests/BitzTests/AgentSessionTrackerTests.swift`)

- Claude-style (`startsTurnOnPrompt: false`): seed `[.turnEnd(true), .prompt]` → prime emits nothing; next live `.assistantOutput` emits `working`; later `.turnEnd(isDone: true)` emits `done`.
- Claude-style mid-turn: seed `[.prompt, .assistantOutput(1000), .toolCall(id:"t1",…)]` → `turnActive == true`, `pendingTools == 1`, `latestContextTokens == 1000`; live `.toolResult("t1")`, `.turnEnd(true)` → exactly one `done`, no `working`.
- Antigravity-style (`startsTurnOnPrompt: true`): seed `[.prompt]` → no events from prime, `turnActive == true`; live `.turnEnd(true)` emits `done`.
- Seed ending with `.turnEnd` → `turnActive == false`, pending 0.
- Loop streak cleared: seed has 3 identical tool calls; one more identical live call → no loop warning (needs 4 live identical calls).
- `prime` after `reset` on a tracker that had state from a previous session yields only the seed's state.

## Definition of Done (unchanged)
Full `xcrun swift test` green; clean build (`--scratch-path "$(mktemp -d)"`) adds no warnings; only WP03 owned files touched; nothing under `kitty-specs/`.
