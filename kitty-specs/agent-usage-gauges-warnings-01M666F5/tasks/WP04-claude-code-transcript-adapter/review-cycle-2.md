---
affected_files: []
cycle_number: 2
mission_slug: agent-usage-gauges-warnings-01M666F5
reproduction_command:
reviewed_at: '2026-10-30T16:08:53Z'
reviewer_agent: user
wp_id: WP04
---

# WP04 – review cycle 2 feedback (reopened after approval)

**Reason**: the cycle-1 review found that the first turn of a session that starts while Bitz runs is silent (the adapter attaches between the first `user` and first `assistant` line and never ingests the seed). Spec amended in commit `9a70647` (FR-014, Edge Cases "Startup / session switch", research R7, data-model, contract `seed` row). WP03 cycle 2 adds `AgentSessionTracker.prime(fromSeed:)`, which silently restores turn state from seed entries and clears the loop streak.

## Required changes (`src/Services/ClaudeCodeTranscriptAdapter.swift`)

1. On attach (startup or session switch): `tracker.reset()`, then `tracker.prime(fromSeed: seed.lines.flatMap(Self.entries(fromLine:)))`.
2. Always emit exactly one seed usage event on attach: `tracker.usageEvent(at: now, seed: true)`. It carries the primed `turnActive`, `pendingTools` and `contextTokens` (when known). This replaces the hand-built seed metadata (`turnActive=false`, `pendingTools=0`), so a stale turn from the previous session is still cleared when the new seed has no active turn.
3. Do not emit `working` / `done` / warnings for seed lines (FR-014). The prime is silent by contract.
4. Nit from the cycle-1 review: the poll loop should exit when `self` is gone (`guard let self else { return }`), like the Antigravity adapter.

## Required tests (`Tests/BitzTests/ClaudeCodeTranscriptAdapterTests.swift`)

- Session file already holds a prompt (no reply yet) when the adapter attaches. Then append an assistant line, then an `end_turn` line. Assert events (excluding `usage`) are exactly `[.working, .done]`.
- Session file holds prompt + assistant(`tool_use`) when attached (mid-turn). Then append `tool_result` + assistant(`end_turn`). Assert events (excluding `usage`) are exactly `[.done]`, and the seed usage has `turnActive == true`, `pendingTools == 1`.
- The seed usage is emitted even when the seed has no tokens, and carries `turnActive == false` for a finished seed.
- Update existing tests that counted events after attaching to account for the always-emitted seed usage (filter `usage` or assert it explicitly). Don't weaken their intent.

## Definition of Done
Full `xcrun swift test` green; clean build (`--scratch-path "$(mktemp -d)"`) adds no warnings; only WP04 owned files touched; nothing under `kitty-specs/`.
