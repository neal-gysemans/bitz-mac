# Meeting Recorder Hardening — Implementation Plan

> **For agentic workers:** execute task by task. Each task is implemented by a fresh subagent and then checked by a fresh reviewer subagent (spec compliance first, then code quality). Do not start a task until the previous one is committed and reviewed.

- **Spec:** `docs/superpowers/specs/2026-11-05-meeting-recorder-hardening-design.md` (decisions D1–D9)
- **Worktree:** `/Volumes/DevDrive/Code/bitz-mac-wt-125`, branch `fix/125-storage-signing` (later fast-forwarded into `feat/43-meeting-audio-recorder`)
- **Rules for every task**
  - Read `AGENTS.md` and the spec section(s) named in the task before touching code; read the code you change and its callers.
  - Match surrounding style; minimal diff; no new dependencies.
  - Never `pkill`/`open` Bitz, never run `./Scripts/package_and_run.sh`, never push, never touch `/Volumes/DevDrive/Code/bitz-mac` (main checkout).
  - `xcrun swift test` must pass before committing; report exact counts.
  - Grep that every new function/type has a live caller; grep that removed names are gone.
  - One commit per task (or the listed commits), conventional message ending with `Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>`; subject ends with `(refs #43)`.
  - Throwaway probes go in `/private/tmp/claude-501/-Volumes-DevDrive-Code-bitz-mac/410e7cce-7553-4627-99f0-44c25a1f6e98/scratchpad/probes/`, never in the repo.

---

## Task 1 — Structure split (D9, mechanical, no behaviour change)
**Files:** create `src/Services/MeetingRecorder/` with `MeetingPermissionChecker.swift`, `MeetingAudioStreamMixer.swift` (temporary, removed in Task 2), `MeetingAudioCaptureEngine.swift`, `MeetingRecorderService.swift`, and move `src/Services/MeetingTranscriptionService.swift` into the folder; move `MeetingSettingsStore` to `src/Models/MeetingSettingsStore.swift`; move `formatDuration` / `sessionFolderName` to a small `MeetingSessionNaming` (or `MeetingModels`) helper and update callers. Split tests: `MeetingRecorderServiceTests.swift`, `MeetingAudioMixerTests.swift`, `MeetingTranscriptionTests.swift`, hotkey tests into `KeyboardShortcutsTests.swift`; rename "Fix cycle" MARKs by topic.
**Done when:** `git diff -M --stat` shows moves; no logic changes beyond access-level adjustments (`fileprivate(set)` → `internal` where a split requires it); tests green with the same count.
**Commit:** `refactor(audio): split meeting recorder into MeetingRecorder/ files (refs #43)`

## Task 2 — Two-track crash-safe capture (D1 capture half, D2, D3)
**First, probes (report results in the commit body):**
1. Write 10 s of Float32 PCM to a CAF via `AVAudioFile` in a child process, `kill -9` it, then open the CAF and read its length. Must be readable with ≈ the written frames.
2. Log, side by side, mic tap `AVAudioTime.hostTime` and SCStream `CMSampleBufferGetPresentationTimeStamp` vs `CMClockGetTime(CMClockGetHostTimeClock())` to confirm a shared clock (or derive the conversion). If SCStream cannot be run from the probe (permission), use `CMSampleBuffer` docs + the conversion path with `CMSyncConvertTime` and state that it's unverified.
**Build:**
- `MeetingTrackWriter` (new file): owns one `AVAudioFile` (CAF, linear PCM, 48 kHz stereo Float32), its own `AVAudioConverter` (reset on demand), and timestamp placement: `position = round((hostSeconds(buffer) − sessionStartHostSeconds) × 48000)`; pad gaps with silence (cap a single pad at e.g. 10 min to bound a bogus timestamp), trim overlap; thread-safe (one lock per writer).
- Production engine: mic tap → `micWriter`; SCStream → `systemWriter`; remove realtime mixing and the secondary queues; `installTap(..., format: nil)`; register the configuration-change observer before the first `engine.start()`; on mic restart reset the mic converter.
- Session folder collision: suffix `-2`, `-3` (D3); delete the `removeItem` call.
- Keep `mixBuffers` (it becomes the offline mix kernel in Task 3).
**Tests:** writer places buffers by timestamp (gap → silence of exact length, overlap trimmed, out-of-order handled); separate converters per writer; 44.1 kHz mono → 48 kHz stereo length correct; folder collision gets `-2` and the first recording is untouched; tap installed with `format: nil` (assert via a seam or code-level check if no seam exists — say which).
**Commit:** `fix(audio): record mic and system audio to separate crash-safe tracks placed by timestamp (refs #43)`

## Task 3 — Stop-time mix, quit path, launch recovery (D1 second half)
**Build:**
- At stop: offline mix `mic.caf` + `system.caf` (either may be missing/empty) with `mixBuffers` in chunks (no whole-file load) into `audio.m4a`; verify the `.m4a` opens and its length matches the longer track ± 1 buffer; then delete the CAFs. On failure keep CAFs, warn, and set metadata `audio_status: "unmixed"`.
- Transcription uses `audio.m4a` (or the mic/system CAF fallback when mixing failed — mixed is preferred).
- Quit (`finalizeForTermination` / `applicationShouldTerminate`): stop capture, close both writers; run the mix only within the remaining cap; otherwise leave CAFs + `unmixed`.
- Launch recovery service: scan the recordings root once at launch (utility priority, off main), for each session folder with CAF(s) and no `audio.m4a`, run the same mix; mark metadata `recovered: true`; one at a time; never during an active recording.
**Tests:** mix of two tracks with known sample values (sum × 0.85, clamped) and different lengths; only-mic and only-system cases; failure keeps CAFs; recovery mixes an orphaned session and leaves complete ones alone; quit path with an exhausted cap leaves CAFs + `unmixed`.
**Commit:** `fix(audio): mix tracks at stop, finalize safely on quit, recover unmixed sessions at launch (refs #43)`

## Task 4 — Transcription robustness + Transcribe Again (D4, D6)
**Probe:** trigger "no speech" on a silent file and print `(domain, code)`; record the values.
**Build:** pure function for callback handling (result/error → accumulate | finish success | finish partial | finish failure); timeout returns partial + warning (read accumulation on the recognizer queue); no-speech by domain/code; fix precedence bug; overlap de-dup in `UtteranceAccumulator`; remove `enforceOnDeviceRecognition` and its dead branches; skipped-transcription reason in the result; Transcribe Again (menu item + button on failed-transcript completion bubble) re-running transcription + export on a session.
**Tests:** callback function table (no-speech code → empty success; other error with utterances → partial + warning; without → failure; final → full); timeout with utterances → partial; overlap de-dup (shifted start, cumulative result); skipped reason text; Transcribe Again rewrites transcript and re-exports (mock transcription service).
**Commit:** `fix(audio): robust transcription results, partial on timeout, Transcribe Again (refs #43)`

## Task 5 — Bubble model, visibility, chimes (D5)
**Build:** `MeetingBubble` single model with `static let` texts; derive `SpeechBubbleView`, `SpeechBubbleContent.current`, panel interactivity and `isBubbleIdle` from it; personality pauses during meeting bubbles/recording; thermal/wellness warnings outrank meeting bubbles; recording bubble 5 s at start then hidden; interruption warning bubble (accepted while stopping); completion auto-dismiss 45 s; failure bubble with OPEN SETTINGS + DISMISS, stays until dismissed, single-clause texts; menu bar red record glyph + "REC" while recording (no timers); menu item "Transcribing…" while transcribing; new `CyberSoundEvent.meetingRecordingStarted` / `.meetingRecordingSaved` with their own Settings toggle, not gated by the call/screen-share check; remove reuse of `.charging` / `.allAgentsDone`.
**Invariants:** no repeating timers; one-shot cancellable tasks only; leaf observation preserved; shadow before stroke; click-through rules (panel interactive only while a bubble with buttons is visible).
**Tests:** bubble priority table (thermal > meeting failure > interruption > recording(first 5 s) > completion > personality); auto-dismiss timings via injected clock/sleeper (no real 45 s waits, no flaky 20 ms margins — replace the existing timing-based test the same way); personality tick skipped while recording; menu bar indicator flag toggles with recording; chime events fired once on start/save.
**Commit:** `fix(audio): single meeting bubble model, REC indicator, chimes, bubble UX (refs #43)`

## Task 6 — Settings, persistence, consent, retention (D7)
**Build:** `bitz.meeting.` key prefix + one-time migration from `Bitz.MeetingRecorder.*`; injected `UserDefaults` in the permission checker; single injection of the recorder (remove triple fallbacks and default-constructed services in views); Settings → Audio card split (Meeting Recorder / Transcription) after the Cyber Audio cards, plain labels, export `Toggle`, disabled captions with rows; language picker ordering + no invalid selection while loading; first-recording consent sheet (explains capture scope incl. Screen & System Audio Recording, storage, on-device transcription, inform participants) gating the first start; retention setting Off/30/90 with safe deletion (only Bitz-created sessions with valid metadata, older than limit), run at launch and after each recording.
**Tests:** migration copies old keys once and removes them; consent gate blocks start until acknowledged and persists; retention deletes only eligible folders (old + valid metadata) and never anything else; picker ordering function.
**Commit(s):** `fix(audio): meeting settings keys, consent notice, retention, Settings layout (refs #43)`

## Task 7 — Export and metadata hygiene (D8)
**Build:** export retry on "exists" with next suffix (bounded); git-work-tree / cloud-sync caption for the export folder; clipboard transient/concealed markers; `metadata.json` snake_case + `transcript_status` enum + `audio_status`/`recovered` fields from Task 3 + exported file name only + `detected_apps` by meeting-app bundle IDs (no browsers); `NSDocumentsFolderUsageDescription`.
**Tests:** export race retry; git/cloud detection; metadata encode/decode round trip with exact JSON keys; detected apps excludes browsers.
**Commit:** `fix(audio): export retry, metadata schema, clipboard privacy (refs #43)`

## Task 8 — Cleanup, scripts, docs (D9 remainder)
**Build:** state derivation + dead payloads + rename bubble flag; dead API removal/wiring (`permissionDenied`, `toggleMeetingRecordingAction` in main `NSMenu`); fix contradicting comments; `isLoaf(state:isRecording:)` helper + `MascotOverlayView` takes `isRecordingMeeting: Bool`; NITs (Advanced row style, shared JSON encoder, `finalizeForTermination` awaits tasks instead of polling, `CyberHeadphonesOverlay` Equatable); test for the real `agentMonitor` wiring; `Scripts/Info.plist.template` shared by both scripts; `package_and_run.sh` bundle ID default `com.bitz.cybercat.dev` (override `BITZ_BUNDLE_ID`); AGENTS.md map + bubble priority, ARCHITECTURE.md module table + privacy §4 (C-003).
**Tests:** agentMonitor wiring; `bash -n` both scripts; a script-level check that the template renders both bundle IDs.
**Commit(s):** `refactor(audio): recorder state cleanup and dead code (refs #43)`, `chore(build): shared Info.plist template and dev bundle ID (refs #43)`, `docs: meeting recorder architecture and privacy (refs #43)`

## Task 9 — Final verification (orchestrator)
- Full `xcrun swift test`; final whole-branch review by one fresh reviewer against this spec.
- Fast-forward `feat/43-meeting-audio-recorder` to the worktree branch; `./Scripts/package_and_run.sh release` from the main checkout; confirm the running binary path; reset TCC for the dev bundle ID.
- §2.8 idle CPU / RAM: sample `top -l 30 -s 2 -pid <Bitz>` with Settings closed, idle and while recording.
- Push; update PR description; user live test (spec §5).
