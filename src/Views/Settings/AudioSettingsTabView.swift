import SwiftUI
import AppKit

/// Settings tab for configuring Cyber Audio features: master toggle, output volume,
/// individual sound event toggles with preview triggers, environment suppression rules,
/// and the meeting recorder and its on-device transcription (#43).
public struct AudioSettingsTabView: View {
    @ObservedObject public var settingsStore: CyberAudioSettingsStore
    public var audioPlayer: (any CyberAudioPlaying)?
    @ObservedObject public var meetingSettings: MeetingSettingsStore
    @ObservedObject public var meetingRecorder: MeetingRecorderService
    public var licensingService: (any LicensingServiceProtocol)?
    @ObservedObject public var characterStore: AvatarCharacterStore
    @ObservedObject public var whisperModelManager: WhisperKitModelManager
    enum SpeechModelNotice: Equatable {
        case ready
        case downloading
        case needsDownload(title: String)
        case unsupported
    }

    /// Built once in `.onAppear` (probing recognizers is not free), never in `body`.
    @State private var transcriptionLocaleOptions: [(id: String, label: String)] = []
    @State private var speechModelNotice: SpeechModelNotice?
    /// `syncWarning` reads the file system, so it runs when a folder changes, never in `body`.
    @State private var recordingsFolderWarning: String?
    @State private var exportFolderWarning: String?
    @State private var showingProPopover = false

    public init(
        settingsStore: CyberAudioSettingsStore,
        audioPlayer: (any CyberAudioPlaying)? = nil,
        meetingRecorder: MeetingRecorderService,
        licensingService: (any LicensingServiceProtocol)? = nil,
        characterStore: AvatarCharacterStore = AvatarCharacterStore(),
        whisperModelManager: WhisperKitModelManager = WhisperKitModelManager()
    ) {
        self.settingsStore = settingsStore
        self.audioPlayer = audioPlayer
        self.meetingSettings = meetingRecorder.settingsStore
        self.meetingRecorder = meetingRecorder
        self.licensingService = licensingService
        self.characterStore = characterStore
        self.whisperModelManager = whisperModelManager
    }

    private var isMeetingRecorderUnlocked: Bool {
        licensingService?.isFeatureUnlocked(.meetingRecorder) ?? meetingRecorder.isMeetingRecorderUnlocked
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            // Master Toggle & Volume Card
            masterAudioCard

            // Per-Event Toggles & Previews
            soundEventsCard

            // Environmental Suppression Card
            suppressionCard

            // Meeting recorder and its transcription (#43)
            meetingRecorderCard
            transcriptionCard
        }
        .onAppear {
            Task { await meetingRecorder.refreshPermissions() }
            whisperModelManager.refreshAllStatuses()
            updateRecordingsFolderWarning()
            updateExportFolderWarning()
            loadTranscriptionLocaleOptions()
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            loadTranscriptionLocaleOptions()
        }
        .onChange(of: meetingSettings.transcriptionLocaleIdentifier) { loadSpeechModelNotice(autoDownloadIfNeeded: true) }
        .onChange(of: meetingSettings.meetingsRootDirectoryURL) { updateRecordingsFolderWarning() }
        .onChange(of: meetingSettings.transcriptExportDirectoryURL) { updateExportFolderWarning() }
    }

    private func loadTranscriptionLocaleOptions() {
        SpeechFrameworkTranscriptionService.invalidateCachedLocaleOptions()
        let selectedID = meetingSettings.transcriptionLocaleIdentifier
        // Probing ~60 recognizers takes ~0.2 s, so build the list off the main thread
        Task {
            let (options, notice) = await Task.detached(priority: .utility) {
                (
                    SpeechFrameworkTranscriptionService.onDeviceLocaleOptions(),
                    Self.resolveSpeechModelNotice(localeID: selectedID)
                )
            }.value
            transcriptionLocaleOptions = options
            if meetingSettings.transcriptionLocaleIdentifier == selectedID, speechModelNotice != .downloading {
                speechModelNotice = notice
            }
        }
    }

    private func loadSpeechModelNotice(autoDownloadIfNeeded: Bool = false) {
        let selectedID = meetingSettings.transcriptionLocaleIdentifier
        Task {
            let notice = await Task.detached(priority: .utility) {
                Self.resolveSpeechModelNotice(localeID: selectedID)
            }.value
            guard meetingSettings.transcriptionLocaleIdentifier == selectedID else { return }
            if autoDownloadIfNeeded, #available(macOS 26.0, *), case .needsDownload = notice {
                await performModelDownload(for: selectedID)
            } else {
                speechModelNotice = notice
            }
        }
    }

    private func downloadSpeechModel() {
        let selectedID = meetingSettings.transcriptionLocaleIdentifier
        Task {
            await performModelDownload(for: selectedID)
        }
    }

    private func performModelDownload(for selectedID: String?) async {
        speechModelNotice = .downloading
        let targetLocale = Self.targetDownloadLocale(for: selectedID)
        let (options, updatedNotice) = await Task.detached(priority: .utility) {
            await SpeechFrameworkTranscriptionService.ensureOnDeviceAssetInstalled(for: targetLocale)
            return (
                SpeechFrameworkTranscriptionService.onDeviceLocaleOptions(),
                Self.resolveSpeechModelNotice(localeID: selectedID)
            )
        }.value
        transcriptionLocaleOptions = options
        if meetingSettings.transcriptionLocaleIdentifier == selectedID {
            speechModelNotice = updatedNotice
        }
    }

    nonisolated static func targetDownloadLocale(for localeID: String?) -> Locale {
        if let localeID {
            return Locale(identifier: localeID)
        }
        do {
            return try SpeechFrameworkTranscriptionService.resolveOnDeviceLocale(requested: nil)
        } catch let MeetingTranscriptionError.missingOnDeviceAsset(missingLocaleID, _) {
            return Locale(identifier: missingLocaleID)
        } catch {
            return .current
        }
    }

    nonisolated static func resolveSpeechModelNotice(localeID: String?) -> SpeechModelNotice? {
        if let localeID {
            switch SpeechFrameworkTranscriptionService.checkOnDeviceAssetStatus(for: Locale(identifier: localeID)) {
            case .ready:
                return .ready
            case .needsDownload:
                return .needsDownload(title: "On-device speech model is not downloaded in macOS.")
            case .unsupported:
                return .unsupported
            }
        }
        do {
            let resolved = try SpeechFrameworkTranscriptionService.resolveOnDeviceLocale(requested: nil)
            if SpeechFrameworkTranscriptionService.checkOnDeviceAssetStatus(for: resolved) == .needsDownload {
                let langName = Locale.current.localizedString(forIdentifier: resolved.identifier) ?? resolved.identifier
                return .needsDownload(title: "Automatic model (\(langName)) is not downloaded in macOS.")
            }
            return nil
        } catch let MeetingTranscriptionError.missingOnDeviceAsset(_, langName) {
            return .needsDownload(title: "Automatic model (\(langName)) is not downloaded in macOS.")
        } catch {
            return nil
        }
    }

    private func updateRecordingsFolderWarning() {
        recordingsFolderWarning = MeetingSettingsStore.syncWarning(for: meetingSettings.meetingsRootDirectoryURL)
    }

    private func updateExportFolderWarning() {
        exportFolderWarning = meetingSettings.transcriptExportDirectoryURL.flatMap { MeetingSettingsStore.syncWarning(for: $0) }
    }

    // MARK: - Meeting Recorder Card (#43)

    private var meetingRecorderCard: some View {
        settingsCard(title: "Meeting Recorder", systemImage: "waveform.badge.mic") {
            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .center, spacing: 10) {
                    Text("Records your microphone and the meeting's sound into the recordings folder below.")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    Spacer()

                    if !isMeetingRecorderUnlocked {
                        ProBadgeView()
                            .onTapGesture {
                                showingProPopover = true
                            }
                            .popover(isPresented: $showingProPopover, arrowEdge: .bottom) {
                                proMeetingPopover
                            }
                    }

                    Text(meetingStatusBadgeText)
                        .font(.caption.bold())
                        .foregroundStyle(meetingStatusBadgeColor)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(
                            Capsule()
                                .fill(meetingStatusBadgeColor.opacity(0.15))
                        )
                }

                HStack(spacing: 10) {
                    Button {
                        if !isMeetingRecorderUnlocked && !meetingRecorder.isRecording {
                            showingProPopover = true
                            return
                        }
                        Task {
                            await meetingRecorder.toggleRecording()
                        }
                    } label: {
                        Label(
                            meetingRecorder.isRecording ? "Stop Meeting Recording" : "Start Meeting Recording",
                            systemImage: meetingRecorder.isRecording ? "stop.circle.fill" : "record.circle"
                        )
                        .font(.subheadline.bold())
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(meetingRecorder.isRecording ? .red : .accentColor)
                    .disabled(meetingRecorder.busyMenuLabel != nil)

                    if let lastResult = meetingRecorder.lastCompletedResult {
                        Button {
                            meetingRecorder.revealInFinder(lastResult.sessionDirectoryURL)
                        } label: {
                            Label("Reveal Last Recording in Finder", systemImage: "folder.fill")
                                .font(.caption)
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                    }

                    if meetingRecorder.canTranscribeAgain {
                        Button {
                            Task {
                                await meetingRecorder.transcribeAgain()
                            }
                        } label: {
                            Label("Transcribe Last Recording Again", systemImage: "arrow.clockwise")
                                .font(.caption)
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                    }

                    Button {
                        meetingRecorder.revealInFinder(meetingSettings.meetingsRootDirectoryURL)
                    } label: {
                        Label("Open Meetings Folder", systemImage: "folder")
                            .font(.caption)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }

                Text(meetingRecorder.statusMessage)
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Divider()

                Toggle("Microphone", isOn: Binding(
                    get: { meetingSettings.captureMicrophone },
                    set: { meetingSettings.setCaptureMicrophone($0) }
                ))
                .font(.subheadline)
                .disabled(meetingRecorder.isRecording)

                Toggle("Meeting / system audio", isOn: Binding(
                    get: { meetingSettings.captureSystemAudio },
                    set: { meetingSettings.setCaptureSystemAudio($0) }
                ))
                .font(.subheadline)
                .disabled(meetingRecorder.isRecording)

                HStack(spacing: 8) {
                    Image(systemName: meetingRecorder.activeOutputDevice.deviceType.systemImage)
                        .foregroundStyle(.cyan)
                    Text("Output:")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text("\(meetingRecorder.activeOutputDevice.name) (\(meetingRecorder.activeOutputDevice.deviceType.displayName))")
                        .font(.caption.bold())
                    Spacer()
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(
                    RoundedRectangle(cornerRadius: 6)
                        .fill(Color.secondary.opacity(0.1))
                )

                if let notice = meetingRecorder.activeOutputDevice.advisoryRoutingNotice {
                    HStack(alignment: .top, spacing: 6) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                            .imageScale(.small)
                        Text(notice)
                            .font(.caption2)
                            .foregroundStyle(.orange)
                    }
                }

                HStack(spacing: 10) {
                    Text("Recordings folder")
                        .font(.subheadline)

                    Spacer()

                    Button("Choose…") {
                        if let url = chooseFolder(message: "Select the folder where Bitz stores meeting recordings") {
                            meetingSettings.setMeetingsRootDirectoryURL(url)
                        }
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)

                    Button("Use Default") {
                        meetingSettings.setMeetingsRootDirectoryURL(nil)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .disabled(meetingSettings.isUsingDefaultMeetingsDirectory)
                }
                .disabled(meetingRecorder.isRecording)

                caption((meetingSettings.meetingsRootDirectoryURL.path as NSString).abbreviatingWithTildeInPath,
                        enabled: !meetingRecorder.isRecording)

                if let warning = recordingsFolderWarning {
                    Text("Recordings folder: \(warning)")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }

                Picker("Delete older recordings", selection: Binding(
                    get: { meetingSettings.retentionDays },
                    set: { meetingSettings.setRetentionDays($0) }
                )) {
                    Text("Off").tag(Int?.none)
                    ForEach(MeetingSettingsStore.retentionDayOptions, id: \.self) { days in
                        Text("\(days) days").tag(Optional(days))
                    }
                }
                .font(.subheadline)

                // The cutoff is anchored on the newest recording, not on today (MeetingRecorderService retention)
                if let days = meetingSettings.retentionDays {
                    caption("Deletes recordings Bitz made that are more than \(days) days older than your newest one, at launch and after each recording. Your newest recordings stay until you delete them in Finder, so a Mac clock that jumps ahead doesn't remove older recordings until you make a new one.",
                            enabled: true)
                } else {
                    caption("Only recordings Bitz made in the recordings folder are deleted, at launch and after each recording.",
                            enabled: true)
                }

                Picker("Recording shortcut", selection: Binding(
                    get: { meetingSettings.recordingHotkey },
                    set: { meetingSettings.setRecordingHotkey($0) }
                )) {
                    ForEach(MeetingRecordingHotkey.allCases) { hotkey in
                        Text(hotkey.displayString).tag(hotkey)
                    }
                }
                .font(.subheadline)

                Toggle("Start chime", isOn: Binding(
                    get: { settingsStore.isMeetingStartChimeEnabled },
                    set: { settingsStore.setMeetingStartChimeEnabled($0) }
                ))
                .font(.subheadline)

                caption(eventDescription(for: .meetingRecordingStarted), enabled: true)

                Divider()

                HStack(spacing: 12) {
                    permissionPill(label: "Microphone", status: meetingRecorder.permissionState.microphone)
                    permissionPill(label: "System audio", status: meetingRecorder.permissionState.screenAudio)

                    Spacer()

                    Button("Check / Request Permissions") {
                        Task {
                            await meetingRecorder.requestPermissions()
                        }
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }
            }
        }
    }

    // MARK: - Transcription Card (#43)

    private var transcriptionCard: some View {
        settingsCard(title: "Transcription", systemImage: "text.bubble") {
            VStack(alignment: .leading, spacing: 12) {
                Toggle("Transcribe after recording", isOn: Binding(
                    get: { meetingSettings.autoTranscribeOnStop },
                    set: { meetingSettings.setAutoTranscribeOnStop($0) }
                ))
                .font(.subheadline)

                caption("Transcripts are made on this Mac and saved next to the recording.", enabled: true)

                whisperSettingsSection

                Toggle("Copy transcript path to clipboard", isOn: Binding(
                    get: { meetingSettings.copyTranscriptPathToClipboard },
                    set: { meetingSettings.setCopyTranscriptPathToClipboard($0) }
                ))
                .font(.subheadline)

                HStack(spacing: 10) {
                    Toggle("Copy transcripts to a folder", isOn: Binding(
                        get: { meetingSettings.transcriptExportDirectoryURL != nil },
                        set: { isOn in
                            if isOn {
                                chooseExportFolder()
                            } else {
                                meetingSettings.setTranscriptExportDirectoryURL(nil)
                            }
                        }
                    ))
                    .font(.subheadline)

                    Spacer()

                    Button("Choose…") {
                        chooseExportFolder()
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .disabled(meetingSettings.transcriptExportDirectoryURL == nil)
                }

                if let exportURL = meetingSettings.transcriptExportDirectoryURL {
                    caption((exportURL.path as NSString).abbreviatingWithTildeInPath, enabled: true)
                }

                caption("Every transcript is copied, including work meetings — turn this off for recordings that must not leave Bitz's folder.",
                        enabled: true)

                if let warning = exportFolderWarning {
                    Text("Export folder: \(warning)")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
            }
        }
    }

    private var languageOptions: [(id: String, label: String)] {
        Self.languageOptions(selected: meetingSettings.transcriptionLocaleIdentifier, loaded: transcriptionLocaleOptions)
    }

    /// Loaded options, plus the saved language while the list loads (or if it is gone), so the selection is always valid.
    static func languageOptions(selected: String?, loaded: [(id: String, label: String)]) -> [(id: String, label: String)] {
        guard let selected, !loaded.contains(where: { $0.id == selected }) else { return loaded }
        return [(id: selected, label: Locale.current.localizedString(forIdentifier: selected) ?? selected)] + loaded
    }

    private func chooseExportFolder() {
        if let url = chooseFolder(message: "Select a folder that also receives a copy of each meeting transcript") {
            meetingSettings.setTranscriptExportDirectoryURL(url)
        }
    }

    private func missingSpeechModelNotice(title: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                Text(title)
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
            if #available(macOS 26.0, *) {
                caption("Bitz can download this speech model from macOS automatically, or you can enable Dictation for the language in System Settings → Keyboard.", enabled: true)
                HStack(spacing: 8) {
                    Button("Download Model") {
                        downloadSpeechModel()
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)

                    Button("Open macOS Dictation Settings…") {
                        SpeechFrameworkTranscriptionService.openDictationSettings()
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }
            } else {
                caption("Enable Dictation for this language in System Settings → Keyboard to download its on-device speech model.", enabled: true)
                Button("Open macOS Dictation Settings…") {
                    SpeechFrameworkTranscriptionService.openDictationSettings()
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
        }
    }

    /// `.disabled` does not dim plain text, so a caption dims itself along with its row.
    private func caption(_ text: String, enabled: Bool) -> some View {
        Text(text)
            .font(.caption)
            .foregroundStyle(enabled ? .secondary : .tertiary)
    }

    private func chooseFolder(message: String) -> URL? {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = true
        panel.prompt = "Select"
        panel.message = message
        return panel.runModal() == .OK ? panel.url : nil
    }

    private var meetingStatusBadgeText: String {
        if !isMeetingRecorderUnlocked && !meetingRecorder.isRecording {
            return "Bitz Pro"
        }
        if meetingRecorder.isRecording {
            return "Recording"
        }
        return meetingRecorder.busyMenuLabel ?? "Ready"
    }

    private var meetingStatusBadgeColor: Color {
        if !isMeetingRecorderUnlocked && !meetingRecorder.isRecording {
            return .orange
        }
        if meetingRecorder.isRecording {
            return .red
        }
        if meetingRecorder.busyMenuLabel != nil {
            return .orange
        }
        return .green
    }

    private var proMeetingPopover: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                Image(systemName: "crown.fill")
                    .foregroundStyle(.orange)
                Text("Bitz Pro Feature")
                    .font(.headline)
            }
            Text("Dual-track meeting audio recording and 100% on-device Speech transcription require Bitz Pro.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Button {
                showingProPopover = false
                NotificationCenter.default.post(name: .bitzOpenProSettingsTab, object: nil)
            } label: {
                Label("View Bitz Pro Perks", systemImage: "crown.fill")
                    .font(.caption.bold())
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .tint(.orange)
            .controlSize(.small)
        }
        .padding(14)
        .frame(width: 260)
    }

    private func permissionPill(label: String, status: MeetingPermissionState.Status) -> some View {
        let color: Color = {
            switch status {
            case .authorized: return .green
            case .denied: return .red
            case .notDetermined: return .secondary
            }
        }()
        return HStack(spacing: 4) {
            Circle()
                .fill(color)
                .frame(width: 6, height: 6)
            Text("\(label): \(status.displayLabel)")
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - Master Audio & Volume Card

    private var masterAudioCard: some View {
        settingsCard(title: "Cyber Audio Engine", systemImage: "speaker.wave.2.fill") {
            VStack(alignment: .leading, spacing: 14) {
                HStack {
                    Toggle("Enable Cyber Audio", isOn: Binding(
                        get: { settingsStore.isEnabled },
                        set: { settingsStore.setEnabled($0) }
                    ))
                    .font(.headline)

                    Spacer()

                    Text(settingsStore.isEnabled ? "Active" : "Muted")
                        .font(.caption.bold())
                        .foregroundStyle(settingsStore.isEnabled ? .green : .secondary)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(
                            Capsule()
                                .fill(settingsStore.isEnabled ? Color.green.opacity(0.15) : Color.secondary.opacity(0.12))
                        )
                }

                Text("Low-latency 8-bit cybernetic sound effects for mascot wellness transitions and AI coding agent lifecycle alerts. Automatically pauses engine when silent (0.0% idle CPU).")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Text("Turning this off silences every sound except the meeting start chime (Meeting Recorder card).")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Divider()

                // Master Volume Slider
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text("Master Volume:")
                            .font(.subheadline.bold())
                        Spacer()
                        Text(settingsStore.formattedVolumeSummary)
                            .font(.subheadline.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }

                    HStack(spacing: 12) {
                        Image(systemName: "speaker.fill")
                            .font(.caption)
                            .foregroundStyle(.secondary)

                        Slider(
                            value: Binding(
                                get: { settingsStore.volume },
                                set: { settingsStore.setVolume($0) }
                            ),
                            in: 0.0...1.0,
                            step: 0.05
                        )
                        .disabled(!settingsStore.isEnabled)

                        Image(systemName: "speaker.wave.3.fill")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
    }

    // MARK: - Sound Events Card

    private var soundEventsCard: some View {
        settingsCard(title: "Sound Effects & Previews", systemImage: "waveform") {
            VStack(alignment: .leading, spacing: 12) {
                Text("Toggle individual sound cues or preview them using the Test buttons.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                ForEach(Self.soundEffectEvents) { event in
                    HStack(alignment: .center, spacing: 12) {
                        Toggle(isOn: Binding(
                            get: { settingsStore.isEventEnabled(event) },
                            set: { settingsStore.setEventEnabled(event, enabled: $0) }
                        )) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(displayName(for: event))
                                    .font(.subheadline.bold())
                                Text(eventDescription(for: event))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .disabled(!settingsStore.isEnabled)

                        Spacer()

                        Button {
                            if event == .purr {
                                audioPlayer?.playReactionSound(for: characterStore.selectedCharacter)
                            } else {
                                audioPlayer?.play(event, bypassCooldown: true)
                            }
                        } label: {
                            Label("Test", systemImage: "play.fill")
                                .font(.caption)
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .disabled(!settingsStore.isEnabled || !settingsStore.isEventEnabled(event))
                    }

                    if event != Self.soundEffectEvents.last {
                        Divider()
                    }
                }
            }
        }
    }

    // MARK: - Suppression Card

    private var suppressionCard: some View {
        settingsCard(title: "Environmental Suppression", systemImage: "bell.slash.fill") {
            VStack(alignment: .leading, spacing: 12) {
                Text("Bitz automatically respects system volume and mute status. You can also customize additional suppression rules:")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                if let audioService = audioPlayer as? CyberAudioService {
                    AudioSuppressionNotice(audioService: audioService)
                        .font(.caption.bold())
                        .foregroundStyle(.orange)
                }

                Toggle("Mute while any app is using the microphone", isOn: Binding(
                    get: { settingsStore.isCallSuppressionEnabled },
                    set: { settingsStore.setCallSuppressionEnabled($0) }
                ))
                .font(.subheadline)
                .disabled(!settingsStore.isEnabled)

                Text("Covers calls, but also dictation tools, webcam apps and browser tabs that keep the microphone open.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Toggle("Suppress when macOS Focus / Do Not Disturb is active", isOn: Binding(
                    get: { settingsStore.isFocusDNDSuppressionEnabled },
                    set: { settingsStore.setFocusDNDSuppressionEnabled($0) }
                ))
                .font(.subheadline)
                .disabled(!settingsStore.isEnabled)
            }
        }
    }

    /// The start chime has its own row in the Meeting Recorder card, outside the master switch.
    static let soundEffectEvents = CyberSoundEvent.allCases.filter { !$0.ignoresMasterAndFocus }

    private func displayName(for event: CyberSoundEvent) -> String {
        if event == .purr {
            let character = characterStore.selectedCharacter
            return "Companion Reaction: \(character.name) — \(character.reactionSoundDisplayName)"
        }
        return event.displayName
    }

    private func eventDescription(for event: CyberSoundEvent) -> String {
        switch event {
        case .purr:
            let charName = characterStore.selectedCharacter.name
            return "Comfort reaction for \(charName) (plays on petting & at random intervals when supercharged)"
        case .burnout:
            return "8-bit power-down pitch sweep when entering burnout"
        case .overheating:
            return "Rapid stutter alarm glitch when CPU or battery overheats"
        case .agentNeedsApproval:
            return "Crisp two-tone cyber chime when an AI agent requests confirmation"
        case .allAgentsDone:
            return "Ascending 8-bit victory fanfare when all agents finish"
        case .charging:
            return "Calm ascending blip when entering offline/break charging"
        case .meetingRecordingStarted:
            return "Plays even with Cyber Audio off or Focus on, so you know Bitz is listening. Only this switch or a muted Mac silences it."
        case .meetingRecordingSaved:
            return "Fanfare when a meeting recording is saved — plays while the mic is in use; system mute, Focus suppression and Enable Cyber Audio still silence it"
        }
    }

    @ViewBuilder
    private var whisperSettingsSection: some View {
        Picker("Whisper Model", selection: Binding(
            get: { meetingSettings.whisperModelVariant },
            set: { meetingSettings.setWhisperModelVariant($0) }
        )) {
            ForEach(WhisperModelVariant.allCases, id: \.self) { variant in
                Text(variant.displayName).tag(variant)
            }
        }
        .font(.subheadline)
        .disabled(meetingRecorder.hasUnfinalizedRecording || meetingRecorder.isTranscribing)

        whisperModelStatusRow

        Picker("Language", selection: Binding(
            get: { meetingSettings.transcriptionLocaleIdentifier },
            set: { meetingSettings.setTranscriptionLocaleIdentifier($0) }
        )) {
            Text("Automatic (Auto-detect)").tag(String?.none)
            ForEach(Self.whisperLanguageOptions(selected: meetingSettings.transcriptionLocaleIdentifier), id: \.id) { option in
                Text(option.label).tag(Optional(option.id))
            }
        }
        .font(.subheadline)
        .disabled(meetingRecorder.hasUnfinalizedRecording || meetingRecorder.isTranscribing)

        caption(
            "Whisper AI runs 100% on-device via Apple Neural Engine. Dual-track recordings label You (mic) and Participants (system audio) separately.",
            enabled: true
        )
    }

    @ViewBuilder
    private var whisperModelStatusRow: some View {
        let variant = meetingSettings.whisperModelVariant
        let modelState = whisperModelManager.state(for: variant)
        HStack(spacing: 8) {
            switch modelState {
            case .downloaded(let bytes):
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                Text("Ready on this Mac (\(ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file))).")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Delete Cache") {
                    try? whisperModelManager.deleteModel(variant)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(meetingRecorder.isTranscribing)
            case .downloading(let progress):
                ProgressView(value: progress)
                    .frame(width: 90)
                Text("Downloading Whisper AI model (\(Int((progress * 100).rounded()))%)…")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Cancel") {
                    whisperModelManager.cancelDownload(for: variant)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            case .notDownloaded:
                Image(systemName: "arrow.down.circle")
                    .foregroundStyle(.secondary)
                Text("Model not downloaded yet (\(variant.approximateSizeLabel)); downloads automatically on first transcription.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Download") {
                    Task { _ = try? await whisperModelManager.ensureModelDownloaded(variant) }
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            case .failed(let message):
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                Text("Download failed: \(message)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                Spacer()
                Button("Retry") {
                    Task { _ = try? await whisperModelManager.ensureModelDownloaded(variant) }
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
        }
    }

    @ViewBuilder
    private var appleDictationSettingsSection: some View {
        Picker("Language", selection: Binding(
            get: { meetingSettings.transcriptionLocaleIdentifier },
            set: { meetingSettings.setTranscriptionLocaleIdentifier($0) }
        )) {
            Text("Automatic").tag(String?.none)
            ForEach(languageOptions, id: \.id) { option in
                Text(option.label).tag(Optional(option.id))
            }
        }
        .font(.subheadline)
        .disabled(meetingRecorder.hasUnfinalizedRecording || meetingRecorder.isTranscribing || speechModelNotice == .downloading)

        HStack(spacing: 4) {
            Text("Don't see your language?")
                .font(.caption)
                .foregroundStyle(.secondary)
            Button {
                SpeechFrameworkTranscriptionService.openDictationSettings()
            } label: {
                HStack(spacing: 3) {
                    Text("Add in macOS Settings…")
                    Image(systemName: "arrow.up.forward.app")
                        .imageScale(.small)
                }
            }
            .buttonStyle(.link)
            .font(.caption)
        }

        caption("Transcription uses one language per recording. Only languages enabled in System Settings → Keyboard → Dictation appear here; selecting one downloads its on-device model automatically on macOS 26+.", enabled: true)

        switch speechModelNotice {
        case .ready:
            HStack(spacing: 6) {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                Text("On-device speech model is installed on this Mac.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        case .downloading:
            HStack(spacing: 6) {
                ProgressView()
                    .controlSize(.small)
                Text("Downloading on-device speech model from macOS…")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        case .needsDownload(let title):
            missingSpeechModelNotice(title: title)
        case .unsupported:
            HStack(spacing: 6) {
                Image(systemName: "info.circle.fill")
                    .foregroundStyle(.secondary)
                Text("On-device speech recognition is not supported for this locale.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        case nil:
            EmptyView()
        }
    }

    static func whisperLanguageOptions(selected: String?) -> [(id: String, label: String)] {
        let common: [(id: String, label: String)] = [
            ("en", "English"),
            ("nl", "Dutch / Flemish"),
            ("fr", "French"),
            ("de", "German"),
            ("es", "Spanish"),
            ("it", "Italian"),
            ("pt", "Portuguese"),
            ("ja", "Japanese"),
            ("zh", "Chinese"),
            ("ko", "Korean")
        ]
        guard let selected, !common.contains(where: { $0.id == selected }) else {
            return common
        }
        let label = Locale.current.localizedString(forIdentifier: selected) ?? selected
        return [(id: selected, label: label)] + common
    }
}

/// Says why the last sound stayed silent; a leaf view so only this line re-renders (AGENTS.md §2.5).
public struct AudioSuppressionNotice: View {
    @ObservedObject var audioService: CyberAudioService

    public init(audioService: CyberAudioService) {
        self.audioService = audioService
    }

    public var body: some View {
        if let last = audioService.lastEnvironmentSuppression, let cause = last.reason.environmentDescription {
            Label("Last sound skipped at \(last.date.formatted(date: .omitted, time: .shortened)): \(cause)",
                  systemImage: "speaker.slash.fill")
        }
    }
}
