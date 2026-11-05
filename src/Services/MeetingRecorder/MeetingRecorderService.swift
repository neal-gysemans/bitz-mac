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
    @Published public private(set) var isCompletionBubbleVisible: Bool = false
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

    /// Optional sound callback so Bitz chimes when recording starts/completes.
    public var onPlaySound: ((CyberSoundEvent) -> Void)?

    private var elapsedTimerTask: Task<Void, Never>?
    private var activeSessionID: String?
    private var activeSessionDirectoryURL: URL?
    private var activeStartedAt: Date?
    private var activeDetectedApps: [String] = []
    private var activeCaptureWarning: String?
    /// Synchronous guards set before the first `await`, so a double toggle can never start or stop twice.
    private var isStarting = false
    private var isStopping = false
    private var failureDismissTask: Task<Void, Never>?
    private var transcribingMetadata: (metadata: MeetingRecordingMetadata, url: URL)?
    var failureBubbleDurationNanoseconds: UInt64 = 6_000_000_000

    private static let knownMeetingAppNames: Set<String> = [
        "zoom.us", "Zoom", "Microsoft Teams", "Slack", "FaceTime", "Discord",
        "Webex", "Around", "Tuple", "Google Chrome", "Arc", "Brave Browser", "Safari", "Firefox"
    ]

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
        let resolvedPermissionChecker = permissionChecker ?? SystemMeetingPermissionChecker()
        self.permissionChecker = resolvedPermissionChecker
        self.permissionState = resolvedPermissionChecker.currentPermissions()
        self.nowProvider = nowProvider
        self.freeBytesProvider = freeBytesProvider
        self.onRevealURL = onRevealURL
        self.captureEngine.onCaptureInterrupted = { [weak self] message in
            Task { @MainActor in self?.handleCaptureInterruption(message) }
        }
    }

    deinit {
        elapsedTimerTask?.cancel()
        failureDismissTask?.cancel()
    }

    /// True while capture is live or still being finalized, so quitting must wait for `finalizeForTermination()`.
    public var hasUnfinalizedRecording: Bool {
        isRecording || isStarting || isStopping
    }

    // MARK: - Derived UI State

    /// Whether the speech bubble currently shows an interactive Meeting Recorder action ("OPEN IN FINDER" / "DISMISS").
    public var isInteractiveBubbleActive: Bool {
        if case .completed = state, isCompletionBubbleVisible {
            return true
        }
        return false
    }

    /// Ambient speech bubble text displayed while recording, transcribing, or showing completion status.
    public var activeSpeechBubbleText: String? {
        switch state {
        case .idle:
            return nil
        case .recording:
            return "🔴 Recording meeting (\(MeetingFormatting.formatDuration(timerStore.elapsedSeconds)))..."
        case .transcribing:
            return "✨ Meeting saved! Transcribing audio..."
        case .completed(let result):
            guard isCompletionBubbleVisible else { return nil }
            return result.bubbleHeadline
        case .failed(let message):
            guard isCompletionBubbleVisible else { return nil }
            return "⚠️ \(message)"
        }
    }

    public func refreshPermissions() {
        permissionState = permissionChecker.currentPermissions()
    }

    @discardableResult
    public func requestPermissions() async -> MeetingPermissionState {
        let updated = await permissionChecker.requestPermissions(
            captureMicrophone: settingsStore.captureMicrophone,
            captureSystemAudio: settingsStore.captureSystemAudio,
            transcribe: settingsStore.autoTranscribeOnStop
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
            showFailure(MeetingRecorderError.noAudioSourcesEnabled.localizedDescription)
            return
        }

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
            showFailure(msg)
            return
        }

        if let freeBytes = freeBytesProvider(settingsStore.meetingsRootDirectoryURL), freeBytes < Self.minimumFreeBytesToRecord {
            showFailure("Not enough free disk space to record: Bitz needs about 2 GB free on the recordings drive.")
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
            failureDismissTask?.cancel()
            timerStore.elapsedSeconds = 0
            isCompletionBubbleVisible = false
            isRecording = true
            state = .recording(sessionID: sessionID, startedAt: startDate, elapsedSeconds: 0)
            statusMessage = "Recording meeting into \(sessionDir.lastPathComponent)..."
            startElapsedTimer()
        } catch {
            // Only the folder this attempt just created; an earlier recording's folder is never reused or removed
            if let createdSessionDir {
                try? FileManager.default.removeItem(at: createdSessionDir)
            }
            showFailure(error.localizedDescription)
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
        await captureEngine.stopCapture()

        let endedAt = nowProvider()
        let duration = max(0, endedAt.timeIntervalSince(startedAt))
        let metadataURL = sessionDir.appendingPathComponent("metadata.json")
        let shouldTranscribe = transcribe && settingsStore.autoTranscribeOnStop && permissionState.canTranscribe
        var warnings = [activeCaptureWarning].compactMap { $0 }

        var metadata = MeetingRecordingMetadata(
            sessionID: sessionID,
            startedAt: startedAt,
            endedAt: endedAt,
            durationSeconds: duration,
            captureMicrophone: settingsStore.captureMicrophone,
            captureSystemAudio: settingsStore.captureSystemAudio,
            detectedAppNames: activeDetectedApps,
            audioFileNames: MeetingTrackMixer.audioFileNames(in: sessionDir),
            audioStatus: "unmixed",
            transcriptStatus: shouldTranscribe ? "pending" : "skipped"
        )
        // Written before the mix, so a quit that cuts the mix short still leaves metadata pointing at the tracks
        Self.writeMetadata(metadata, to: metadataURL)

        let mixed: Bool
        if let mixDeadline, ContinuousClock.now + .seconds(MeetingTrackMixer.estimatedMixSeconds(in: sessionDir)) > mixDeadline {
            warnings.append("Bitz quit before mixing the audio tracks; they are kept and mixed at next launch.")
            mixed = false
        } else {
            // Off the main actor; if quit's safety net cuts it short, mic.caf / system.caf stay intact
            let outcome = await Task.detached(priority: .userInitiated) {
                MeetingTrackMixer.mixSession(in: sessionDir)
            }.value
            warnings += outcome.warnings
            mixed = outcome.mixed
        }
        let mixedURL = sessionDir.appendingPathComponent(MeetingTrackMixer.audioFileName)
        if mixed {
            Self.restrictToOwner(mixedURL)
        }
        metadata.audioStatus = mixed ? "mixed" : "unmixed"
        metadata.audioFileNames = MeetingTrackMixer.audioFileNames(in: sessionDir)
        Self.writeMetadata(metadata, to: metadataURL)
        // Audio and metadata are final; transcription below never blocks quit or a new start's guard
        isStopping = false

        // The mix is preferred; without it, transcribe the mic track, or system audio when there is no mic track
        let audioURL = mixed
            ? mixedURL
            : MeetingTrackMixer.trackURLs(in: sessionDir).first { FileManager.default.fileExists(atPath: $0.path) } ?? mixedURL

        onPlaySound?(.charging)

        var txtURL: URL?
        var jsonURL: URL?

        if shouldTranscribe {
            isTranscribing = true
            state = .transcribing(sessionID: sessionID, sessionDirectoryURL: sessionDir)
            statusMessage = "✨ Meeting saved! Transcribing audio on-device..."

            transcribingMetadata = (metadata, metadataURL)
            defer { transcribingMetadata = nil }
            do {
                let transcript = try await transcriptionService.transcribe(
                    audioFileURL: audioURL,
                    sessionID: sessionID,
                    locale: settingsStore.transcriptionLocaleIdentifier.map(Locale.init(identifier:))
                )
                let written = try MeetingTranscriptWriter.write(transcript, to: sessionDir)
                Self.restrictToOwner(written.txtURL, written.jsonURL)
                txtURL = written.txtURL
                jsonURL = written.jsonURL
                metadata.transcriptStatus = "completed"
                metadata.transcriptLocale = transcript.localeIdentifier
                if let partialWarning = transcript.warning {
                    warnings.append(partialWarning)
                }
                if let exportDirectory = settingsStore.transcriptExportDirectoryURL {
                    do {
                        let exported = try Self.exportTranscript(written.txtURL, sessionID: sessionID, to: exportDirectory)
                        metadata.transcriptExportPath = exported.path
                    } catch {
                        warnings.append("Transcript saved, but copy to export folder failed: \(error.localizedDescription)")
                    }
                }
                Self.writeMetadata(metadata, to: metadataURL)

                if settingsStore.copyTranscriptPathToClipboard {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(written.txtURL.path, forType: .string)
                }
            } catch {
                metadata.transcriptStatus = "failed"
                Self.writeMetadata(metadata, to: metadataURL)
                warnings.append("Transcript not saved: \(error.localizedDescription)")
            }
            isTranscribing = false
        }

        let result = MeetingRecordingResult(
            sessionID: sessionID,
            sessionDirectoryURL: sessionDir,
            audioFileURL: audioURL,
            metadataFileURL: metadataURL,
            transcriptTextURL: txtURL,
            transcriptJSONURL: jsonURL,
            durationSeconds: duration,
            warning: warnings.isEmpty ? nil : warnings.joined(separator: " ")
        )
        lastCompletedResult = result
        state = .completed(result)
        isCompletionBubbleVisible = true
        statusMessage = txtURL != nil
            ? "Saved \(audioURL.lastPathComponent) & on-device transcript to \(sessionDir.lastPathComponent)."
            : "Saved \(audioURL.lastPathComponent) to \(sessionDir.lastPathComponent)."
        if let warning = result.warning {
            statusMessage += " ⚠️ \(warning)"
        }
        onPlaySound?(.allAgentsDone)

        activeSessionID = nil
        activeSessionDirectoryURL = nil
        activeStartedAt = nil
        activeDetectedApps = []
        activeCaptureWarning = nil
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

    /// Launch recovery (D1): mixes sessions a crash or quit left as tracks, one at a time at utility priority,
    /// never while a recording runs. No transcription; the session gets `recovered: true`.
    public func recoverUnmixedSessions() async {
        let root = settingsStore.meetingsRootDirectoryURL
        let sessions = await Task.detached(priority: .utility) {
            let folders = (try? FileManager.default.contentsOfDirectory(
                at: root,
                includingPropertiesForKeys: nil,
                options: .skipsHiddenFiles
            )) ?? []
            return folders.filter(MeetingTrackMixer.needsMix).sorted { $0.path < $1.path }
        }.value
        for sessionDir in sessions {
            guard !hasUnfinalizedRecording else { return }
            await Task.detached(priority: .utility) {
                Self.recoverSession(sessionDir)
            }.value
        }
    }

    nonisolated static func recoverSession(_ sessionDir: URL) {
        // Rechecked: a recording stopped since the scan may have mixed this folder already
        guard MeetingTrackMixer.needsMix(sessionDir) else { return }
        let metadataURL = sessionDir.appendingPathComponent("metadata.json")
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        // A crash mid-recording leaves no metadata.json; derive what the tracks can tell
        var metadata = (try? Data(contentsOf: metadataURL)).flatMap { try? decoder.decode(MeetingRecordingMetadata.self, from: $0) }
            ?? recoveredMetadata(for: sessionDir)
        let outcome = MeetingTrackMixer.mixSession(in: sessionDir)
        if outcome.mixed {
            restrictToOwner(sessionDir.appendingPathComponent(MeetingTrackMixer.audioFileName))
            metadata.recovered = true
        }
        metadata.audioStatus = outcome.mixed ? "mixed" : "unmixed"
        metadata.audioFileNames = MeetingTrackMixer.audioFileNames(in: sessionDir)
        writeMetadata(metadata, to: metadataURL)
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
            audioStatus: "unmixed",
            transcriptStatus: "skipped"
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
        isCompletionBubbleVisible = false
    }

    public func dismissCompletionBubble() {
        isCompletionBubbleVisible = false
        if case .failed = state {
            state = .idle
        }
    }

    /// Quit path while transcribing: synchronously replaces the "pending" status so metadata never stays stale.
    public func markTranscriptionInterrupted() {
        guard var pending = transcribingMetadata else { return }
        pending.metadata.transcriptStatus = "interrupted"
        Self.writeMetadata(pending.metadata, to: pending.url)
    }

    // MARK: - Internal Helpers

    func handleCaptureInterruption(_ message: String) {
        guard isRecording else { return }
        activeCaptureWarning = message
        statusMessage = "⚠️ \(message)"
    }

    /// Failure bubbles have no buttons, so they dismiss themselves (one-shot, nothing runs while idle).
    private func showFailure(_ message: String) {
        state = .failed(message)
        statusMessage = message
        isCompletionBubbleVisible = true
        failureDismissTask?.cancel()
        failureDismissTask = Task { @MainActor [weak self, failureBubbleDurationNanoseconds] in
            try? await Task.sleep(nanoseconds: failureBubbleDurationNanoseconds)
            guard !Task.isCancelled, let self, case .failed = self.state else { return }
            self.dismissCompletionBubble()
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
    static func exportTranscript(_ txtURL: URL, sessionID: String, to directory: URL) throws -> URL {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var destination = directory.appendingPathComponent("\(sessionID) transcript.txt")
        var suffix = 2
        while FileManager.default.fileExists(atPath: destination.path) {
            destination = directory.appendingPathComponent("\(sessionID) transcript (\(suffix)).txt")
            suffix += 1
        }
        // copyItem never replaces an existing file, so a name taken in the meantime fails instead of overwriting
        try FileManager.default.copyItem(at: txtURL, to: destination)
        restrictToOwner(destination)
        return destination
    }

    /// Meeting files are private (0600), like `FileDropInboxService`. Reapply after every write: atomic writes recreate at 0644.
    nonisolated static func restrictToOwner(_ urls: URL...) {
        for url in urls {
            try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        }
    }

    nonisolated private static func writeMetadata(_ metadata: MeetingRecordingMetadata, to url: URL) {
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
        let names = NSWorkspace.shared.runningApplications.compactMap(\.localizedName)
        return Array(Set(names.filter { knownMeetingAppNames.contains($0) })).sorted()
    }
}
