# Meeting Recorder Hardening — Design

- **Date:** 2026-11-05
- **Issue / PR:** #43 / #125 (branch `feat/43-meeting-audio-recorder`)
- **Status:** Approved by the user ("take all those findings on in this PR")
- **Inputs:** three independent reviews of PR #125 at `cac2f08` (code correctness, security & privacy, cleanliness/architecture/design), plus live tests on a Mac Studio (2026-11-05).

## 1. Goal

Ship the meeting recorder in a state where a recording can never be silently lost, never starts unnoticed, never leaves the Mac by default, and the code is structured like the rest of Bitz. Every review finding is either implemented here or listed in §6 with a reason.

## 2. Already done before this spec (`251c109`, `924d2c4`, `ac600d4` on `fix/125-storage-signing`)

| Item | Finding |
|---|---|
| Default storage `~/Library/Application Support/Bitz/Meetings`, configurable recordings folder, sync-folder warning, 0700/0600 permissions, "transcribed on-device" wording | Security #1, #4; Architecture #8 (folder picker) |
| Hardened runtime + `com.apple.security.device.audio-input` entitlement, `--deep` dropped, `codesign --verify --strict` | Security #2 |
| Configurable recording hotkey (⌃⌥⌘R default, ⌃⌥R, ⌃⇧R, Off) | Architecture #1, Security #3 (hotkey part) |

## 3. Design decisions

### D1. Two-track, crash-safe capture with an offline aligned mix (replaces the realtime mixer)

**Problem (Code #1, #3, #5, #6; earlier F1/N3):** the realtime mixer writes AAC `.m4a` that is unreadable until closed (a crash, force quit or power loss loses the whole meeting — CONFIRMED by probe), aligns the two sources by arrival order (up to 2 s permanent offset after a stall or drift), shares one converter cache between both streams, and has flush-ordering races.

**Design:**
- During capture each source writes its own file in the session folder, 48 kHz stereo, as **CAF with 16-bit integer linear PCM** (processed as Float32 in memory; 16-bit halves disk use to ~1.4 GB/h for both tracks): `mic.caf` and `system.caf`. Recording refuses to start with less than ~2 GB free on the recordings volume. CAF supports an unknown data-chunk size, so a file cut off by a crash stays playable up to the last written buffer. *(Assumption to verify in task A1 with a probe that kills the writer process.)*
- Each source has its **own converter**; converters are reset on mic restart.
- Each writer places audio **by timestamp**, not by arrival: it records the host time of its first sample, and for every buffer computes the frame position `(bufferHostTime − sessionStartHostTime) × 48000`. A gap (device switch, SCStream not delivering during silence, tap stall) is filled with silence; overlap (late/duplicate buffer) is trimmed. Mic timestamps come from the tap's `AVAudioTime.hostTime`; system timestamps from the `CMSampleBuffer` presentation time. *(Assumption: both are on the host clock — verify in A1; if SCStream PTS is not host time, convert via `CMSyncConvertTime` to `CMClockGetHostTimeClock()`.)*
- **At Stop:** mix the two CAFs offline (sum × 0.85 headroom, clamp) into `audio.m4a` (AAC, as today), then delete the CAFs only after the `.m4a` is verified readable. On mix/encode failure keep the CAFs and report it.
- **Quit path:** close both CAFs (instant, always valid); run the mix only if it fits the existing 5 s cap, otherwise leave CAFs and mark metadata `audio_status: "unmixed"`.
- **Launch recovery:** on start-up, any session folder with CAFs and no `audio.m4a` is mixed in the background (utility priority, one at a time) and gets metadata `recovered: true`. No transcription on recovery (user can use Transcribe Again, D6).
- **Removes:** `MeetingAudioStreamMixer` queueing (`secondaryLeftQueue`, `flushSecondary`, `maxQueuedSamples`, overflow path). `mixBuffers` survives as the offline mix kernel.
- Per-track files also make speaker separation ("me" vs "others") possible later; not in scope (§6).

### D2. Mic tap robustness (Code #2, #4)
- `installTap(onBus: 0, bufferSize:, format: nil)` — never pass a format read from `outputFormat(forBus:)`, which can raise an uncatchable Objective-C exception after a device change.
- Register the `AVAudioEngineConfigurationChange` observer **before** the first `engine.start()`.

### D3. Session folder collisions (Code #11, Security #8)
- Never `removeItem` an existing recording. If the session folder already exists, append `-2`, `-3`, … to the folder name.

### D4. Transcription robustness (Code #7, #8, #9; Security #7; silent skip)
- Timeout finishes with the **partial** transcript plus warning "Transcript may be incomplete: transcription timed out" when utterances were collected (accumulation must be read on the recognizer's queue).
- "No speech" detection by error domain/code (`kAFAssistantErrorDomain` code 1110, plus `SFSpeechErrorDomain` equivalents verified by probe), never by English message text; fix the `a || b && c` precedence bug.
- `UtteranceAccumulator` de-duplicates by overlap: inserting a result removes existing utterances whose start lies within the new result's `[firstStart, lastEnd]`.
- Remove the `enforceOnDeviceRecognition` parameter: on-device is hard-coded; the dead `locale ?? .current` / en-US branches go.
- When transcription is skipped (speech permission not granted, or auto-transcribe off), the result bubble says why: "Audio saved. Transcript skipped: Speech Recognition not allowed — Settings → Audio."
- Extract the recognition callback handling into a pure, unit-testable function.

### D5. Recording visibility and the bubble model (Security #3, Architecture #2, #3, #10, Code #10)
- **Single bubble model:** the recorder exposes one `MeetingBubble` value (kind, text, actions, priority); all texts are `static let` constants on one type. `SpeechBubbleView`, `SpeechBubbleContent.current`, `SpeechBubblePanel` interactivity and `triggerPersonalityTick`'s idle check all derive from it. Personality commentary pauses while a meeting bubble or recording is active.
- **Menu bar indicator:** while recording, the status item shows a red record glyph + "REC" (static text, no per-second updates). Uses the existing `menuBarTitle` path or an equivalent `@Published` flag on the delegate; no timers.
- **Start chime + stop chime:** new `CyberSoundEvent` cases `.meetingRecordingStarted` / `.meetingRecordingSaved` with their own toggle in Settings → Audio, not tied to the agent sounds; they are not suppressed by the call/screen-share gate (the user is by definition in a call).
- **Start chime always audible (decision A2):** `.meetingRecordingStarted` ignores the master "Enable Cyber Audio" switch and Focus/DND suppression (`CyberSoundEvent.ignoresMasterAndFocus`); only its own toggle (Meeting Recorder card, default on, new key) and a muted Mac silence it. `.meetingRecordingSaved` keeps the master switch and normal gates, minus the call gate.
- **Recording bubble:** shown for 5 s at start, then hidden; the LED + headphones + menu bar indicator remain. It re-appears only for an interruption warning.
- **Interruptions:** capture interruptions are accepted while `isStopping` too, and during recording surface as a short warning bubble ("⚠️ Mic disconnected — still recording system audio") plus `statusMessage`.
- **Completion bubble:** auto-dismisses after 45 s (one-shot cancellable task, no timer).
- **Failure bubble:** short text ("Recording needs permission") with **OPEN SETTINGS** and **DISMISS** buttons; stays until dismissed; no stacked prefixes ("Transcript not saved: Speech transcription failed: …" → one clause).
- **Wellness priority:** `SYSTEM HOT` / thermal warnings outrank the meeting bubbles.
- **Menu item while transcribing:** label "Transcribing…" (disabled) instead of a greyed "Start Meeting Recording".

### D6. Transcribe Again
- Menu item "Transcribe Last Recording Again" (visible when a last recording exists and nothing is recording/transcribing) and a button in the completion bubble when the transcript failed. Re-runs transcription on the session's `audio.m4a`, overwrites that session's transcript files, re-exports per the export setting.

### D7. Settings, persistence and consent (Architecture #6, #7, #11; Security opinions)
- UserDefaults keys move to `keyPrefix = "bitz.meeting."` with a one-time migration from the `Bitz.MeetingRecorder.*` keys (copy if new key absent, then remove old).
- `SystemMeetingPermissionChecker` takes injected `UserDefaults`.
- One injection path: views receive `meetingRecorder` and read `meetingRecorder.settingsStore`; the triple fallback chains go. Views no longer default-construct `MeetingRecorderService()`.
- Settings → Audio: split into a **Meeting Recorder** card (sources, recordings folder, permissions, shortcut, chimes, retention) and a **Transcription** card (transcribe after recording, language, copy path, export folder), placed **after** the existing Cyber Audio cards; plain labels ("Microphone", "Meeting / system audio", "Transcribe after recording") — no framework names; status badge without shortcut text; export folder uses a `Toggle` + Choose…; privacy caption disabled with its row.
- Language picker: "Automatic", then the user's preferred languages, then one entry per remaining language (region shown only where it disambiguates, e.g. English (US)/(UK)); no invalid selection while the list loads.
- **First-recording notice (consent):** before the first recording ever, a one-time sheet/alert explains what is captured (microphone + all system audio, via the Screen & System Audio Recording permission), where files go, that transcription is on-device, and "Let other participants know before you record." Recording starts only after "Continue"; stored as `bitz.meeting.consentAcknowledged`. This is also where the Screen Recording scope is explained before `CGRequestScreenCaptureAccess` (Security #6).
- **Retention:** setting "Delete older recordings" Off (default) / 30 / 90 days, with a caption that states the newest-recording anchor; runs at launch and after each recording; deletes only session folders under the recordings root that Bitz created (have a valid `metadata.json`) and are older than the limit.
  - Safeguards: the folder's modification date must also be past the limit; each run first sweeps `.deleting-<session>` folders a cut-short delete left (a session is renamed to that before removal); the cutoff is measured from `min(now, newest session start)`, so a clock jumped forward never expires sessions within the limit of the newest one (and the newest session is never expired).

### D8. Export and metadata hygiene (Security #9, #10; Architecture #12)
- Export: on "file exists" during `copyItem`, retry with the next suffix (bounded); when the chosen export folder is inside a git work tree or a cloud-sync location, show the sync/git caption.
- Clipboard: set `org.nspasteboard.TransientType` and `org.nspasteboard.ConcealedType` markers along with the path.
- `metadata.json`: snake_case keys (matching `transcript.json`); `transcript_status` as a `String`-backed `Codable` enum (`pending`, `skipped`, `completed`, `failed`, `interrupted`); `detected_apps` matches meeting apps by bundle ID (as `ActivityMonitorService` does) and excludes browsers; drop the absolute `transcriptExportPath` (store only the exported file name). Decoding stays backward compatible with files written by earlier builds of this branch only where cheap; otherwise acceptable (feature unreleased).
- Add `NSDocumentsFolderUsageDescription` (users may still choose a Documents folder).

### D9. Structure and cleanup (Architecture #4, #5, #8, #9, #14, NITs; follow-ups)
- New folder `src/Services/MeetingRecorder/`: `MeetingPermissionChecker.swift`, `MeetingTrackWriter.swift` (D1), `MeetingAudioCaptureEngine.swift` (protocol, error, production engine), `MeetingRecorderService.swift` (service + first-recording notice; no timer store, see follow-ups), `MeetingTranscriptionService.swift`. `MeetingSettingsStore` moves to `src/Models/MeetingSettingsStore.swift`; `formatDuration` / `sessionFolderName` move off the store.
- Tests split: `MeetingRecorderServiceTests`, `MeetingTrackWriterTests`, `MeetingTranscriptionTests`; hotkey tests in `KeyboardShortcutsTests.swift`; MARK names by topic, not "Fix cycle".
- Recorder state: `isRecording`/`isTranscribing` derived from `state`; drop unused enum payloads; rename `isCompletionBubbleVisible`.
- Dead API removed: `MeetingRecorderError.permissionDenied` (or used), `toggleMeetingRecordingAction` wired into the main `NSMenu` like its siblings and used by the hotkey; the menu bar and Settings buttons call `toggleRecording()` directly, with the same behaviour.
- Comments that contradict code fixed (start sound, UTC, "synchronized"/"ring buffer").
- `isLoaf(state:isRecording:)` single static helper; `MascotOverlayView` receives `isRecordingMeeting: Bool` instead of observing the whole recorder.
- NITs: Advanced shortcut row style; shared `JSONEncoder` factory; `finalizeForTermination` awaits stored tasks instead of polling; `CyberHeadphonesOverlay` `Equatable` used or dropped.
- Follow-ups: `SystemDiffViewer` / `GitActivityProvider` read git's output before waiting for exit (a diff over the ~64 KB pipe buffer deadlocked); the 1 Hz elapsed timer (`MeetingRecordingTimerStore`) and the "(00:03)" counter on the 5 s recording bubble are removed, so nothing ticks while recording.
- **Shared Info.plist template:** `Scripts/Info.plist.template` used by `package_and_run.sh` and `create_dmg.sh`.
- **Local test builds use a separate bundle ID:** `package_and_run.sh` defaults to `com.bitz.cybercat.dev` (override with `BITZ_BUNDLE_ID`); `create_dmg.sh` keeps `com.bitz.cybercat`.
- `MascotOverlayView` now gets the real `agentMonitor` (drive-by from the original commit): keep, add a test.
- **Docs:** AGENTS.md codebase map + bubble priority line; ARCHITECTURE.md module table + §4 privacy (C-003) updated for mic/system capture, running-app enumeration, storage, retention.

## 4. Invariants that must hold (AGENTS.md)
- Idle CPU < 2 %, RAM < 70 MB; no timers or animations when not recording; CoreAnimation for motion; shadow before stroke; mascot window `ignoresMouseEvents = true` / `canBecomeKey = false` except the bubble panel's documented interactive state.
- No network use anywhere in the recorder or transcription path.
- §2.8 idle CPU check run on the final build.

## 5. Verification
- `xcrun swift test` green after every task.
- New unit tests per decision (listed per task in the plan).
- Probes (throwaway, not committed) for the two assumptions in D1 and the error codes in D4.
- Live, by the user, at the end: 1-minute recording with AirPods switch + mic unplug; force-quit mid-recording then relaunch (recovery); transcript complete; menu bar REC + chimes; consent sheet once; idle CPU.

## 6. Explicitly out of scope (with reason)
| Item | Reason |
|---|---|
| Developer ID signing + notarization | Needs a paid Apple Developer account — owner decision, external dependency |
| Core Audio process taps (narrower "System Audio Recording Only" permission) | macOS 14.2+ only (target is 14.0) and a second capture backend; follow-up issue |
| Filtering system audio to detected meeting apps | Browser-based meetings would require including browsers, which removes most of the benefit and risks missing audio; covered by the consent notice instead |
| Per-track transcription / speaker labels ("me" vs "others") | New feature; D1 makes it possible later |
| Echo removal on laptop speakers | Voice processing was measured to duck system audio by ~40 dB; no safe in-scope alternative. Use a headset. (Earlier suggestion that two-track recording removes echo was wrong — it only separates the tracks.) |
| Maximum recording duration / auto-stop | Opinion-level; the menu bar REC indicator + retention address the forgotten-recording risk |
