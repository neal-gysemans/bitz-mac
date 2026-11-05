import SwiftUI

/// Settings tab for configuring Cyber Audio features: master toggle, output volume,
/// individual sound event toggles with preview triggers, environment suppression rules,
/// and the meeting recorder and its on-device transcription (#43).
public struct AudioSettingsTabView: View {
    @ObservedObject public var settingsStore: CyberAudioSettingsStore
    public var audioPlayer: (any CyberAudioPlaying)?
    @ObservedObject public var meetingSettings: MeetingSettingsStore
    @ObservedObject public var meetingRecorder: MeetingRecorderService
    /// Built once in `.onAppear` (probing recognizers is not free), never in `body`.
    @State private var transcriptionLocaleOptions: [(id: String, label: String)] = []
    /// `syncWarning` reads the file system, so it runs when a folder changes, never in `body`.
    @State private var recordingsFolderWarning: String?
    @State private var exportFolderWarning: String?

    public init(
        settingsStore: CyberAudioSettingsStore,
        audioPlayer: (any CyberAudioPlaying)? = nil,
        meetingRecorder: MeetingRecorderService
    ) {
        self.settingsStore = settingsStore
        self.audioPlayer = audioPlayer
        self.meetingSettings = meetingRecorder.settingsStore
        self.meetingRecorder = meetingRecorder
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
            meetingRecorder.refreshPermissions()
            updateRecordingsFolderWarning()
            updateExportFolderWarning()
            // Probing ~60 recognizers takes ~0.2 s, so build the list off the main thread
            Task {
                transcriptionLocaleOptions = await Task.detached(priority: .utility) {
                    SpeechFrameworkTranscriptionService.onDeviceLocaleOptions()
                }.value
            }
        }
        .onChange(of: meetingSettings.meetingsRootDirectoryURL) { updateRecordingsFolderWarning() }
        .onChange(of: meetingSettings.transcriptExportDirectoryURL) { updateExportFolderWarning() }
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

                Picker("Delete recordings after", selection: Binding(
                    get: { meetingSettings.retentionDays },
                    set: { meetingSettings.setRetentionDays($0) }
                )) {
                    Text("Off").tag(Int?.none)
                    ForEach(MeetingSettingsStore.retentionDayOptions, id: \.self) { days in
                        Text("\(days) days").tag(Optional(days))
                    }
                }
                .font(.subheadline)

                caption("Only recordings Bitz made in the recordings folder are deleted, at launch and after each recording.",
                        enabled: true)

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
                    permissionPill(label: "Speech recognition", status: meetingRecorder.permissionState.speechRecognition)

                    Spacer()

                    Button("Check / Request Permissions") {
                        Task {
                            await meetingRecorder.requestPermissions(includeSpeech: true)
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

                caption("Transcription uses one language per recording, so pick the meeting's language.", enabled: true)

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
        if meetingRecorder.isRecording {
            return "Recording"
        }
        return meetingRecorder.busyMenuLabel ?? "Ready"
    }

    private var meetingStatusBadgeColor: Color {
        if meetingRecorder.isRecording {
            return .red
        }
        if meetingRecorder.busyMenuLabel != nil {
            return .orange
        }
        return .green
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
                                Text(event.displayName)
                                    .font(.subheadline.bold())
                                Text(eventDescription(for: event))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .disabled(!settingsStore.isEnabled)

                        Spacer()

                        Button {
                            audioPlayer?.play(event, bypassCooldown: true)
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

    // MARK: - Reusable Settings Card Container

    private func settingsCard<Content: View>(
        title: String,
        systemImage: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Label(title, systemImage: systemImage)
                .font(.headline)
                .foregroundStyle(.primary)

            content()
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(Color(nsColor: .controlBackgroundColor))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(Color.secondary.opacity(0.15), lineWidth: 1)
        )
    }

    /// The start chime has its own row in the Meeting Recorder card, outside the master switch.
    static let soundEffectEvents = CyberSoundEvent.allCases.filter { !$0.ignoresMasterAndFocus }

    private func eventDescription(for event: CyberSoundEvent) -> String {
        switch event {
        case .purr:
            return "Warm, soothing cat purr (plays on petting & at random intervals when supercharged)"
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
