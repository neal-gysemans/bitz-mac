# Research: Agent Wake-Up Alert & 1-Click Approval (GitHub Issue #19)

## Context & Existing Capabilities in `main` (v1.3.0)
- **Agent Audio & Mute Gating (`CyberAudioService` & `AudioEnvironmentDetector`)**: Shipped in #21 / PR #76. Subtle chime (`agent_chime.wav`) on `.needsApproval`, fanfare (`all_done_fanfare.wav`) on `.done`, with Focus/DND & fullscreen suppression.
- **Dedicated Interactive Bubble Window (`SpeechBubblePanel`)**: Shipped in #61 / PR #62. Child floating panel attached to `MascotOverlayPanel` that dynamically toggles `ignoresMouseEvents = false` only when interactive bubbles are displayed while keeping keyboard focus non-stealing (`canBecomeKey = false`).
- **Warning Visor & Dismissal (`AgentMonitorService`)**: Shipped in #38 / PR #71. Context/loop/stall warnings with amber visor and GOT IT button.

## Key Architectural Findings & Decisions

1. **`AgentEventKind.failed` Additive Compatibility**:
   - `AgentEventKind` is a `String, Codable, CaseIterable` enum. Adding `case failed` is 100% backward-compatible.
   - Any agent script or adapter can emit `{"kind": "failed", "message": "..."}`.
   - On `.failed`, `AgentMonitorService` removes the agent from `activeAgents`, clears pending turns, and shows a crimson failure bubble.
2. **Paw-Tap Attention Animation via `CALayerMotionBridge` (`< 2%` Idle CPU)**:
   - In accordance with Performance Invariant 1 (AGENTS.md), continuous mascot animations must NEVER use SwiftUI `TimelineView` or `.repeatForever` geometry modifiers.
   - `CALayerMotionBridge` already provides `.verticalSway` and `.tailWag` on `CALayer` animated by `WindowServer`.
   - Adding a `.pawTap` motion bridge kind (higher frequency ~4Hz, amplitude 3.0pt) provides an unmistakable peripheral cue at **0% app CPU**.
3. **App Activation without Accessibility/TCC Prompts**:
   - macOS AppKit `NSRunningApplication(processIdentifier:)?.activate(options: .activateIgnoringOtherApps)` or matching `NSWorkspace.shared.runningApplications` by `bundleIdentifier` requires NO Accessibility / TCC permissions.
   - Quick Action `"JUMP"` uses an injectable `AppActivating` protocol seam with `WorkspaceAppActivator` default implementation.
4. **Git Diff Launching**:
   - Quick Action `"DIFF"` checks the target repository URL from `AgentEvent.metadata["workingDir"]` (or current repository root) and launches `/usr/bin/git diff` or the user's default diff tool off the main thread.
5. **Safe Hook-Based 1-Click Approval (No Keystroke Injection)**:
   - Keystroke injection (`osascript -e 'tell application "System Events" to keystroke ...'`) is fragile, dangerous, and violates security boundaries.
   - Instead, Bitz uses a deterministic request-scoped decision channel:
     - The agent event specifies `approvalRequestID` and optional `approvalPath` in `metadata`.
     - `AgentApprovalStore` holds the token with a TTL (default 5 minutes).
     - Clicking `"APPROVE"` writes `{"decision": "approve", "request_id": id, "timestamp": iso8601}` to the target response file, immediately marks the token as consumed (single-use), and dismisses the bubble.
     - If no approval channel is declared in metadata, the `"APPROVE"` button is omitted, cleanly falling back to `"JUMP"` and `"DIFF"`.
