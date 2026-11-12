# Implementation Plan: Archetype-Specific Mascot Roster Sound Design

**Branch**: `feat/issue-150-archetype-sound-design` | **Date**: 2026-11-12 | **Spec**: [spec.md](./spec.md)
**Input**: GitHub issue #150: "[Feature]: Archetype-Specific Sound Design for Mascot Roster (Replacing Universal Cat Purr)" (Closes #150, refs #150)

---

## Summary

Currently, all six companion archetypes in `MascotCharacter` (Bitz, Drako, Byte, Aero, Pixel, Volt) play `purr_loop.wav` (a cat purr) during petting reactions and Super Charged periodic comfort bursts. This plan introduces companion-specific reaction audio identities:
1. **Procedural Sound Asset Generation**: Synthesize 5 deterministic, high-quality audio files (< 100 KB each, 22,050 Hz Mono WAV, ≤ 3.0 s) via a checked-in Python script `Scripts/generate_archetype_sounds.py`. Keep Bitz's existing `purr_loop.wav` (132 KB) as is and as universal fallback.
2. **Domain Models & Preloading**: Enrich `MascotCharacter` with reaction sound metadata (`reactionSoundDisplayName`, `reactionSoundFileName`). Preload companion buffers in `CyberAudioService.loadedCharacterBuffers` with graceful fallback to `loadedBuffers[.purr]` (FR-003).
3. **Dynamic Routing**: Wire `AvatarCharacterStore` into `CyberAudioService` (via `selectedCharacterProvider` and observation) so petting reactions and Super Charged bursts play the active companion's sound with zero restart lag. Provide `playReactionSound(for: MascotCharacter)` in `CyberAudioPlaying` for UI auditions.
4. **Settings Integration**:
   - **Settings → Audio**: Dynamically label the reaction event row with the active companion and reaction sound (e.g., "Companion Reaction: Drako — Plasma Wyvern Rumble") and wire its preview button.
   - **Settings → Appearance → Character Roster**: Add an audition preview button to each companion card, allowing users to audition sounds (including locked Pro companions) without changing selection or triggering upgrade popovers.
5. **Invariants & Safety**: Maintain zero idle CPU (< 2% with Settings closed, 0.0% audio idle CPU), memory (< 70 MB), suppression gating parity (system mute, mic/call, Focus/DND), and backward compatibility for the existing `isPurrEnabled` toggle.

---

## Technical Context

- **Language/Version**: Swift 6.0 (`Package.swift`), macOS 14+ (`arm64` / Apple Silicon primary).
- **Primary Frameworks**: AppKit, SwiftUI, AVFoundation (`AVAudioEngine`, `AVAudioPCMBuffer`, `AVAudioPlayerNode`), CoreAnimation (`CALayer`).
- **Dependencies**: Zero external SwiftPM dependencies; standalone Python 3 audio generator script in `Scripts/` using standard library `wave`, `math`, `struct`.
- **Target Platform**: macOS 14.0+ (Sonoma, Sequoia).
- **Audio Assets**:
  - `purr_loop.wav` (Bitz, Cyber Cat — existing asset, 132 KB, 22,050 Hz Mono Int16)
  - `drako_plasma_rumble.wav` (Drako, Cyber Dragon — low-frequency sub-bass flame-core rumble, ~60–80 KB)
  - `byte_servo_whine.wav` (Byte, Cyber Hound — tactical servo whine / metallic pant / chirp, ~50–70 KB)
  - `aero_turbine_spool.wav` (Aero, Hover Sentinel — antigravity turbine spool / ion levitation tone, ~60–80 KB)
  - `pixel_stepper_click.wav` (Pixel, Retro Mech — hydraulic stepper click / cassette relay whir, ~40–60 KB)
  - `volt_capacitor_chirp.wav` (Volt, Cyber Bunny — high-voltage capacitor chirp / bionic pulse, ~40–60 KB)
- **Performance Budget**:
  - Desktop idle CPU: `< 2%` in release build with Settings closed.
  - Audio rendering engine: Paused/stopped when silent (0.0% audio idle CPU).
  - Memory: Total RSS `< 70 MB`; buffers loaded once at launch.
  - Latency: Reaction sound starts within `50 ms`.
- **Constraints**:
  - `AGENTS.md` §2 & §4 invariants strictly preserved.
  - Closed secondary windows detach content (`contentViewController = nil`).
  - Unit tests use isolated `UserDefaults(suiteName:)` domains.

---

## Project Structure & Implementation Concerns

```
Scripts/
└── generate_archetype_sounds.py        # IC-01: Deterministic audio generator for 5 companion WAVs

src/
├── Models/
│   ├── MascotCharacterModels.swift     # IC-02: Companion sound metadata (display name, filename)
│   ├── CyberAudioModels.swift          # IC-02: Sound event mapping & display extensions
│   └── CyberAudioSettingsStore.swift   # IC-02: Toggle continuity & reaction helpers
├── Services/
│   ├── CyberAudioPlaying.swift         # IC-03: Protocol audition API & Spy updates
│   └── CyberAudioService.swift         # IC-03: Buffer preloading, dynamic character routing & fallback
├── Views/Settings/
│   ├── AudioSettingsTabView.swift      # IC-04: Dynamic reaction sound row label & preview
│   ├── AppearanceSettingsTabView.swift # IC-04: Pass audioPlayer down
│   ├── AppearanceCharacterRosterSectionView.swift # IC-04: Card audition speaker preview buttons
│   └── SettingsRootView.swift          # IC-04: Wire characterStore & audioPlayer
└── App/
    └── BitzApp.swift                   # IC-03: Wire characterStore observation to audioService

Tests/BitzTests/
├── MascotCharacterTests.swift          # IC-05: Metadata & sound mapping tests
├── CyberAudioServiceTests.swift        # IC-05: Companion routing, fallback, and audition tests
└── AudioSettingsViewsTests.swift       # IC-05: Dynamic label & preview button tests
```

### Implementation Concern Map

- **IC-01: Asset Generator & Bundled Audio**:
  - Create `Scripts/generate_archetype_sounds.py` synthesizing 5 WAVs (Mono, 22,050 Hz, 16-bit PCM, ≤ 3.0 s, < 100 KB).
  - Place output in `src/Resources/Sounds/`.
  - Update `src/Resources/Sounds/LICENSE.md` documenting generator equations, parameters, and CC0 dedication.
- **IC-02: Domain Models & Sound Metadata**:
  - Add `reactionSoundDisplayName: String` and `reactionSoundFileName: String` to `MascotCharacter`.
  - Validate naming conventions and mapping for all 6 companions.
  - Maintain preference continuity for `isPurrEnabled` in `CyberAudioSettingsStore`.
- **IC-03: Audio Service & Dynamic Routing**:
  - Update `CyberAudioPlaying` protocol with `func playReactionSound(for character: MascotCharacter)`.
  - Update `SpyCyberAudioPlayer` recording `playedCharacterReactions: [MascotCharacter]`.
  - In `CyberAudioService`, add `loadedCharacterBuffers: [MascotCharacter: AVAudioPCMBuffer]`.
  - Add `selectedCharacterProvider: @Sendable () -> MascotCharacter` and `observe(characterStore: AvatarCharacterStore)`.
  - Update `playPurrBurst(for character: MascotCharacter? = nil)` to retrieve companion buffer with fallback to `purr_loop.wav`.
  - Wire character observation in `BitzApp.swift`.
- **IC-04: Settings UI (Audio & Roster Audition)**:
  - In `AudioSettingsTabView`, pass `characterStore` and dynamically render reaction sound title: `"Companion Reaction: \(character.name) — \(character.reactionSoundDisplayName)"`.
  - In `AppearanceCharacterRosterSectionView`, add an audition button per card calling `audioPlayer?.playReactionSound(for: character)`.
  - Ensure auditioning works for locked Pro companions without opening Pro popover or changing selection.
- **IC-05: Deterministic Unit & Layout Verification**:
  - Add test coverage for all 6 companion sound mappings, missing-asset fallback, companion change routing, and preview triggers.
  - Verify package build, app launch, and `< 2%` idle CPU.
