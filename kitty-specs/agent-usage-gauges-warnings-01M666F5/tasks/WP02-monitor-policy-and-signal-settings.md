---
work_package_id: WP02
title: Monitor Policy & Signal Settings
dependencies:
- WP01
requirement_refs:
- FR-001
- FR-002
- FR-005
- FR-007
- FR-009
- FR-010
- FR-012
- FR-013
- FR-014
- NFR-003
- NFR-005
planning_base_branch: feat/issue-38-agent-gauges-warnings
merge_target_branch: feat/issue-38-agent-gauges-warnings
branch_strategy: Planning artifacts for this mission were generated on feat/issue-38-agent-gauges-warnings. During /spec-kitty.implement this WP may branch from a dependency-specific base, but completed changes must merge back into feat/issue-38-agent-gauges-warnings unless the human explicitly redirects the landing branch.
subtasks:
- T007
- T008
- T009
- T010
- T011
- T012
- T013
- T044
phase: Phase 1 - Policy
history:
- !!omap
  - at: '2026-10-30T13:37:15Z'
  - actor: system
  - action: Prompt generated via /spec-kitty.tasks
agent_profile: implementer-ivan
authoritative_surface: src/Services/AgentMonitorService.swift
create_intent:
- Tests/BitzTests/AgentSignalPolicyTests.swift
execution_mode: code_change
model: ''
owned_files:
- src/Services/AgentMonitorService.swift
- Tests/BitzTests/AgentMonitorServiceTests.swift
- Tests/BitzTests/AgentSignalPolicyTests.swift
- src/Services/ProcessAgentAdapter.swift
- Tests/BitzTests/ProcessAgentAdapterTests.swift
role: implementer
tags: []
task_type: implement
tracker_refs: []
---

# Work Package Prompt: WP02 – Monitor Policy & Signal Settings

## ⚡ Do This First: Load Agent Profile

Use the `/ad-hoc-profile-load` skill to load the agent profile specified in the frontmatter, and behave according to its guidance before parsing the rest of this prompt.

- **Profile**: `implementer-ivan`
- **Role**: `implementer`
- **Agent/tool**: `claude`

If no profile is specified, run `spec-kitty agent profile list` and select the best match for this work package's `task_type` and `authoritative_surface`.

---

## ⚠️ IMPORTANT: Review Feedback

- **Has review feedback?**: Check the `review_ref` field in the event log or the Activity Log below.
- **You must address all feedback** before your work is complete.

---

## Objectives & Success Criteria

`AgentMonitorService` becomes the single owner of signal policy (decision `policy_placement`, research R1/R8). Done when:
- Settings persist through an injected `UserDefaults` (FR-012 model, NFR-005).
- `usage` events update per-agent context readings and raise one context warning per threshold crossing; seeded readings never warn (FR-005, FR-007, FR-014).
- A 5 s stall sweep raises one stall warning per stall under the exact FR-009 conditions.
- The warning slot follows FR-010 exactly, including the approval override and restoration.
- Almost-done popups show for 6 s unless a warning is active or the toggle is off (FR-001).
- Disabling an agent clears its warning, readings and session state (FR-013).
- `done` events from `ProcessAgentAdapter` (tagged `source = process`) never clear a warning or end a turn (spec Edge Case "Claude desktop app quits").
- Every existing `AgentMonitorServiceTests` case passes unchanged; new `AgentSignalPolicyTests` cover every acceptance scenario of User Stories 1–4 at the policy level.
- No new compiler warnings, measured with a clean build (`xcrun swift build --scratch-path "$(mktemp -d)" 2>&1 | grep 'warning:' | sort -u`): the only allowed lines are the 3 pre-existing Swift 6 warnings at `src/Views/MascotOverlayView.swift:142` (from #61), which WP06 removes. Incremental builds hide warnings, so don't use them for this check (charter quality gate; SwiftLint is not configured in this repo).

## Context & Constraints

- Read: `data-model.md` (Monitor state, State transitions, Warning slot invariants), `research.md` R1, R4, R7, R8, `contracts/agent-event-contract.md` (Kinds table).
- WP01 placed `case .almostDone, .warning, .usage: break` in `handleEvent`; replace it.
- `@MainActor` class; keep the existing `clock` injection and the 60 s stale-event drop.
- AGENTS.md §3.2: new tests use `UserDefaults(suiteName:)` + `defer { removePersistentDomain }`.

## Branch Strategy

- **Planning base branch**: `feat/issue-38-agent-gauges-warnings`
- **Merge target branch**: `feat/issue-38-agent-gauges-warnings`
- Execution worktrees are allocated per computed lane from `lanes.json`.
- Implementation command: `spec-kitty agent action implement WP02 --agent claude`

## Subtasks & Detailed Guidance

### Subtask T007 – Inject `UserDefaults`; persist `signalSettings`

- **Steps**:
  1. Add `private let userDefaults: UserDefaults` and an init parameter `userDefaults: UserDefaults = .standard` (after `clock`). Replace every `UserDefaults.standard` in the file with `userDefaults` (custom agents, disabled flags, popups flag) — default behaviour unchanged.
  2. Add:
     ```swift
     private static let signalSettingsKey = "Bitz.AgentMonitor.SignalSettings"
     @Published public var signalSettings: AgentSignalSettings {
         didSet {
             let clamped = signalSettings.clamped()
             if clamped != signalSettings { signalSettings = clamped; return }
             if let data = try? JSONEncoder().encode(signalSettings) { userDefaults.set(data, forKey: Self.signalSettingsKey) }
             recomputeContextReadings()   // window changes apply immediately (US5 scenario 2)
         }
     }
     ```
     Load in `init` from the key (decode → `clamped()`), else `.default`. Assign before `loadCatalog()`; note `didSet` does not run during `init`.
  3. `popupsEnabled.didSet`: when switched back on and `activeWarning != nil`, call `presentWarningBubble()` (T009).
- **Files**: `src/Services/AgentMonitorService.swift`

### Subtask T008 – Session state, context readings, crossing

- **Steps**:
  1. Private state (see `data-model.md`):
     ```swift
     private struct SessionState {
         var turnActive = false, awaitingApproval = false
         var pendingTools = 0
         var lastActivity: Date
         var stallFired = false, contextFired = false
     }
     private var sessions: [String: SessionState] = [:]
     private var contextReadings: [String: AgentContextReading] = [:]
     @Published public private(set) var latestContext: AgentContextReading? = nil
     ```
  2. Update session state per event (after the stale + enabled guards), exactly per the data-model transition table: `working`, `usage`, `needsApproval`, `done`, `almostDone` (`lastActivity` only).
  3. `usage` with `contextTokens`:
     ```swift
     let reading = AgentContextReading(agentID: id, agentName: name, tokens: tokens,
                                       windowTokens: signalSettings.contextWindow(for: id))
     contextReadings[id] = reading; latestContext = reading
     if reading.percent >= signalSettings.contextThresholdPercent {
         if !state.contextFired {
             state.contextFired = true
             if !event.isSeed && signalSettings.contextWarningEnabled {
                 raiseWarning(AgentWarning(agentID: id, agentName: name, reason: .context,
                     text: "⚠️ \(name): context at \(reading.percent)%! Consider /compact soon."))
             }
         }
     } else { state.contextFired = false }
     ```
  4. `usage` never touches `activeAgents` or `activePopup` (except via `raiseWarning`).
  5. `recomputeContextReadings()`: rebuild each reading with the current window; refresh `latestContext` for the same agent. No warnings from recompute.
- **Notes**: `latestContext` is the most recently *updated* reading (FR-006 consumes it in WP07).

### Subtask T009 – Warning slot

- **Steps**:
  1. `@Published public private(set) var activeWarning: AgentWarning? = nil`
  2. `private var approvalOverrideAgentID: String? = nil` — set when another agent's approval bubble covers the warning.
  3. `private func raiseWarning(_ w: AgentWarning)` — `activeWarning = w` (newer replaces older), `approvalOverrideAgentID = nil`, `presentWarningBubble()`.
  4. `private func presentWarningBubble()` — if `popupsEnabled`, `displayPopup(text: w.text, kind: .warning, agentName: w.agentName, durationSeconds: nil)`.
  5. `public func acknowledgeWarning()` — `activeWarning = nil`, `approvalOverrideAgentID = nil`, clear `activePopup` if its kind is `.warning`.
  6. `warning` events: `let w = AgentWarning(agentID:…, reason: event.warningReason, text: event.message ?? "⚠️ \(name) reported a problem")`; raise only if `signalSettings.isEnabled(reason)`.
  7. Keep `dismissPopup()` as is (clears the bubble only, not the warning).
- **Invariant**: at most one `activeWarning`; it is cleared only by acknowledge, the same agent's `done` / `needsApproval`, a newer warning, or disabling that agent.

### Subtask T010 – Popup priority

Rewrite the popup part of `handleEvent` so the following table holds (W = active warning of agent A):

| Event | No warning | Warning W of agent A |
|-------|-----------|----------------------|
| `working` (any) | 4 s cyan popup (existing) | no popup change; if from the override agent → clear override, `presentWarningBubble()` |
| `almostDone` (any) | 6 s popup if `almostDoneEnabled` | same as `working` row |
| `needsApproval` from A | persistent popup (existing) | clear W, persistent popup |
| `needsApproval` from B | — | persistent popup, `approvalOverrideAgentID = B`, W stays |
| `done` from A | 6 s popup (existing) | clear W, 6 s popup — unless `event.isProcessPresence` (T044): then treat as the `done` from B row |
| `done` from B | — | no popup change; if B is the override agent → clear override, `presentWarningBubble()` |
| `warning` | raise | newer replaces W |
| `usage` | no popup | no popup (may raise a context warning) |

- Default messages: `almostDone` → `event.message ?? "✨ \(name) is almost done!"`.
- `activeAgents` updates stay exactly as today (`started`/`working`/`needsApproval` insert, `done` removes); `almostDone` inserts.
- `popupsEnabled == false` → no popups at all, but warning/session/reading state still updates.

### Subtask T011 – Stall sweep

- **Steps**:
  1. `private var stallTask: Task<Void, Never>?`; start in `startMonitoring()`:
     ```swift
     stallTask = Task { @MainActor [weak self] in
         while !Task.isCancelled {
             try? await Task.sleep(nanoseconds: 5_000_000_000)
             self?.evaluateStalls()
         }
     }
     ```
     Cancel + nil in `stopMonitoring()`; also clear `sessions`, `contextReadings`, `latestContext`, `activeWarning` there.
  2. `public func evaluateStalls()` (public for tests): for each session with `turnActive && !awaitingApproval && pendingTools == 0 && !stallFired && clock().timeIntervalSince(lastActivity) >= Double(signalSettings.stallTimeoutMinutes) * 60 && signalSettings.stallWarningEnabled` and the agent still enabled → `stallFired = true`, raise `.stall` with text `"⚠️ \(name) may be stuck: no output for \(minutes) min."` (agent name from the catalog).
  3. Any later `working`/`usage` resets `stallFired` (T008 table).
- **Notes**: Sweep cost is O(agents) every 5 s on the main actor; negligible.

### Subtask T012 – Disabled agent clearing

- In `setAgentEnabled(id:isEnabled:)` when disabling: remove `sessions[id]`, `contextReadings[id]`; nil `latestContext` if it belongs to `id`; if `activeWarning?.agentID == id` → `acknowledgeWarning()`; if `approvalOverrideAgentID == id` → clear it and `presentWarningBubble()` when a warning remains.

### Subtask T044 – Ignore app-presence `done` for warnings and turns

- **Why**: the Claude desktop app (`ProcessAgentAdapter`, bundle `com.anthropic.claudefordesktop`) and Claude Code share agent ID `claude`; quitting the app emits `done` for `claude` (analysis finding I2, research R8).
- **Steps**:
  1. `src/Services/ProcessAgentAdapter.swift`: pass `metadata: [AgentEvent.MetadataKey.source: "process"]` on every `AgentEvent` it creates (started, working, done). No other behaviour change.
  2. `AgentMonitorService.handleEvent`: for `done` with `event.isProcessPresence`: keep the existing `activeAgents.remove` and, when no warning is active, the existing 6 s popup; but never clear `activeWarning`, never touch `sessions[id]` (`turnActive`, `pendingTools`), and when a warning is active follow the "`done` from B" row.
  3. `Tests/BitzTests/ProcessAgentAdapterTests.swift`: extend `testDetectsStartedAndExitedAgent` (or add a test) to assert `isProcessPresence == true` on emitted events.

### Subtask T013 – Tests

- Keep `Tests/BitzTests/AgentMonitorServiceTests.swift` green; only touch it if an assertion breaks because of the new `userDefaults` parameter (it should not).
- Create `Tests/BitzTests/AgentSignalPolicyTests.swift` (`@MainActor final class`), each test with its own suite:
  ```swift
  private func makeService(now: @escaping @Sendable () -> Date = { Date() }) -> (AgentMonitorService, UserDefaults, String) // suite name for cleanup
  ```
  Use a mutable clock box (`final class ClockBox: @unchecked Sendable { var now = Date() }`) to advance time. Event helpers: `usage(_ id:, tokens:, seed:)`, `event(_ id:, _ kind:, reason:)`.
- Required tests (names are suggestions):
  1. `testSettingsPersistAndReloadClamped` (threshold 120 stored → 99 after reload; isolated suite).
  2. `testContextWarningFiresOnceAndRearms` (180k/200k → warning; 190k → none; 100k → none; 185k → second warning).
  3. `testSeedReadingAboveThresholdDoesNotWarnButMarksFired`.
  4. `testContextWarningToggleOffSuppressesWarningButKeepsReading`.
  5. `testWindowChangeRecomputesPercent` (200k → 1M window halves… check exact percent).
  6. `testWorkingAndAlmostDoneDoNotReplaceWarning`.
  7. `testSameAgentDoneClearsWarning` and `testSameAgentApprovalClearsWarning`.
  8. `testOtherAgentDoneKeepsWarning`.
  9. `testOtherAgentApprovalOverridesThenWarningReturns` (B approval → popup kind `.needsApproval`, `activeWarning` still set; B `working` → popup back to `.warning`).
  10. `testNewerWarningReplacesOlder`.
  11. `testAcknowledgeClearsWarningAndBubble`.
  12. `testAlmostDonePopupAndToggle` (6 s expiry via `expiresAt`, none when toggle off).
  13. `testPopupsDisabledKeepsWarningStateWithoutBubble` and re-enable shows the warning bubble.
  14. `testStallFiresOnceAfterTimeout` (working → +2:59 none → +3:00 one → +10 min none).
  15. `testNoStallWhilePendingToolOrAwaitingApprovalOrAfterDone`.
  16. `testActivityResetsStall` (usage after stall → can fire again after another timeout).
  17. `testDisablingAgentClearsWarningReadingAndSession`.
  18. `testReportedWarningAlwaysShownAndLoopToggleRespected`.
  19. `testProcessPresenceDoneDoesNotClearWarningOrEndTurn` (warning for `claude`, then `done` with `source = process` → warning stays, stall still fires after the timeout).

## Test Strategy

- TDD: write the failing policy test per row of the T010 table before changing `handleEvent`.
- Run `xcrun swift test --filter AgentSignalPolicyTests`, `--filter AgentMonitorServiceTests`, then the full suite.

## Risks & Mitigations

- **Popup regressions**: the existing `testAgentEventLifecycle`-style tests guard working/approval/done timings; do not change their timings (4 s / persistent / 6 s).
- **didSet recursion** in `signalSettings`: the clamp-and-return pattern assigns at most once.
- **Main-actor sweep after stop**: `stopMonitoring()` cancels the task; `[weak self]` avoids retain cycles.

## Review Guidance

- Walk the T010 table against the code line by line.
- Confirm no `UserDefaults.standard` remains in the file.
- Confirm `usage` never produces a bubble and never changes `activeAgents`.

## Activity Log

- 2026-10-30T13:37:15Z – system – Prompt created.
