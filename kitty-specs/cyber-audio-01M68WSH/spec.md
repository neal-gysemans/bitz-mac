# Mission Specification: Cyber Audio Design (Purr, State Sounds, Agent Chimes)

**Mission Branch**: `feat/issue-21-cyber-audio`  
**Created**: 2026-10-31  
**Status**: Draft  
**Input**: User request: "start with issue 21 with spec-kitty" (Tracks GitHub issue #21: "Cyber Audio Design (purr, state sounds, agent chimes)")

## User Scenarios & Testing *(mandatory)*

### User Story 1 - Cyber Audio Settings & Master Toggle (Priority: P1)

Users have complete control over audio feedback through `CyberAudioSettingsStore` and dedicated UI in the Settings window and menu bar. Cyber audio defaults to **OFF** so current users experience no unexpected audio. When enabled, users can adjust volume (0.0–1.0, default 0.3) and toggle individual sound categories (purr, burnout, overheating, agent approval chime, all agents finished fanfare).

**Why this priority**: Essential foundation that guarantees non-intrusiveness (default off) and provides user configuration before any audio can play.

**Independent Test**: Enable audio in settings, change volume to 50%, toggle off agent chime, relaunch app; verify settings persist in `UserDefaults` and audio respects toggles.

**Acceptance Scenarios**:

1. **Given** a fresh Bitz launch, **When** checking `CyberAudioSettingsStore.isEnabled`, **Then** it defaults to `false` (muted/disabled).
2. **Given** the Settings window "Audio" section or Menu Bar "Sound" submenu, **When** the user toggles master audio on, **Then** sounds become audible according to per-event toggles.
3. **Given** master audio is enabled, **When** the user clicks "Test Sound" for an event, **Then** that sound preview plays at the configured master volume.
4. **Given** a specific sound toggle (e.g., `isAgentChimeEnabled = false`), **When** an agent needs approval, **Then** no sound is played even though master audio is enabled.

---

### User Story 2 - Low-Latency Audio Engine & Asset Decoupling (Priority: P1)

`CyberAudioService` manages low-latency playback of bundled 8-bit / cybernetic sound assets using `AVAudioEngine` with preloaded `AVAudioPCMBuffer`s (or `AVAudioPlayer` fallback). The audio engine automatically pauses / stops when silent so idle CPU usage remains at 0% with zero impact on battery life.

**Why this priority**: Core audio engine infrastructure required for instant (< 50 ms) playback without introducing CPU overhead or battery drain.

**Independent Test**: Trigger a sound event; measure time to audio playback (< 50 ms). Check CPU usage while idle; verify 0.0% audio thread usage.

**Acceptance Scenarios**:

1. **Given** `CyberAudioService` initialized, **When** app starts up, **Then** sound assets are preloaded into memory as mono PCM buffers without blocking the main UI thread.
2. **Given** no sounds are currently playing, **When** checking audio engine state, **Then** engine is stopped/idle and consumes zero CPU cycles.
3. **Given** `play(_ event: CyberSoundEvent)` is invoked, **When** audio begins, **Then** playback starts in < 50 ms.
4. **Given** a mock audio player injected into `CyberAudioService`, **When** running unit tests, **Then** test suite executes deterministically in headless CI without real audio hardware.

---

### User Story 3 - Mascot State Sound Transitions (Priority: P2)

Bitz plays distinct cybernetic sound effects when transitioning into key emotional/wellness states:
- Transition into `BitzState.burnout`: glitchy "power-down" sweep.
- Transition into `BitzState.overheating`: short fan-whir / thermal alarm glitch.
- Entering `BitzState.superCharged` or user petting: soft mechanical purr loop that smoothly ramps gain up, loops, and fades out when state ends.

**Why this priority**: Brings the "cyber cat" persona to life and alerts users when health/wellness status deteriorates without requiring direct visual attention.

**Independent Test**: Simulate burnout state; hear glitchy power-down sweep. Return to balanced; sound ends. Switch to superCharged; soft purr loops gently.

**Acceptance Scenarios**:

1. **Given** Bitz transitions from `balanced` to `burnout`, **When** audio is enabled, **Then** the glitchy power-down sound plays once.
2. **Given** Bitz remains in `burnout` across consecutive evaluation ticks, **When** audio is enabled, **Then** the power-down sound is NOT repeated (transition only).
3. **Given** Bitz enters `superCharged`, **When** purr is enabled, **Then** `CyberAudioService.setPurring(true)` fades in the mechanical purr loop at low volume.
4. **Given** Bitz exits `superCharged`, **When** `setPurring(false)` is called, **Then** the purr loop fades out smoothly within 300 ms.

---

### User Story 4 - AI Coding Agent Audio Notifications (Priority: P2)

Bitz observes `AgentMonitorService` and emits non-intrusive sound cues for critical agent events:
- Two-tone chime when an agent hits `.needsApproval` (waiting for human intervention).
- Short 8-bit fanfare when all active agents finish (`.done` leaving `activeAgents` empty).

**Why this priority**: Directly solves developer pain point of AI agents sitting idle waiting for approval while developer is in another Space or window.

**Independent Test**: Run a mock agent hitting `.needsApproval`; hear two-tone chime. Trigger agent `.done`; hear short fanfare.

**Acceptance Scenarios**:

1. **Given** an agent emits `AgentEventKind.needsApproval`, **When** audio is enabled, **Then** the two-tone chime plays.
2. **Given** repeated approval events for the same agent within 10 seconds, **When** the event fires, **Then** the chime is suppressed by per-agent cooldown.
3. **Given** multiple active agents, **When** the final agent completes and `activeAgents` becomes empty, **Then** the 8-bit all-done fanfare plays once (cooldown ≥ 60 s).

---

### User Story 5 - Environmental Suppression & Context Respect (Priority: P3)

Bitz respects the user's working context and suppresses audio automatically:
- System mute or zero master volume: skip playback entirely.
- macOS Focus / Do Not Disturb active: suppress sounds (optionally allow agent approval if configured).
- Active voice call or screen sharing detected (e.g. mic in use or conferencing apps): suppress mascot sounds so calls are never interrupted.
- Never steals audio session focus or ducks other applications.

**Why this priority**: Prevents embarrassing or disruptive noise during meetings, presentations, or focused quiet work.

**Independent Test**: Simulate mic in-use or system mute; trigger agent event; verify audio playback is cleanly skipped with no queuing.

**Acceptance Scenarios**:

1. **Given** system audio output is muted, **When** a sound event is triggered, **Then** playback is discarded immediately without buffering for later.
2. **Given** a microphone is active (CoreAudio device in use) or known conferencing app is frontmost, **When** a state change occurs, **Then** sound is suppressed.
3. **Given** macOS Do Not Disturb is active, **When** state sounds trigger, **Then** sounds are suppressed according to DND preferences.

---

## Edge Cases

- **Rapid State Fluttering**: Rapid toggling between states (e.g. under oscillating CPU/RAM) must not queue or stutter sounds; global rate limiter enforces minimum 1.5 s between non-purr sound events.
- **Audio Device Disconnect**: Unplugging headphones or switching output device while purr is looping must handle engine reset gracefully without crashing.
- **App Termination**: Quitting Bitz while audio engine is playing or purr is looping must shut down `AVAudioEngine` cleanly without audio pops or memory leaks.
- **Missing or Corrupt Assets**: If an audio file fails to load or decode, the service must log a warning and degrade silently without crashing or blocking app initialization.

## Requirements *(mandatory)*

### Functional Requirements

| ID | Title | User Story | Priority | Status |
|----|-------|------------|----------|--------|
| FR-001 | CyberAudioSettingsStore | Persist master audio toggle (default false), volume (0.0-1.0), and per-event toggles in UserDefaults. | P1 | Open |
| FR-002 | CyberAudioService Core | Implement `CyberAudioPlaying` protocol and `@MainActor final class CyberAudioService: ObservableObject` using `AVAudioEngine` and PCM buffers. | P1 | Open |
| FR-003 | Zero Idle CPU | Stop/pause `AVAudioEngine` when no audio is rendering to maintain 0.0% idle CPU footprint. | P1 | Open |
| FR-004 | State Transition Sounds | Trigger power-down on `burnout`, fan/glitch on `overheating`, blip on `charging` transitions only. | P2 | Open |
| FR-005 | Looping Mechanical Purr | Smoothly fade-in and loop mechanical purr during `superCharged` / petting, and fade-out upon exit. | P2 | Open |
| FR-006 | Agent Approval Chime | Play two-tone cyber chime when `AgentMonitorService` emits `needsApproval` (≥ 10s per-agent cooldown). | P2 | Open |
| FR-007 | Agent All-Done Fanfare | Play short 8-bit victory fanfare when `activeAgents` becomes empty after completion (≥ 60s cooldown). | P2 | Open |
| FR-008 | Settings & Menu Bar UI | Provide Sound settings tab in Settings window and Sound submenu in MenuBarExtra with volume & test buttons. | P2 | Open |
| FR-009 | Environmental Suppression | Skip audio when system is muted, Focus/DND active, or microphone/screen sharing in use. | P3 | Open |
| FR-010 | Small Bundled Assets | Include license-clean 8-bit sound clips under `Resources/Sounds/` (< 300 KB total) with `LICENSE.md`. | P1 | Open |

### Non-Functional Requirements

| ID | Title | Requirement | Category | Priority | Status |
|----|-------|-------------|----------|----------|--------|
| NFR-001 | Playback Latency | Latency from event trigger to audio hardware output MUST be < 50 ms. | Performance | High | Open |
| NFR-002 | Idle Energy Consumption | Zero audio thread activity and 0.0% CPU usage when no sounds are playing. | Performance | High | Open |
| NFR-003 | Default Off | All sounds MUST remain completely disabled by default until user explicitly turns audio on. | Usability | High | Open |
| NFR-004 | Asset Footprint | Total compressed asset payload of all sound files must not exceed 300 KB. | Resource | Medium | Open |
| NFR-005 | CI Determinism | All audio tests MUST pass deterministically without requiring physical sound hardware. | Quality | High | Open |

### Constraints

| ID | Title | Constraint | Category | Priority | Status |
|----|-------|------------|----------|----------|--------|
| C-001 | macOS 14.0+ & Apple Silicon | Built using Swift 6 / macOS 14 SDK with `AVFoundation` / `CoreAudio`. | Platform | High | Open |
| C-002 | No Audio Hijacking | Do not request exclusive audio hardware control or duck audio of background music/players. | Platform | High | Open |
| C-003 | License Cleanliness | Every sound asset must be custom synthesized or CC0/public domain, documented in `Resources/Sounds/LICENSE.md`. | Legal | High | Open |

## Success Criteria *(mandatory)*

### Measurable Outcomes

- **SC-001**: 100% of defined sound events (burnout, overheating, purr loop, agent chime, all-done fanfare) trigger reliably when enabled.
- **SC-002**: Audio engine pauses when idle, adding zero measurable background CPU overhead (< 0.1% CPU).
- **SC-003**: Per-event cooldowns prevent audio spam during repeated evaluations or rapid agent notifications.
- **SC-004**: Total bundled sound assets stay under 300 KB with explicit license provenance.
- **SC-005**: 100% test pass rate across all new and existing unit tests via `xcrun swift test`.
