# Data Model: Agent Usage Gauges, "Almost Done" Milestones & Critical Warnings

## Value types (`src/Models/AgentModels.swift`)

### `AgentEventKind` (extended)
`started`, `working`, `needsApproval`, `done` (existing) + `almostDone`, `warning`, `usage`.
- `usage` is never shown; it carries readings and marks activity.

### `AgentEvent` (extended)
| Field | Type | Notes |
|-------|------|-------|
| `metadata` | `[String: String]?` | Optional; absent in old payloads. Decoding a payload without it yields `nil`. |

Metadata keys (`AgentEvent.MetadataKey`):
| Key | Used on | Value |
|-----|---------|-------|
| `reason` | `warning` | `context` \| `loop` \| `stall` \| `reported` (default `reported` when absent) |
| `contextTokens` | `usage` | Non-negative integer, latest turn's input tokens |
| `pendingTools` | `usage` | Non-negative integer |
| `turnActive` | `usage` | `true` \| `false` |
| `seed` | `usage` | `true` when produced from the startup / session-switch tail |
| `source` | any | `process` on `ProcessAgentAdapter` events (app presence); such `done` events never clear a warning or end a turn |

### `AgentWarningReason`
`context`, `loop`, `stall`, `reported` (`String` raw values matching `reason`).

### `AgentWarning`
| Field | Type |
|-------|------|
| `agentID` | `String` |
| `agentName` | `String` |
| `reason` | `AgentWarningReason` |
| `text` | `String` |

### `AgentContextReading`
| Field | Type | Rule |
|-------|------|------|
| `agentID`, `agentName` | `String` | |
| `tokens` | `Int` | ≥ 0 |
| `windowTokens` | `Int` | > 0, from settings |
| `percent` | `Int` (computed) | `min(100, tokens * 100 / windowTokens)` |
| `compactText` | `String` (computed) | e.g. `Claude ctx 148k · 74%` |

### `AgentSignalSettings` (`Codable`, `Sendable`, `Equatable`)
| Field | Default | Range |
|-------|---------|-------|
| `almostDoneEnabled` | `true` | |
| `contextWarningEnabled` | `true` | |
| `loopWarningEnabled` | `true` | |
| `stallWarningEnabled` | `true` | |
| `contextThresholdPercent` | `90` | clamped 50…99 |
| `stallTimeoutMinutes` | `3` | clamped 1…30 |
| `contextWindowTokens` | `["claude": 200_000, "antigravity": 1_000_000]` | values > 0; `contextWindow(for:)` falls back to 200_000 |

Persisted as JSON at `Bitz.AgentMonitor.SignalSettings` in the injected `UserDefaults`.

## Monitor state (`AgentMonitorService`, `@MainActor`)

| Member | Visibility | Purpose |
|--------|------------|---------|
| `activeWarning: AgentWarning?` | `@Published` read-only | Single warning slot; drives visor + warning bubble |
| `contextReadings: [String: AgentContextReading]` | private | Per-agent latest reading |
| `latestContext: AgentContextReading?` | `@Published` read-only | Most recently updated reading (gauge) |
| `signalSettings: AgentSignalSettings` | `@Published` read-write | Persists on `didSet` |
| `sessions: [String: AgentSessionState]` | private | Per-agent stall inputs |

`AgentSessionState`: `turnActive: Bool`, `awaitingApproval: Bool`, `pendingTools: Int`, `lastActivity: Date`, `stallFired: Bool`, `contextFired: Bool`.

## State transitions

### Per-agent session (monitor)
| Event | Effect |
|-------|--------|
| `working` | `turnActive = true`, `awaitingApproval = false`, `lastActivity = now`, `stallFired = false` |
| `usage` | `lastActivity = now`, `stallFired = false`; `pendingTools` / `turnActive` from metadata when present; `contextTokens` → reading + crossing check |
| `needsApproval` | `awaitingApproval = true` |
| `done` | `turnActive = false`, `awaitingApproval = false`, `pendingTools = 0` |
| stall sweep (every 5 s) | if `turnActive && !awaitingApproval && pendingTools == 0 && !stallFired && now − lastActivity ≥ timeout && stallWarningEnabled` → raise `stall`, `stallFired = true` |

### Context crossing (per agent)
- `percent ≥ threshold && !contextFired` → `contextFired = true`; raise `context` warning unless `seed` or toggle off.
- `percent < threshold` → `contextFired = false` (re-armed).

### Warning slot
```
           raise(w)                       raise(w') newer
  ∅ ───────────────────► Active(w) ──────────────────────► Active(w')
                           │  ▲
   Got it / menu Dismiss / │  │ other agent's next lifecycle
   same-agent done|        │  │ event (not usage) after its
   needsApproval (not      │  │ approval
   source=process) /       │  │
   agent disabled          ▼  │
                           ∅  Active(w), bubble = other agent's approval
```
Invariants:
- At most one `activeWarning`.
- `done` with `metadata.source == "process"` never clears `activeWarning` and never changes `turnActive`.
- `activeWarning != nil` ⇔ `WellnessPointEngine.isWarningVisorActive == true` (wired in `BitzAppDelegate`).
- While `activeWarning != nil`, `activePopup` is the warning bubble unless another agent's `needsApproval` is showing.
- `working` / `almostDone` / other agents' `done` never replace the warning bubble.
- `popupsEnabled == false` → `activePopup` stays `nil`, but `activeWarning`, visor and gauge still update.

## Warning visor input (`WellnessPointEngine`)

| Member | Visibility | Rule |
|--------|------------|------|
| `isWarningVisorActive: Bool` | `@Published` read-only | Set only via `setWarningVisor(active:)` |
| `setWarningVisor(active:)` | public | Stores the flag and calls `syncWithRive()`; never changes `currentState`, points or thresholds |
| `syncWithRive()` | public (existing) | After the per-state inputs: if `isWarningVisorActive && currentState != .overheating` → `visorColor = BitzVisorColor.amber` |

`MascotOverlayView` draws `visorColor(for: engine.currentState, warningVisorActive: engine.isWarningVisorActive)`, so the drawn visor and the Rive input always match.

## Adapter-side tracker (`AgentSessionTracker`, pure value type)

Input entries (from per-agent line parsers): `prompt`, `assistantOutput(tokens?)`, `toolCall(id?, fingerprint, name)`, `toolResult(id?)`, `turnEnd(isDone)`, `compaction`, `anyLine`.

| State | Rule |
|-------|------|
| `awaitingFirstOutput` | set by `prompt`; first `assistantOutput` emits `working`, sets `turnActive` (Claude Code) |
| `turnActive` | cleared by `turnEnd`; `turnEnd(isDone: true)` emits `done` once per turn |
| `pendingIDs` | `toolCall` inserts, `toolResult` removes; Antigravity: replaced on each `PLANNER_RESPONSE`, cleared by any later line |
| `loop` | same fingerprint → `count += 1`, else `count = 1`, `fired = false`; `count == 4 && !fired` → emit `warning(loop)`; reset by `compaction` / new session |
| `latestTokens` | last non-nil `assistantOutput.tokens` |
| `prime(fromSeed:)` | after `reset()`: silently ingest the seed entries (events discarded), then clear the loop streak; restores `turnActive` / `awaitingFirstOutput` / pending tools / `latestTokens` for a turn already in progress |
