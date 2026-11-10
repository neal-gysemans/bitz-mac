# Tasks: Multi-Mascot Character Roster & Selection

**Spec**: [spec.md](spec.md) | **Plan**: [plan.md](plan.md)

---

## Work Package WP01: Mascot Character Models & Persistence Store

**Goal**: Implement `MascotCharacter` enum with roster metadata and `AvatarCharacterStore` with `UserDefaults` persistence (`"avatarSelectedCharacter"`) and `BitzFeature.multiMascot` Pro licensing integration.
**Requirement Refs**: FR-001, FR-002, FR-006, NFR-003, C-001, C-002  
**Dependencies**: None  

### Included Subtasks
- **T001**: Create `src/Models/MascotCharacterModels.swift` defining `MascotCharacter` (`cyberCat`, `cyberDog`, `hoverDrone`, `retroMech`, `cyberBunny`) with `name`, `archetype`, `title`, `bio`, `menuBarSymbolName`, `isPro`, `petReactionBubble`, and `petVisorText`.
- **T002**: Create `src/Models/AvatarCharacterStore.swift` implementing `@MainActor public final class AvatarCharacterStore: ObservableObject` persisting `"avatarSelectedCharacter"` in `UserDefaults`, enforcing `.multiMascot` Pro entitlement, and supporting `validateTierEntitlement()`.

---

## Work Package WP02: Modular Character Rigs & CoreAnimation Rendering

**Goal**: Extend `BitzCharacterView`, `LiveBitzCharacterView`, `AnimatedBitzCharacterView`, and `MascotOverlayView` to render all 5 companion characters deterministically in SwiftUI and via out-of-process CoreAnimation (`< 2%` CPU).
**Requirement Refs**: FR-003, FR-006, NFR-001, NFR-002, C-001, C-002  
**Dependencies**: WP01  

### Included Subtasks
- **T003**: Update `src/Views/BitzCharacterView.swift` to support all 5 `MascotCharacter` rigs (`cyberCat`, `cyberDog`, `hoverDrone`, `retroMech`, `cyberBunny`) in both deterministic `BitzCharacterView` and CoreAnimation-offloaded `LiveBitzCharacterView` / `AnimatedBitzCharacterView`, including character-specific head/ear/antenna geometry, torso emblems, tail/thruster animations, custom palettes, petting visors, and accurate `earOverflow(for:isLoafPosture:)`.
- **T004**: Update `src/Views/MascotOverlayView.swift` to observe `AvatarCharacterStore`, render the selected character in `LiveBitzCharacterView`, and report character-specific `earOverflow` to `SpeechBubblePanel`.

---

## Work Package WP03: Settings Character Gallery & Menu Bar Switcher

**Goal**: Add the visual **Companion Character Roster** gallery to Settings -> Appearance and the `"Companion Character"` quick-switcher submenu to the macOS Menu Bar.
**Requirement Refs**: FR-004, FR-005, C-002  
**Dependencies**: WP01, WP02  

### Included Subtasks
- **T005**: Create `src/Views/Settings/AppearanceCharacterRosterSectionView.swift` and integrate it into `src/Views/Settings/AppearanceSettingsTabView.swift` and `src/Views/Settings/SettingsRootView.swift` with live character previews, bios, Pro badges/popovers, and top preview card binding.
- **T006**: Update `BitzMenuBarContentView` and `BitzMenuBarLabel` in `src/App/BitzApp.swift` with the `"Companion Character"` submenu, Pro lock handling, and dynamic status item icon.

---

## Work Package WP04: App Wiring, Deterministic Tests & Live CPU Verification

**Goal**: Wire `AvatarCharacterStore` into `BitzAppDelegate`, write comprehensive unit and layout tests for all 5 characters, and verify release packaging and `< 2%` desktop idle CPU.
**Requirement Refs**: FR-001, FR-002, FR-003, FR-004, FR-005, FR-006, NFR-001, NFR-002, NFR-003  
**Dependencies**: WP01, WP02, WP03  

### Included Subtasks
- **T007**: Wire `AvatarCharacterStore` in `BitzAppDelegate` (`src/App/BitzApp.swift`), connecting character-specific pet reactions and license tier changes.
- **T008**: Add `Tests/BitzTests/MascotCharacterTests.swift` and update `Tests/BitzTests/MascotOverlayLayoutTests.swift` to test all 5 characters (`AvatarCharacterStore` persistence, Pro gating, `ImageRenderer` bounds inside `250×250`, and `earOverflow` accuracy).
- **T009**: Run `xcrun swift test` and `./Scripts/package_and_run.sh release` to verify all tests pass and desktop idle CPU stays `< 2%`.
