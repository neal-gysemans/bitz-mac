---
work_package_id: WP06
title: Warning Bubble, Amber Visor & App Wiring
dependencies:
- WP02
- WP04
requirement_refs:
- C-002
- C-005
- C-006
- FR-001
- FR-010
- FR-011
planning_base_branch: feat/issue-38-agent-gauges-warnings
merge_target_branch: feat/issue-38-agent-gauges-warnings
branch_strategy: Planning artifacts for this mission were generated on feat/issue-38-agent-gauges-warnings. During /spec-kitty.implement this WP may branch from a dependency-specific base, but completed changes must merge back into feat/issue-38-agent-gauges-warnings unless the human explicitly redirects the landing branch.
subtasks:
- T026
- T027
- T028
- T029
- T030
- T031
- T045
- T046
phase: Phase 3 - Presentation
history:
- !!omap
  - at: '2026-10-30T13:37:15Z'
  - actor: system
  - action: Prompt generated via /spec-kitty.tasks
agent_profile: implementer-ivan
authoritative_surface: src/Views/
create_intent:
- Tests/BitzTests/AgentWarningPresentationTests.swift
- Tests/BitzTests/AgentSignalIntegrationTests.swift
execution_mode: code_change
model: ''
owned_files:
- src/Views/SpeechBubbleView.swift
- src/Views/MascotOverlayView.swift
- src/App/BitzApp.swift
- Tests/BitzTests/OverlayTestFixtures.swift
- Tests/BitzTests/MascotOverlayLayoutTests.swift
- Tests/BitzTests/SpeechBubblePanelTests.swift
- Tests/BitzTests/AgentWarningPresentationTests.swift
- src/Services/WellnessPointEngine.swift
- Tests/BitzTests/WellnessPointEngineTests.swift
- Tests/BitzTests/MenuBarContentViewTests.swift
- Tests/BitzTests/AgentSignalIntegrationTests.swift
role: implementer
tags: []
task_type: implement
tracker_refs: []
---

# Work Package Prompt: WP06 – Warning Bubble, Amber Visor & App Wiring

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

Present the WP02 policy on the mascot, wire the new adapter, and prove the pipeline end to end (FR-001, FR-010, FR-011, C-002, C-005, SC-002). Done when:
- A `.warning` agent popup renders a distinct warning bubble with a **GOT IT** button that calls `agentMonitor.acknowledgeWarning()`; only this bubble (and the existing update bubble) takes clicks.
- A `.almostDone` popup renders a distinct eager style (no button, click-through).
- While `agentMonitor.activeWarning != nil`, `WellnessPointEngine.isWarningVisorActive` is `true`; the Rive `visorColor` input **and** the drawn visor are Amber (`BitzVisorColor.amber` / `#FFB000`), except in `.overheating` where both stay red. They never disagree (charter DIR-004, research R10).
- The menu bar dropdown shows the active warning and a **Dismiss Agent Warning** button whenever a warning is active (spec FR-010, US3 scenario 7).
- The app runs `ClaudeCodeTranscriptAdapter` alongside the existing adapters and creates `AgentMonitorService` with the delegate's injected `userDefaults`.
- An integration test replays a Claude Code session through the real adapter into the real monitor (SC-002).
- Layout tests prove both new bubbles fit their window at the largest scale; the click-through test proves the bubble reverts to `ignoresMouseEvents = true` right after **GOT IT**.
- A clean build (`xcrun swift build --scratch-path "$(mktemp -d)" 2>&1 | grep -c 'warning:'`) prints `0`: this WP also removes the 3 pre-existing Swift 6 warnings at `src/Views/MascotOverlayView.swift:142` (from #61; see T027 step 3). Charter quality gate; SwiftLint is not configured in this repo.

## Context & Constraints

- AGENTS.md §2.1/§2.2/§2.4: panels never become key; bubble panel takes clicks only while an interactive bubble shows; nothing drawn outside its window (`MascotOverlayLayoutTests`).
- Existing interactivity path: `SpeechBubbleContent.isInteractive` (`src/Views/SpeechBubbleView.swift:12-17`) → `BitzAppDelegate.updatePanelsInteractivity()` (`src/App/BitzApp.swift:221-234`), re-run on every `activePopup` change by `bubbleInteractivityCancellable` (`BitzApp.swift:111-119`). Reuse it; add nothing parallel.
- `WellnessPointEngine.syncWithRive()` (`src/Services/WellnessPointEngine.swift:436-482`) pushes per-state Rive inputs; `SpyRiveController` (same file, ~line 72) records them for tests.
- WP01 left placeholder colours for the new kinds in `agentPopupColors`; replace them.
- Stacks on PR #62's bubble window (C-006); do not touch `SpeechBubblePanel.swift`.
- Read `research.md` R8/R10 and `data-model.md` "Warning visor input".

## Branch Strategy

- **Planning base branch**: `feat/issue-38-agent-gauges-warnings`
- **Merge target branch**: `feat/issue-38-agent-gauges-warnings`
- Execution worktrees are allocated per computed lane from `lanes.json`.
- Implementation command: `spec-kitty agent action implement WP06 --agent claude`

## Subtasks & Detailed Guidance

### Subtask T026 – Warning + almost-done bubbles, interactivity

- **File**: `src/Views/SpeechBubbleView.swift`
- **Steps**:
  1. `SpeechBubbleContent.isInteractive`: return `true` for `.update` **and** for `.agentPopup(p)` where `p.kind == .warning`. Update the doc comment ("Update alert and agent warning bubbles have buttons…").
  2. In `bubble`, for `.agentPopup(let popup)`: if `popup.kind == .warning` → `warningBubbleView(popup)`; else existing `textBubble`.
  3. `warningBubbleView`: mirror `updateBubbleView` — `VStack(spacing: 5)` with the text (same font/lineLimit/minimumScaleFactor as `textBubble`) and one capsule button `GOT IT` (black text on amber capsule) calling `agentMonitor.acknowledgeWarning()`; stroke Amber `#FFB000`, fill `Color(red: 0.45, green: 0.12, blue: 0.04).opacity(0.96)`; `.frame(maxWidth: Self.maxBubbleWidth)`; shadow like the others.
  4. `agentPopupColors`: `.almostDone` → stroke Magenta `#FF007F`, fill `Color(red: 0.42, green: 0.10, blue: 0.55).opacity(0.96)`; `.warning` → the warning pair above; `.usage` → existing cyan pair (never shown).
- **Notes**: Keep the priority order in `SpeechBubbleContent.current` unchanged (agent popup first).

### Subtask T027 – Warning visor through the engine [P]

- **Files**: `src/Services/WellnessPointEngine.swift`, `src/Views/MascotOverlayView.swift`
- **Steps**:
  1. Engine:
     ```swift
     /// External alert (e.g. an agent warning) shown as an Amber visor; never changes state, points or thresholds.
     @Published public private(set) var isWarningVisorActive = false
     public func setWarningVisor(active: Bool) {
         guard active != isWarningVisorActive else { return }
         isWarningVisorActive = active
         syncWithRive()
     }
     ```
     At the end of `syncWithRive()` (after the state `switch`): `if isWarningVisorActive && currentState != .overheating { rive.setInput(BitzRiveInputName.visorColor, value: BitzVisorColor.amber) }`. Every existing state transition already calls `syncWithRive()`, so the override survives state changes.
  2. `MascotOverlayView`: add
     ```swift
     /// The warning visor is Amber except while overheating (red wins); mirrors `WellnessPointEngine.syncWithRive()`.
     public static func visorRGB(for state: BitzState, warningVisorActive: Bool) -> (red: Double, green: Double, blue: Double) {
         warningVisorActive && state != .overheating ? visorRGB(for: .overworked) : visorRGB(for: state)
     }
     public static func visorColor(for state: BitzState, warningVisorActive: Bool) -> Color
     ```
     and make the private `visorColor` use `engine.isWarningVisorActive`. Keep the one-argument helpers unchanged (used by `SpeechBubbleView`, `MascotOverlayPanelTests`, `SettingsViewsTests`). **No `agentMonitor` parameter on `MascotOverlayView`.**
  3. Remove the 3 pre-existing Swift 6 warnings at `MascotOverlayView.swift:142`: the `.onGeometryChange` transform closure is `Sendable` but reads main-actor `Self.canvasSpace`, `isLoafPosture` and `BitzCharacterView.earOverflow(isLoafPosture:)`. Compute those values into local `let`s in `body` before the modifier and capture the locals; behaviour must stay identical (`SpeechBubblePanelTests.testMascotViewReportsEarTopForPostureAndHUD` and `MascotOverlayLayoutTests.testEarOverflowMatchesDrawnEarTips` stay green).
- **Notes**: Wellness thresholds, `currentState` and the other Rive inputs are untouched.

### Subtask T028 – App wiring

- **File**: `src/App/BitzApp.swift`
- **Steps**:
  1. Next to the existing adapters (`BitzApp.swift:71-75`): `let claudeAdapter = ClaudeCodeTranscriptAdapter()` and include it in the adapters array.
  2. `AgentMonitorService(adapters: [...], userDefaults: userDefaults)` — the delegate's injected defaults (NFR-005).
  3. Map the warning slot to the engine (store the `AnyCancellable` like `bubbleInteractivityCancellable`):
     ```swift
     warningVisorCancellable = agentMonitor.$activeWarning
         .map { $0 != nil }
         .removeDuplicates()
         .receive(on: DispatchQueue.main)
         .sink { [weak self] active in self?.engine.setWarningVisor(active: active) }
     ```
  4. Leave `bubbleInteractivityCancellable` as is (it already reacts to `$activePopup`).

### Subtask T045 – Menu bar "Dismiss Agent Warning"

- **File**: `src/App/BitzApp.swift` (`BitzMenuBarContentView`, ~line 486)
- **Steps**:
  1. When `agentMonitor.activeWarning` is non-nil: `Divider()`, its text in `.caption` `.orange`, and `Button("Dismiss Agent Warning") { agentMonitor.acknowledgeWarning() }`.
  2. Hide the existing blue `agentPopup.text` line when `agentPopup.kind == .warning` (avoid showing the same text twice).
  3. Keep the dropdown otherwise unchanged (the streamlined-menu tests must stay green).
- **Test** (`Tests/BitzTests/MenuBarContentViewTests.swift`): `testMenuBarShowsDismissForActiveWarning` — isolated defaults, `AgentMonitorService(adapters: [], userDefaults: defaults)`, raise a warning via `handleEvent`, evaluate `body`; then call `acknowledgeWarning()` (the button's action) and assert `activeWarning == nil` and `body` still evaluates.

### Subtask T029 – Fixtures + layout tests

- **Files**: `Tests/BitzTests/OverlayTestFixtures.swift`, `Tests/BitzTests/MascotOverlayLayoutTests.swift`
- **Steps**:
  1. `OverlayFixture`: construct `agentMonitor` with the fixture's isolated `defaults`; add helpers:
     ```swift
     func showWarning(_ text: String) { agentMonitor.handleEvent(AgentEvent(agentID: "claude", agentName: "Claude", kind: .warning, message: text, metadata: [AgentEvent.MetadataKey.reason: "reported"])) }
     func showAlmostDone(_ text: String) { agentMonitor.handleEvent(AgentEvent(agentID: "claude", agentName: "Claude", kind: .almostDone, message: text)) }
     ```
  2. Layout tests (mirror `testUpdateBubbleAtLargestScaleIsNotClippedByItsWindow`):
     - `testWarningBubbleWithButtonAtLargestScaleIsNotClippedByItsWindow` (long text, max scale).
     - `testAlmostDoneBubbleIsNotClippedByItsWindow`.
     - `testMascotWithWarningVisorStaysInsidePanel` (`fixture.engine.setWarningVisor(active: true)`).

### Subtask T030 – Click-through test

- **File**: `Tests/BitzTests/SpeechBubblePanelTests.swift`
- Add `testWarningBubbleTakesClicksOnlyUntilAcknowledged` modelled on `testOnlyABubbleWithButtonsTakesClicks` (synchronous, same comment about main-queue callbacks):
  1. Delegate with isolated defaults; `setupOverlayPanel()`.
  2. `handleEvent(.warning …)` → `spinRunLoop { !bubble.ignoresMouseEvents }`; mascot panel still click-through; `spinRunLoop { delegate.engine.isWarningVisorActive }`.
  3. `agentMonitor.acknowledgeWarning()` → `spinRunLoop { bubble.ignoresMouseEvents }` and `!delegate.engine.isWarningVisorActive`.
  4. `handleEvent(.almostDone …)` → bubble stays click-through.
  5. Assert `bubble.canBecomeKey == false` throughout (AGENTS.md §2.2).

### Subtask T031 – Presentation + engine unit tests

- **Files**: `Tests/BitzTests/AgentWarningPresentationTests.swift` (new, `@MainActor`), `Tests/BitzTests/WellnessPointEngineTests.swift`
- Cases:
  1. `testVisorAmberWhileWarningVisorActiveForEveryStateExceptOverheating` — loop over `BitzState` cases with `MascotOverlayView.visorRGB(for:warningVisorActive:)`.
  2. `testVisorUnchangedWithoutWarningVisor`.
  3. `testOnlyWarningAgentPopupIsInteractive` — `SpeechBubbleContent.agentPopup` for each `AgentEventKind` (only `.warning` true); `.update` still true.
  4. `WellnessPointEngineTests.testWarningVisorDrivesRiveAmberAndMatchesDrawnVisor` — `SpyRiveController`; balanced → `setWarningVisor(active: true)` → `floatInputs["visorColor"] == BitzVisorColor.amber`, `currentState == .balanced`; thermal warning → red; clear thermal → amber again; `setWarningVisor(active: false)` → cyan. For each step assert the drawn RGB from `MascotOverlayView.visorRGB(for:warningVisorActive:)` equals the colour of the pushed Rive value (amber/red/cyan) — the "always match" rule.

### Subtask T046 – End-to-end replay test (SC-002)

- **File**: `Tests/BitzTests/AgentSignalIntegrationTests.swift` (new, `@MainActor`)
- **Approach**: temp `projects/<p>/<s>.jsonl`; `ClaudeCodeTranscriptAdapter(projectsURL:clock:)` with a mutable clock box; `adapter.setHandlerForTesting { events.append($0) }` (lock-protected collector); call `adapter.checkForUpdates()` after each append, then feed the collected events in order to `AgentMonitorService(adapters: [], clock: { clockBox.now }, userDefaults: isolated)` via `handleEvent`. Use small JSON line builders like WP04's tests.
- Cases:
  1. `testReplayedSessionCrossingThresholdWarnsExactlyOnce` — window 200k: turns at 120k, 185k, 190k tokens → exactly one `.context` warning; compaction-sized turn at 60k then 182k → exactly one more.
  2. `testReplayedLoopOfFourIdenticalCallsWarnsOnce`.
  3. `testReplayedFinishedTurnNeverStalls` — full turn ending `end_turn`, advance clock 10 min, `evaluateStalls()` → no warning.
  4. `testReplayedMidTurnSilenceStalls` — turn with tool result returned and no further lines, advance clock past 3 min, `evaluateStalls()` → one `.stall` warning.

## Test Strategy

- Run `xcrun swift test --filter MascotOverlayLayoutTests`, `--filter SpeechBubblePanelTests`, `--filter AgentWarningPresentationTests`, `--filter WellnessPointEngineTests`, `--filter MenuBarContentViewTests`, `--filter AgentSignalIntegrationTests`, `--filter MascotOverlayPanelTests`, then the full suite. Isolated defaults everywhere (AGENTS.md §3.2).

## Risks & Mitigations

- **Interactive bubble left on**: covered by T030 step 3.
- **Engine override lost on a state change**: the override is applied inside `syncWithRive()`, which every transition calls; T031 case 4 covers thermal on/off.
- **Combine sink timing in tests**: use `spinRunLoop` when asserting the engine flag after monitor changes.

## Review Guidance

- Verify only `isInteractive` changed for interactivity; no new click-handling path.
- Verify `MascotOverlayPanel` code is untouched and `MascotOverlayView` has no `agentMonitor` dependency.
- Verify drawn visor and Rive input agree in every tested state (T031 case 4).
- Compare bubble styles visually via `./Scripts/package_and_run.sh release` + `quickstart.md` §1–§2 if possible.

## Activity Log

- 2026-10-30T13:37:15Z – system – Prompt created.
- 2026-10-30T14:05:04Z – claude – Prompt revised after /spec-kitty.analyze (findings C1, C2, U1, G1).
