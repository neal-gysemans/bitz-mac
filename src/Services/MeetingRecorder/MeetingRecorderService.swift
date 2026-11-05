import AppKit
import Foundation

// MARK: - Isolated Elapsed Timer Store (Leaf View Observation, AGENTS.md §2.5)

/// Publishes the 1-second elapsed timer exclusively to leaf subviews (`MeetingRecordingTimerBubbleView`)
/// so `MascotOverlayView` and `SpeechBubbleView` roots never re-evaluate on every elapsed second (#43, #70).
@MainActor
public final class MeetingRecordingTimerStore: ObservableObject {
    @Published public fileprivate(set) var elapsedSeconds: Int = 0

    public init() {}
}

// MARK: - Meeting Recorder Coordinator Service

/// Coordinates dual-stream meeting audio recording (`audio.m4a`), metadata export (`metadata.json`),
/// native on-device transcription (`transcript.txt` & `transcript.json`), and Finder reveal (#43).
@MainActor
public final class MeetingRecorderService: ObservableObject {
    @Published public private(set) var state: MeetingRecorderState = .idle
    @Published public private(set) var isRecording: Bool = false
    @Published public private(set) var isTranscribing: Bool = false
    @Published public private(set) var permissionState: MeetingPermissionState
    @Published public private(set) var lastCompletedResult: MeetingRecordingResult?
    /// The meeting bubble on screen, nil when none (#43 D5).
    @Published public private(set) var bubble: MeetingBubble?
    @Published public private(set) var statusMessage: String = "Ready to record meetings locally (transcribed on-device)."

    public let timerStore = MeetingRecordingTimerStore()
    public let settingsStore: MeetingSettingsStore
    private let captureEngine: any MeetingAudioCapturing
    private let transcriptionService: any MeetingTranscriptionProviding
    private let permissionChecker: any MeetingPermissionChecking
    private let onRevealURL: (URL) -> Void
    private let nowProvider: () -> Date
    private let freeBytesProvider: (URL) -> Int64?
    /// Two 16-bit tracks take ~1.4 GB per hour, plus the mix; refuse to start below this.
    static let minimumFreeBytesToRecord: Int64 = 2_000_000_000

    /// Chimes once when a recording starts and once when its audio is saved.
    public var onPlaySound: ((CyberSoundEvent) -> Void)?
    /// OPEN SETTINGS on the failure bubble: the delegate opens Settings → Audio.
    public var onOpenSettings: (() -> Void)?
    /// First-recording notice (D7): true for Continue. Tests inject one instead of the modal alert.
    var consentPresenter: @MainActor (_ recordingsFolder: URL) -> Bool = MeetingConsentNotice.present
    /// One-shot delay before a bubble hides itself; tests inject one they release by hand.
    var sleep: @Sendable (Duration) async -> Void = { try? await Task.sleep(for: $0) }
    private(set) var bubbleHideTask: Task<Void, Never>?
    static let recordingBubbleDuration: Duration = .seconds(5)
    static let completionBubbleDuration: Duration = .seconds(45)

    private var elapsedTimerTask: Task<Void, Never>?
    private var activeSessionID: String?
    private var activeSessionDirectoryURL: URL?
    private var activeStartedAt: Date?
    private var activeDetectedApps: [String] = []
    private var activeCaptureWarning: String?
    /// Sources still recording; an interruption removes its source so the bubble says what is left.
    private var activeSources: Set<MeetingCaptureSource> = []
    /// Synchronous guards set before the first `await`, so a double toggle can never start or stop twice.
    private var isStarting = false
    private var isStopping = false
    /// The launch-recovery mix in progress; a starting recording cancels it so the two never compete for disk and CPU.
    private var recoveryMixTask: Task<Void, Never>?
    /// Launch recovery is scanning or mixing; retention waits so it never deletes a folder being recovered.
    private(set) var isRecovering = false
    private var transcribingMetadata: (metadata: MeetingRecordingMetadata, url: URL)?

    /// Meeting apps by bundle ID, as `ActivityMonitorService` matches them; browsers are never listed.
    nonisolated static let meetingAppBundleKeywords = ActivityMonitorService.workMeetingBundleKeywords + ["discord"]
    /// Bound on ` (N)` suffixes when another app keeps taking the export name.
    nonisolated static let maxExportAttempts = 100
    static let transientPasteboardType = NSPasteboard.PasteboardType("org.nspasteboard.TransientType")
    static let concealedPasteboardType = NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType")

    public init(
        settingsStore: MeetingSettingsStore = MeetingSettingsStore(),
        captureEngine: (any MeetingAudioCapturing)? = nil,
        transcriptionService: (any MeetingTranscriptionProviding)? = nil,
        permissionChecker: (any MeetingPermissionChecking)? = nil,
        nowProvider: @escaping () -> Date = { Date() },
        freeBytesProvider: @escaping (URL) -> Int64? = MeetingRecorderService.availableBytes(at:),
        onRevealURL: @escaping (URL) -> Void = { url in
            NSWorkspace.shared.activateFileViewerSelecting([url])
        }
    ) {
        self.settingsStore = settingsStore
        self.captureEngine = captureEngine ?? ProductionMeetingAudioCaptureEngine()
        self.transcriptionService = transcriptionService ?? SpeechFrameworkTranscriptionService()
        let resolvedPermissionChecker = permissionChecker ?? SystemMeetingPermissionChecker(userDefaults: settingsStore.userDefaults)
        self.permissionChecker = resolvedPermissionChecker
        self.permissionState = resolvedPermissionChecker.currentPermissions()
        self.nowProvider = nowProvider
        self.freeBytesProvider = freeBytesProvider
        self.onRevealURL = onRevealURL
        self.captureEngine.onCaptureInterrupted = { [weak self] source, message in
            Task { @MainActor in self?.handleCaptureInterruption(source, message) }
        }
    }

    deinit {
        elapsedTimerTask?.cancel()
        bubbleHideTask?.cancel()
    }

    /// True while capture is live or still being finalized, so quitting must wait for `finalizeForTermination()`.
    public var hasUnfinalizedRecording: Bool {
        isRecording || isStarting || isStopping
    }

    // MARK: - Derived UI State

    /// Between Stop and the end of the mix.
    public var isSaving: Bool {
        if case .saving = state { return true }
        return false
    }

    /// Disabled menu item shown instead of Start/Stop while the last recording is still being saved or transcribed.
    public var busyMenuLabel: String? {
        isSaving ? MeetingBubble.savingMenuLabel : isTranscribing ? MeetingBubble.transcribingMenuLabel : nil
    }

    public func refreshPermissions() {
        permissionState = permissionChecker.currentPermissions()
    }

    /// `includeSpeech`: also ask for Speech Recognition when auto-transcribe is off (Settings button; Transcribe Again needs it).
    @discardableResult
    public func requestPermissions(includeSpeech: Bool = false) async -> MeetingPermissionState {
        let updated = await permissionChecker.requestPermissions(
            captureMicrophone: settingsStore.captureMicrophone,
            captureSystemAudio: settingsStore.captureSystemAudio,
            transcribe: includeSpeech || settingsStore.autoTranscribeOnStop
        )
        permissionState = updated
        return updated
    }

    // MARK: - Recording Lifecycle

    public func toggleRecording() async {
        if isRecording {
            await stopRecording()
        } else {
            await startRecording()
        }
    }

    public func startRecording() async {
        guard !isRecording && !isTranscribing && !isStarting && !isStopping else { return }
        isStarting = true
        defer { isStarting = false }

        let captureMic = settingsStore.captureMicrophone
        let captureSys = settingsStore.captureSystemAudio
        guard captureMic || captureSys else {
            showFailure(MeetingBubble.noSourceText, message: MeetingRecorderError.noAudioSourcesEnabled.localizedDescription)
            return
        }

        // Before any permission prompt, so the Screen & System Audio Recording scope is explained first
        if !settingsStore.consentAcknowledged {
            guard consentPresenter(settingsStore.meetingsRootDirectoryURL) else {
                statusMessage = "Recording cancelled."
                return
            }
            settingsStore.setConsentAcknowledged(true)
        }
        recoveryMixTask?.cancel()

        let perms = await requestPermissions()
        guard perms.canRecord(captureMicrophone: captureMic, captureSystemAudio: captureSys) else {
            var missing: [String] = []
            if captureMic && perms.microphone != .authorized {
                missing.append("Microphone")
            }
            if captureSys && perms.screenAudio != .authorized {
                missing.append("Screen & System Audio Recording")
            }
            var msg = "Permission needed for \(missing.joined(separator: " & ")) in System Settings → Privacy & Security."
            if captureSys && perms.screenAudio != .authorized {
                msg += " Relaunch Bitz after granting Screen & System Audio Recording."
            }
            showFailure(MeetingBubble.needsPermissionText, detail: missing.joined(separator: " & "), message: msg)
            return
        }

        if let freeBytes = freeBytesProvider(settingsStore.meetingsRootDirectoryURL), freeBytes < Self.minimumFreeBytesToRecord {
            showFailure(
                MeetingBubble.lowDiskText,
                detail: "Bitz needs about 2 GB free on the recordings drive.",
                message: "Not enough free disk space to record: Bitz needs about 2 GB free on the recordings drive."
            )
            return
        }

        let startDate = nowProvider()
        var createdSessionDir: URL?

        do {
            let sessionDir = try Self.createSessionDirectory(
                in: settingsStore.meetingsRootDirectoryURL,
                baseName: MeetingFormatting.sessionFolderName(for: startDate)
            )
            createdSessionDir = sessionDir
            let sessionID = sessionDir.lastPathComponent
            try await captureEngine.startCapture(
                sessionDirectoryURL: sessionDir,
                captureMicrophone: captureMic,
                captureSystemAudio: captureSys
            )

            activeSessionID = sessionID
            activeSessionDirectoryURL = sessionDir
            activeStartedAt = startDate
            Self.restrictToOwner(
                sessionDir.appendingPathComponent(MeetingTrackWriter.micFileName),
                sessionDir.appendingPathComponent(MeetingTrackWriter.systemFileName)
            )
            activeDetectedApps = Self.detectRunningMeetingApps()
            activeCaptureWarning = nil
            activeSources = Set([captureMic ? .microphone : nil, captureSys ? .systemAudio : nil].compactMap { $0 })
            timerStore.elapsedSeconds = 0
            isRecording = true
            state = .recording(sessionID: sessionID, startedAt: startDate, elapsedSeconds: 0)
            statusMessage = "Recording meeting into \(sessionDir.lastPathComponent)..."
            // Shown briefly; the LED, headphones and menu bar REC stay for the whole recording
            present(.recording, hideAfter: Self.recordingBubbleDuration)
            onPlaySound?(.meetingRecordingStarted)
            startElapsedTimer()
        } catch {
            // Only the folder this attempt just created; an earlier recording's folder is never reused or removed
            if let createdSessionDir {
                try? FileManager.default.removeItem(at: createdSessionDir)
            }
            let detail: String
            if case .captureStartFailed(let reason) = error as? MeetingRecorderError {
                detail = reason
            } else {
                detail = error.localizedDescription
            }
            showFailure(MeetingBubble.couldNotStartText, detail: detail, message: error.localizedDescription)
        }
    }

    /// Stops and finalizes `audio.m4a` + `metadata.json`. `transcribe: false` is the fast quit path; with `mixDeadline`
    /// the mix only runs if its estimate fits, otherwise the tracks stay for launch recovery.
    public func stopRecording(transcribe: Bool = true, mixDeadline: ContinuousClock.Instant? = nil) async {
        guard isRecording, !isStopping,
              let sessionID = activeSessionID,
              let sessionDir = activeSessionDirectoryURL,
              let startedAt = activeStartedAt else {
            return
        }

        isStopping = true
        stopElapsedTimer()
        isRecording = false
        state = .saving(sessionID: sessionID)
        statusMessage = "Saving meeting into \(sessionDir.lastPathComponent)..."
        present(.saving)
        await captureEngine.stopCapture()

        let endedAt = nowProvider()
        let duration = max(0, endedAt.timeIntervalSince(startedAt))
        let metadataURL = sessionDir.appendingPathComponent("metadata.json")
        let skipReason: MeetingTranscriptSkipReason? = !transcribe ? nil
            : !settingsStore.autoTranscribeOnStop ? .transcriptionTurnedOff
            : !permissionState.canTranscribe ? .speechRecognitionNotAllowed
            : nil
        let shouldTranscribe = transcribe && skipReason == nil
        var warnings: [String] = []

        var metadata = MeetingRecordingMetadata(
            sessionID: sessionID,
            startedAt: startedAt,
            endedAt: endedAt,
            durationSeconds: duration,
            captureMicrophone: settingsStore.captureMicrophone,
            captureSystemAudio: settingsStore.captureSystemAudio,
            detectedAppNames: activeDetectedApps,
            audioFileNames: MeetingTrackMixer.audioFileNames(in: sessionDir),
            audioStatus: .unmixed,
            transcriptStatus: shouldTranscribe ? .pending : .skipped
        )
        // Written before the mix, so a quit that cuts the mix short still leaves metadata pointing at the tracks
        Self.writeMetadata(metadata, to: metadataURL)

        let mixed: Bool
        if let mixDeadline, ContinuousClock.now + .seconds(MeetingTrackMixer.estimatedMixSeconds(in: sessionDir)) > mixDeadline {
            warnings.append("Bitz quit before mixing the audio tracks; they are kept and mixed at next launch.")
            mixed = false
        } else {
            // Off the main actor; if quit's safety net cuts it short, mic.caf / system.caf stay intact
            let beforeMix = metadata
            let outcome = await Task.detached(priority: .userInitiated) {
                MeetingTrackMixer.mixSession(in: sessionDir) { names in
                    var recorded = beforeMix
                    recorded.mixedTracks = names
                    Self.writeMetadata(recorded, to: metadataURL)
                }
            }.value
            warnings += outcome.warnings
            mixed = outcome.mixed
            if mixed {
                metadata.mixedTracks = outcome.mixedTracks
            }
        }
        let mixedURL = sessionDir.appendingPathComponent(MeetingTrackMixer.audioFileName)
        if mixed {
            Self.restrictToOwner(mixedURL)
        }
        metadata.audioStatus = MeetingTrackMixer.audioStatus(in: sessionDir)
        metadata.audioFileNames = MeetingTrackMixer.audioFileNames(in: sessionDir)
        Self.writeMetadata(metadata, to: metadataURL)
        // Audio and metadata are final; transcription below never blocks quit or a new start's guard
        isStopping = false
        // Interruptions are accepted until here, so one reported while finalizing still reaches the result
        warnings = [activeCaptureWarning].compactMap { $0 } + warnings

        let audioURL = Self.transcriptionAudioURL(in: sessionDir)

        onPlaySound?(.meetingRecordingSaved)

        var transcriptURLs: (txtURL: URL, jsonURL: URL)?
        var transcriptError: String?
        if shouldTranscribe {
            isTranscribing = true
            transcriptURLs = await transcribeSession(
                sessionDir,
                audioURL: audioURL,
                metadata: &metadata,
                metadataURL: metadataURL,
                warnings: &warnings,
                transcriptError: &transcriptError
            )
        }

        showCompletion(MeetingRecordingResult(
            sessionID: sessionID,
            sessionDirectoryURL: sessionDir,
            audioFileURL: audioURL,
            metadataFileURL: metadataURL,
            transcriptTextURL: transcriptURLs?.txtURL,
            transcriptJSONURL: transcriptURLs?.jsonURL,
            durationSeconds: duration,
            warning: warnings.isEmpty ? nil : warnings.joined(separator: " "),
            transcriptSkipReason: skipReason,
            transcriptError: transcriptError
        ))

        activeSessionID = nil
        activeSessionDirectoryURL = nil
        activeStartedAt = nil
        activeDetectedApps = []
        activeCaptureWarning = nil
        activeSources = []
        // Not on the quit path, which must finish within its cap
        if transcribe {
            await applyRetention()
        }
    }

    /// Nothing is recording, stopping or transcribing, and there is a last recording to transcribe again (D6).
    public var canTranscribeAgain: Bool {
        lastCompletedResult != nil && !hasUnfinalizedRecording && !isTranscribing
    }

    /// Transcribe Again (D6): re-runs transcription and export on the last recording's session folder, overwriting its
    /// transcript files and updating its metadata. Runs even with auto-transcribe off, since the user asked for it.
    public func transcribeAgain() async {
        guard canTranscribeAgain, let last = lastCompletedResult else { return }
        // Set before the first await, so a double click or a start in between is refused
        isTranscribing = true
        let sessionDir = last.sessionDirectoryURL
        let metadataURL = last.metadataFileURL
        let audioURL = Self.transcriptionAudioURL(in: sessionDir)
        refreshPermissions()
        if permissionState.speechRecognition == .notDetermined {
            // Speech only: with auto-transcribe off nothing has asked yet, and the capture permissions are not needed here
            permissionState = await permissionChecker.requestPermissions(
                captureMicrophone: false,
                captureSystemAudio: false,
                transcribe: true
            )
        }
        var warnings: [String] = []
        var transcriptURLs: (txtURL: URL, jsonURL: URL)?
        var transcriptError: String?
        if !permissionState.canTranscribe {
            isTranscribing = false
        } else if var metadata = Self.recoveryMetadata(at: metadataURL, sessionDir: sessionDir) {
            transcriptURLs = await transcribeSession(
                sessionDir,
                audioURL: audioURL,
                metadata: &metadata,
                metadataURL: metadataURL,
                warnings: &warnings,
                transcriptError: &transcriptError
            )
        } else {
            isTranscribing = false
            transcriptError = MeetingBubble.metadataUnreadableError
        }
        showCompletion(MeetingRecordingResult(
            sessionID: last.sessionID,
            sessionDirectoryURL: sessionDir,
            audioFileURL: audioURL,
            metadataFileURL: metadataURL,
            transcriptTextURL: transcriptURLs?.txtURL,
            transcriptJSONURL: transcriptURLs?.jsonURL,
            durationSeconds: last.durationSeconds,
            warning: warnings.isEmpty ? nil : warnings.joined(separator: " "),
            transcriptSkipReason: permissionState.canTranscribe ? nil : .speechRecognitionNotAllowed,
            transcriptError: transcriptError
        ))
    }

    /// The mixed `audio.m4a` is preferred; without a readable one, the mic track, or system audio when there is no mic track.
    nonisolated static func transcriptionAudioURL(in sessionDir: URL) -> URL {
        let mixedURL = sessionDir.appendingPathComponent(MeetingTrackMixer.audioFileName)
        if MeetingTrackMixer.mixedLength(in: sessionDir) != nil { return mixedURL }
        return MeetingTrackMixer.trackURLs(in: sessionDir).first { FileManager.default.fileExists(atPath: $0.path) } ?? mixedURL
    }

    /// Transcribes `audioURL` into the session's transcript files (replacing earlier ones), copies the text to the export
    /// folder, and records the outcome in `metadata.json`. The caller sets `isTranscribing` before its first await.
    /// No transcript at all sets `transcriptError`; a kept or partial one adds to `warnings`.
    private func transcribeSession(
        _ sessionDir: URL,
        audioURL: URL,
        metadata: inout MeetingRecordingMetadata,
        metadataURL: URL,
        warnings: inout [String],
        transcriptError: inout String?
    ) async -> (txtURL: URL, jsonURL: URL)? {
        let sessionID = sessionDir.lastPathComponent
        state = .transcribing(sessionID: sessionID, sessionDirectoryURL: sessionDir)
        statusMessage = "✨ Meeting saved! Transcribing audio on-device..."
        present(.transcribing)
        transcribingMetadata = (metadata, metadataURL)
        defer {
            transcribingMetadata = nil
            isTranscribing = false
        }
        // Only a Transcribe Again finds transcript files here; a fresh session folder has none. Read before the run:
        // the previous export is replaced only while it still holds exactly these bytes (not edited by hand).
        let previousTxtURL = sessionDir.appendingPathComponent("transcript.txt")
        let previousJSONURL = sessionDir.appendingPathComponent("transcript.json")
        let previousTranscript = try? Data(contentsOf: previousTxtURL)
        func giveUp(_ message: String, keptWarning: String) -> (txtURL: URL, jsonURL: URL)? {
            if previousTranscript != nil {
                // Metadata (status, locale, export name) still describes the kept transcript, so it is not rewritten
                warnings.append(keptWarning)
                return (previousTxtURL, previousJSONURL)
            }
            metadata.transcriptStatus = .failed
            Self.writeMetadata(metadata, to: metadataURL)
            transcriptError = message
            return nil
        }
        let transcript: MeetingTranscript
        do {
            transcript = try await transcriptionService.transcribe(
                audioFileURL: audioURL,
                sessionID: sessionID,
                locale: settingsStore.transcriptionLocaleIdentifier.map(Locale.init(identifier:))
            )
        } catch {
            return giveUp(error.localizedDescription, keptWarning: "\(MeetingBubble.previousTranscriptKeptWarning): \(error.localizedDescription)")
        }
        let written: (txtURL: URL, jsonURL: URL)
        do {
            written = try MeetingTranscriptWriter.write(transcript, to: sessionDir)
        } catch {
            let message = "\(MeetingBubble.transcriptNotSavedError): \(error.localizedDescription)"
            return giveUp(message, keptWarning: message)
        }
        Self.restrictToOwner(written.txtURL, written.jsonURL)
        metadata.transcriptStatus = .completed
        metadata.transcriptLocale = transcript.localeIdentifier
        if let partialWarning = transcript.warning {
            warnings.append(partialWarning)
        }
        if let exportDirectory = settingsStore.transcriptExportDirectoryURL {
            do {
                let exported = try Self.exportTranscript(
                    written.txtURL,
                    sessionID: sessionID,
                    to: exportDirectory,
                    replacing: metadata.transcriptExportFileName,
                    ifUnchangedFrom: previousTranscript
                )
                metadata.transcriptExportFileName = exported.lastPathComponent
            } catch {
                warnings.append("Transcript saved, but copy to export folder failed: \(error.localizedDescription)")
            }
        }
        Self.writeMetadata(metadata, to: metadataURL)

        if settingsStore.copyTranscriptPathToClipboard {
            Self.copyPathToClipboard(written.txtURL.path)
        }
        return written
    }

    private func showCompletion(_ result: MeetingRecordingResult) {
        lastCompletedResult = result
        state = .completed(result)
        present(.completion(for: result), hideAfter: Self.completionBubbleDuration)
        let folder = result.sessionDirectoryURL.lastPathComponent
        statusMessage = result.transcriptTextURL != nil
            ? "Saved \(result.audioFileURL.lastPathComponent) & on-device transcript to \(folder)."
            : "Saved \(result.audioFileURL.lastPathComponent) to \(folder)."
        if let reason = result.transcriptSkipReason {
            statusMessage += " Transcript skipped: \(reason.text)"
        }
        if let error = result.transcriptError {
            statusMessage += " ⚠️ \(error)"
        }
        if let warning = result.warning {
            statusMessage += " ⚠️ \(warning)"
        }
    }

    /// Quit path: waits for an in-flight start/stop, then finalizes without transcribing. The mix only runs if it fits
    /// `mixBudget` (the delegate's 5 s quit cap minus a margin); otherwise the tracks stay and are mixed at next launch.
    public func finalizeForTermination(mixBudget: Duration = .milliseconds(4_500)) async {
        let mixDeadline = ContinuousClock.now + mixBudget
        while isStarting || isStopping {
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
        await stopRecording(transcribe: false, mixDeadline: mixDeadline)
    }

    /// At launch: recovery first, so a session it rebuilds metadata for is judged by retention with that metadata.
    public func runLaunchMaintenance() async {
        await recoverUnmixedSessions()
        await applyRetention()
    }

    /// Launch recovery (D1): mixes sessions a crash or quit left as tracks, one at a time at utility priority,
    /// never while a recording runs (a start cancels the mix in progress). No transcription; the session gets `recovered: true`.
    public func recoverUnmixedSessions() async {
        isRecovering = true
        defer { isRecovering = false }
        let root = settingsStore.meetingsRootDirectoryURL
        let sessions = await Task.detached(priority: .utility) {
            let folders = (try? FileManager.default.contentsOfDirectory(
                at: root,
                includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey],
                options: .skipsHiddenFiles
            )) ?? []
            return folders.filter(Self.needsRecovery).sorted { $0.path < $1.path }
        }.value
        for sessionDir in sessions {
            guard !hasUnfinalizedRecording else { return }
            let task = Task.detached(priority: .utility) {
                Self.recoverSession(sessionDir)
            }
            recoveryMixTask = task
            await task.value
        }
        recoveryMixTask = nil
    }

    /// Retention (D7): deletes finished sessions older than the "Delete recordings after" setting. Skipped while recording,
    /// transcribing or recovering; it runs again after the next recording and at launch. Each run first finishes deletes
    /// an earlier run left behind (`.deleting-*`), even with the setting Off, since those sessions were already removed.
    public func applyRetention() async {
        guard !hasUnfinalizedRecording, !isTranscribing, !isRecovering else { return }
        let days = settingsStore.retentionDays
        let root = settingsStore.meetingsRootDirectoryURL
        let now = nowProvider()
        await Task.detached(priority: .utility) {
            Self.sweepUnfinishedDeletes(in: root)
            guard let days else { return }
            Self.expiredSessions(in: root, olderThanDays: days, now: now).forEach(Self.deleteSession)
        }.value
    }

    nonisolated static let deletingPrefix = ".deleting-"

    /// One atomic rename hides the session, so a delete cut short never leaves a half-empty session in the list.
    /// removeItem deletes a symlink inside the folder, never its target.
    nonisolated static func deleteSession(_ sessionDir: URL) {
        let trash = sessionDir.deletingLastPathComponent().appendingPathComponent(deletingPrefix + sessionDir.lastPathComponent)
        guard (try? FileManager.default.moveItem(at: sessionDir, to: trash)) != nil else { return }
        try? FileManager.default.removeItem(at: trash)
    }

    /// Removes `.deleting-<session>` folders a killed or failed delete left in the recordings root (real folders only).
    nonisolated static func sweepUnfinishedDeletes(in root: URL) {
        let entries = (try? FileManager.default.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey]
        )) ?? []
        for entry in entries where isSessionFolder(entry, prefix: deletingPrefix) {
            try? FileManager.default.removeItem(at: entry)
        }
    }

    /// Session folders Bitz created (its folder name and a decodable `metadata.json`) that started more than `days` ago.
    /// The folder's modification date must agree, so a wrong `startedAt` alone never expires a recent session.
    /// Symlinks are never candidates. The caller guarantees no session is active, so none is in progress here.
    nonisolated static func expiredSessions(in root: URL, olderThanDays days: Int, now: Date) -> [URL] {
        let cutoff = now.addingTimeInterval(-Double(days) * 86_400)
        let folders = (try? FileManager.default.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey, .contentModificationDateKey],
            options: .skipsHiddenFiles
        )) ?? []
        return folders.filter { sessionDir in
            guard isSessionFolder(sessionDir),
                  let modified = try? sessionDir.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate,
                  modified < cutoff,
                  let metadata = decodedMetadata(at: sessionDir.appendingPathComponent("metadata.json")) else { return false }
            return metadata.startedAt < cutoff
        }
    }

    /// Only folders Bitz names (`yyyy-MM-dd_HH-mm-ss`, optional `-N`, after `prefix`), never symlinks: the recordings
    /// root can be any folder.
    nonisolated static func isSessionFolder(_ url: URL, prefix: String = "") -> Bool {
        let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        let name = url.lastPathComponent
        return values?.isDirectory == true && values?.isSymbolicLink == false && name.hasPrefix(prefix)
            && name.dropFirst(prefix.count).wholeMatch(of: #/[0-9]{4}-[0-9]{2}-[0-9]{2}_[0-9]{2}-[0-9]{2}-[0-9]{2}(-[0-9]+)?/#) != nil
    }

    nonisolated static func needsRecovery(_ sessionDir: URL) -> Bool {
        guard isSessionFolder(sessionDir) else { return false }
        if MeetingTrackMixer.needsMix(sessionDir) { return true }
        // A verified mix whose track cleanup or final metadata write was cut short (kill right after the rename)
        guard MeetingTrackMixer.mixedLength(in: sessionDir) != nil,
              let metadata = decodedMetadata(at: sessionDir.appendingPathComponent("metadata.json")) else { return false }
        return !MeetingTrackMixer.tracksCoveredByMix(in: sessionDir, mixedTracks: metadata.mixedTracks).isEmpty
            || metadata.audioStatus != .mixed
            || metadata.audioFileNames != MeetingTrackMixer.audioFileNames(in: sessionDir)
    }

    nonisolated static func recoverSession(_ sessionDir: URL) {
        let metadataURL = sessionDir.appendingPathComponent("metadata.json")
        // Read before the mix deletes the tracks the derived metadata is measured from
        let metadata = recoveryMetadata(at: metadataURL, sessionDir: sessionDir)
        var mixedTracks = metadata?.mixedTracks
        let mixedNow: Bool
        // Rechecked: a recording stopped since the scan may have mixed this folder already
        if MeetingTrackMixer.needsMix(sessionDir) {
            let outcome = MeetingTrackMixer.mixSession(in: sessionDir) { names in
                guard var recorded = metadata else { return }
                recorded.mixedTracks = names
                writeMetadata(recorded, to: metadataURL)
            }
            mixedNow = outcome.mixed
            if mixedNow {
                mixedTracks = outcome.mixedTracks
            }
        } else {
            // audio.m4a is a verified mix; the tracks the metadata lists as mixed are left over from a cleanup cut short
            MeetingTrackMixer.tracksCoveredByMix(in: sessionDir, mixedTracks: mixedTracks)
                .forEach { try? FileManager.default.removeItem(at: $0) }
            // Metadata derived from a leftover track would understate the recording; only existing metadata is updated
            guard FileManager.default.fileExists(atPath: metadataURL.path) else { return }
            mixedNow = false
        }
        if mixedNow {
            restrictToOwner(sessionDir.appendingPathComponent(MeetingTrackMixer.audioFileName))
        }
        // Metadata that exists but does not decode is left as it is rather than replaced
        guard var metadata else { return }
        if mixedNow {
            metadata.recovered = true
        }
        // Also reconciles metadata a kill left saying "unmixed" or listing deleted tracks
        metadata.mixedTracks = mixedTracks
        metadata.audioStatus = MeetingTrackMixer.audioStatus(in: sessionDir)
        metadata.audioFileNames = MeetingTrackMixer.audioFileNames(in: sessionDir)
        writeMetadata(metadata, to: metadataURL)
    }

    /// The session's metadata to merge into; derived from the tracks when a crash left none; nil when it does not decode.
    nonisolated private static func recoveryMetadata(at url: URL, sessionDir: URL) -> MeetingRecordingMetadata? {
        guard FileManager.default.fileExists(atPath: url.path) else {
            return recoveredMetadata(for: sessionDir)
        }
        return decodedMetadata(at: url)
    }

    nonisolated static func decodedMetadata(at url: URL) -> MeetingRecordingMetadata? {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return (try? Data(contentsOf: url)).flatMap { try? decoder.decode(MeetingRecordingMetadata.self, from: $0) }
    }

    nonisolated private static func recoveredMetadata(for sessionDir: URL) -> MeetingRecordingMetadata {
        let startedAt = (try? sessionDir.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? Date()
        let duration = Double(MeetingTrackMixer.trackLengths(in: sessionDir).max() ?? 0) / MeetingTrackWriter.sampleRate
        let fileExists = { FileManager.default.fileExists(atPath: sessionDir.appendingPathComponent($0).path) }
        return MeetingRecordingMetadata(
            sessionID: sessionDir.lastPathComponent,
            startedAt: startedAt,
            endedAt: startedAt.addingTimeInterval(duration),
            durationSeconds: duration,
            captureMicrophone: fileExists(MeetingTrackWriter.micFileName),
            captureSystemAudio: fileExists(MeetingTrackWriter.systemFileName),
            detectedAppNames: [],
            audioStatus: .unmixed,
            transcriptStatus: .skipped
        )
    }

    public func revealInFinder(_ targetURL: URL? = nil) {
        let url = targetURL
            ?? lastCompletedResult?.sessionDirectoryURL
            ?? settingsStore.meetingsRootDirectoryURL
        try? FileManager.default.createDirectory(
            at: settingsStore.meetingsRootDirectoryURL,
            withIntermediateDirectories: true
        )
        onRevealURL(url)
        if bubble?.kind == .completion {
            present(nil)
        }
    }

    public func dismissBubble() {
        present(nil)
        if case .failed = state {
            state = .idle
        }
    }

    /// A button on the meeting bubble.
    public func perform(_ action: MeetingBubble.Action) {
        switch action {
        case .transcribeAgain:
            Task { await transcribeAgain() }
        case .openInFinder:
            revealInFinder()
        case .openSettings:
            dismissBubble()
            onOpenSettings?()
        case .dismiss:
            dismissBubble()
        }
    }

    /// Quit path while transcribing: synchronously replaces the "pending" status so metadata never stays stale.
    /// A Transcribe Again that finds a transcript from the earlier run keeps that run's status: the transcript is still there.
    public func markTranscriptionInterrupted() {
        guard var pending = transcribingMetadata,
              !FileManager.default.fileExists(atPath: pending.url.deletingLastPathComponent().appendingPathComponent("transcript.txt").path)
        else { return }
        pending.metadata.transcriptStatus = .interrupted
        Self.writeMetadata(pending.metadata, to: pending.url)
    }

    // MARK: - Internal Helpers

    /// Accepted while recording and while stopping (the warning reaches the result); only a live recording shows a bubble.
    func handleCaptureInterruption(_ source: MeetingCaptureSource, _ message: String) {
        guard isRecording || isStopping else { return }
        activeCaptureWarning = message
        statusMessage = "⚠️ \(message)"
        guard isRecording else { return }
        activeSources.remove(source)
        present(.interruption(source, remaining: activeSources))
    }

    /// `text` is the short headline; `message` (the full cause) goes to `statusMessage`. Stays until dismissed.
    private func showFailure(_ text: String, detail: String? = nil, message: String) {
        state = .failed(message)
        statusMessage = message
        present(.failure(text, detail: detail))
    }

    /// Replaces the bubble; with `hideAfter` it hides itself once (one-shot task, nothing runs while idle).
    private func present(_ newBubble: MeetingBubble?, hideAfter: Duration? = nil) {
        bubbleHideTask?.cancel()
        bubbleHideTask = nil
        bubble = newBubble
        guard let newBubble, let hideAfter else { return }
        bubbleHideTask = Task { @MainActor [weak self, sleep] in
            await sleep(hideAfter)
            guard !Task.isCancelled, let self, self.bubble == newBubble else { return }
            self.bubble = nil
        }
    }

    private func startElapsedTimer() {
        stopElapsedTimer()
        elapsedTimerTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                guard !Task.isCancelled, let self, self.isRecording,
                      let startedAt = self.activeStartedAt else {
                    break
                }
                let elapsed = max(0, Int(self.nowProvider().timeIntervalSince(startedAt).rounded(.down)))
                if self.timerStore.elapsedSeconds != elapsed {
                    self.timerStore.elapsedSeconds = elapsed
                }
            }
        }
    }

    private func stopElapsedTimer() {
        elapsedTimerTask?.cancel()
        elapsedTimerTask = nil
    }

    /// Claims a new session folder. A name already taken by an earlier recording gets `-2`, `-3`… instead.
    static func createSessionDirectory(in root: URL, baseName: String) throws -> URL {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        var suffix = 1
        while true {
            let name = suffix == 1 ? baseName : "\(baseName)-\(suffix)"
            let url = root.appendingPathComponent(name, isDirectory: true)
            do {
                // Without intermediates, creation fails if the folder exists, so claiming is atomic
                try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
                return url
            } catch CocoaError.fileWriteFileExists {
                suffix += 1
            }
        }
    }

    /// Copies `transcript.txt` into the export folder as `<sessionID> transcript.txt`, adding ` (2)`, ` (3)`… instead of overwriting.
    /// `previousName` (this session's earlier export) is replaced in place only when that file in this folder still holds
    /// exactly `previousTranscript`, the session's transcript before this run: anything else is another file or a hand edit.
    static func exportTranscript(
        _ txtURL: URL,
        sessionID: String,
        to directory: URL,
        replacing previousName: String? = nil,
        ifUnchangedFrom previousTranscript: Data? = nil
    ) throws -> URL {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        if let previousName, let previousTranscript {
            let previous = directory.appendingPathComponent((previousName as NSString).lastPathComponent)
            if (try? Data(contentsOf: previous)) == previousTranscript {
                try Data(contentsOf: txtURL).write(to: previous, options: .atomic)
                restrictToOwner(previous)
                return previous
            }
        }
        for attempt in 1...maxExportAttempts {
            let name = attempt == 1 ? "\(sessionID) transcript.txt" : "\(sessionID) transcript (\(attempt)).txt"
            let destination = directory.appendingPathComponent(name)
            do {
                // copyItem never replaces an existing file; a name taken (even in the meantime) moves on to the next suffix
                try FileManager.default.copyItem(at: txtURL, to: destination)
                restrictToOwner(destination)
                return destination
            } catch CocoaError.fileWriteFileExists {
                continue
            }
        }
        throw CocoaError(.fileWriteFileExists)
    }

    /// Transient and concealed markers (nspasteboard.org) ask clipboard managers not to keep the path in their history.
    static func copyPathToClipboard(_ path: String, pasteboard: NSPasteboard = .general) {
        pasteboard.clearContents()
        pasteboard.setString(path, forType: .string)
        pasteboard.setData(Data(), forType: transientPasteboardType)
        pasteboard.setData(Data(), forType: concealedPasteboardType)
    }

    /// Meeting files are private (0600), like `FileDropInboxService`. Reapply after every write: atomic writes recreate at 0644.
    nonisolated static func restrictToOwner(_ urls: URL...) {
        for url in urls {
            try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        }
    }

    nonisolated static func writeMetadata(_ metadata: MeetingRecordingMetadata, to url: URL) {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        if let data = try? encoder.encode(metadata) {
            try? data.write(to: url, options: .atomic)
            restrictToOwner(url)
        }
    }

    /// Free space on the recordings volume (the folder may not exist yet, so its nearest existing parent); nil if unknown.
    public nonisolated static func availableBytes(at url: URL) -> Int64? {
        var existing = url
        while !FileManager.default.fileExists(atPath: existing.path) && existing.pathComponents.count > 1 {
            existing.deleteLastPathComponent()
        }
        return try? existing.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]).volumeAvailableCapacityForImportantUsage
    }

    private static func detectRunningMeetingApps() -> [String] {
        meetingAppNames(in: NSWorkspace.shared.runningApplications.map { ($0.bundleIdentifier, $0.localizedName) })
    }

    /// Names of the apps whose bundle ID matches a meeting app keyword, sorted and unique.
    nonisolated static func meetingAppNames(in apps: [(bundleID: String?, name: String?)]) -> [String] {
        let names = apps.compactMap { app -> String? in
            guard let bundleID = app.bundleID?.lowercased(),
                  meetingAppBundleKeywords.contains(where: { bundleID.contains($0) }) else { return nil }
            return app.name ?? app.bundleID
        }
        return Array(Set(names)).sorted()
    }
}

// MARK: - First-Recording Notice (D7)

/// One-time notice before the first recording ever: what is captured, where it goes, and that others must be told.
@MainActor
enum MeetingConsentNotice {
    static let title = "Before your first meeting recording"

    static func message(recordingsFolder: URL) -> String {
        let folder = (recordingsFolder.path as NSString).abbreviatingWithTildeInPath
        return """
        Bitz records your microphone and all sound your Mac plays, so everyone in the call is captured. \
        Recording that sound needs the Screen & System Audio Recording permission. macOS calls it screen recording, \
        but Bitz only uses the audio.

        Recordings are saved in \(folder). Transcripts are made on this Mac.

        Let other participants know before you record.
        """
    }

    /// Modal alert; a menu-bar app activates first so the alert is in front. True for Continue.
    static func present(recordingsFolder: URL) -> Bool {
        // runModal would hang a test run forever: fail loudly instead, and act as Cancel where asserts are off
        if NSClassFromString("XCTestCase") != nil {
            assertionFailure("Inject consentPresenter in tests")
            return false
        }
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message(recordingsFolder: recordingsFolder)
        alert.addButton(withTitle: "Continue")
        alert.addButton(withTitle: "Cancel")
        NSApp.activate(ignoringOtherApps: true)
        return alert.runModal() == .alertFirstButtonReturn
    }
}
