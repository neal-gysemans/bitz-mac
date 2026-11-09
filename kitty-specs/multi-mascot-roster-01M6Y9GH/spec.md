# Mission Specification: Multi-Mascot Character Roster & Selection

**Mission Branch**: `feat/issue-30-multi-mascot-roster`  
**Created**: 2026-11-08  
**Status**: Ready for Planning  
**Input**: User request & GitHub issue #30: "[Feature]: Multi-Mascot Character Roster & Selection (Cyber Cat, Cyber Dog, Hover Drone, Retro Mech)" (Tracks GitHub issue #30, refs #30, Closes #30)

---

## 1. Executive Summary & Purpose for Contributors

Currently, Bitz is tied to a single character silhouette: the Cyber Cat vector rig inside `src/Views/BitzCharacterView.swift` and `src/Views/MascotOverlayView.swift`. While Bitz the Cyber Cat is beloved, users have diverse preferences for their desktop companions—from a loyal cyber-pup (`Byte`) to an antigravity hover sentinel (`Aero`), a retro CRT pocket mech (`Pixel`), or a high-energy cyber-bunny (`Volt`).

This mission decouples character visual representations from the core wellness, telemetry, and AI agent monitoring engine by introducing a **Multi-Mascot Character Roster & Selection System** with 5 procedural vector companions, persisted user preferences (`avatarSelectedCharacter`), Menu Bar quick-switching, a visual Character Gallery in Settings, custom palette & Bitz Pro tier integration, and zero idle CPU regression (`< 2%` CPU via CoreAnimation layer offloading).

---

## 2. Cyber Character Roster

| Character ID | Name | Archetype | Tier | Signature Visual Anatomy & Procedural Motion |
|---|---|---|---|---|
| `cyber_cat` | **Bitz** | The Cyber Cat (Default) | Free | Pointed triangular cyber ears, wrap-around LED visor, front paw trot/tap, swishing cyber tail. |
| `cyber_dog` | **Byte** | The Cyber Dog | Bitz Pro | Articulated floppy mechanical ears, snout & collar tag core, rapid antenna tail wag, happy panting visor (`^ w ^`). |
| `hover_drone` | **Aero** | The Hover Sentinel | Bitz Pro | Antigravity tech-orb chassis, dual stabilizing side wings, pulsing lower thruster ring, 360° cyclops sensor optic. |
| `retro_mech` | **Pixel** | The Retro Mech | Bitz Pro | Boxy CRT monitor chassis, dual top antenna beacons, articulated servo clamp hands, scanline terminal expressions. |
| `cyber_bunny` | **Volt** | The Cyber Bunny | Bitz Pro | Tall dual-channel upright antenna ears that perk/droop by state, cotton-capacitor tail puff, nimble hop cycle. |

---

## 3. User Scenarios & Testing *(mandatory)*

### User Story 1 - Selecting & Persisting a Companion Character (Priority: P1)

A user with Bitz Pro (or in unrestricted developer mode) wants to switch their desktop companion from Bitz (Cyber Cat) to Byte (Cyber Dog), Aero (Hover Drone), Pixel (Retro Mech), or Volt (Cyber Bunny). Their selection immediately updates the desktop mascot overlay, Menu Bar status icon/menu, and Settings live preview, and persists across app restarts in `UserDefaults` under `"avatarSelectedCharacter"`.

**Why this priority**: Core value proposition of Issue #30.

**Independent Test**: Instantiate `AvatarCharacterStore` with isolated `UserDefaults(suiteName:)`; select each `MascotCharacter` case; verify `selectedCharacter` updates, persists to `"avatarSelectedCharacter"`, and reloads cleanly in a new store instance.

**Acceptance Scenarios**:
1. **Given** a fresh install, **When** `AvatarCharacterStore` initializes, **Then** `selectedCharacter` defaults to `.cyberCat`.
2. **Given** `multiMascot` entitlement is unlocked, **When** the user selects `.cyberDog`, `.hoverDrone`, `.retroMech`, or `.cyberBunny`, **Then** `AvatarCharacterStore.selectedCharacter` updates immediately and writes the raw value to `UserDefaults` key `"avatarSelectedCharacter"`.
3. **Given** `.retroMech` is saved in `UserDefaults`, **When** the app relaunches with `multiMascot` unlocked, **Then** `AvatarCharacterStore` restores `.retroMech`.

---

### User Story 2 - Modular Procedural Vector Rigs & Emotional States (Priority: P1)

Every character in the roster responds to all 7 `BitzState` emotional states (`balanced`, `superCharged`, `dopamineSad`, `overworked`, `burnout`, `charging`, `overheating`), eye blinking, petting reactions (`isPetReactionActive`), resting/loaf posture (`isLoafPosture`), agent approval attention cues (`isAttentionCueActive`), and custom color palettes (`AvatarResolvedPalette`).

**Why this priority**: Ensures every companion feels alive and deeply integrated with Bitz's wellness engine, agent monitor, and theme engine (#28).

**Independent Test**: Render all 5 `MascotCharacter` cases across all 7 `BitzState` values, loaf postures, and petting states using `ImageRenderer` in `MascotOverlayLayoutTests` and `MascotCharacterTests`; verify non-empty deterministic pixel output, distinct silhouettes per character, accurate `earOverflow`, and zero pixels drawn outside the `250×250` panel bounds.

**Acceptance Scenarios**:
1. **Given** any `MascotCharacter` and any `BitzState`, **When** rendered via `BitzCharacterView(state:time:character:...)`, **Then** the character renders deterministically inside the `180×140` frame and `250×250` overlay canvas without clipping.
2. **Given** `LiveBitzCharacterView(state:character:...)`, **When** displayed on the desktop, **Then** continuous motion (breathing/hovering, tail wag/thruster pulse, paw/clamp/wing sway, overheating glitch, and ambient particles) runs in out-of-process CoreAnimation (`CALayerMotionBridge` + `CoreAnimationParticlesView`) at `< 2%` app CPU.
3. **Given** custom theme palettes (`AvatarResolvedPalette`), **When** applied to any character rig, **Then** chassis, deep chassis, trim, visor LED, and glow intensity tint the character seamlessly.

---

### User Story 3 - Settings Character Gallery & Menu Bar Switcher with Pro Gating (Priority: P1)

Users can browse and switch companions either from the `"Companion Character"` submenu in the macOS Menu Bar or from the visual **Companion Character Roster** gallery inside Settings -> Appearance. Free tier users can use Bitz (Cyber Cat) unrestricted and preview all companion cards in the Settings gallery with a `PRO` badge and upgrade popover.

**Why this priority**: Provides intuitive discovery and switching in both quick-access Menu Bar and visual Settings workflows while honoring Bitz Pro licensing (#117).

**Independent Test**: Construct `AppearanceSettingsTabView` and `BitzMenuBarContentView` with `AvatarCharacterStore` and mock `LicensingService`; verify Free vs. Pro selection behavior and live preview binding.

**Acceptance Scenarios**:
1. **Given** Free tier (`isFeatureUnlocked(.multiMascot) == false`), **When** clicking a Pro character in Settings or Menu Bar, **Then** `.cyberCat` remains active and the user is shown the Bitz Pro upgrade popover / tab.
2. **Given** Pro tier (`isFeatureUnlocked(.multiMascot) == true`), **When** clicking any character card in Settings or item in the Menu Bar `"Companion Character"` submenu, **Then** the desktop mascot and live preview immediately switch to that character.
3. **Given** license deactivation while a Pro character is selected, **When** `validateTierEntitlement()` runs, **Then** `AvatarCharacterStore` gracefully reverts to `.cyberCat`.

---

## 4. Edge Cases

- **Corrupted or Unknown `UserDefaults` Value**: If `"avatarSelectedCharacter"` contains an unrecognized string, `AvatarCharacterStore` safely falls back to `.cyberCat`.
- **Speech Bubble Anchoring Across Varying Ear/Antenna Heights**: Each character defines its own `headLift(for: character, isLoafPosture:)` and `earOverflow(for: character, isLoafPosture:)` so `SpeechBubblePanel` sits cleanly above tall bunny ears, cat ears, mech antennas, dog heads, or hover drones without overlapping or clipping.
- **Settings Window Closed**: Animated previews in `AppearanceSettingsTabView` pause when `!settingsWindowManager.isWindowVisible` and tear down when the Settings window closes (`AGENTS.md` Rule 2.3).

---

## 5. Requirements

### Functional Requirements

| ID | Title | Description | Priority | Status |
|---|---|---|---|---|
| FR-001 | `MascotCharacter` Enum & Metadata | Define `MascotCharacter` (`cyberCat`, `cyberDog`, `hoverDrone`, `retroMech`, `cyberBunny`) with names, bios, SF symbols, pet reaction labels, and Pro flags. | High | Open |
| FR-002 | `AvatarCharacterStore` Persistence & Licensing | `@MainActor` `ObservableObject` persisting selection under `"avatarSelectedCharacter"` in `UserDefaults` and enforcing `.multiMascot` Pro entitlement. | High | Open |
| FR-003 | Modular Character Rigs (`BitzCharacterView` & `LiveBitzCharacterView`) | Implement deterministic SwiftUI and CoreAnimation-offloaded rigs for all 5 characters supporting all 7 `BitzState`s, blinking, petting, loaf posture, attention cues, and custom palettes. | High | Open |
| FR-004 | Settings Character Roster Gallery | Visual character gallery in `AppearanceSettingsTabView` with animated mini-previews, character bio blurbs, Pro badges/popovers, and one-click selection. | High | Open |
| FR-005 | Menu Bar `"Companion Character"` Submenu & Dynamic Icon | Add `"Companion Character"` submenu to `BitzMenuBarContentView` and update `BitzMenuBarLabel` icon to reflect the active companion. | High | Open |
| FR-006 | Character-Tailored Petting Feedback | Distinct petting visor/body animations and transient pet reaction bubble messages per companion character. | Medium | Open |

### Non-Functional Requirements

| ID | Title | Requirement | Category | Priority | Status |
|---|---|---|---|---|---|
| NFR-001 | Idle CPU Budget (`< 2%`) | All character rigs must use `CALayerMotionBridge` and `CoreAnimationParticlesView` for continuous motion with zero `TimelineView` or SwiftUI `.repeatForever` geometry animations. | Performance | High | Open |
| NFR-002 | Canvas Bounds & `earOverflow` Accuracy | All 5 characters must draw strictly within the `250×250` overlay canvas and match `earOverflow` within `1.5 pt` in `MascotOverlayLayoutTests`. | Layout | High | Open |
| NFR-003 | Test Isolation | All unit tests must use isolated `UserDefaults(suiteName:)` domains with cleanup in `tearDown`. | Reliability | High | Open |

### Constraints

| ID | Title | Constraint | Category | Priority | Status |
|---|---|---|---|---|---|
| C-001 | Zero External Dependencies | Pure SwiftUI + AppKit + QuartzCore (`CoreAnimation`), zero third-party packages. | Architecture | High | Open |
| C-002 | Backward Compatibility | Default parameters on `BitzCharacterView`, `LiveBitzCharacterView`, `AnimatedBitzCharacterView`, `MascotOverlayView`, `AppearanceSettingsTabView`, and `BitzMenuBarContentView` must preserve existing call sites. | Maintainability | High | Open |

---

## 6. Success Criteria

- **SC-001**: All 5 companion characters (`cyberCat`, `cyberDog`, `hoverDrone`, `retroMech`, `cyberBunny`) render distinct procedural vector rigs across all 7 `BitzState` emotional states.
- **SC-002**: `AvatarCharacterStore` persists `"avatarSelectedCharacter"` in `UserDefaults` and enforces `BitzFeature.multiMascot` tier gating.
- **SC-003**: `MascotOverlayLayoutTests` and `MascotCharacterTests` pass 100% via `xcrun swift test`, verifying pixel bounds and `earOverflow` for every character.
- **SC-004**: Live release build (`./Scripts/package_and_run.sh release`) maintains `< 2%` idle CPU and `< 70 MB` RAM.
