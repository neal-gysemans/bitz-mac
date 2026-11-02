<!-- spec-kitty intake: ingested from issues/2026-10-30-agent-usage-gauges-warnings.md at 2026-10-30T10:42:10.021006+00:00 -->
<!-- brief_hash: e0b1a62aba50087d4e89bc0bf598cc2eba07dcadbebedea393cfaae6a8ab9582 -->

# Feature Request: AI Agent Usage Gauges, "Almost Done" Milestones & Critical Warnings

Tracks GitHub issue #38.

## Summary
Extend Bitz's agent monitoring so the mascot gives an "almost done" heads-up, shows how full an agent's context window is, and raises warnings when an agent is close to its context limit, stuck in a tool-call loop, or stalled.

## Environment
- **Product/Service**: bitz-mac (Bitz the Cyber Cat)
- **Region/Version**: current `main` + speech bubble panel rework (#61 / PR #62)
- **Browser/OS**: macOS 14.0+ (Apple Silicon)

## Problem / Motivation
`AgentMonitorService` (`src/Services/AgentMonitorService.swift`) only knows `started`, `working`, `needsApproval` and `done`. During long agent runs the user cannot tell:

1. **Progress**: whether a task is 10% or 95% done. There is no "almost done" heads-up before the final notification.
2. **Context depletion**: when the agent's context window is nearly full (quality degrades, auto-compaction kicks in).
3. **Silent loops and stalls**: an agent repeating the same tool call, or sitting in `working` with no output, burns budget unnoticed.

## Data Sources Available Today (verified locally)
- **Claude Code** session transcripts (`~/.claude/projects/<project>/<session>.jsonl`): assistant lines carry `message.model` and `message.usage` (`input_tokens`, `cache_creation_input_tokens`, `cache_read_input_tokens`, `output_tokens`) and `tool_use` content blocks (name + input), including the todo list tool.
- **Antigravity** transcripts (`~/.gemini/antigravity/brain/<id>/.system_generated/logs/transcript.jsonl`, already tailed by `AntigravityTranscriptAdapter`): lines carry `input_tokens`, `cache_read_tokens`, `output_tokens`, `step_index` and `tool_calls`.
- **Drop-box JSON API** (`~/Library/Application Support/Bitz/agent-events/*.json`, `DropboxAgentAdapter`): any hook or script can emit events directly.
- Neither transcript records the model's context window size, session cost, or rate-limit state.

## Expected Behavior
1. **Almost Done**: when an agent enters the final step of its own task list (e.g. last todo item in progress), Bitz shows an eager "✨ Claude is almost done!" bubble.
2. **Context gauge**: the existing AI Agents telemetry metric shows the active agent's context usage (e.g. `Claude ctx 74%`) in the Cyber HUD / bubble carousel / menu bar title placements.
3. **Warnings** (new `.warning` kind):
   - Context window above a threshold (default 90%): "⚠️ Claude: context at 92%! Consider /compact soon."
   - Tool loop: the same tool call (name + input) repeated 3+ times in a row.
   - Stall: an agent in `working` with no new activity for 3+ minutes, while no tool call is pending.
4. **Mascot**: warning bubbles stay until acknowledged or cleared by the next agent event; the visor turns amber while an agent warning is active.
5. **Settings**: AI Agents tab gets toggles per warning type, the context threshold, the stall timeout, and the assumed context window size.

## Scope Decisions (agreed 2026-10-30)
In scope: event model (`.almostDone`, `.warning`, optional `metadata`), monitor lifecycle, Claude Code transcript adapter, Antigravity usage/loop signals, stall detection, amber visor, context % on the AI Agents metric, settings, unit tests.

Out of scope, to be split into follow-up issues:
- **Session cost ($)**: transcripts carry no cost; would require a maintained price table.
- **Rate limit (429) detection**: no verified transcript or hook signal yet.
- **Runaway CPU alerts**: `ProcessAgentAdapter` does not sample per-process CPU today; needs its own design against the charter's < 2% CPU budget.
- **Do Not Disturb / Focus integration**: depends on #19 / #22 (not built yet).
- **Alert sounds**: depends on #21 (not built yet).

## Acceptance Criteria
- [ ] `AgentEventKind` supports `.almostDone` and `.warning`; `AgentEvent` carries optional `metadata: [String: String]` and still decodes old drop-box JSON.
- [ ] Mascot shows a distinct "Almost Done" bubble when an agent enters its final task step.
- [ ] Context window usage percentage renders through the existing AI Agents telemetry metric.
- [ ] Warning alerts trigger for context usage above threshold, repeated tool-call loops, and stalls (> 3 min, configurable).
- [ ] Mascot visor turns amber while an agent warning is active.
- [ ] Settings allow toggling each warning type and setting thresholds.
- [ ] Unit tests cover `AgentMonitorService` handling of `.almostDone` and `.warning` lifecycle transitions and the transcript signal parsing.

## Impact
**Medium** - Makes long autonomous agent runs observable from the desktop without checking the terminal, and prevents context degradation and runaway loops from going unnoticed.
