# Tasks: Cyber Audio Design (Purr, State Sounds, Agent Chimes)

**Spec**: [spec.md](spec.md) | **Plan**: [plan.md](plan.md)

## Work Package WP01: Audio Models, Settings Store & Protocol Architecture

**Goal**: Establish data models, `CyberAudioPlaying` protocol, test spy, and `UserDefaults`-backed `CyberAudioSettingsStore` (defaulting to OFF).
**Prompt**: `/tasks/WP01-audio-models-and-settings-store.md`
**Requirement Refs**: FR-001, NFR-003, C-001
**Dependencies**: none

### Included Subtasks
- T001: Implement `CyberSoundEvent` enum, sound event metadata, and suppression reasons in `src/Models/CyberAudioModels.swift`.
- T002: Implement `@MainActor public final class CyberAudioSettingsStore: ObservableObject` in `src/Models/CyberAudioSettingsStore.swift` with `UserDefaults` persistence, default-off setting, volume control, and per-event toggles.
- T003: Define `CyberAudioPlaying` protocol and `SpyCyberAudioPlayer` test double in `src/Services/CyberAudioPlaying.swift`.
- T004: Write comprehensive unit tests for `CyberAudioSettingsStore` persistence and domain isolation in `Tests/BitzTests/CyberAudioSettingsStoreTests.swift`.

---

## Work Package WP02: Sound Assets & Low-Latency Audio Engine

**Goal**: Synthesize license-clean audio assets, configure SPM bundle resources, and implement `CyberAudioService` using `AVAudioEngine` with preloaded PCM buffers and 0% idle CPU footprint.
**Prompt**: `/tasks/WP02-sound-assets-and-audio-engine.md`
**Requirement Refs**: FR-002, FR-003, FR-005, FR-010, NFR-001, NFR-002, NFR-004, C-003
**Dependencies**: WP01

### Included Subtasks
- T005: Create license-clean sound assets under `Resources/Sounds/` (`purr_loop.wav`, `burnout_glitch.wav`, `overheat_alarm.wav`, `agent_chime.wav`, `all_done_fanfare.wav`) and license document `Resources/Sounds/LICENSE.md`.
- T006: Configure `Package.swift` resource processing and `Scripts/package_and_run.sh` bundle copying for sound assets.
- T007: Implement `@MainActor public final class CyberAudioService: ObservableObject, CyberAudioPlaying` in `src/Services/CyberAudioService.swift` with preloaded `AVAudioPCMBuffer`s, looping purr with fade in/out gain ramp, and auto-pause when idle.
- T008: Write unit tests in `Tests/BitzTests/CyberAudioServiceTests.swift` covering buffer decoding, engine state management, and mock audio fallback.

---

## Work Package WP03: Event Wiring, Cooldowns, State Transitions & Context Suppression

**Goal**: Connect `WellnessPointEngine` state transitions and `AgentMonitorService` events to `CyberAudioService` with per-event cooldowns, global rate limits, and environmental suppression.
**Prompt**: `/tasks/WP03-event-wiring-cooldowns-and-suppression.md`
**Requirement Refs**: FR-004, FR-006, FR-007, FR-009, SC-001, SC-003
**Dependencies**: WP01, WP02

### Included Subtasks
- T009: Implement event cooldown and rate limiting logic (≥ 10s per agent, ≥ 60s all-done fanfare, ≥ 1.5s global rate limit, transition-only state sounds) with an injectable clock.
- T010: Implement `AudioEnvironmentDetector` in `src/Services/AudioEnvironmentDetector.swift` for checking system mute, active microphone/screen-sharing, and DND suppression.
- T011: Wire `CyberAudioService` to observe `WellnessPointEngine` state changes and `AgentMonitorService` agent lifecycle events.
- T012: Unit tests in `Tests/BitzTests/CyberAudioServiceTests.swift` and `Tests/BitzTests/AudioEnvironmentDetectorTests.swift` for state transition sounds, cooldown enforcement, and suppression behavior.

---

## Work Package WP04: Settings Window Tab & Menu Bar UI Integration

**Goal**: Provide user controls for cyber audio in the Settings window and menu bar dropdown.
**Prompt**: `/tasks/WP04-settings-and-menu-bar-ui.md`
**Requirement Refs**: FR-008, SC-001
**Dependencies**: WP01, WP02, WP03

### Included Subtasks
- T013: Implement `AudioSettingsTabView` in `src/Views/Settings/AudioSettingsTabView.swift` with master toggle, volume slider, per-event checkboxes, and "Test Sound" preview buttons.
- T014: Add the "Audio" tab to `SettingsRootView` in `src/Views/Settings/SettingsRootView.swift`.
- T015: Add a "Sound" submenu in `BitzMenuBarContentView` in `src/App/BitzApp.swift` for quick mute/unmute and volume adjustments.
- T016: Unit tests in `Tests/BitzTests/AudioSettingsViewsTests.swift` verifying UI bindings and settings modifications.

---

## Work Package WP05: Quality Verification, Invariants & Packaging

**Goal**: Validate full test suite execution, verify mascot invariants, check asset constraints, and test release packaging.
**Prompt**: `/tasks/WP05-quality-verification-and-packaging.md`
**Requirement Refs**: C-001, NFR-001, NFR-002, NFR-005, SC-002, SC-004, SC-005
**Dependencies**: WP01, WP02, WP03, WP04

### Included Subtasks
- T017: Run `xcrun swift test` and ensure all unit tests pass with zero failures.
- T018: Verify `MascotOverlayPanel.ignoresMouseEvents` invariant remains `true` and verify zero keyboard focus stealing.
- T019: Verify total sound asset bundle size is strictly < 300 KB and license provenance is complete.
- T020: Package and run with `./Scripts/package_and_run.sh release` to confirm live signing and AppKit execution.
