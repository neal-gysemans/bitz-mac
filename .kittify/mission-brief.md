<!-- spec-kitty intake: ingested from issues/2026-10-31-cyber-audio-design.md at 2026-10-31T11:51:11.786560+00:00 -->
<!-- brief_hash: f0504fecab05450f33758df0b5afa41da3d9f7f9022d6424cdaebdce86fc2fda -->

# [Feature]: Cyber Audio Design (purr, state sounds, agent chimes)

**Issue**: refs #21

## Summary
Add an optional Cyber Audio layer: low-latency 8-bit / cybernetic sound effects tied to mascot states and agent events.

## Environment
- **Product/Service**: bitz-mac (Bitz the Cyber Cat)
- **Region/Version**: current `main`
- **Browser/OS**: macOS 14.0+ (Apple Silicon)

## Problem or Motivation
Bitz communicates its state today purely visually (Rive animations / visor color driven by `BitzState` in `src/Services/WellnessPointEngine.swift`, and agent popups from `AgentMonitorService` in `src/Services/AgentMonitorService.swift`). When the mascot is out of the user's line of sight (another Space, full-screen editor, second monitor), important moments are missed:

- An AI agent hits `.needsApproval` and sits idle waiting for the user.
- All tracked agents finish (`activeAgents` becomes empty after `.done`).
- Bitz slides into `.burnout` / `.overheating` — exactly when the user is too heads-down to look at the corner of the screen.

A small, tasteful audio layer would make Bitz feel alive (a "cyber cat" that purrs) and make agent hand-offs noticeable, without becoming noisy.

## Proposed Solution / Feature
Add an optional **Cyber Audio** layer: low-latency 8-bit / cybernetic sound effects tied to mascot states and agent events.

### Sound Map (Initial Set)

| Trigger | Source | Sound |
|---|---|---|
| Flow / petting | `BitzState.superCharged` (and future petting interaction) | Soft looping mechanical purr (fades in/out, very low volume) |
| Burnout | transition into `BitzState.burnout` | Glitchy "power-down" sweep |
| Overheating | transition into `BitzState.overheating` | Short fan-whir / thermal alarm glitch |
| Agent needs attention | `AgentEventKind.needsApproval` in `AgentMonitorService.handleEvent(_:)` | Two-tone chime |
| All agents finished | `.done` that leaves `activeAgents` empty | Short 8-bit fanfare |
| (optional) Charging | `BitzState.charging` | Soft "power-up" blip |

### Architecture

- New `src/Services/CyberAudioService.swift` (`@MainActor final class CyberAudioService: ObservableObject`) that:
  - Uses `AVAudioEngine` + a small pool of `AVAudioPlayerNode`s with **preloaded `AVAudioPCMBuffer`s** (decoded once at launch) for low latency; the purr uses a looping buffer with a gain ramp.
  - Stops/pauses the engine when nothing is playing so idle CPU ≈ 0 (no running render loop while silent).
  - Exposes `play(_ event: CyberSoundEvent)` and `setPurring(_ on: Bool)`; observes `WellnessPointEngine`'s published state and `AgentMonitorService`'s `activeAgents` / events via Combine rather than modifying their logic heavily.
  - Per-event **cooldowns** (e.g. chime ≥ 10 s per agent, fanfare ≥ 60 s, burnout/overheat only on state *transition*, never on repeat evaluations) plus a global rate limit to prevent spam.
- New `src/Models/CyberAudioSettingsStore.swift` following the existing `AvatarOpacityStore` / `AvatarScaleStore` pattern (UserDefaults-backed `ObservableObject`, owned by the app delegate in `src/App/BitzApp.swift` next to `scaleStore` / `opacityStore` / `positionStore`):
  - `isEnabled` master toggle — **default off** (or "subtle" preset at low volume if enabled).
  - `volume` (0.0–1.0, default ~0.3), applied via the engine's main mixer.
  - Per-event toggles (purr, burnout, overheating, agent chime, all-done fanfare).
- Menu bar UI in `BitzApp.swift` / Settings window alongside other tabs/menus: Audio settings section with master toggle, volume slider, per-event toggles, and a "Test sounds" action.

### Respecting the User's Context
- Respect system mute / zero output volume (skip playback rather than queueing).
- Respect macOS **Focus / Do Not Disturb** when detectable (suppress everything except, optionally, the agent-approval chime behind an explicit opt-in).
- Suppress sounds while **screen sharing or in a call** when detectable (e.g. microphone/camera in use via CoreAudio `kAudioDevicePropertyDeviceIsRunningSomewhere`, or known conferencing apps frontmost). If detection isn't reliable, document the limitation and fall back to the user's toggles.
- Never steal audio focus or duck other apps.

### Assets
- Small bundled assets (target < 300 KB total), short mono CAF/WAV (or AAC) clips under a `Resources/Sounds/` folder.
- License-clean only: custom-made (e.g. synthesized with sfxr/jsfxr/ChipTone) or CC0, with a `Resources/Sounds/LICENSE.md` / credits file listing each asset's source and license.

## Acceptance Criteria
- [ ] `CyberAudioService` plays preloaded buffers via `AVAudioEngine` (or `AVAudioPlayer` fallback) with perceptibly instant (< ~50 ms) playback.
- [ ] Sounds trigger for: purr during `superCharged`/petting, power-down on entering `burnout`, glitch on entering `overheating`, chime on `needsApproval`, fanfare when all active agents are done.
- [ ] State sounds fire only on state **transitions**; per-event cooldowns and a global rate limit prevent spam (covered by unit tests with an injected clock).
- [ ] `CyberAudioSettingsStore` persists master toggle (default **off**), volume, and per-event toggles in UserDefaults, following the `AvatarOpacityStore` pattern.
- [ ] Settings & menu bar exposed: master toggle, volume control, per-event toggles, and a "Test sounds" action.
- [ ] Playback is skipped when system output is muted, when Focus/DND is active (if detectable), and during calls/screen sharing (if detectable); limitations are documented.
- [ ] Idle CPU usage is unchanged vs. baseline when no sound is playing (engine paused/stopped when idle).
- [ ] Bundled assets are small (< 300 KB total) and license-clean (custom or CC0) with a credits/LICENSE file.
- [ ] Unit tests cover state→sound mapping, cooldowns, settings persistence, and suppression rules using a mock audio player.
