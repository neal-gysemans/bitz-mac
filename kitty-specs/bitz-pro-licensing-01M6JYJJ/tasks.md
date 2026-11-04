# Tasks: Bitz Pro Feature Tiering & Backendless License Architecture

**Spec**: [spec.md](spec.md) | **Plan**: [plan.md](plan.md)

---

## Work Package WP01: Licensing Models & Keychain Storage Isolation

**Goal**: Implement the core domain models, error types, abstract storage protocol, and secure macOS `Keychain` persistence.
**Requirement Refs**: FR-001, FR-004, FR-007, NFR-003, NFR-004, C-001, C-002, C-003  
**Dependencies**: None  

### Included Subtasks
- **T001**: Create `src/Models/LicensingModels.swift` with `BitzTier` (`.free`, `.pro`), `BitzFeature` enum (`.multiMascot`, `.customThemes`, `.multiAgentSwarm`, `.meetingRecorder`, `.deepTelemetry`, `.soundPacks`), `LicensePayload` (Decodable struct with `tier`, `license_id`, `issued_at`, `expires_at`), and `LicensingError` enum (`.invalidFormat`, `.invalidSignature`, `.licenseExpired`, `.storageFailed`).
- **T002**: Create `src/Services/Licensing/LicenseStorageProtocol.swift` defining `loadLicenseToken() -> String?`, `saveLicenseToken(_ token: String) throws`, and `deleteLicenseToken() throws`.
- **T003**: Create `src/Services/Licensing/KeychainLicenseStorage.swift` implementing `LicenseStorageProtocol` using Apple `Security` framework APIs (`kSecClassGenericPassword`, `kSecAttrService`, `kSecAttrAccount`, `kSecAttrAccessibleAfterFirstUnlock`).

---

## Work Package WP02: Cryptographic Licensing Service & Test Suite

**Goal**: Implement `LicensingServiceProtocol`, `LicensingService` with offline `CryptoKit` Ed25519 cryptographic validation, and a deterministic unit test suite.
**Requirement Refs**: FR-002, FR-003, NFR-002, NFR-004, C-003  
**Dependencies**: WP01  

### Included Subtasks
- **T004**: Create `src/Services/Licensing/LicensingServiceProtocol.swift` defining `@MainActor public protocol LicensingServiceProtocol: AnyObject, ObservableObject` with `currentTier`, `activeLicense: LicensePayload?`, `isFeatureUnlocked(_ feature: BitzFeature) -> Bool`, `activateLicense(key: String) throws`, and `deactivateLicense() throws`.
- **T005**: Implement `src/Services/Licensing/LicensingService.swift` with native `CryptoKit.Curve25519.Signing.PublicKey` offline verification, embedded production public key, Base64URL parsing, and expiration validation.
- **T006**: Create `Tests/BitzTests/LicensingServiceTests.swift` with an in-memory `MockLicenseStorage`, verifying default state, valid key activation, corrupt signature, malformed format, expired license, and deactivation. Run `xcrun swift test`.

---

## Work Package WP03: Settings UI & Pro Gating Controls

**Goal**: Implement the presentation layer in SwiftUI: a dedicated "Bitz Pro" tab in Settings, key input field, celebratory feedback, and subtle feature gating badges.
**Requirement Refs**: FR-005, FR-006, NFR-001  
**Dependencies**: WP01, WP02  

### Included Subtasks
- **T007**: Create `src/Views/Components/ProBadgeView.swift`: an elegant neon capsule badge and `.proFeatureGated(...)` view modifier.
- **T008**: Create `src/Views/Settings/BitzProSettingsTabView.swift` containing Plan Status Card, key activation form with inline feedback, Pro features showcase cards (Mascots #30, Themes #28, Meeting Recorder #43, Swarm), and web checkout link.
- **T009**: Integrate `BitzProSettingsTabView` into `src/Views/Settings/SettingsRootView.swift` with tab navigation.

---

## Work Package WP04: App Wiring, CPU Verification & Contributor Docs

**Goal**: Wire `LicensingService` into `BitzApp`, author contributor documentation (`docs/LICENSING.md`), and verify desktop idle CPU `< 2%`.
**Requirement Refs**: NFR-001  
**Dependencies**: WP01, WP02, WP03  

### Included Subtasks
- **T010**: Wire `LicensingService` into `BitzApp.swift` and pass as an environment/injected object to `SettingsWindowManager` and `SettingsRootView`.
- **T011**: Create `docs/LICENSING.md` documenting key structure, cryptographic verification, web checkout webhook flow, and dev key generation snippet.
- **T012**: Run `./Scripts/package_and_run.sh release` and verify desktop idle CPU remains strictly `< 2%` and RAM `< 70 MB`.
