# Agent Approval & Security Gate Contract

## Purpose
Specifies the architectural contract for safe, request-scoped, single-use agent approval dispatch without keystroke injection.

## Invariants
1. **Zero Keystroke Injection (NFR-002)**: The approval store dispatches decisions strictly through explicit hook response channels (atomic file or socket writes) specified in `AgentApprovalRequest.decisionChannel`. It MUST NEVER simulate keyboard events or synthetic typing.
2. **Single-Use Consumption (C-003)**: An approval request token can only be consumed once. On `submitDecision`, the token is immediately removed from `pendingRequests` before channel dispatch. Subsequent calls for the same token return `.tokenNotFound`.
3. **Automatic TTL Expiry**: Approval tokens have a strict time-to-live (default 300 seconds). Attempting to approve an expired token yields `.tokenExpired` and drops the decision.
4. **Channel Availability Gating**: The `"APPROVE"` button is conditionally rendered only when `request.decisionChannel != nil`. Agents lacking a hook response channel only expose `"JUMP"` and `"DIFF"`.

## Interfaces
- `AgentApprovalRequest`: Immutable value struct containing `requestID`, `agentID`, `toolName`, `commandSummary`, `decisionChannel`, `createdAt`, `expiresAt`.
- `AgentApprovalStore`: `@MainActor public final class` managing active requests, registering requests from `AgentEvent.metadata`, dispatching decisions, and sweeping expired tokens.
