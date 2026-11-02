# Decision Moment `01M66FW0HB2C3MAT2X927BN0RG`

- **Mission:** `agent-usage-gauges-warnings-01M666F5`
- **Origin flow:** `plan`
- **Slot key:** `plan.architecture.policy-placement`
- **Input key:** `policy_placement`
- **Status:** `resolved`
- **Created:** `2026-10-30T13:26:59.371662+00:00`
- **Resolved:** `2026-10-30T13:31:48.504484+00:00`
- **Opened by:** `cli`
- **Other answer:** `false`

## Question

Where should warning policy (thresholds, stall timer, warning slot, toggles) live?

## Options

- AgentMonitorService evaluates; adapters only parse and emit readings
- Adapters detect and emit finished warnings
- Other

## Final answer

AgentMonitorService evaluates; adapters only parse and emit readings (usage kind) plus fixed-threshold loop warnings

## Rationale

_(none)_

## Change log

- `2026-10-30T13:26:59.371662+00:00` — opened
- `2026-10-30T13:31:48.504484+00:00` — resolved (final_answer="AgentMonitorService evaluates; adapters only parse and emit readings (usage kind) plus fixed-threshold loop warnings")
