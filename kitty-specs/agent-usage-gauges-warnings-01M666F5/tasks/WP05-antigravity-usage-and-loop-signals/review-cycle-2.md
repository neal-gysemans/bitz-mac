---
affected_files: []
cycle_number: 2
mission_slug: agent-usage-gauges-warnings-01M666F5
reproduction_command:
reviewed_at: '2026-10-30T16:08:55Z'
reviewer_agent: user
wp_id: WP05
---

# WP05 – review cycle 2 feedback (reopened after approval)

**Reason**: same gap as WP04. When Bitz starts mid-turn, or switches to an Antigravity session already in a turn, the turn's `done` is never shown because the seed is not ingested. Spec amended in commit `9a70647` (FR-014, Edge Cases, research R7, data-model, contract `seed` row). WP03 cycle 2 adds `AgentSessionTracker.prime(fromSeed:)`.

## Required changes (`src/Services/AntigravityTranscriptAdapter.swift`)

1. On attach: `tracker.reset()`, then `tracker.prime(fromSeed: seed.lines.flatMap(Self.entries(fromLine:)))`. Replace the throwaway-tracker seed construction.
2. Always emit exactly one seed usage event on attach: `tracker.usageEvent(at: now, seed: true)`, carrying the primed `turnActive`, `pendingTools` and `contextTokens` (when known).
3. No `working` / `done` / warnings for seed lines (FR-014).
4. Keep the `ask_question` `function.name` lookup unchanged (#63).

## Required tests (`Tests/BitzTests/AntigravityTranscriptAdapterTests.swift`)

- Transcript already holds `USER_INPUT` (turn in progress) when the adapter starts. Then append a final `PLANNER_RESPONSE` (`status DONE`, no tool calls). Assert events (excluding `usage`) are exactly `[.done]`, and the seed usage has `turnActive == true`.
- Transcript with a finished turn when attached. The seed usage has `turnActive == false` and nothing else is emitted.
- Keep `testStartupSeedIsSilent` and the existing lifecycle test intent; adjust only for the always-emitted seed usage.

## Definition of Done
Full `xcrun swift test` green; clean build (`--scratch-path "$(mktemp -d)"`) adds no warnings; only WP05 owned files touched; nothing under `kitty-specs/`.
