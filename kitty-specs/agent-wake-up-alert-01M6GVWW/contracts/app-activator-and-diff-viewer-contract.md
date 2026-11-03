# App Activator & Diff Viewer Contract

## Purpose
Specifies the protocol seams and focus invariants for the quick-action HUD buttons (`"JUMP"` and `"DIFF"`).

## Invariants
1. **Zero Focus Stealing (NFR-003, AGENTS.md §4)**: `SpeechBubblePanel` and `MascotOverlayPanel` remain `.nonactivatingPanel` with `canBecomeKey = false`. Interacting with buttons does not make Bitz key window.
2. **Standard macOS Public APIs Only (C-002)**: Process activation uses `NSRunningApplication.activate(options: [])` or `NSWorkspace.shared.openApplication(at:configuration:completionHandler:)`. No private APIs or accessibility injection.
3. **Off-Main-Thread Diff Execution**: `DiffViewing.openDiff(workingDirectory:)` spawns `/usr/bin/git diff` asynchronously off the main thread to ensure the UI never blocks.

## Interfaces
- `AppActivating`: Protocol for activating application by PID or bundle identifier.
- `WorkspaceAppActivator`: Production implementation using `NSWorkspace`.
- `DiffViewing`: Protocol for presenting repository changes.
- `SystemDiffViewer`: Production implementation querying git status and launching viewer.
