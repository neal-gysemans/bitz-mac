# Mission Specification: Agent Usage Gauges, "Almost Done" Milestones & Critical Warnings

**Mission Branch**: `feat/issue-38-agent-gauges-warnings`  
**Created**: 2026-10-30  
**Status**: Draft  
**Input**: Brief `issues/2026-10-30-agent-usage-gauges-warnings.md` (Tracks GitHub issue #38). Scope: "feasible core", confirmed 2026-10-30 after an independent review against real Claude Code and Antigravity transcript structure.

## User Scenarios & Testing *(mandatory)*

### User Story 1 - Context Usage Gauge & Context Warning (Priority: P1)

A developer runs a long Claude Code or Antigravity session. Bitz shows how full the agent's context window is (tokens and percent) wherever the AI Agents telemetry metric is displayed. When usage reaches the configured threshold, Bitz raises a warning before quality degrades or auto-compaction kicks in.

**Why this priority**: Context depletion is the most common silent failure in long agent runs and the signal is reliably present in both agents' local session logs.

**Independent Test**: Replay a session-log fixture whose latest turn uses 185k of a 200k window; the AI Agents metric reads `Claude ctx 185k · 93%` and exactly one context warning is raised.

**Acceptance Scenarios**:

1. **Given** a Claude Code session is active, **When** a new model turn is logged, **Then** the AI Agents metric shows that turn's context tokens and percent of the configured window within one telemetry refresh.
2. **Given** context usage is below the threshold (default 90%), **When** a turn crosses the threshold, **Then** one context warning is raised naming the agent and the percent.
3. **Given** a context warning already fired, **When** further turns stay above the threshold, **Then** no additional context warning is raised.
4. **Given** usage dropped below the threshold (e.g. after compaction), **When** it crosses the threshold again, **Then** a new context warning is raised.
5. **Given** the configured window is smaller than the real one, **When** usage exceeds the window, **Then** the percent is capped at 100% and the raw token count stays visible.

---

### User Story 2 - Loop & Stall Warnings (Priority: P1)

A developer leaves an agent running and switches to other work. If the agent repeats the same tool call over and over, or goes silent mid-turn, Bitz warns them instead of letting the agent burn budget unnoticed.

**Why this priority**: Runaway loops and stalls waste the most time and money because nobody is watching the terminal.

**Independent Test**: Replay a fixture with four identical consecutive tool calls; exactly one loop warning is raised. Replay a mid-turn fixture with no new log output for the stall timeout and no running tool; exactly one stall warning is raised.

**Acceptance Scenarios**:

1. **Given** an agent makes the same tool call (same tool, identical input) four times in a row, **When** the fourth call is logged, **Then** one loop warning is raised.
2. **Given** three identical calls followed by a different call, **When** logged, **Then** no loop warning is raised and the streak resets.
3. **Given** an agent is mid-turn, no tool is running and it is not awaiting approval, **When** its session log gets no new output for the stall timeout (default 3 minutes), **Then** one stall warning is raised.
4. **Given** an agent finished its turn, **When** the stall timeout passes with no output, **Then** no stall warning is raised.
5. **Given** a long-running tool call (e.g. a test suite) has started and not returned, **When** the stall timeout passes, **Then** no stall warning is raised.

---

### User Story 3 - Warning Presentation & Acknowledgement (Priority: P2)

When any agent warning is active, Bitz's visor turns amber and a warning bubble stays visible until the developer clicks **Got it**, or the same agent finishes or asks for approval.

**Why this priority**: Warnings only help if they are noticed and do not vanish after a few seconds like routine status bubbles.

**Independent Test**: Raise a warning; the bubble persists past the routine auto-dismiss time, the visor is amber, and a following "working" event from any agent does not replace it. Clicking **Got it** clears both.

**Acceptance Scenarios**:

1. **Given** a warning is raised, **When** routine "working" or "almost done" events arrive, **Then** the warning bubble stays.
2. **Given** a warning from agent A is shown, **When** agent A reports done or needs approval, **Then** the warning is cleared and replaced by that bubble.
3. **Given** a warning from agent A is shown, **When** agent B reports done, **Then** agent A's warning stays.
4. **Given** a warning from agent A is shown, **When** agent B needs approval, **Then** B's approval bubble is shown, the visor stays amber, and A's warning bubble returns when B's next event supersedes the approval.
5. **Given** a warning is shown, **When** a newer warning arrives, **Then** the newer warning replaces it.
6. **Given** a warning is shown, **When** the user clicks **Got it**, **Then** the bubble disappears, the visor returns to its wellness color, and the bubble no longer takes clicks.
7. **Given** a warning is active, **When** the user chooses **Dismiss Agent Warning** in the menu bar dropdown, **Then** the warning clears exactly as with **Got it**, even if its bubble was hidden.
8. **Given** the CPU is overheating, **When** a warning is active, **Then** the visor stays overheating red.

---

### User Story 4 - "Almost Done" Heads-Up (Priority: P2)

An agent, hook or script reports that a task is in its final phase. Bitz perks up with a distinct "almost done" bubble so the developer can wrap up and get ready to review.

**Why this priority**: Valuable heads-up, but no reliable "final phase" signal exists in today's session logs, so it is limited to agents that report it.

**Independent Test**: Drop an "almost done" event into the drop-box; Bitz shows the eager bubble, which auto-dismisses.

**Acceptance Scenarios**:

1. **Given** speech bubbles are enabled, **When** an "almost done" event arrives for an enabled agent, **Then** Bitz shows a distinct "almost done" bubble that auto-dismisses after 6 seconds.
2. **Given** a warning is active, **When** an "almost done" event arrives, **Then** the warning stays visible.

---

### User Story 5 - Signal Settings & Thresholds (Priority: P3)

In Settings → AI Agents, the developer turns each signal on or off and tunes the context threshold, stall timeout and each agent's context window size.

**Why this priority**: Defaults cover most users; tuning reduces false alarms for heavy users (e.g. 1M-context models, long builds).

**Independent Test**: Turn off loop warnings; a four-call loop fixture raises no warning. Set the stall timeout to 10 minutes; a 5-minute silence raises no warning.

**Acceptance Scenarios**:

1. **Given** the AI Agents tab, **When** the user toggles a signal or changes a threshold, **Then** the change applies immediately and persists across relaunch.
2. **Given** the user sets Claude Code's window to 1M, **When** the next turn is logged, **Then** the percent is computed against 1M.

---

### Edge Cases

- **Subagents**: Claude Code subagent sessions are ignored; only the top-level session counts, so a running subagent never resets streaks or replaces the main session's gauge.
- **Startup / session switch**: Bitz seeds the gauge from the recent end of the session log but shows no bubbles for anything logged before it started watching; loop and stall state starts fresh. A turn already in progress (e.g. the first prompt of a session that just started, or Bitz launching mid-turn) is picked up silently, so its next live reply and its end still produce bubbles.
- **Multiple sessions**: only the most recently active top-level session per agent is tracked.
- **Bubbles disabled**: turning off "Show Agent Speech Bubbles" hides bubbles only; the amber visor and the gauge keep working.
- **Agent disabled**: disabling an agent immediately clears its warning and its gauge reading.
- **Duplicate done**: the session log and the existing Claude Code Stop hook may both report done; the second bubble simply replaces the first.
- **Claude desktop app quits**: Claude Code and the Claude desktop app share the agent identity `claude`; the desktop app's "finished" event (app quit) never clears a Claude Code warning or ends its turn.
- **No bubble to click**: when the warning bubble is hidden (bubbles turned off, or another agent's approval is showing), the warning can still be dismissed from the menu bar dropdown.
- **Malformed or partial log lines**: skipped silently; the next complete line is processed normally.
- **Unknown model window**: the session logs do not state the window size; a wrong setting is visible because raw tokens are shown next to the percent.

## Requirements *(mandatory)*

### Functional Requirements

| ID | Title | User Story | Priority | Status |
|----|-------|------------|----------|--------|
| FR-001 | Almost-Done Event | As a developer, I want any agent, hook or script to report "almost done" through the drop-box so Bitz shows a distinct eager bubble that auto-dismisses after 6 s. No session-log heuristic in this mission. | Medium | Open |
| FR-002 | Warning Event | As a developer, I want any agent, hook or script to report a warning with a reason through the drop-box so Bitz presents it per FR-010. | High | Open |
| FR-003 | Event Details | As an integrator, I want events to carry optional key/value details (e.g. context tokens) so that richer signals travel through the same channel; events without details, or with the four existing kinds, are accepted unchanged. | High | Open |
| FR-004 | Claude Code Session Tracking | As a developer, I want Bitz to follow my active top-level Claude Code session log (subagent sessions and sidechain lines ignored) so the agent's first reply to a prompt marks it working and a finished turn marks it done, without installing new hooks. A prompt that gets no reply (e.g. a local slash command) does not start a turn. | High | Open |
| FR-005 | Context Usage Measure | As a developer, I want context usage computed from the latest model turn's input tokens (including cached tokens, excluding output) for Claude Code and Antigravity, as tokens and percent of that agent's configured window, capped at 100%. | High | Open |
| FR-006 | Context Gauge Display | As a developer, I want the existing AI Agents telemetry metric to show the most recently active agent's context as tokens and percent (e.g. `Claude ctx 148k · 74%`) in its existing placements, refreshed within one telemetry interval. | High | Open |
| FR-007 | Context Warning | As a developer, I want one warning when context usage reaches the threshold (default 90%), re-armed after usage drops below it. | High | Open |
| FR-008 | Loop Warning | As a developer, I want one warning when the same tool call (same tool, identical input) occurs 4 times in a row; text or reasoning between calls does not break the streak; a different call, a context compaction or a new session resets it. | High | Open |
| FR-009 | Stall Warning | As a developer, I want one warning when an agent is mid-turn, its session log gets no new output for the stall timeout (default 3 min), no tool call is running and it is not awaiting approval. | High | Open |
| FR-010 | Warning Lifecycle | As a developer, I want a single persistent warning slot: a warning stays until I click **Got it**, choose **Dismiss Agent Warning** in the menu bar dropdown, or the same agent reports done or needs approval; a newer warning replaces an older one; working, almost-done and other agents' done events never replace it. Another agent's needs-approval temporarily takes the bubble while the warning stays active (amber visor); the warning bubble returns once that approval request is superseded. | High | Open |
| FR-011 | Amber Visor | As a developer, I want the visor amber while a warning is unacknowledged (overheating red keeps priority) so the alert is visible at a glance; the drawn visor and the animation's visor color input always show the same color. | Medium | Open |
| FR-012 | Signal Settings | As a developer, I want Settings → AI Agents to offer on/off per signal (almost done, context, loop, stall), context threshold (50–99%, default 90), stall timeout (1–30 min, default 3), and context window per agent (Claude Code default 200k, Antigravity default 1M; 200k / 1M / custom), applied immediately and persisted. | Medium | Open |
| FR-013 | Existing Toggles Respected | As a developer, I want "Show Agent Speech Bubbles" to hide bubbles only (visor and gauge still apply) and disabling an agent to clear its warning and gauge reading. | Medium | Open |
| FR-014 | Quiet Startup | As a developer, I want Bitz, on startup or session switch, to seed the gauge from the recent end of the session log, reset loop and stall state, and show no bubbles for lines logged before it started watching. A turn already in progress at that moment is tracked from then on: its next live reply shows working (if none was logged yet) and its end shows done. | Medium | Open |

### Non-Functional Requirements

| ID | Title | Requirement | Category | Priority | Status |
|----|-------|-------------|----------|----------|--------|
| NFR-001 | Incremental Reads | A poll with no new log output reads 0 bytes and parses 0 lines; the read position advances by exactly the appended bytes; polling is no more frequent than every 1.5 s (charter < 2% CPU budget). | Performance | High | Open |
| NFR-002 | Bounded Memory | A session log is never loaded whole; at most its last 256 KB is read on startup or session switch. | Performance | High | Open |
| NFR-003 | Timeliness | A qualifying log line produces its bubble or warning within 5 s of being written. | Performance | Medium | Open |
| NFR-004 | Privacy | Only token counts, tool names and fingerprints of tool inputs are retained, in memory only; no prompt, response or code text is stored or displayed. | Security | High | Open |
| NFR-005 | Test Isolation | New settings persist in an injectable defaults domain so 100% of new tests use an isolated suite with cleanup (AGENTS.md §3.2). | Reliability | High | Open |
| NFR-006 | Robust Parsing | Malformed, partial and unknown log lines are skipped without a crash; each case has a fixture test. | Reliability | High | Open |

### Constraints

| ID | Title | Constraint | Category | Priority | Status |
|----|-------|------------|----------|----------|--------|
| C-001 | Platform | macOS 14.0+ on Apple Silicon, Swift 6 strict concurrency, no new third-party dependencies. | Technical | High | Open |
| C-002 | Overlay Invariants | Mascot and bubble panels stay click-through and never take keyboard focus; the warning bubble takes clicks only while **Got it** is shown (AGENTS.md §2.1). Accepted trade-off: the bubble area intercepts clicks until acknowledged. | Architecture | High | Open |
| C-003 | No New Hooks | No new hooks and no new writes to the user's Claude Code settings file. | Technical | High | Open |
| C-004 | No Invented Data | No cost, rate-limit or CPU alerts in this mission; they lack a verified data source and are tracked as follow-ups. | Business | High | Open |
| C-005 | Nothing Outside Window | The overlay layout test stays green; new bubble styles stay inside their window (AGENTS.md §2.4). | Architecture | High | Open |
| C-006 | Stacked on PR #62 | Builds on the speech-bubble panel rework (#61, PR #62, unmerged at mission start); this mission's PR shows #62's commits until it merges. | Technical | Medium | Open |

### Key Entities

- **Agent Event**: a reported state change for an agent — kind (started, working, needs approval, almost done, warning, done, or a never-shown usage reading), agent, optional message, optional details.
- **Agent Warning**: the single active alert — agent, reason (context, loop, stall, or reported), text, acknowledged or not.
- **Context Reading**: per agent — tokens used in the latest turn, configured window, percent (capped at 100%).
- **Signal Settings**: per-signal on/off, context threshold, stall timeout, per-agent context window.

### Domain Language

| Canonical term | Meaning | Avoid |
|----------------|---------|-------|
| Session log | An agent's local append-only transcript of a session. Code types keep the existing `Transcript` naming (e.g. `ClaudeCodeTranscriptAdapter`); user-facing text says "session log". | "history", "chat file" |
| Turn | One cycle from a user prompt to the model's final answer | "step" (Antigravity uses step for something else) |
| Context usage | Input tokens of the latest turn, incl. cached tokens | "token usage" (ambiguous with output/cost) |
| Agent warning | A persistent alert raised by the monitor or reported by an agent | "alert", "error" |
| Almost done | A reported final-phase milestone | "progress %" |

### Assumptions

- Claude Code session logs do not reveal the context window size; the 200k Claude Code default will be wrong for 1M-context users (contexts up to ~943k observed locally). Raw tokens next to the percent make this visible.
- Only the most recently modified top-level session per agent is tracked.
- Antigravity's own approval detection is broken today (tool-call shape mismatch); fixed separately in #63.

## Success Criteria *(mandatory)*

### Measurable Outcomes

- **SC-001**: A reported "almost done" event shows the eager bubble, which auto-dismisses, in 100% of test runs.
- **SC-002**: A threshold crossing in a replayed session produces exactly one context warning; dropping below and crossing again produces exactly one more.
- **SC-003**: Four identical consecutive tool calls produce exactly one loop warning; three produce none.
- **SC-004**: A finished turn never produces a stall warning.
- **SC-005**: Each warning type can be switched off in one click from Settings.
- **SC-006**: The full automated test suite passes with zero regressions.

## Out of Scope (follow-up issues)

- Session cost ($) — no cost data in session logs.
- Rate-limit (429) detection — no verified signal.
- Runaway CPU alerts — no per-process CPU sampling today.
- Do Not Disturb / Focus integration — depends on #19 / #22.
- Alert sounds — depends on #21.
- Session-log "almost done" heuristics — no reliable final-phase signal observed.
