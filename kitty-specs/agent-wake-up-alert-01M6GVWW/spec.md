# Mission Specification: Agent Wake-Up Alert & 1-Click Approval

**Mission Branch**: `feat/issue-19-agent-wake-up-alert`  
**Created**: 2026-11-03  
**Status**: Approved  
**Input**: GitHub Issue #19 — "[Feature]: Agent Wake-Up Alert & 1-Click Approval" (refs #19)

---

## 1. Context & Scope

### 1.1 Baseline Shipped in main (v1.3.0)
- **Agent Chimes & Focus/DND Mute Gating**: `CyberAudioService` & `AudioEnvironmentDetector` trigger subtle `agent_chime.wav` for `.needsApproval`, `all_done_fanfare.wav` for `.done`, and honor DND/fullscreen suppression (#21 / PR #76).
- **Dedicated Clickable SpeechBubblePanel**: Child floating panel (`SpeechBubblePanel`) with dynamic text fitting and `ignoresMouseEvents = false` only when interactive bubbles are displayed (#61 / PR #62).
- **Warning Alerts & GOT IT Dismissal**: Context-limit, loop, and stall warnings with amber visor and interactive dismissal (#38 / PR #71).

### 1.2 Remaining Target Scope for #19
1. **Explicit `.failed` Event Kind & Paw-Tap Attention Cue**:
   - Add `AgentEventKind.failed` end-to-end (`AgentModels.swift`, `AgentMonitorService.swift`, `DropboxAgentAdapter.swift`, hook generators, speech bubble styling, and sound/chime trigger).
   - Add paw-tap attention animation on mascot front paws while an agent is in `.needsApproval` status (offloaded to CoreAnimation `CALayerMotionBridge` at 0% idle CPU).
2. **Quick-Action Bubble HUD (`Jump to Terminal` / `View Diff`)**:
   - Provide clickable action buttons inside `SpeechBubbleView` for `.needsApproval`:
     - **Jump to Terminal**: Brings the owning terminal/IDE application forward using `NSRunningApplication.activate(options: .activateIgnoringOtherApps)` (matching PID, bundle identifier, or active terminal app).
     - **View Diff**: Opens the repository git diff using system default diff viewer or git CLI (`/usr/bin/git diff`).
3. **Safe Hook-Based 1-Click Approval**:
   - Single-use, expiring, request-scoped approval token architecture (`AgentApprovalStore` / `AgentApprovalRequest`).
   - Only shown when the event provides an explicit hook-based approval decision channel (never keystroke injection, never auto-approving).
   - Clear summary of what tool/command is being approved (e.g. `Bash: git push`).
4. **Deterministic Testing**:
   - Unit tests covering `.failed` event lifecycle, quick actions, approval token single-use & expiry, paw-tap state, and speech bubble interactivity.

---

## 2. User Scenarios & Testing *(mandatory)*

### User Story 1 - End-to-End Agent Failure Event (`.failed`) & Mascot Indication (Priority: P1)

Developers running autonomous coding agents (Claude Code, Antigravity, custom scripts) need immediate visual and auditory notification when an agent encounters an unrecoverable failure or non-zero exit code. When an agent emits or drops a `.failed` event, Bitz displays a high-contrast crimson failure bubble (`"❌ <Agent> failed: <message>"`), clears active working states, and triggers the appropriate failure sound feedback (or glitch tone) while respecting Focus/DND mute settings.

**Why this priority**: Without explicit `.failed` support, failed tasks either hang silently as working/stalled or disappear without notifying the developer.

**Independent Test**: Post a `.failed` `AgentEvent` to `AgentMonitorService`, verify `activePopup.kind == .failed`, verify speech bubble colors (crimson fill, red stroke), verify `activeAgents` removes the failed agent, and verify audio trigger dispatch.

**Acceptance Scenarios**:
1. **Given** an active agent session, **When** an `AgentEvent` with `kind: .failed` is received, **Then** `AgentMonitorService.activePopup` updates to `.failed` with the failure message and the agent is removed from `activeAgents`.
2. **Given** a `.failed` popup is active, **When** rendered in `SpeechBubbleView`, **Then** it renders with red stroke and crimson background, and auto-dismisses after 6.0 seconds.
3. **Given** `DropboxAgentAdapter` watching the drop-box directory, **When** a hook script writes `{"kind":"failed","message":"Build error"}`, **Then** it decodes and dispatches cleanly to `AgentMonitorService`.

---

### User Story 2 - Paw-Tap Attention Cue on `.needsApproval` (Priority: P1)

When an AI agent halts waiting for user permission to run a command or write a file, Bitz must draw the user's peripheral attention immediately through an unmistakable physical motion: rhythmic paw-tapping. While `activePopup?.kind == .needsApproval`, the mascot's front paws transition from gentle sway to rhythmic paw-tapping using out-of-process CoreAnimation layer animations, stopping immediately once approved or dismissed.

**Why this priority**: Peripheral visual motion ensures developers notice approval requests even if sound is muted or headphones are off.

**Independent Test**: Toggle `isAttentionCueActive` on `LiveBitzCharacterView` / `LiveMotionStageView`, verify the paw layer receives the `.pawTap` motion bridge configuration with higher frequency/amplitude, and verify 0% app CPU usage.

**Acceptance Scenarios**:
1. **Given** `AgentMonitorService.activePopup?.kind == .needsApproval`, **When** `MascotOverlayView` renders `LiveBitzCharacterView`, **Then** `isAttentionCueActive` is passed as `true`.
2. **Given** `isAttentionCueActive == true`, **When** mascot front paws are animated, **Then** `CALayerMotionBridge` applies rhythmic paw-tap motion without main-thread animation timers (`0%` CPU).
3. **Given** an approval is completed or dismissed, **When** `activePopup` changes, **Then** paw-tap immediately ceases and returns to normal resting sway.

---

### User Story 3 - Quick-Action Bubble HUD: Jump to Terminal & View Diff (Priority: P2)

When an agent needs approval or attention, the user needs fast shortcuts right from Bitz's speech bubble:
1. **Jump to Terminal**: Activates the terminal emulator or IDE window hosting the agent (using the agent PID, bundle ID, or active terminal host) without needing to manually hunt through macOS spaces or dock items.
2. **View Diff**: Opens the repository diff in the user's default tool or git diff viewer so they can inspect changes before approving.

**Why this priority**: Reduces context-switching friction when evaluating whether to approve an agent's proposed changes.

**Independent Test**: Mock `AppActivating` and `DiffViewing` protocols; trigger the action buttons in `SpeechBubbleView`, verify `activateApplication` is called with the expected bundle/PID and `openDiff` is called with the target working directory.

**Acceptance Scenarios**:
1. **Given** an approval bubble is visible in `SpeechBubbleView`, **When** the user clicks `"JUMP"`, **Then** the owning terminal or IDE application is brought forward (`activateIgnoringOtherApps`).
2. **Given** an approval bubble is visible with a detected git repository, **When** the user clicks `"DIFF"`, **Then** the diff viewer is launched cleanly off the main thread.
3. **Given** quick-action buttons are clicked, **Then** `SpeechBubblePanel` handles the click without making the mascot panel key window or stealing keyboard focus.

---

### User Story 4 - Safe Hook-Based 1-Click Approval (Priority: P2)

For agents with an explicit hook-based approval channel (such as Claude Code `PermissionRequest` hooks or custom drop-box response channels), Bitz displays an interactive `"APPROVE"` button. Clicking `"APPROVE"` sends a single, expiring, request-scoped decision to the agent's response channel, displaying what command/tool is being approved. Keystroke injection is strictly forbidden; if an agent lacks an explicit hook channel, the `"APPROVE"` button is hidden and only `"JUMP"` / `"DIFF"` are offered.

**Why this priority**: Delivers maximum convenience while maintaining strict security boundaries (never auto-approving, never simulating keystrokes into active shells).

**Independent Test**: Inject a mock `AgentApprovalStore` with a pending request; click `"APPROVE"`, verify the decision is dispatched once, the token is invalidated (cannot be re-approved), and verify expired tokens reject approval.

**Acceptance Scenarios**:
1. **Given** an approval event with valid `approvalRequestID` and `approvalChannel`, **When** rendered in `SpeechBubbleView`, **Then** an `"APPROVE"` button is shown alongside a summary of the requested tool/command.
2. **Given** the user clicks `"APPROVE"`, **When** the approval token is valid, **Then** the single-use decision is written to the approval channel, the token is invalidated, and the approval bubble is dismissed.
3. **Given** an agent without an explicit approval channel in its metadata, **When** `SpeechBubbleView` renders the approval bubble, **Then** the `"APPROVE"` button is NOT displayed (only `"JUMP"` and `"DIFF"` appear).
4. **Given** an expired approval token (older than TTL e.g. 5 minutes), **When** clicked, **Then** the action safely fails without re-sending stale decisions.

---

## 3. Requirements *(mandatory)*

### 3.1 Functional Requirements

| ID | Title | User Story | Priority | Status |
|----|-------|------------|----------|--------|
| FR-001 | `AgentEventKind.failed` Support | As a developer, I want `AgentEventKind.failed` supported across `AgentModels`, `AgentMonitorService`, adapters, and hook scripts so agent failures are explicitly tracked. | High | Open |
| FR-002 | Failure Speech Bubble Styling | As a user, I want agent failure popups displayed in crimson with red border and clear failure messages (`"❌ <Agent>: <message>"`) auto-dismissing after 6s. | High | Open |
| FR-003 | Paw-Tap Attention Cue on NeedsApproval | As a user, I want Bitz's front paws to perform a rhythmic paw-tap animation while an agent is in `.needsApproval` status to alert my peripheral vision. | High | Open |
| FR-004 | Quick-Action HUD (Jump to Terminal) | As a user, I want a `"JUMP"` button on approval bubbles that brings the owning terminal or IDE window forward using `NSRunningApplication`. | High | Open |
| FR-005 | Quick-Action HUD (View Diff) | As a user, I want a `"DIFF"` button on approval bubbles that opens the working git diff so I can review proposed changes. | Medium | Open |
| FR-006 | Safe Hook-Based Approval Channel | As a user, I want an `"APPROVE"` button shown only when an explicit hook response channel exists, sending a single-use, request-scoped decision without keystroke injection. | High | Open |
| FR-007 | Approval Token Store & Expiry Lifecycle | As a developer, I want `AgentApprovalStore` managing request tokens with single-use consumption and automatic TTL expiry (default 5 minutes). | High | Open |
| FR-008 | Interactive Bubble Window Click Routing | As a user, I want approval HUD buttons clickable in `SpeechBubblePanel` (`isInteractive == true`) while maintaining 100% click-through on `MascotOverlayPanel`. | High | Open |

### 3.2 Non-Functional Requirements

| ID | Title | Requirement | Category | Priority | Status |
|----|-------|-------------|----------|----------|--------|
| NFR-001 | Idle CPU & Zero Geometry Animations | Mascot paw-tap animation MUST use out-of-process CoreAnimation layer transforms (`CALayerMotionBridge`); app idle CPU must remain `< 2%`. | Performance | High | Open |
| NFR-002 | Zero Keystroke Injection & Security Gate | Bitz MUST NEVER inject keystrokes into user terminal windows; approval decisions must use explicit file/socket/hook response channels only. | Security | High | Open |
| NFR-003 | Zero Focus Stealing | `SpeechBubblePanel` and `MascotOverlayPanel` must remain `.nonactivatingPanel` with `canBecomeKey = false` so clicking bubble buttons never steals keyboard focus from the active IDE or terminal. | Reliability | High | Open |
| NFR-004 | Headless Deterministic Unit Tests | 100% of approval token lifecycle, quick actions, failure event handling, and paw-tap state tests must execute in `< 2s` with zero external process dependencies. | Reliability | High | Open |

### 3.3 Constraints

| ID | Title | Constraint | Category | Priority | Status |
|----|-------|------------|----------|----------|--------|
| C-001 | Backward-Compatible Initializers | `SpeechBubbleView`, `LiveBitzCharacterView`, `BitzCharacterView`, and `AgentMonitorService` must preserve default parameter compatibility. | Technical | High | Open |
| C-002 | Public macOS AppKit APIs Only | Process activation and window management must rely on standard `NSWorkspace` and `NSRunningApplication` without private entitlements or Accessibility/TCC prompts. | Regulatory | High | Open |
| C-003 | Single-Use Token Invalidation | Approval decisions cannot be replayed or duplicated; once consumed, the token is deleted immediately. | Security | High | Open |

---

## 4. Key Entities

- **`AgentEventKind.failed`**: New enum case representing an unrecoverable failure or non-zero exit from an agent.
- **`AgentApprovalRequest`**: Value type recording `requestID`, `agentID`, `toolName`, `commandSummary`, `decisionChannel`, `createdAt`, and `expiresAt`.
- **`AgentApprovalStore`**: `@MainActor` observable store managing active pending approval tokens, single-use consumption, and expiration sweeps.
- **`AppActivating` / `WorkspaceAppActivator`**: Protocol seam for bringing terminal / IDE applications forward by PID or bundle identifier.
- **`DiffViewing` / `SystemDiffViewer`**: Protocol seam for executing `/usr/bin/git diff` or opening git diffs cleanly off the main thread.
- **`CALayerMotionBridge.Kind.pawTap`**: CoreAnimation-offloaded transform animation for rapid front-paw tapping at 0% app CPU.

---

## 5. Success Criteria *(mandatory)*

- **SC-001**: Emitting `AgentEvent(kind: .failed)` triggers a crimson bubble with clear failure message and removes the agent from active sessions.
- **SC-002**: Mascot front paws visibly tap during `.needsApproval` and revert to resting sway once resolved, with idle CPU measured `< 2%`.
- **SC-003**: Clicking `"JUMP"` on an approval bubble brings the owning terminal/IDE forward without stealing keyboard focus or breaking desktop click-through.
- **SC-004**: Clicking `"DIFF"` opens the git diff for the agent's target working directory.
- **SC-005**: Clicking `"APPROVE"` sends an approval payload to the designated response channel, invalidates the token, and dismisses the bubble; tokens cannot be double-spent.
- **SC-006**: 100% of unit tests pass with zero regressions across `BitzTests`.
