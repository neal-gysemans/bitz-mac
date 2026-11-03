# Implementation Plan: Agent Wake-Up Alert & 1-Click Approval

**Branch**: `feat/issue-19-agent-wake-up-alert` | **Date**: 2026-11-03 | **Spec**: [spec.md](spec.md)  
**Input**: Feature specification from `/kitty-specs/agent-wake-up-alert-01M6GVWW/spec.md` (Tracks GitHub issue #19)

## Summary

Complete the remaining scope of **Agent Wake-Up Alert & 1-Click Approval** (GitHub Issue #19):
1. Support `AgentEventKind.failed` end-to-end (models, monitor service, adapters, hook generator, audio, and crimson bubble UI).
2. Offload rhythmic paw-tap attention animation to CoreAnimation (`CALayerMotionBridge`) during `.needsApproval` at 0% idle CPU.
3. Quick-Action Bubble HUD providing `"JUMP"` (to owning terminal/IDE via `NSRunningApplication`) and `"DIFF"` (launching git diff).
4. Safe Hook-Based 1-Click `"APPROVE"` button for agents with an explicit request channel, managed by `AgentApprovalStore` with single-use consumption and TTL expiry (zero keystroke injection).

## Technical Context

**Language/Version**: Swift 6.0 (`swift-tools-version: 6.0`)  
**Primary Dependencies**: AppKit, SwiftUI, CoreAnimation (`QuartzCore`), Combine, Foundation (`Process`) — zero external SwiftPM dependencies  
**Storage**: Injectable `UserDefaults` (`init(userDefaults: UserDefaults = .standard)`) for any persisted preferences, memory/file-backed approval token lifecycle  
**Testing**: Deterministic XCTest in `Tests/BitzTests/` (`AgentEventFailedTests`, `PawTapAttentionTests`, `QuickActionHUDTests`, `AgentApprovalStoreTests`)  
**Target Platform**: macOS 14.0+, Apple Silicon (`arm64`)  
**Project Type**: Single Swift package (`BitzCore` library + `Bitz` executable + `BitzTests` test suite)  
**Performance Goals**: `< 2%` desktop idle CPU (0 extra polling timers; out-of-process CoreAnimation on `CALayer` for continuous paw-tap motion), `< 70 MB` RAM  
**Constraints**: Zero keystroke injection; zero keyboard focus stealing (`SpeechBubblePanel` remains `.nonactivatingPanel`); 100% desktop click-through preserved on `MascotOverlayPanel`; backward-compatible initializers with default parameters  
**Scale/Scope**: ~4 work packages, 4-6 modified/new source files, 3-4 new test suites

## Charter Check

- **Idle CPU & Memory (`< 2%` CPU, `< 70 MB` RAM)**: PASS. Continuous paw-tap is implemented as a CoreAnimation transform in `CALayerMotionBridge` (`WindowServer` GPU-interpolated), running at **0% app CPU**. No `TimelineView` or main-thread repeatForever animations.
- **100% Click-Through & Zero Focus Stealing**: PASS. `MascotOverlayPanel` retains `ignoresMouseEvents = true`. `SpeechBubblePanel` enables clicks only while interactive bubbles are visible, remaining `.nonactivatingPanel` with `canBecomeKey = false`.
- **Zero Keystroke Injection**: PASS. Approval decisions are written to explicit file/FIFO/hook channels provided in event metadata. Bitz never synthesizes keyboard events.
- **Backward Initializer Compatibility**: PASS. All modified initializers (`SpeechBubbleView.init`, `LiveBitzCharacterView.init`, etc.) provide default values (`= nil` or defaults).

## Design Decisions

1. **`AgentEventKind.failed` End-to-End Handling**:
   - `AgentEventKind` gains `case failed`.
   - In `AgentMonitorService`: on `.failed`, remove agent from `activeAgents`, clear active turn and stall timers, present crimson popup (`"❌ <Name> failed: <message>"`), and auto-dismiss after 6.0 seconds.
   - In `SpeechBubbleView`: `agentPopupColors(for: .failed)` returns crimson background (`Color(red: 0.65, green: 0.08, blue: 0.12).opacity(0.96)`) and red border (`Color.red`).
   - Hook scripts and `DropboxAgentAdapter` accept `kind: "failed"`.

2. **CoreAnimation Paw-Tap Attention Cue**:
   - When `AgentMonitorService.activePopup?.kind == .needsApproval`, `isAttentionCueActive` becomes `true`.
   - `MascotOverlayView` propagates `isAttentionCueActive` to `LiveBitzCharacterView`.
   - In `BitzCharacterView.swift`: `CALayerMotionBridge.Kind.pawTap` applies a rapid vertical translation (`amplitude: 3.0pt`, `halfPeriod: 0.22s`) to the front paw layer.
   - When approval is granted or popup dismissed, paw returns to standard resting sway (`amplitude: 1.8pt`, `halfPeriod: 1.05s`).

3. **Quick-Action Bubble HUD (`Jump to Terminal` & `View Diff`)**:
   - `AppActivating` protocol and `WorkspaceAppActivator`:
     - Checks `owningPID` from metadata; if valid, calls `NSRunningApplication(processIdentifier: pid)?.activate(options: .activateIgnoringOtherApps)`.
     - Otherwise checks `bundleID` (or matches agent definition bundle/process name, e.g. VS Code, Cursor, iTerm2, Terminal) and activates running instances.
   - `DiffViewing` protocol and `SystemDiffViewer`:
     - Dispatches `/usr/bin/git diff` or opens the repository path off `@MainActor` without stalling the UI thread.
   - `SpeechBubbleView`: renders action buttons (`"JUMP"`, `"DIFF"`, and optionally `"APPROVE"`) inside approval bubbles.

4. **Safe Hook-Based 1-Click Approval (`AgentApprovalStore`)**:
   - Value type `AgentApprovalRequest(id, agentID, agentName, toolName, commandSummary, decisionChannel, createdAt, expiresAt)`.
   - `AgentApprovalStore` holds active requests:
     - `register(request:)` registers an approval request from event metadata.
     - `approve(requestID:) -> Bool` writes JSON approval decision (`{"decision": "approve", "request_id": ...}`) to the `decisionChannel`, deletes the request, and marks token consumed.
     - `isExpired(requestID:) -> Bool` rejects requests older than TTL (300 seconds).
   - In `SpeechBubbleView`: `"APPROVE"` button only renders if `approvalRequestID` is present in metadata and request is unexpired. Keystroke injection is never used.

## Project Structure

```
src/
├── Models/
│   ├── AgentModels.swift               # Adds .failed, metadata keys, AgentApprovalRequest
│   └── AgentApprovalStore.swift        # Token store, single-use approval, expiry cleanup
├── Services/
│   ├── AgentMonitorService.swift       # Handles .failed, wires approval store & attention cue
│   ├── AgentHookInstaller.swift        # Generator support for .failed & approval channels
│   ├── AppActivator.swift              # AppActivating & WorkspaceAppActivator
│   └── DiffViewer.swift                # DiffViewing & SystemDiffViewer
├── Views/
│   ├── BitzCharacterView.swift         # Adds .pawTap to CALayerMotionBridge
│   ├── LiveBitzCharacterView.swift     # Passes isAttentionCueActive to front paws
│   ├── MascotOverlayView.swift         # Reads activePopup for attention cue
│   └── SpeechBubbleView.swift          # Approval HUD (APPROVE, JUMP, DIFF) + failure styling
└── App/
    └── BitzApp.swift                   # Wires approval store & activators to view hierarchy

Tests/
└── BitzTests/
    ├── AgentEventFailedTests.swift     # .failed event parsing, monitor state, bubble styling
    ├── PawTapAttentionTests.swift      # Attention cue trigger, CALayerMotionBridge setup
    ├── QuickActionHUDTests.swift       # App activation & diff launching mock tests
    └── AgentApprovalStoreTests.swift   # Single-use consumption, expiry, and channel dispatch
```

## Implementation Concern Map

### IC-01 — Agent Failure Event (`.failed`)
- **Purpose**: Add `AgentEventKind.failed` across models, monitor service, bubble rendering, and adapters.
- **Affected files**: `src/Models/AgentModels.swift`, `src/Services/AgentMonitorService.swift`, `src/Views/SpeechBubbleView.swift`, `src/Services/AgentHookInstaller.swift`
- **Sequencing**: Foundation for failure alerting.

### IC-02 — Paw-Tap Attention Cue (CoreAnimation Offloaded)
- **Purpose**: Add rhythmic paw-tap motion on front paws when an agent needs approval.
- **Affected files**: `src/Views/BitzCharacterView.swift`, `src/Views/MascotOverlayView.swift`
- **Sequencing**: Depends on `.needsApproval` activePopup state. Must satisfy `< 2%` CPU invariant.

### IC-03 — Quick-Action Bubble HUD (Jump to Terminal & View Diff)
- **Purpose**: Allow 1-click jump to the owning IDE/terminal and opening git diff directly from the bubble.
- **Affected files**: `src/Services/AppActivator.swift`, `src/Services/DiffViewer.swift`, `src/Views/SpeechBubbleView.swift`, `src/App/Window/SpeechBubblePanel.swift`
- **Sequencing**: Depends on interactive bubble panel click routing.

### IC-04 — Safe Hook-Based 1-Click Approval
- **Purpose**: Provide request-scoped, expiring approval token dispatch without keystroke simulation.
- **Affected files**: `src/Models/AgentApprovalStore.swift`, `src/Views/SpeechBubbleView.swift`, `src/App/BitzApp.swift`
- **Sequencing**: Depends on IC-03 for bubble layout and IC-01 for metadata models.
