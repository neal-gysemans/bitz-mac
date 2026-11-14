# Tasks: Multilingual Meeting Transcription (Quick Switcher & Offline Model Setup)

**Spec**: [spec.md](spec.md) | **Plan**: [plan.md](plan.md)

## Work Package WP01: Speech Recognition Model Probing, Diagnostics & Deep Linking

**Goal**: Implement on-device speech asset readiness checking, friendly error classification for missing Dictation models, and macOS System Settings deep-linking utility.
**Prompt**: `/tasks/WP01-speech-model-probing-and-diagnostics.md`
**Requirement Refs**: FR-005, FR-006, FR-007, C-001
**Dependencies**: none

### Included Subtasks
- T001: Implement `checkOnDeviceAssetStatus(for:)` in `SpeechFrameworkTranscriptionService` (`src/Services/MeetingRecorder/MeetingTranscriptionService.swift`).
- T002: Enhance `MeetingTranscriptionError` and `recognitionStep` to classify missing Assistant/Dictation asset errors (e.g. `kAFAssistantErrorDomain` or `No Assistant asset`) into friendly, actionable errors.
- T003: Implement `openDictationSettings()` deep-linking to macOS System Settings Keyboard/Dictation (`x-apple.systempreferences:com.apple.Keyboard-Settings.extension?Dictation` with fallbacks).
- T004: Add unit tests in `Tests/BitzTests/MeetingTranscriptionTests.swift` covering asset status checks and missing-model error classification.

---

## Work Package WP02: Multi-Locale Re-transcription Engine

**Goal**: Extend `MeetingRecorderService.transcribeAgain(localeIdentifier:)` to accept an explicit target locale, re-transcribe session audio with that locale, and update session metadata.
**Prompt**: `/tasks/WP02-multi-locale-retranscription.md`
**Requirement Refs**: FR-004, SC-002
**Dependencies**: WP01

### Included Subtasks
- T005: Update `MeetingRecorderService.transcribeAgain(localeIdentifier: String? = nil)` to accept an optional locale override.
- T006: Route requested locale to `transcriptionService.transcribe(..., locale:)` during re-transcription.
- T007: Update session metadata with the locale used for the transcript.
- T008: Add unit tests in `Tests/BitzTests/MeetingRecorderServiceTests.swift` covering re-transcription with custom locale.

---

## Work Package WP03: Menu Bar Quick Language Switcher & Re-transcribe As Submenus

**Goal**: Add `Meeting Language ▸` and `Transcribe Last Recording Again As ▸` submenus directly in `BitzMenuBarContentView`.
**Prompt**: `/tasks/WP03-menu-bar-language-switcher.md`
**Requirement Refs**: FR-001, FR-002, FR-003, SC-001
**Dependencies**: WP01, WP02

### Included Subtasks
- T009: Add `Meeting Language ▸` submenu in `BitzMenuBarContentView` (`src/App/BitzApp.swift`) listing Automatic and supported locales with an active checkmark.
- T010: Ensure changing language updates `meetingSettings.setTranscriptionLocaleIdentifier` immediately and is disabled/guarded during active recording.
- T011: Add `Transcribe Last Recording Again As ▸` submenu listing locales and invoking `meetingRecorder.transcribeAgain(localeIdentifier:)`.
- T012: Add unit tests covering Menu Bar language options and selection actions.

---

## Work Package WP04: Settings Model Status Badges & 1-Click Dictation Deep Link

**Goal**: Display model readiness status in Settings > Audio > Transcription, show missing model warnings, and provide the 1-click button opening macOS Dictation settings.
**Prompt**: `/tasks/WP04-settings-model-status-and-deep-link.md`
**Requirement Refs**: FR-005, FR-006, SC-003
**Dependencies**: WP01

### Included Subtasks
- T013: Add asset readiness probe and status indicator in `AudioSettingsTabView.swift` for the currently selected language.
- T014: If model is missing, display warning badge/caption and 1-click button "Download in macOS Dictation Settings...".
- T015: Add unit tests in `Tests/BitzTests/AudioSettingsViewsTests.swift` for the status indicators and deep-link button.

---

## Work Package WP05: Verification, Performance Invariants & Packaging

**Goal**: Build release app, verify desktop idle CPU `< 2%` with Settings closed, verify RAM `< 70 MB`, and check end-to-end functionality.
**Prompt**: `/tasks/WP05-verification-and-packaging.md`
**Requirement Refs**: NFR-001, NFR-002, NFR-003, NFR-004, C-002, SC-004, SC-005
**Dependencies**: WP01, WP02, WP03, WP04

### Included Subtasks
- T016: Verify package build and codesigning via `./Scripts/package_and_run.sh release`.
- T017: Verify desktop idle CPU `< 2%` and memory `< 70 MB` via `top` per AGENTS.md §2.8.
- T018: Final acceptance check for bilingual workflow (Quick Switcher, Dictation Deep Link, Re-transcribe As).
