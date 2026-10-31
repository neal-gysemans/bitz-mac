import SwiftUI

/// Settings tab for configuring Cyber Audio features: master toggle, output volume,
/// individual sound event toggles with preview triggers, and environment suppression rules.
public struct AudioSettingsTabView: View {
    @ObservedObject public var settingsStore: CyberAudioSettingsStore
    public var audioPlayer: (any CyberAudioPlaying)?

    public init(
        settingsStore: CyberAudioSettingsStore,
        audioPlayer: (any CyberAudioPlaying)? = nil
    ) {
        self.settingsStore = settingsStore
        self.audioPlayer = audioPlayer
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            // Master Toggle & Volume Card
            masterAudioCard

            // Per-Event Toggles & Previews
            soundEventsCard

            // Environmental Suppression Card
            suppressionCard
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

                Toggle("Suppress during active microphone or screen sharing", isOn: Binding(
                    get: { settingsStore.isCallSuppressionEnabled },
                    set: { settingsStore.setCallSuppressionEnabled($0) }
                ))
                .font(.subheadline)
                .disabled(!settingsStore.isEnabled)

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
            return "Warm, soothing cat purr loop with rhythmic chest rumble"
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
