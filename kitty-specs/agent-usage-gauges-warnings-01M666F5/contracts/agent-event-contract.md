# Contract: Agent Event v2 (drop-box files and adapter events)

Applies to JSON files dropped into `~/Library/Application Support/Bitz/agent-events/*.json` (`DropboxAgentAdapter`) and to `AgentEvent` values emitted by in-process adapters. `docs/agent-dropbox-event.schema.json` is updated to match in IC-01.

## Payload

```json
{
  "id": "6f1c…",                     // optional UUID
  "agentID": "claude",               // required
  "agentName": "Claude",             // required
  "kind": "warning",                 // required, see kinds
  "message": "Claude: context at 92%!", // optional display text
  "timestamp": "2026-10-30T11:00:00Z",  // required ISO-8601; events older than 60 s are dropped
  "metadata": { "reason": "context" }   // optional, string → string
}
```

## Kinds

| Kind | Shown | Bubble | Notes |
|------|-------|--------|-------|
| `started` | no | — | existing |
| `working` | yes | 4 s, cyan | existing; never replaces an active warning |
| `needsApproval` | yes | persistent, amber | existing; clears same-agent warning; takes the bubble over another agent's warning |
| `done` | yes | 6 s, green | existing; clears same-agent warning unless `metadata.source = process` (app presence) |
| `almostDone` | yes | 6 s, distinct eager style | new; toggle `almostDoneEnabled`; never replaces an active warning |
| `warning` | yes | persistent, warning style + **Got it** | new; `metadata.reason` ∈ `context` `loop` `stall` `reported` (default `reported`); toggles apply to `context` / `loop` / `stall` |
| `usage` | no | — | new; readings + activity heartbeat |

## Metadata keys

| Key | Kind | Value | Effect |
|-----|------|-------|--------|
| `reason` | `warning` | `context` \| `loop` \| `stall` \| `reported` | selects toggle + warning text |
| `contextTokens` | `usage` | integer string | context reading; percent uses the agent's configured window |
| `pendingTools` | `usage` | integer string | stall suppressed while > 0 |
| `turnActive` | `usage` | `true` \| `false` | stall only while `true` |
| `seed` | `usage` | `true` | always emitted when an adapter attaches to a session log; carries the primed `turnActive` / `pendingTools` and `contextTokens` when known; reading updates gauge; no context warning for this reading |
| `source` | any | `process` | set by Bitz's process adapter (app presence); a `done` with this source never clears a warning or ends a turn. Integrators should omit it. |

## Compatibility

- Payloads without `metadata` and with the four original kinds decode exactly as before.
- Unknown `kind` values fail decoding and the file is discarded (existing behaviour).
- Non-integer `contextTokens` / `pendingTools` values are ignored (reading skipped), never crash.

## Example: hook reporting "almost done"

```bash
dir="$HOME/Library/Application Support/Bitz/agent-events"; mkdir -p "$dir"
id=$(uuidgen | tr '[:upper:]' '[:lower:]'); ts=$(date -u +%Y-%m-%dT%H:%M:%SZ)
printf '{"id":"%s","agentID":"claude","agentName":"Claude","kind":"almostDone","message":"✨ Claude is almost done!","timestamp":"%s"}\n' "$id" "$ts" > "$dir/$id.json"
```
