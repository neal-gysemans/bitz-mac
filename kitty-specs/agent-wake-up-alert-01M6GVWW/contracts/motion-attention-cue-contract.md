# Motion Attention Cue Contract

## Purpose
Specifies the contracts and performance invariants for peripheral attention cues when an agent requires approval.

## Invariants
1. **Zero App CPU Overhead (NFR-001, AGENTS.md §2)**: Continuous motion MUST NOT use `TimelineView` or main-thread SwiftUI animation timers. Mascot front paw tapping runs via `CALayerMotionBridge.Kind.pawTap` on `CALayer`, where `WindowServer` interpolates on the GPU at 0% app CPU.
2. **Frequency & Amplitude Constraints**:
   - `amplitude`: 3.0 pt.
   - `halfPeriod`: 0.22 s (frequency ~2.27 Hz).
3. **State Binding**: `isAttentionCueActive` is passed into `LiveBitzCharacterView` only while `agentMonitor.activePopup?.kind == .needsApproval`. When dismissed or approved, paws revert immediately to standard sway.
