# Tasks: Archetype-Specific Sound Design for Mascot Roster

**Spec**: [spec.md](spec.md) | **Plan**: [plan.md](plan.md)

## Work Package WP01: Procedural Asset Generation & Licensing Documentation

**Goal**: Synthesize 5 deterministic, license-clean companion reaction sound WAV files (< 100 KB each, 22,050 Hz Mono, ≤ 3.0 s) via a checked-in script, verify them, and document parameters in `src/Resources/Sounds/LICENSE.md`.
**Prompt**: `/tasks/WP01-procedural-asset-generation.md`
**Requirement Refs**: FR-007, NFR-003, C-002, C-003, SC-001, SC-006
**Dependencies**: none

### Included Subtasks
- T001: Create deterministic sound synthesis script `Scripts/generate_archetype_sounds.py` using Python standard library (`wave`, `struct`, `math`) for Drako, Byte, Aero, Pixel, and Volt.
- T002: Run generator script to produce `drako_plasma_rumble.wav`, `byte_servo_whine.wav`, `aero_turbine_spool.wav`, `pixel_stepper_click.wav`, and `volt_capacitor_chirp.wav` in `src/Resources/Sounds/`.
- T003: Verify file sizes (< 100 KB each), durations (≤ 3.0 s), and formats (Mono 22,050 Hz Int16 PCM).
- T004: Update `src/Resources/Sounds/LICENSE.md` with algorithmic recipes, acoustic descriptions, and CC0 / Public Domain dedication.

---

## Work Package WP02: Companion Sound Metadata & Protocol Architecture

**Goal**: Extend `MascotCharacter` with reaction sound metadata and update `CyberAudioPlaying` protocol and test spy with companion reaction playback support.
**Prompt**: `/tasks/WP02-companion-sound-metadata-and-protocol.md`
**Requirement Refs**: FR-001, FR-006, NFR-005
**Dependencies**: none

### Included Subtasks
- T005: Add `reactionSoundDisplayName: String` and `reactionSoundFileName: String` to `MascotCharacter` in `src/Models/MascotCharacterModels.swift`.
- T006: Extend `CyberAudioPlaying` protocol in `src/Services/CyberAudioPlaying.swift` with `func playReactionSound(for character: MascotCharacter)` and provide default protocol extension implementation.
- T007: Update `SpyCyberAudioPlayer` to track `playedCharacterReactions: [MascotCharacter]`.
- T008: Add unit tests in `Tests/BitzTests/MascotCharacterTests.swift` covering all 6 companions' sound metadata.

---

## Work Package WP03: Dynamic Companion Sound Routing & Audio Service

**Goal**: Preload companion reaction audio buffers in `CyberAudioService`, wire dynamic character tracking from `AvatarCharacterStore`, implement fallback to `purr_loop.wav`, and wire observation in `BitzApp.swift`.
**Prompt**: `/tasks/WP03-audio-service-routing-and-fallback.md`
**Requirement Refs**: FR-001, FR-002, FR-003, NFR-001, NFR-002, NFR-004, NFR-005, C-001, SC-002, SC-003
**Dependencies**: WP01, WP02

### Included Subtasks
- T009: Preload companion sound buffers in `CyberAudioService.loadedCharacterBuffers` with format alignment.
- T010: Implement `selectedCharacterProvider` and `observe(characterStore: AvatarCharacterStore)` in `CyberAudioService`.
- T011: Implement companion buffer resolution with universal fallback to `loadedBuffers[.purr]` (FR-003).
- T012: Update `playPurrBurst(for character: MascotCharacter? = nil)` and implement `playReactionSound(for character: MascotCharacter)`.
- T013: Wire `audioService.observe(characterStore: self.characterStore)` in `BitzApp.swift`.
- T014: Add unit tests in `Tests/BitzTests/CyberAudioServiceTests.swift` covering companion buffer loading, fallback on missing asset, companion change routing, and suppression parity.

---

## Work Package WP04: Settings UI Integration (Audio Tab & Roster Audition)

**Goal**: Surface active companion reaction sound in Settings → Audio, and provide companion sound audition preview buttons on each card in Settings → Appearance → Character Roster.
**Prompt**: `/tasks/WP04-settings-ui-integration.md`
**Requirement Refs**: FR-004, FR-005, C-004, SC-004
**Dependencies**: WP02, WP03

### Included Subtasks
- T015: Update `AudioSettingsTabView` to accept `characterStore` and dynamically render active companion reaction sound name in the reaction toggle row with functioning Test button.
- T016: Pass `audioPlayer` down through `SettingsRootView` → `AppearanceSettingsTabView` → `AppearanceCharacterRosterSectionView`.
- T017: Add audition speaker button on each companion card in `AppearanceCharacterRosterSectionView` allowing preview without changing selection or triggering Pro popovers.
- T018: Add/update unit tests in `Tests/BitzTests/AudioSettingsViewsTests.swift` verifying dynamic labels, test button actions, and roster preview triggers.

---

## Work Package WP05: Verification, CPU Invariants & Packaging

**Goal**: Execute full test suite, verify idle CPU `< 2%` in release build, check package DMG/App signing, and validate acceptance criteria.
**Prompt**: `/tasks/WP05-verification-and-packaging.md`
**Requirement Refs**: NFR-001, NFR-002, NFR-005, C-004, SC-005
**Dependencies**: WP01, WP02, WP03, WP04

### Included Subtasks
- T019: Run full test suite `xcrun swift test` and ensure 0 failures.
- T020: Package release build `./Scripts/package_and_run.sh release`.
- T021: Verify idle CPU `< 2%` with Settings closed via `top` per AGENTS.md §2.8.
- T022: Final manual sound listening check and acceptance verification.
