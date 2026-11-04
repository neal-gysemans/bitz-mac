# Mission Specification: Bitz Pro Feature Tiering & Backendless License Architecture

**Mission Branch**: `feat/issue-117-bitz-pro-licensing`  
**Created**: 2026-11-04  
**Status**: Ready for Planning  
**Input**: User request & GitHub issue #117: "[Feature]: Bitz Pro Feature Tiering & Backendless License Architecture" (Tracks GitHub issue #117, refs #117, Closes #117)

---

## 1. Executive Summary & Purpose for Contributors

Bitz is transitioning from an untiered open prototype to a sustainable consumer desktop companion. To ensure long-term development while keeping the app accessible, we establish a clean **Free vs. Pro** feature split.

### Guiding Principles:
1. **The Free Tier is a Complete, Delighful Product**: Free users must never feel like second-class citizens. The core cyber cat companion, all emotional PTS states, hold-to-pet, screen break reminders, single-agent monitoring, and standard telemetry work 100% unrestricted with zero nagging popups or expiring trial timers.
2. **Backendless & Zero Maintenance**: There is no custom backend API, no database to maintain, and no user accounts or passwords. Licensing is handled via Merchant of Record (e.g., Polar.sh / Lemon Squeezy) issuing cryptographic signature tokens.
3. **100% Offline Cryptographic Verification**: Verification uses Apple's native `CryptoKit` (`Curve25519.Signing.PublicKey` / Ed25519). The app never phones home to validate a key.
4. **Secure Local Storage**: Activated licenses are saved directly to macOS `Keychain` (`kSecClassGenericPassword`), surviving app updates and uninstalls.
5. **Zero Performance Footprint**: Adheres strictly to `AGENTS.md` Rule 2: desktop idle CPU remains `< 2%` and RAM `< 70 MB`.

---

## 2. Feature Matrix: Free vs. Pro

| Feature Area | Free Tier (Beta Testers & Everyday Users) | Bitz Pro Tier (Paid Supporters & Power Users) |
|---|---|---|
| **Primary Mascot** | Bitz the Cyber Cat (full emotional states, animations) | Bitz + Full Mascot Roster (#30: Byte Dog, Aero Drone, Pixel Mech) |
| **Mascot Interactions** | Hold-to-pet, freeform drag & magnetic edge snap | All Free interactions + special mascot animations & click responses |
| **Wellness & Health** | Full PTS engine (superCharged, balanced, burnout, offline recovery) | Full PTS engine + customizable reminder intervals & custom break sounds |
| **Theme & Visor** | Default Cyberpunk Neon (Cyan / Magenta) | Custom Palette Studio (#28: Synthwave, Tokyo Night, Monokai, Paperwhite, Matrix) |
| **AI Agent Monitoring** | 1 Active Agent session (Claude Code or Antigravity) with stall alerts & wake-up buttons | Multi-Agent Swarm: 2+ simultaneous agent sessions, aggregated context & swarm HUD |
| **Hardware Telemetry** | Core telemetry: CPU load, RAM usage, die temperature, battery level | Deep telemetry: per-process battery drain & browser tab memory breakdown |
| **Audio & SFX** | Standard 8-bit cyber audio pack (purr, alert, low-battery) | Extended Audio Studio: Chiptune, Mechanical Switches, Soft Chimes + custom alerts |
| **Productivity Tools** | Standard companion HUD & speech bubble notes | Local Meeting Assistant (#43): local mic recording & on-device Whisper transcript |

---

## 3. User Scenarios & Testing *(mandatory)*

### User Story 1 - Free Tier Companion Experience (Priority: P1)

An everyday developer or beta tester installs Bitz. They enjoy the full companion experience out of the box without creating an account, entering credit card details, or encountering blocking paywalls.

**Why this priority**: Essential for user acquisition, beta testing validation, and core product delight.

**Independent Test**: Clean install of Bitz with no license key; verify all core cat states, dragging, petting, single-agent tracking, and menu bar telemetry work continuously without limitation.

**Acceptance Scenarios**:
1. **Given** a fresh install with no license key in Keychain, **When** Bitz launches, **Then** `LicensingService.currentTier` defaults to `.free`.
2. **Given** `.free` tier, **When** the user interacts with Bitz (drag, pet, wellness triggers), **Then** all core interactions succeed without displaying blocking modal dialogs.
3. **Given** a single coding agent session running in Claude Code or Antigravity, **When** the agent requests approval, **Then** the wake-up popup and GOT IT button fire normally.

---

### User Story 2 - Offline Cryptographic License Activation (Priority: P1)

A user purchases Bitz Pro on the website (via Polar.sh or Lemon Squeezy). They receive a license key (e.g. `BITZ-PRO-XXXX-XXXX-XXXX-SIGNATURE`). In Bitz Settings, they paste their key. Bitz immediately verifies the Ed25519 signature locally using `CryptoKit`, saves the entitlement receipt to macOS `Keychain`, unlocks Pro features, and celebrates with cyber audio and UI feedback.

**Why this priority**: Core revenue and entitlement mechanism; must be completely offline, fast, and cryptographically secure.

**Independent Test**: Generate a signed test key using the Ed25519 private key; paste it into `LicensingService.activateLicense(key:)`; verify it unlocks `.pro` instantly and persists across app restarts without internet access.

**Acceptance Scenarios**:
1. **Given** a cryptographically valid license string signed by the authorized private key, **When** `activateLicense(key:)` is invoked, **Then** `isFeatureUnlocked(.multiMascot)` and all Pro features immediately return `true`.
2. **Given** an invalid or tampered license string, **When** `activateLicense(key:)` is invoked, **Then** it throws `LicensingError.invalidSignature` and leaves tier as `.free`.
3. **Given** an expired license (if timestamp-bounded), **When** `activateLicense(key:)` is invoked, **Then** it throws `LicensingError.licenseExpired`.
4. **Given** a valid key activated once, **When** the app is terminated and relaunched offline, **Then** `LicensingService` reads the receipt from `Keychain` and restores `.pro` status instantly.

---

### User Story 3 - Settings "Bitz Pro" Tab & Key Management (Priority: P2)

The user opens Settings (`⌘,` or via Menu Bar). A dedicated "Bitz Pro" tab displays the active tier badge, preview cards of Pro features, a text field to paste a license key, an "Activate" button, and an "Upgrade to Pro" link for non-Pro users. When Pro is active, it displays "Bitz Pro Active" with a "Deactivate / Transfer" option.

**Why this priority**: Primary UI touchpoint for user-facing tier awareness, upgrades, and key management.

**Independent Test**: Open Settings -> "Bitz Pro" tab; inspect UI layout, enter invalid key (see inline error), enter valid key (see success badge).

**Acceptance Scenarios**:
1. **Given** user is on `.free` tier, **When** opening the Bitz Pro tab, **Then** a "Free Tier" status badge is shown with an "Enter License Key" field and an "Upgrade to Pro" button opening the web store.
2. **Given** user enters a valid key and clicks "Activate", **Then** the badge updates to "Bitz Pro Active", a success sound plays, and the input field transitions to an active license summary card.
3. **Given** user clicks "Deactivate", **Then** the license is cleared from Keychain and tier reverts gracefully to `.free`.

---

### User Story 4 - Graceful Feature Gating in Settings (Priority: P2)

When navigating existing Settings tabs (e.g. General, Appearance/Themes #28, Mascot Roster #30), Pro-exclusive options display a subtle, elegant `PRO` badge. If a Free user clicks on a locked item, a non-intrusive preview popover explains the feature with a one-click "View Pro Perks" shortcut.

**Why this priority**: Provides organic discovery and upgrade incentive without annoying or interrupting the user's workflow.

**Independent Test**: With `.free` tier, navigate to Mascot Roster; verify Free mascot (Bitz) is selectable, while Byte/Aero show `PRO` badges; selecting a locked item shows preview sheet/popover instead of switching avatar.

**Acceptance Scenarios**:
1. **Given** `.free` tier, **When** viewing the Mascot Roster, **Then** Bitz Cyber Cat is selectable and other mascots display a `PRO` lock indicator.
2. **Given** `.pro` tier, **When** viewing the Mascot Roster or Custom Themes, **Then** all mascots and theme palettes are fully selectable.

---

### User Story 5 - Deterministic Unit Tests & Mock Fixtures (Priority: P1)

Developers and CI workflows can run `xcrun swift test` with 100% deterministic tests for the licensing domain without requiring live macOS Keychain access or network requests.

**Why this priority**: Required by `AGENTS.md` Rule 5.2 to prevent flaky CI tests or test pollution of the developer's personal macOS Keychain.

**Independent Test**: Execute `xcrun swift test --filter LicensingServiceTests`; verify 100% pass with isolated mock storage.

**Acceptance Scenarios**:
1. **Given** `LicensingService` initialized with `MockKeychainStorage`, **When** testing valid, invalid, expired, and malformed keys, **Then** all edge cases behave deterministically with 0 test failures.

---

## 4. Edge Cases

- **Keychain Access Denied**: If sandbox or OS denies Keychain access, fallback gracefully to in-memory session tier or isolated app group container with an informative log warning rather than crashing.
- **Clock Tampering**: If an expired key check is enabled, verify signature timestamp against monotonic system uptime or sanity-check system clock to avoid simple year-rollback bypasses.
- **Air-Gapped / Offline Machines**: Validation NEVER invokes `URLSession`. It operates 100% offline at all times.
- **Multi-Monitor / Dynamic Reconfiguration**: Tier changes must publish updates via `@Published` or Swift Concurrency `@Observable` on `@MainActor` so UI components refresh smoothly without window tear-down.

---

## 5. Requirements

### Functional Requirements

| ID | Title | Description | Priority | Status |
|---|---|---|---|---|
| FR-001 | `BitzTier` & `BitzFeature` Enums | Model defining `.free` vs `.pro` tiers and discrete feature flags (`multiMascot`, `customThemes`, `multiAgentSwarm`, etc.). | High | Open |
| FR-002 | `LicensingServiceProtocol` | `@MainActor` service providing `currentTier`, `isFeatureUnlocked(_:)`, and `activateLicense(key:)`. | High | Open |
| FR-003 | Offline Ed25519 Cryptographic Verification | Public key verification using Apple's `CryptoKit.Curve25519.Signing.PublicKey`. | High | Open |
| FR-004 | macOS Keychain Persistence | Secure storage and retrieval of license token receipts using `Security` framework (`kSecClassGenericPassword`). | High | Open |
| FR-005 | Settings "Bitz Pro" Tab View | Dedicated SwiftUI view inside `SettingsRootView` with tier status, key activation input, and feature highlights. | High | Open |
| FR-006 | Feature Gating Helper (`ProFeatureGateView`) | Reusable SwiftUI wrapper/badge for marking Pro controls in Settings with lock icons. | Medium | Open |
| FR-007 | Deactivation & Reset Flow | Allows clearing stored license key from Keychain to revert to Free tier or switch licenses. | Medium | Open |

### Non-Functional Requirements

| ID | Title | Requirement | Category | Priority | Status |
|---|---|---|---|---|---|
| NFR-001 | Zero Idle CPU Impact | Licensing state checks must be $O(1)$ cached properties with 0% background timer overhead (`< 2%` idle CPU invariant). | Performance | High | Open |
| NFR-002 | Zero Network Dependencies | Key validation must run strictly offline in `< 5 ms` with 0 network calls. | Reliability | High | Open |
| NFR-003 | Zero External Dependencies | Built entirely using native macOS frameworks (`SwiftUI`, `AppKit`, `CryptoKit`, `Security`). | Architecture | High | Open |
| NFR-004 | Keychain Isolation in Tests | Unit tests must use dependency-injected mock storage to avoid polluting system Keychain. | Maintainability | High | Open |

### Constraints

| ID | Title | Constraint | Category | Priority | Status |
|---|---|---|---|---|---|
| C-001 | Zero Backend Server | No server backend, cloud database, or recurring hosting cost. | Infrastructure | High | Open |
| C-002 | Zero Account Requirement | No email capture, username, or password management required for end users. | Privacy | High | Open |
| C-003 | Swift 6.0 Strict Concurrency | Full compatibility with `@MainActor` and Swift 6 sendable rules without warnings. | Language | High | Open |

---

## 6. Success Criteria

- **SC-001**: 100% of Free tier features remain fully functional without degradation for beta testers.
- **SC-002**: Valid license keys activate in `< 10 ms` offline and persist across app reboots.
- **SC-003**: 100% pass rate in `LicensingServiceTests` (valid signature, corrupt signature, expired key, empty input).
- **SC-004**: System idle CPU remains strictly `< 2%` and memory `< 70 MB`.
