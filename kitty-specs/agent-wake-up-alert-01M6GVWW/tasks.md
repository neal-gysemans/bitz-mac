# Tasks: Agent Wake-Up Alert & 1-Click Approval

**Spec**: [spec.md](spec.md) | **Plan**: [plan.md](plan.md)

## Work Package WP01: Agent Failure Event (.failed) & Crimson Bubble
**Goal**: Add `AgentEventKind.failed` end-to-end (models, monitor service, bubble rendering, hook scripts, adapters) with deterministic unit tests.  
**Prompt**: `/tasks/WP01-agent-failure-event.md`  
**Requirement Refs**: FR-001, FR-002, NFR-004  
**Dependencies**: none  

### Included Subtasks
- T001: Add `case failed` to `AgentEventKind` and extend `MetadataKey` in `src/Models/AgentModels.swift`.
- T002: Update `AgentMonitorService.handleEvent(_:)` to process `.failed`: remove agent from `activeAgents`, clear pending turn, present crimson popup (`"❌ <Name> failed: <message>"`), and auto-dismiss after 6.0 seconds.
- T003: Update `SpeechBubbleView.agentPopupColors(for:)` to render `.failed` with crimson background (`Color(red: 0.65, green: 0.08, blue: 0.12).opacity(0.96)`) and red stroke (`Color.red`).
- T004: Update `AgentHookInstaller.swift` and `DropboxAgentAdapter.swift` to handle `.failed` events cleanly.
- T005: Write unit tests in `Tests/BitzTests/AgentEventFailedTests.swift` validating `.failed` event decoding, monitor service state transitions, and bubble styling.

---

## Work Package WP02: Paw-Tap Attention Cue on .needsApproval (CoreAnimation Offloaded)
**Goal**: Implement out-of-process CoreAnimation paw-tap motion on mascot front paws when an agent is awaiting approval, satisfying the `< 2%` idle CPU invariant.  
**Prompt**: `/tasks/WP02-paw-tap-attention-cue.md`  
**Requirement Refs**: FR-003, NFR-001, NFR-004, C-002  
**Dependencies**: none  

### Included Subtasks
- T006: Add `.pawTap(amplitude: Double, halfPeriod: Double)` to `CALayerMotionBridge.Kind` in `src/Views/BitzCharacterView.swift` creating rapid vertical translation on front paw layers via `CABasicAnimation`.
- T007: Wire `isAttentionCueActive` state in `LiveBitzCharacterView` and `MascotOverlayView` observing `AgentMonitorService.activePopup?.kind == .needsApproval`.
- T008: Verify paw-tap stops immediately when approval popup is cleared or dismissed and verify layout invariant tests pass.
- T009: Write unit tests in `Tests/BitzTests/PawTapAttentionTests.swift` validating attention cue state propagation and motion bridge configuration.

---

## Work Package WP03: Quick-Action Bubble HUD (Jump to Terminal & View Diff)
**Goal**: Implement `AppActivating` and `DiffViewing` protocol seams and integrate quick-action buttons (`"JUMP"` and `"DIFF"`) into `SpeechBubbleView` for approval bubbles.  
**Prompt**: `/tasks/WP03-quick-action-bubble-hud.md`  
**Requirement Refs**: FR-004, FR-005, FR-008, NFR-003, C-002  
**Dependencies**: none  

### Included Subtasks
- T010: Implement `AppActivating` protocol and `WorkspaceAppActivator` in `src/Services/AppActivator.swift` activating owning terminal / IDE by PID (`NSRunningApplication`) or bundle identifier without stealing keyboard focus.
- T011: Implement `DiffViewing` protocol and `SystemDiffViewer` in `src/Services/DiffViewer.swift` executing git diff for the agent's working directory off the main thread.
- T012: Update `SpeechBubbleContent.isInteractive` to return `true` for approval popups so `SpeechBubblePanel` receives mouse clicks.
- T013: Add `"JUMP"` and `"DIFF"` action buttons to approval bubble layout in `src/Views/SpeechBubbleView.swift`.
- T014: Write unit tests in `Tests/BitzTests/QuickActionHUDTests.swift` verifying mock app activation, mock diff launching, and bubble layout.

---

## Work Package WP04: Safe Hook-Based 1-Click Approval
**Goal**: Implement `AgentApprovalStore` managing request-scoped, expiring approval tokens with single-use consumption and channel dispatch (never keystroke injection).  
**Prompt**: `/tasks/WP04-safe-hook-approval.md`  
**Requirement Refs**: FR-006, FR-007, FR-008, NFR-002, NFR-004, C-003  
**Dependencies**: WP01, WP03  

### Included Subtasks
- T015: Implement `AgentApprovalRequest` in `src/Models/AgentModels.swift` and `@MainActor public final class AgentApprovalStore: ObservableObject` in `src/Models/AgentApprovalStore.swift` with TTL expiry (default 300s) and single-use decision writing.
- T016: Connect `AgentApprovalStore` to `AgentMonitorService` registering incoming approval requests from `AgentEvent.metadata` and dismissing popups on approval.
- T017: Add `"APPROVE"` button in `SpeechBubbleView` displaying tool/command summary when `approvalRequestID` is present; gate visibility so agents without hook channels only see `"JUMP"` and `"DIFF"`.
- T018: Wire `approvalStore` into `BitzApp.swift` / `BitzAppDelegate` and verify window click-through and non-activating invariants.
- T019: Write comprehensive unit tests in `Tests/BitzTests/AgentApprovalStoreTests.swift` verifying token registration, single-use invalidation, expiry rejection, decision dispatch, and zero keystroke injection.
