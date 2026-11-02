# Implementation Plan: Cyber Audio Design (Purr, State Sounds, Agent Chimes)

**Branch**: `feat/issue-21-cyber-audio` | **Date**: 2026-10-31 | **Spec**: [spec.md](spec.md)
**Input**: Feature specification from `/kitty-specs/cyber-audio-01M68WSH/spec.md` (Tracks GitHub issue #21)

## Summary

Add an optional, lightweight Cyber Audio layer to Bitz that produces 8-bit / cybernetic sound effects tied to mascot wellness states and AI coding agent lifecycle events. The audio engine uses `AVAudioEngine` with preloaded PCM buffers for instant (< 50 ms) playback, stops when idle for 0.0% CPU overhead, enforces per-event cooldowns and global rate limits to prevent spam, respects user context (mute, DND, active calls/screen-sharing), and is managed by a UserDefaults-backed `CyberAudioSettingsStore` (defaulting to OFF) exposed in the Settings window and menu bar.

## Technical Context

**Language/Version**: Swift 6.0 (swift-tools-version 6.0)  
**Primary Dependencies**: AppKit, SwiftUI, AVFoundation (`AVAudioEngine`, `AVAudioPlayerNode`, `AVAudioPCMBuffer`, `AVAudioFormat`), CoreAudio  
**Storage**: `UserDefaults` (suite-isolated in tests via `UserDefaults(suiteName:)`) backing `CyberAudioSettingsStore`  
**Testing**: XCTest in `Tests/BitzTests/` (`CyberAudioServiceTests`, `CyberAudioSettingsStoreTests`, `CyberAudioIntegrationTests`)  
**Target Platform**: macOS 14.0+, Apple Silicon  
**Project Type**: Single Swift package (`BitzCore` library + `Bitz` executable)  
**Performance Goals**: < 50 ms audio trigger-to-sound latency; 0.0% CPU usage when idle (engine paused/stopped); total sound asset bundle size < 300 KB  
**Constraints**: 100% click-through guarantee preserved (`ignoresMouseEvents = true`); zero focus stealing; default OFF; license-clean CC0 or custom synthesized audio assets  
**Scale/Scope**: 1 new settings store (`CyberAudioSettingsStore`), 1 new service (`CyberAudioService` + protocol `CyberAudioPlaying`), 1 audio tab/section in Settings (`AudioSettingsTabView`), sound menu wiring in `BitzApp`, 5 bundled sound assets under `Resources/Sounds/`, and comprehensive unit tests  

## Charter Check

- **Click-Through Guarantee**: PASS. Audio playback operates strictly as a background/service layer without modifying `MascotOverlayPanel` or `SpeechBubblePanel` mouse event transparency (`ignoresMouseEvents = true`).
- **Zero Keyboard Focus Stealing**: PASS. Audio triggers and playback involve no window activation or key-window changes.
- **Multi-Display & Screen Clamping**: PASS. Audio is non-spatial/ambient stereo output; screen geometry invariants are untouched.
- **Deterministic Tests**: PASS. All unit tests use an injected protocol mock / clock (`SpyAudioPlayer` / test clock) and isolated `UserDefaults(suiteName:)` domains with `defer { defaults.removePersistentDomain(...) }`. Real audio hardware is never required in CI.
- **Resource Footprint**: PASS. `AVAudioEngine` stops/pauses when no audio is playing, guaranteeing 0.0% idle CPU overhead.

## Design Decisions

1. **Protocol-Driven Audio Architecture**:
   - Define `CyberAudioPlaying` protocol to decouple state logic, cooldowns, and suppression from `AVFoundation`:
     ```swift
     @MainActor
     public protocol CyberAudioPlaying: AnyObject {
         func play(_ event: CyberSoundEvent)
         func setPurring(_ on: Bool)
         func stopAll()
     }
     ```
   - Implement `CyberAudioService` conforming to `CyberAudioPlaying` and `ObservableObject`.
   - Provide a mock/spy implementation `SpyCyberAudioPlayer` for unit testing state transitions, cooldown timers, suppression rules, and event triggers without physical audio hardware.

2. **AVAudioEngine Low-Latency Buffer Engine**:
   - Decodes bundled audio files (WAV/CAF, 44.1kHz mono/stereo) into memory at startup as `AVAudioPCMBuffer`s.
   - Uses an `AVAudioPlayerNode` pool attached to the engine's `mainMixerNode`.
   - Mechanical Purr: Uses a dedicated looping player node with an exponential/linear gain ramp (`fader`) to smoothly fade in over ~250 ms and fade out over ~300 ms.
   - Idle Power Optimization: When all nodes finish playing and purring is inactive, the engine calls `pause()` / `stop()` so no background audio rendering loop runs while silent.

3. **Event Cooldowns & Global Rate Limiter**:
   - Prevent acoustic fatigue and sound spam:
     - State sounds (`burnout`, `overheating`, `charging`): Trigger **only on state transitions** (new state != old state), never on periodic evaluation ticks.
     - Agent needs approval chime: Cooldown ≥ 10 seconds per unique agent ID.
     - Agent all-done fanfare: Cooldown ≥ 60 seconds globally.
     - Global rate limiter: Minimum 1.5 seconds between discrete one-shot sounds.
   - An injectable clock/time provider (`DateProvider` or time interval lambda) allows unit tests to simulate passing time instantly.

4. **Settings Store & Persistence**:
   - Create `CyberAudioSettingsStore` following the established `AvatarOpacityStore` / `AvatarScaleStore` pattern:
     - `isEnabled`: Bool (default: `false` — default off ensures existing silent experience).
     - `volume`: Double (range 0.0–1.0, default: `0.3`).
     - `isPurrEnabled`: Bool (default: `true`).
     - `isBurnoutEnabled`: Bool (default: `true`).
     - `isOverheatEnabled`: Bool (default: `true`).
     - `isAgentChimeEnabled`: Bool (default: `true`).
     - `isAllDoneFanfareEnabled`: Bool (default: `true`).
   - Uses `UserDefaults` with key prefix `bitz.audio.*`.

5. **Context & Environmental Suppression**:
   - Check system audio output: If output volume is 0 or muted, skip playback.
   - Check active calls/microphone: Query CoreAudio default input device running status (`kAudioDevicePropertyDeviceIsRunningSomewhere`). If microphone or screen capture is actively streaming, suppress sounds.
   - Check Focus / Do Not Disturb: Check system DND status where accessible without private APIs, falling back to user settings.

6. **Bundled Audio Assets & Licensing**:
   - Sound assets placed in `Resources/Sounds/`:
     - `purr_loop.wav` (soft mechanical cyber purr)
     - `burnout_glitch.wav` (power-down glitch sweep)
     - `overheat_alarm.wav` (short fan-whir / thermal alarm)
     - `agent_chime.wav` (two-tone attention chime)
     - `all_done_fanfare.wav` (8-bit short fanfare)
   - Created with custom synthesizer scripts (sfxr / algorithmic WAV generation) to ensure 100% CC0 public domain provenance.
   - Documented in `Resources/Sounds/LICENSE.md` with source generator parameters.

7. **UI Integration**:
   - Add "Audio" tab or section to the Settings window (`AudioSettingsTabView` / in `SettingsRootView`).
   - Add "Sound" submenu in the menu bar dropdown (`BitzMenuBarContentView`) for quick mute/unmute and volume adjustments.
   - Include "Test" buttons next to each sound effect for instant preview.

## Project Structure

### Documentation (this mission)

```
kitty-specs/cyber-audio-01M68WSH/
├── plan.md              # This file
├── spec.md              # Feature specification
└── tasks.md             # Tasks decomposition generated by spec-kitty
```

### Source Code Layout

```
Resources/
└── Sounds/
    ├── LICENSE.md                  # Asset license documentation & synth params
    ├── agent_chime.wav             # Two-tone cyber chime
    ├── all_done_fanfare.wav        # Short 8-bit completion fanfare
    ├── burnout_glitch.wav          # Power-down glitch sweep
    ├── overheat_alarm.wav          # Thermal warning sound
    └── purr_loop.wav               # Looping soft mechanical purr

src/
├── Models/
│   ├── CyberAudioModels.swift      # CyberSoundEvent enum, AudioSuppressionReason
│   └── CyberAudioSettingsStore.swift # UserDefaults-backed settings store
├── Services/
│   ├── CyberAudioPlaying.swift     # CyberAudioPlaying protocol + mock for tests
│   ├── CyberAudioService.swift     # AVAudioEngine buffer playback & purr loop
│   └── AudioEnvironmentDetector.swift # CoreAudio mic/call/mute suppression checks
├── Views/
│   └── Settings/
│       └── AudioSettingsTabView.swift # Dedicated Audio tab in Settings window
└── App/
    └── BitzApp.swift               # Sound menu bar integration & service wiring

Tests/
└── BitzTests/
    ├── CyberAudioSettingsStoreTests.swift # Persistence, defaults, key isolation
    ├── CyberAudioServiceTests.swift       # State transitions, cooldowns, mock engine
    └── AudioEnvironmentDetectorTests.swift # Suppression logic tests
```

## Implementation Concern Map

### IC-01 — Audio Models, Protocol, & Settings Store
- **Purpose**: Establish data models, `CyberAudioPlaying` protocol, `SpyCyberAudioPlayer`, and `CyberAudioSettingsStore`.
- **Relevant requirements**: FR-001, NFR-003, C-001
- **Affected surfaces**: `src/Models/CyberAudioModels.swift`, `src/Models/CyberAudioSettingsStore.swift`, `src/Services/CyberAudioPlaying.swift`
- **Sequencing/depends-on**: none
- **Risks**: Ensuring `UserDefaults` keys don't collide and tests use clean isolated domains.

### IC-02 — Audio Assets & AVAudioEngine Service Core
- **Purpose**: Generate license-clean sound assets, configure `Package.swift` resource bundling, implement `CyberAudioService` with preloaded PCM buffers, purr fading loop, and 0% idle CPU behavior.
- **Relevant requirements**: FR-002, FR-003, FR-005, FR-010, NFR-001, NFR-002, NFR-004, C-003
- **Affected surfaces**: `Resources/Sounds/*`, `Package.swift`, `Scripts/package_and_run.sh`, `src/Services/CyberAudioService.swift`
- **Sequencing/depends-on**: IC-01
- **Risks**: Audio device configuration changes or headless test runs without audio devices; mitigated by protocol mock and fallback player.

### IC-03 — Event Wiring, State Transitions, Cooldowns, & Suppression
- **Purpose**: Connect `WellnessPointEngine` state transitions and `AgentMonitorService` events to `CyberAudioService` with per-event cooldowns, global rate limiting, and environmental suppression (mute/mic).
- **Relevant requirements**: FR-004, FR-006, FR-007, FR-009, SC-001, SC-003
- **Affected surfaces**: `src/Services/CyberAudioService.swift`, `src/Services/AudioEnvironmentDetector.swift`, `src/Services/AgentMonitorService.swift`, `src/Services/WellnessPointEngine.swift`
- **Sequencing/depends-on**: IC-02
- **Risks**: Ensuring Combine subscriptions or notifications do not create retain cycles or duplicate triggers.

### IC-04 — Settings Window & Menu Bar UI
- **Purpose**: Create `AudioSettingsTabView` in the Settings window, add Sound submenu in `BitzApp.swift`, and expose volume/sound tests.
- **Relevant requirements**: FR-008, SC-001
- **Affected surfaces**: `src/Views/Settings/AudioSettingsTabView.swift`, `src/Views/Settings/SettingsRootView.swift`, `src/App/BitzApp.swift`
- **Sequencing/depends-on**: IC-01, IC-03
- **Risks**: Menu bar extra sizing constraints; settings window tab bar layout.

### IC-05 — Verification & End-to-End Quality
- **Purpose**: Comprehensive test coverage across all stores, engine, service, UI previews, and packaging verification via `./Scripts/package_and_run.sh`.
- **Relevant requirements**: NFR-005, SC-002, SC-004, SC-005
- **Affected surfaces**: `Tests/BitzTests/*`
- **Sequencing/depends-on**: IC-01, IC-02, IC-03, IC-04
- **Risks**: None.
