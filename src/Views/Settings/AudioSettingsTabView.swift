import SwiftUI

/// Settings tab for configuring Cyber Audio features: master toggle, output volume,
/// individual sound event toggles with preview triggers, environment suppression rules,
/// and the Local Meeting Audio Recorder & On-Device Transcription pipeline (#43).
public struct AudioSettingsTabView: View {
    @ObservedObject public var settingsStore: CyberAudioSettingsStore
    public var audioPlayer: (any CyberAudioPlaying)?
    @ObservedObject public var meetingSettings: MeetingSettingsStore
    @ObservedObject public var meetingRecorder: MeetingRecorderService
    /// Built once in `.onAppear` (probing recognizers is not free), never in `body`.
    @State private var transcriptionLocaleOptions: [(id: String, label: String)] = []

    public init(
        settingsStore: CyberAudioSettingsStore,
        audioPlayer: (any CyberAudioPlaying)? = nil,
        meetingSettings: MeetingSettingsStore? = nil,
        meetingRecorder: MeetingRecorderService? = nil
    ) {
        self.settingsStore = settingsStore
        self.audioPlayer = audioPlayer
        let resolvedMeetingSettings = meetingSettings ?? meetingRecorder?.settingsStore ?? MeetingSettingsStore()
        self.meetingSettings = resolvedMeetingSettings
        self.meetingRecorder = meetingRecorder ?? MeetingRecorderService(settingsStore: resolvedMeetingSettings)
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            // Local Meeting Audio Recorder & On-Device Transcription (#43)
            meetingAssistantCard

            // Master Toggle & Volume Card
            masterAudioCard

            // Per-Event Toggles & Previews
            soundEventsCard

            // Environmental Suppression Card
            suppressionCard
        }
    }

    // MARK: - Local Meeting Audio Recorder & On-Device Transcription Card (#43)

    private var meetingAssistantCard: some View {
        settingsCard(title: "Meeting Audio Recorder & On-Device Transcription", systemImage: "waveform.badge.mic") {
            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .center, spacing: 10) {
                    Text("Capture microphone and system meeting audio (Zoom, Meet, Teams, Slack) into the recordings folder below, transcribed on-device with Apple `SFSpeechRecognizer`.")
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
                    .disabled(meetingRecorder.isTranscribing)

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

                Text((meetingSettings.meetingsRootDirectoryURL.path as NSString).abbreviatingWithTildeInPath)
                    .font(.caption)
                    .foregroundStyle(.secondary)

                if let warning = MeetingSettingsStore.syncWarning(for: meetingSettings.meetingsRootDirectoryURL) {
                    Text("Recordings folder: \(warning)")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }

                Text(meetingRecorder.statusMessage)
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Divider()

                Toggle("Record Microphone Input (AVAudioEngine)", isOn: Binding(
                    get: { meetingSettings.captureMicrophone },
                    set: { meetingSettings.setCaptureMicrophone($0) }
                ))
                .font(.subheadline)
                .disabled(meetingRecorder.isRecording)

                Toggle("Record System / Meeting Output Audio (ScreenCaptureKit)", isOn: Binding(
                    get: { meetingSettings.captureSystemAudio },
                    set: { meetingSettings.setCaptureSystemAudio($0) }
                ))
                .font(.subheadline)
                .disabled(meetingRecorder.isRecording)

                Toggle("Generate On-Device Transcript (`transcript.txt` & `transcript.json`)", isOn: Binding(
                    get: { meetingSettings.autoTranscribeOnStop },
                    set: { meetingSettings.setAutoTranscribeOnStop($0) }
                ))
                .font(.subheadline)

                Toggle("Copy Transcript File Path to Clipboard on Completion", isOn: Binding(
                    get: { meetingSettings.copyTranscriptPathToClipboard },
                    set: { meetingSettings.setCopyTranscriptPathToClipboard($0) }
                ))
                .font(.subheadline)
                .disabled(!meetingSettings.autoTranscribeOnStop)

                Picker("Transcription Language", selection: Binding(
                    get: { meetingSettings.transcriptionLocaleIdentifier },
                    set: { meetingSettings.setTranscriptionLocaleIdentifier($0) }
                )) {
                    Text("Automatic").tag(String?.none)
                    ForEach(transcriptionLocaleOptions, id: \.id) { option in
                        Text(option.label).tag(Optional(option.id))
                    }
                }
                .font(.subheadline)
                .disabled(!meetingSettings.autoTranscribeOnStop)

                Picker("Recording shortcut", selection: Binding(
                    get: { meetingSettings.recordingHotkey },
                    set: { meetingSettings.setRecordingHotkey($0) }
                )) {
                    ForEach(MeetingRecordingHotkey.allCases) { hotkey in
                        Text(hotkey.displayString).tag(hotkey)
                    }
                }
                .font(.subheadline)

                Text("Transcription uses one language per recording, so pick the meeting's language.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                HStack(spacing: 10) {
                    Text("Copy transcripts to folder")
                        .font(.subheadline)

                    Spacer()

                    Button("Choose…") {
                        if let url = chooseFolder(message: "Select a folder that also receives a copy of each meeting transcript") {
                            meetingSettings.setTranscriptExportDirectoryURL(url)
                        }
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)

                    Button("Turn Off") {
                        meetingSettings.setTranscriptExportDirectoryURL(nil)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .disabled(meetingSettings.transcriptExportDirectoryURL == nil)
                }
                .disabled(!meetingSettings.autoTranscribeOnStop)

                Text(meetingSettings.transcriptExportDirectoryURL.map { ($0.path as NSString).abbreviatingWithTildeInPath } ?? "Off")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Text("Every transcript is copied, including work meetings — turn this off for recordings that must not leave Bitz's folder.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                if let exportURL = meetingSettings.transcriptExportDirectoryURL,
                   let warning = MeetingSettingsStore.syncWarning(for: exportURL) {
                    Text("Export folder: \(warning)")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }

                Divider()

                HStack(spacing: 12) {
                    permissionPill(label: "Mic", status: meetingRecorder.permissionState.microphone)
                    permissionPill(label: "System Audio", status: meetingRecorder.permissionState.screenAudio)
                    permissionPill(label: "On-Device Speech", status: meetingRecorder.permissionState.speechRecognition)

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
        .onAppear {
            meetingRecorder.refreshPermissions()
            // Probing ~60 recognizers takes ~0.2 s, so build the list off the main thread
            Task {
                transcriptionLocaleOptions = await Task.detached(priority: .utility) {
                    SpeechFrameworkTranscriptionService.onDeviceLocaleOptions()
                }.value
            }
        }
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
        if meetingRecorder.isTranscribing {
            return "Transcribing"
        }
        let hotkey = meetingSettings.recordingHotkey
        return hotkey == .off ? "Ready" : "Ready (\(hotkey.displayString))"
    }

    private var meetingStatusBadgeColor: Color {
        if meetingRecorder.isRecording {
            return .red
        }
        if meetingRecorder.isTranscribing {
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

                ForEach(CyberSoundEvent.allCases) { event in
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

                    if event != CyberSoundEvent.allCases.last {
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
