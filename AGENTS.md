# AGENTS.md — Agent & Contributor Workflow, Architecture Map & Performance Invariants

This file is the **single source of truth** for all AI coding agents (Antigravity, Claude Code, Cursor, Codex, Jules, etc.) and human contributors working on `bitz-mac`. Read this before exploring or modifying code.

---

## 🗺️ 1. Instant Codebase Map (No Blind Searching Needed)

- **Tech Stack**: Swift 6.0 (`Package.swift`), macOS 14+ (`arm64` / Apple Silicon primary), AppKit + SwiftUI + CoreAnimation (`QuartzCore`) + IOKit, zero external SwiftPM dependencies.
- **Targets**:
  - `Bitz` (`src/Executable/main.swift`) — Thin executable entry point calling `BitzApp.main()`.
  - `BitzCore` (`src/`) — All app, window, view, model, and service code (imported `@testable import BitzCore` in tests).
  - `BitzTests` (`Tests/BitzTests/`) — 300+ deterministic XCTest unit & layout tests.

### `src/App/` — Lifecycle, Windows & Settings Shell
- `src/App/BitzApp.swift` — `BitzApp`, `BitzAppDelegate`, `BitzMenuBarContentView` (`MenuBarExtra`). Owns all singleton stores/services, wires callbacks (`agentMonitor` ↔ `engine` ↔ `cyberAudio` ↔ `speechBubblePanel`), and builds `MascotOverlayPanel`.
- `src/App/Window/MascotOverlayPanel.swift` — Borderless floating `NSPanel` (`250×250` base scaled by `AvatarScaleStore` `0.50...1.75`), `AvatarScaleStore`, `AvatarOpacityStore`, `AvatarPositionStore` (freeform drag, `⌥ Option` hover, `⎋ Esc` lock, magnetic ~20pt edge snap, multi-display clamping). Owns child `SpeechBubblePanel`.
- `src/App/Window/SpeechBubblePanel.swift` — Child floating `NSPanel` anchored just above Bitz's ear tips (`earOverflow`), dynamically sized to wrapped bubble text (#61).
- `src/App/Window/DisplayPreferenceStore.swift` — Multi-monitor selection & fallback resolution when displays disconnect.
- `src/App/Settings/SettingsWindowManager.swift` — Native `NSWindow` (`820×560`) hosting `SettingsRootView`. Detaches `contentViewController = nil` on close (`tearDownHostedContent`) so hidden SwiftUI trees consume **0% CPU & 0 MB** while closed (#70).

### `src/Views/` — Mascot Canvas, Speech Bubbles & Settings Tabs
- `src/Views/MascotOverlayView.swift` — Fixed `250×250` mascot overlay canvas: hosts `LiveBitzCharacterView`, `MascotCyberHUDContainerView` (`MascotCyberHUDPillView`), and drag-unlock border/pill.
- `src/Views/BitzCharacterView.swift` —
  - `BitzCharacterView(state:time:...)`: Pure deterministic SwiftUI vector mascot (used for static rendering & `ImageRenderer` snapshot tests).
  - `LiveBitzCharacterView` / `AnimatedBitzCharacterView`: Production CoreAnimation-offloaded mascot (`CALayerMotionBridge` + `CoreAnimationParticlesView`) running continuous motion in `WindowServer` at 0% app CPU (#70).
- `src/Views/SpeechBubbleView.swift` — Priority-ordered bubble renderer (`SpeechBubbleContent`: `.agentPopup` > `.update` > `.wellness` > `.carousel`) with `BubbleWindowLayout` and isolated `CarouselSpeechBubbleObserver`.
- `src/Views/Settings/` — `SettingsRootView.swift` + 6 tabs: `GeneralSettingsTabView.swift`, `BehaviorSettingsTabView.swift`, `AgentsSettingsTabView.swift`, `TelemetrySettingsTabView.swift`, `AudioSettingsTabView.swift`, `AdvancedSettingsTabView.swift`.

### `src/Services/` & `src/Models/` — Domain Engine, Telemetry, Agents & Audio
- `src/Services/WellnessPointEngine.swift` — `@MainActor` PTS state machine (`0...100` pts across `.superCharged`, `.balanced`, `.dopamineSad`, `.overworked`, `.burnout`, `.charging`, `.overheating`), offline break recovery, warning visor (`isWarningVisorActive`), pet reaction debounce, and `BitzRiveControllable` contract.
- `src/Services/ActivityMonitorService.swift` — 5s coalesced activity/thermal/idle monitor (`SystemActivityTelemetryProvider`), `AppleSiliconHardwareSensors` (`IOHIDEventSystemClient` die temp + Mach `HOST_CPU_LOAD_INFO` + `IOPMCopyAssertionsByProcess` video detection), and `BrowserTabTelemetryReader` (Firefox `recovery.jsonlz4`, Chromium `SNSS`, Safari AppleScript).
- `src/Services/TelemetryDashboardService.swift` & `src/Models/TelemetryModels.swift` — Async off-main-thread hardware telemetry sampler (Disk, RAM, Network, Battery, Display FPS, CPU, Agents) + `TelemetrySettingsStore`.
- `src/Services/AgentMonitorService.swift` & `src/Models/AgentModels.swift` — AI coding agent coordinator, popup/warning priority queue, stall detector, context gauge, and catalog persistence.
  - Adapters: `AntigravityTranscriptAdapter.swift`, `ClaudeCodeTranscriptAdapter.swift`, `DropboxAgentAdapter.swift`, `ProcessAgentAdapter.swift`, `LogWatcherAgentAdapter.swift` (sharing `SessionLogTail.swift` & `AgentSessionTracker.swift`).
  - `AgentHookInstaller.swift` — Safe backup-first `~/.claude/settings.json` hook installer.
- `src/Services/CyberAudioService.swift`, `CyberAudioPlaying.swift`, `AudioEnvironmentDetector.swift`, `src/Models/CyberAudioModels.swift`, `CyberAudioSettingsStore.swift` — Sound effects (`src/Resources/Sounds/*.wav`), DND/fullscreen/other-audio mute gating.
- `src/Services/AppUpdateService.swift` — GitHub Releases checker (`AppUpdateStore`).

### Key Docs & Packaging Scripts
- `docs/ARCHITECTURE.md` (system design & NFR budgets), `docs/STATE_MACHINE.md` (PTS math & edge cases), `docs/ACCEPTANCE_CRITERIA.md` (FR/NFR specs).
- `docs/DISTRIBUTION.md` — Private repo distribution architecture (`AkramKs/bitz-mac` private source, `AkramKs/bitz-releases` public release sink, `AkramKs/homebrew-tap` Cask sync).
- `Scripts/package_and_run.sh [debug|release]` (builds, signs ad-hoc `build/Bitz.app`, kills old instance, launches with SDK fallback), `Scripts/create_dmg.sh` (release DMG builder).

---

## ⚡ 2. Performance & Idle CPU Invariants (`< 2%` CPU, `< 70 MB` RAM — STRICT)

Bitz sits on the user's desktop all day alongside heavy IDEs and LLM agents. Regressions #10 and #70 pushed idle CPU above `40%` due to SwiftUI animation/layout traps. **Never reintroduce any of the following:**

1. **NO `TimelineView` or SwiftUI `.repeatForever` Geometry Animations for Continuous Motion**:
   - On ProMotion Macs (120Hz), `TimelineView(.animation)`, `PhaseAnimator`, and SwiftUI `.animation(.repeatForever(...))` on `.offset(...)` / `.transformEffect(...)` wake `ViewGraphRootValueUpdater` and `-[NSView setFrameOrigin:]` on the main thread every frame (~15–42% CPU).
   - **Rule**: Keep continuous mascot & particle motion in **out-of-process CoreAnimation** (`CABasicAnimation` / `CAAnimationGroup` on `CALayer` inside `LiveBitzCharacterView`, `CALayerMotionBridge`, and `CoreAnimationParticlesView`), where `WindowServer` interpolates on the GPU at **0% app CPU**.
   - Keep `BitzCharacterView(state:time:...)` pure deterministic SwiftUI so `ImageRenderer` in `MascotOverlayLayoutTests` renders every pixel without `NSViewRepresentable` blanks.
2. **NO `Canvas` with Dynamic `GraphicsContext.draw(Text(...))` in Loops**:
   - Drawing `Text` inside `Canvas` invokes CoreText (`CTLineCreateWithAttributedString`) + Metal `RenderBox` surface submissions on every frame. Use `CATextLayer` or static SwiftUI `Text` layers instead.
3. **Detach Closed Secondary Windows (`contentViewController = nil`)**:
   - AppKit windows with `isReleasedWhenClosed = false` keep their `NSHostingController` / `NSHostingView` active in the background when closed!
   - `SettingsWindowManager` detaches `window.contentViewController = nil` on close (`tearDownHostedContent`) and exposes `isWindowVisible`. Any new secondary window MUST do the same.
4. **`NSHostingView.sizingOptions` Rule**:
   - Fixed-size windows (`MascotOverlayPanel` `250×250` and `SettingsWindowManager` `820×560`) MUST set `sizingOptions = []` so AppKit never runs per-frame intrinsic content size measurement passes.
   - **Exception**: `SpeechBubblePanel`'s `NSHostingView` MUST retain default `sizingOptions` so the bubble window resizes dynamically to fit multi-line text (#61).
5. **Isolate Polling `@ObservedObject`s to Leaf Subviews**:
   - Never attach `@ObservedObject var telemetryDashboard` (or any 1–5s polling service) directly to `MascotOverlayView` or `SpeechBubbleView` root properties. Subscribe inside small leaf views (`MascotCyberHUDContainerView` + `.equatable()`, `CarouselSpeechBubbleObserver`) so unchanged ticks never invalidate the mascot or speech bubble layout.
6. **Shadow Placement (`.shadow` Before Stroke `.overlay`)**:
   - Apply `.shadow(...)` directly onto simple filled shapes (`RoundedRectangle().fill(...)`) *before* `.overlay(...stroke...)`. Applying `.shadow` after composite overlays triggers CPU Bezier path unioning (`ShapeLayerShadowHelper`). Avoid `.shadow` on tiny moving particles (use a translucent halo `Circle`/`CALayer` instead).
7. **Cache Hardware Sensors & File-Backed Telemetry on `@MainActor`**:
   - Never call `IOHIDEventSystemClientCopyServices` on every 5s tick or re-parse unchanged browser session files (`recovery.jsonlz4` / Chromium `SNSS`). Always cache matched `IOHIDServiceClient` handles, respect cool-state TTLs, and gate session file reads on `modificationDate`.
8. **Mandatory Live CPU Verification for UI / Window / Timer Changes**:
   - Whenever modifying `src/Views/`, `src/App/Window/`, or any polling service in `src/Services/`, package & launch `release`, close the Settings window, and verify desktop idle CPU stays **`< 2%`**:
     ```bash
     ./Scripts/package_and_run.sh release
     osascript -e 'tell application "System Events" to tell process "Bitz" to close (every window whose name contains "Settings")' 2>/dev/null || true
     sleep 2 && top -l 6 -s 2 -pid $(pgrep -x Bitz) -stats pid,cpu,mem
     ```

---

## 🔒 3. Issue Ticket & PR Lifecycle (STRICT)

> **Private Repository Note**: `AkramKs/bitz-mac` is private. On GitHub Free accounts, branch protection rulesets are unavailable for private repos. Therefore, **all contributors and AI agents must strictly honor the PR and CI check lifecycle without exception**—never pushing directly to `main`.

### Rule 3.1: Ticket First
- Never write code or open a PR without an associated GitHub Issue ticket.
- First check open issues (`gh issue list --repo AkramKs/bitz-mac`).
- If no ticket exists, create one (`gh issue create`) before branching.
- Verify your active `gh` CLI account has write access (`gh auth status`; switch to `AkramKs` via `gh auth switch --user AkramKs` if needed).

### Rule 3.2: Explicit Ticket References in PRs
- Every Pull Request MUST reference its issue ticket in both the commit message and PR body:
  - `Closes #<id>` and `refs #<id>`
- This ensures automated CI passes `.github/workflows/pr-ticket-check.yml`.

### Rule 3.3: Human Review & Validation (NO AUTO-MERGING BY AGENTS)
> **CRITICAL RULE**: **AI agents must NEVER merge Pull Requests automatically.**
>
> 1. Once all tests pass, local packaging succeeds, and CI checks are green on the PR, the agent MUST **STOP**.
> 2. The agent hands off the PR link to the user/maintainer for human review, verification, and validation.
> 3. Only the human maintainer validates and merges the PR.

### Rule 3.4: Mandatory Post-Merge Issue Closure
> **CRITICAL RULE**: When a Pull Request is merged into `main` by the maintainer, verify that the linked issue ticket is officially **CLOSED**.
>
> 1. Check issue status: `gh issue view <id> --repo AkramKs/bitz-mac`
> 2. If the ticket remains open for any reason, immediately close it:
>    ```bash
>    gh issue close <id> --repo AkramKs/bitz-mac --comment "Resolved and merged into main via PR #<pr_number>."
>    ```
> 3. **Never leave completed issue tickets open after a PR is done.**

### Rule 3.5: Branch Sync & Cleanup
- Immediately after a PR is merged into `main`:
  1. Switch back to `main`: `git checkout main`
  2. Pull latest upstream commits: `git pull origin main`
  3. Delete the local feature branch: `git branch -D <branch>`
  4. Ensure `git status` reports working directory clean.

---

## 🐱 4. Mascot & Window Invariants

1. **100% Click-Through Guarantee**:
   - `MascotOverlayPanel` and its child `SpeechBubblePanel` keep `ignoresMouseEvents = true` during normal operation.
   - Each switches to `false` only for its own interaction:
     - `MascotOverlayPanel`: while the user drags/moves the mascot (`positionStore.isInteractivityEnabled == true`).
     - `SpeechBubblePanel`: while an interactive bubble is showing (e.g., Update Download or Agent Warning **GOT IT** buttons).
   - Once dismissed or locked, it MUST immediately revert to `ignoresMouseEvents = true`.

2. **Zero Keyboard Focus Stealing**:
   - Both panels must always be `.nonactivatingPanel` with `canBecomeKey = false`.
   - Modifiers and keybinds (`⌥ Option`, `⎋ Escape`, `⏎ Return`) must use global/local event monitors without making the panel key window or stealing focus from the user's IDE or terminal.

3. **Multi-Display & Screen Clamping**:
   - Bitz must never be positioned off-screen or stranded behind a disconnected display.
   - Screen boundary clamping (`clampOriginToVisibleFrame`) and magnetic edge snapping (~20pt) must be preserved.

4. **Nothing Drawn Outside Its Window**:
   - Each panel clips to its own frame. `MascotOverlayView` fits the fixed 250×250 pt canvas; speech bubbles live in `SpeechBubbleView`, whose panel sizes itself to the bubble (#61).
   - `MascotOverlayLayoutTests` renders both with an empty margin and fails if content lands outside; new mascot rows or bubble styles must keep it green.

---

## 🧪 5. Verification & Build Invariants

1. **Toolchain Execution**:
   - Always run with Xcode Swift toolchain: `/usr/bin/swift` or `xcrun swift`. Never rely on bare `swift` from `.swiftly` or third-party path overrides.
2. **Deterministic Tests**:
   - Run the full test suite before pushing: `xcrun swift test`.
   - All tests must pass with zero failures.
   - Every store or service test must use an isolated `UserDefaults(suiteName:)` domain with cleanup in `defer { defaults.removePersistentDomain(...) }`.
3. **Local Packaging**:
   - Test packaging and run locally with `./Scripts/package_and_run.sh release` to confirm signing and live AppKit execution.
   - The script automatically checks active Command Line Tools and falls back to `MacOSX26.5.sdk` if the active SDK is a preview seed (e.g. 27.x) missing standalone SwiftUI macro binaries.

---

## 📄 6. Ownership & Legal Policy

- Bitz is exclusively owned by **Akram Kasimi**.
- Released under a **Source-Available & Personal Hobbyist License** (see [LICENSE](LICENSE)).
- Personal, educational, and hobbyist use is permitted.
- Commercial redistribution, resale, white-labeling, or unauthorized commercial cloning is strictly prohibited.
