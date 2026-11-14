# Implementation Plan: Multilingual Meeting Transcription (Quick Switcher & Offline Model Setup)

**Branch**: `feat/issue-148-multilingual-transcription` | **Date**: 2026-11-12 | **Spec**: [spec.md](./spec.md)
**Input**: GitHub issue #148: "[Feature]: Multilingual Meeting Transcription (Quick Switcher & Offline Model Setup)" (Closes #148, refs #148)

---

## Summary

Many users work in bilingual/multilingual environments (e.g. English Mac system language, but frequent Dutch or other language meetings). This plan delivers zero-friction multilingual meeting transcription:
1. **Menu Bar Quick Language Switcher**: Add a lightweight `Meeting Language ▸` submenu directly in the Menu Bar extra (`BitzMenuBarContentView`), letting users switch between Automatic, English, Nederlands, and other preferred languages with a single click before recording.
2. **Multi-Locale Re-transcription Engine**: Extend `MeetingRecorderService.transcribeAgain(localeIdentifier:)` to accept an explicit target locale, and add a `Transcribe Last Recording Again As ▸` submenu in the Menu Bar extra so users can rescue meetings recorded under the wrong language setting.
3. **Offline Model Status & Diagnostic Error Handling**: Detect missing on-device speech models in `MeetingTranscriptionService.swift` and present clear, actionable diagnostics rather than cryptic `No Assistant asset for language` failures.
4. **Settings Model Status & 1-Click Dictation Deep Link**: In `Settings > Audio > Transcription`, show model readiness/missing status indicators and provide a 1-click button to deep-link directly to macOS System Settings Keyboard/Dictation pane.
5. **Invariants & Performance**: Strictly preserve zero idle CPU (< 2% with Settings closed, 0.0% audio idle CPU), memory (< 70 MB), zero external dependencies, and backward compatibility with `bitz.meeting.transcriptionLocale`.

---

## Technical Context

- **Language/Version**: Swift 6.0 (`Package.swift`), macOS 14+ (`arm64` / Apple Silicon primary).
- **Primary Frameworks**: AppKit, SwiftUI, Speech.framework (`SFSpeechRecognizer`, `SFSpeechURLRecognitionRequest`), AVFoundation.
- **Dependencies**: Zero external SwiftPM dependencies.
- **Target Platform**: macOS 14.0+ (Sonoma, Sequoia, and macOS 26).
- **Settings Deep Link**:
  - Primary URL: `x-apple.systempreferences:com.apple.Keyboard-Settings.extension?Dictation`
  - Fallback URL: `x-apple.systempreferences:com.apple.preference.keyboard`
- **Performance Budget**:
  - Desktop idle CPU: `< 2%` in release build with Settings closed.
  - Speech engine: Inactive when not transcribing (0.0% idle CPU).
  - Memory: Total RSS `< 70 MB`.
- **Constraints**:
  - `AGENTS.md` §2 & §4 invariants strictly preserved.
  - Privacy: 100% on-device speech recognition (`requiresOnDeviceRecognition = true`).
  - Unit tests use isolated `UserDefaults(suiteName:)` domains.

---

## Project Structure & Implementation Concerns

```
src/
├── Models/
│   ├── MeetingSettingsStore.swift              # IC-01: Shared locale option helpers and accessors
│   ├── MeetingBubble.swift                     # IC-03: Actionable missing asset bubble messages
│   └── MeetingModels.swift                     # IC-02: Transcription metadata with locale record
├── Services/MeetingRecorder/
│   ├── MeetingTranscriptionService.swift       # IC-03: Asset readiness probe, error classifier, locale resolver
│   └── MeetingRecorderService.swift            # IC-02: Locale-parameterized transcribeAgain(localeIdentifier:)
├── Views/Settings/
│   └── AudioSettingsTabView.swift              # IC-04: Language status badges & 1-click Dictation deep link
└── App/
    └── BitzApp.swift                           # IC-01: Menu Bar 'Meeting Language' & 'Transcribe Again As' submenus

Tests/BitzTests/
├── MeetingTranscriptionTests.swift             # IC-05: Locale resolution, asset error classification tests
├── MeetingRecorderServiceTests.swift           # IC-05: Multi-locale transcribeAgain tests
└── AudioSettingsViewsTests.swift               # IC-05: Language picker, deep-link action tests
```

### Implementation Concern Map

- **IC-01: Menu Bar Quick Language Switcher**:
  - In `BitzMenuBarContentView` (`src/App/BitzApp.swift`), add `Menu("Meeting Language")` positioned near the meeting recording controls.
  - Render `Automatic` (nil tag) followed by on-device locale options.
  - Show a checkmark next to the currently selected language.
  - Selecting a language updates `meetingSettings.setTranscriptionLocaleIdentifier(...)` instantly.
  - Disable or show notice when recording is in progress so active sessions are not disrupted.
- **IC-02: Multi-Locale Re-transcription Engine**:
  - Update `MeetingRecorderService.transcribeAgain(localeIdentifier: String? = nil)`.
  - When a `localeIdentifier` is provided, transcribe the session using that specific locale without necessarily permanently altering the user's default setting (or optionally updating it based on intent).
  - In `BitzMenuBarContentView`, expose `Menu("Transcribe Last Recording Again As...")` listing available locales alongside the primary `Transcribe Last Recording Again` button.
- **IC-03: Asset Readiness Probe & Diagnostic Error Handling**:
  - In `SpeechFrameworkTranscriptionService`, implement an asset availability check:
    `func checkOnDeviceAssetStatus(for locale: Locale) -> OnDeviceModelStatus` (.ready, .needsDownload, .unsupported).
  - Enhance `MeetingTranscriptionError` and `recognitionStep`: classify `kAFAssistantErrorDomain` or missing asset errors into a user-friendly error specifying the language name and directing the user to macOS Dictation settings.
  - Update `MeetingBubble` to display helpful instructions when an asset is missing.
- **IC-04: Settings Model Status & System Settings Deep Link**:
  - In `AudioSettingsTabView.swift`, observe the selected locale and display an asset status pill/caption:
    - If ready: "On-device speech model is installed on this Mac."
    - If missing: "On-device model not downloaded in macOS." with an orange warning indicator.
  - Add a button: "Download in macOS Dictation Settings..." that calls `NSWorkspace.shared.open(url)` using the keyboard/dictation preference pane URL.
- **IC-05: Deterministic Unit & Verification**:
  - Add unit tests for `checkOnDeviceAssetStatus`, missing asset error mapping, Menu Bar locale option formatting, and `transcribeAgain(localeIdentifier:)`.
  - Verify release package build, run live check, and verify desktop idle CPU stays `< 2%`.
