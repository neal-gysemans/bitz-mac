# Implementation Plan: Multi-Mascot Character Roster & Selection

**Branch**: `feat/issue-30-multi-mascot-roster` | **Date**: 2026-11-08 | **Spec**: [spec.md](spec.md)  
**Input**: Feature specification from `/kitty-specs/multi-mascot-roster-01M6Y9GH/spec.md` (Tracks GitHub issue #30, refs #30, Closes #30)

---

## 1. Summary

Deliver a modular **Multi-Mascot Character Roster & Selection System** with 5 procedural cyberpunk companions—**Bitz** (`cyber_cat`, Free default), **Byte** (`cyber_dog`, Pro), **Aero** (`hover_drone`, Pro), **Pixel** (`retro_mech`, Pro), and **Volt** (`cyber_bunny`, Pro)—sharing the unified `WellnessPointEngine`, `AvatarPaletteStore`, `LicensingService`, and CoreAnimation-offloaded rendering pipeline (`< 2%` idle CPU).

---

## 2. Technical Context

- **Language/Version**: Swift 6.0 (`swift-tools-version 6.0`), AppKit, SwiftUI, QuartzCore (`CoreAnimation`)
- **Primary Dependencies**: Native macOS frameworks only (`AppKit`, `SwiftUI`, `QuartzCore`); **zero external SwiftPM dependencies**
- **Storage**: `UserDefaults` key `"avatarSelectedCharacter"` managed by `@MainActor final class AvatarCharacterStore: ObservableObject`
- **Testing**: Deterministic XCTest in `Tests/BitzTests/MascotCharacterTests.swift` and `Tests/BitzTests/MascotOverlayLayoutTests.swift` using `ImageRenderer` and isolated `UserDefaults(suiteName:)`
- **Target Platform**: macOS 14.0+ (Sonoma), Apple Silicon (`arm64`) primary
- **Performance Goals**: Out-of-process `WindowServer` CoreAnimation via `CALayerMotionBridge` and `CoreAnimationParticlesView`; **desktop idle CPU strictly `< 2%` and RAM `< 70 MB`**
- **Scope**:
  - `src/Models/MascotCharacterModels.swift`
  - `src/Models/AvatarCharacterStore.swift`
  - `src/Views/BitzCharacterView.swift`
  - `src/Views/MascotOverlayView.swift`
  - `src/Views/Settings/AppearanceCharacterRosterSectionView.swift`
  - `src/Views/Settings/AppearanceSettingsTabView.swift`
  - `src/Views/Settings/SettingsRootView.swift`
  - `src/App/BitzApp.swift`
  - `Tests/BitzTests/MascotCharacterTests.swift`
  - `Tests/BitzTests/MascotOverlayLayoutTests.swift`

---

## 3. Charter & Performance Invariants Check

- **No `TimelineView` or `.repeatForever` Geometry Animations (AGENTS.md Rule 2.1)**: **PASS**. All 5 character rigs use `CALayerMotionBridge` (`CABasicAnimation` on `CALayer`) in `LiveBitzCharacterView` for continuous motion and keep `BitzCharacterView(state:time:character:...)` pure deterministic SwiftUI for `ImageRenderer` snapshot tests.
- **Detach Closed Secondary Windows (AGENTS.md Rule 2.3)**: **PASS**. Character gallery previews in `AppearanceSettingsTabView` pause when `!settingsWindowManager.isWindowVisible` and are deallocated when Settings closes.
- **100% Click-Through & Zero Focus Stealing (AGENTS.md Rule 4.1–4.2)**: **PASS**. `MascotOverlayPanel` and `SpeechBubblePanel` window flags remain untouched.
- **Nothing Drawn Outside Its Window (AGENTS.md Rule 4.4)**: **PASS**. All 5 character rigs fit inside the `180×140` character stage and `250×250` overlay canvas, verified by `MascotOverlayLayoutTests`.

---

## 4. Architectural & Design Decisions

### 4.1 `MascotCharacter` Domain Model & `AvatarCharacterStore`
- `MascotCharacter` (`String, CaseIterable, Identifiable, Codable, Sendable`) defines:
  - `.cyberCat = "cyber_cat"` (Bitz — Free)
  - `.cyberDog = "cyber_dog"` (Byte — Pro)
  - `.hoverDrone = "hover_drone"` (Aero — Pro)
  - `.retroMech = "retro_mech"` (Pixel — Pro)
  - `.cyberBunny = "cyber_bunny"` (Volt — Pro)
- `AvatarCharacterStore` mirrors `AvatarPaletteStore`:
  - Persists selection in `UserDefaults` under `"avatarSelectedCharacter"`.
  - Checks `licensingService?.isFeatureUnlocked(.multiMascot)` before selecting Pro characters.
  - Exposes `validateTierEntitlement()` so activating or deactivating a Bitz Pro license in Settings updates entitlement state cleanly.

### 4.2 Modular Character Rigs & CoreAnimation Offloading
- `BitzCharacterView`, `LiveBitzCharacterView`, and `AnimatedBitzCharacterView` accept `character: MascotCharacter = .cyberCat` (defaulting to `.cyberCat` for 100% source compatibility with existing callers).
- Each character has:
  1. **Tail / Rear / Propulsion Element**:
     - `cyberCat`: Swishing cyber tail capsule
     - `cyberDog`: Rapidly wagging upward antenna-tail with glowing tip
     - `hoverDrone`: Pulsing lower antigravity thruster ring & plasma jet
     - `retroMech`: Dual rear/side exhaust heat-sink vents
     - `cyberBunny`: Glowing cotton-capacitor tail puff
  2. **Torso / Chassis Subtree (`Equatable`)**:
     - Styled with `palette.chassisDeepColor`, `palette.trim(over: visorColor)`, and a character-specific chest emblem (core circle for Cat, collar tag diamond for Dog, gyro stabilizer ring for Drone, CRT drive bay slots for Mech, lightning core for Bunny).
  3. **Front Limbs / Stabilizers**:
     - `cyberCat` & `cyberDog` & `cyberBunny`: Front paws with trot sway and `.needsApproval` paw-tap
     - `hoverDrone`: Side antigravity stabilizer fins with hover sway and `.needsApproval` pulse
     - `retroMech`: Articulated servo clamp hands with sway and `.needsApproval` clamp-tap
  4. **Head, Ears/Antennas & Visor Subtree (`Equatable`)**:
     - `cyberCat`: Pointed triangular `CyberEarShape` ears + wrap-around LED visor
     - `cyberDog`: Mechanical articulated floppy ears + cyber snout badge + expressive dog visor (`^ w ^` on pet)
     - `hoverDrone`: Spherical tech-orb dome + upper sensor fin + 360° cyclops/optic ring visor
     - `retroMech`: Boxy bevelled CRT monitor head + dual top antenna beacons + terminal bracket visor (`[ ^ ^ ]`)
     - `cyberBunny`: Long dual-channel antenna ears + rounded bunny head + energetic visor (`* ^ *` on pet)
- `BitzCharacterView.earOverflow(for: character, isLoafPosture:)` returns the exact top inset for each character so `SpeechBubblePanel` anchors accurately above any companion.

### 4.3 UI Touchpoints (Menu Bar & Settings Appearance Gallery)
- **Settings (`AppearanceCharacterRosterSectionView`)**:
  - Placed in `AppearanceSettingsTabView` right below the Live Mascot Preview card.
  - Displays a responsive grid/list of all 5 companions with live `AnimatedBitzCharacterView` thumbnails, name, archetype badge, personality bio, and `ProBadgeView` for locked Pro companions (with a popover linking to the Bitz Pro tab).
- **Menu Bar (`BitzMenuBarContentView` & `BitzMenuBarLabel`)**:
  - Adds a `"Companion Character"` `Menu` above `"Theme"` listing all 5 characters with checkmarks and `(Pro 🔒)` indicators.
  - Updates `BitzMenuBarLabel` icon to `appDelegate.characterStore.selectedCharacter.menuBarSymbolName`.
