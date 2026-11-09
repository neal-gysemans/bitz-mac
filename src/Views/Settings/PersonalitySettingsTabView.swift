import SwiftUI
import AppKit
#if canImport(FoundationModels)
import FoundationModels
#endif

/// Settings tab for configuring Bitz's opt-in, on-device AI personality commentary (`FR-001`, `FR-007`, `FR-009`, `FR-012`, `C-003`).
public struct PersonalitySettingsTabView: View {
    @ObservedObject public var settingsStore: PersonalitySettingsStore
    public var licensingService: (any LicensingServiceProtocol)?
    @State private var showingProPopover: Bool = false

    private var isPersonalityUnlocked: Bool {
        licensingService?.isFeatureUnlocked(.personality) ?? settingsStore.isPersonalityUnlocked
    }

    public init(
        settingsStore: PersonalitySettingsStore,
        licensingService: (any LicensingServiceProtocol)? = nil
    ) {
        self.settingsStore = settingsStore
        self.licensingService = licensingService
    }

    public var isFoundationModelsAvailable: Bool {
        #if canImport(FoundationModels)
        if #available(macOS 26.0, *) {
            return SystemLanguageModel.default.isAvailable
        } else {
            return false
        }
        #else
        return false
        #endif
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            // Section 1: Master Enable Toggle & Backend Status
            masterToggleCard

            // Section 2: Voice Preset Selection
            presetSelectionCard

            // Section 3: Cadence & Daily Quotas
            cadenceAndQuotasCard

            // Section 4: Watched Git Repositories
            watchedReposCard
        }
    }

    // MARK: - Subcards

    private var masterToggleCard: some View {
        settingsCard(title: "AI Personality Commentary", systemImage: "sparkles") {
            VStack(alignment: .leading, spacing: 12) {
                if !isPersonalityUnlocked {
                    HStack(spacing: 8) {
                        Image(systemName: "lock.fill")
                            .foregroundStyle(.cyan)
                        Text("On-device AI Personality Commentary & warning rephrasing require Bitz Pro.")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                        Spacer()
                        Button {
                            showingProPopover = true
                        } label: {
                            ProBadgeView()
                        }
                        .buttonStyle(.plain)
                        .popover(isPresented: $showingProPopover) {
                            VStack(alignment: .leading, spacing: 8) {
                                HStack {
                                    Image(systemName: "lock.fill")
                                        .foregroundColor(.cyan)
                                    Text(BitzFeature.personality.title)
                                        .font(.headline)
                                }

                                Text(BitzFeature.personality.description)
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                                    .fixedSize(horizontal: false, vertical: true)

                                Divider()

                                HStack {
                                    Spacer()
                                    Button("View Bitz Pro Perks") {
                                        showingProPopover = false
                                        NotificationCenter.default.post(name: .bitzOpenProSettingsTab, object: nil)
                                    }
                                    .buttonStyle(.borderedProminent)
                                    .tint(.cyan)
                                    .controlSize(.small)
                                }
                            }
                            .padding(14)
                            .frame(width: 260)
                        }
                    }
                    .padding(.vertical, 2)

                    Divider()
                }

                Toggle("Enable Personality Commentary", isOn: Binding(
                    get: { settingsStore.isEnabled },
                    set: { enabled in
                        if enabled && !isPersonalityUnlocked {
                            showingProPopover = true
                        } else {
                            settingsStore.setEnabled(enabled)
                        }
                    }
                ))
                .font(.subheadline.bold())

                Text(settingsStore.isEnabled
                    ? "Bitz will periodically share short, context-aware commentary lines while your speech bubble is idle."
                    : "Personality commentary is completely disabled. Bitz only shows standard wellness and telemetry status.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Divider()

                HStack(spacing: 8) {
                    Image(systemName: isFoundationModelsAvailable ? "checkmark.circle.fill" : "bolt.circle.fill")
                        .foregroundStyle(isFoundationModelsAvailable ? .green : .blue)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(isFoundationModelsAvailable
                            ? "Apple Foundation Models: Active (On-Device LLM)"
                            : "Templated Generator: Active (Zero-Latency Fallback)")
                            .font(.caption.bold())
                        Text(isFoundationModelsAvailable
                            ? "Running locally on Apple Silicon NPU/GPU with 0% cloud egress."
                            : "Offline deterministic generator active on macOS 14–25 or when model is unavailable.")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color(nsColor: .controlBackgroundColor))
                .cornerRadius(8)
            }
        }
    }

    private var presetSelectionCard: some View {
        settingsCard(title: "Voice Preset", systemImage: "quote.bubble.fill") {
            VStack(alignment: .leading, spacing: 12) {
                Picker("Preset Tone", selection: Binding(
                    get: { settingsStore.preset },
                    set: { settingsStore.setPreset($0) }
                )) {
                    ForEach(PersonalityPreset.allCases) { preset in
                        Text(preset.displayName).tag(preset)
                    }
                }
                .pickerStyle(.segmented)
                .disabled(!settingsStore.isEnabled)

                VStack(alignment: .leading, spacing: 4) {
                    Text(presetDescription(for: settingsStore.preset))
                        .font(.caption)
                        .foregroundStyle(.primary)

                    Text("Sample: \"\(sampleLine(for: settingsStore.preset))\"")
                        .font(.caption2.italic())
                        .foregroundStyle(.secondary)
                }
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color(nsColor: .controlBackgroundColor).opacity(0.8))
                .cornerRadius(8)
            }
        }
    }

    private var cadenceAndQuotasCard: some View {
        settingsCard(title: "Cadence & Safety Quotas", systemImage: "clock.arrow.circlepath") {
            VStack(alignment: .leading, spacing: 14) {
                // Minimum interval stepper
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Cooldown Interval")
                            .font(.subheadline)
                        Text("Wait at least \(settingsStore.minIntervalMinutes) minutes between comments")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Stepper("\(settingsStore.minIntervalMinutes) min", value: Binding(
                        get: { settingsStore.minIntervalMinutes },
                        set: { settingsStore.setMinIntervalMinutes($0) }
                    ), in: 1...60)
                    .disabled(!settingsStore.isEnabled)
                }

                Divider()

                // Daily cap stepper
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Daily Comment Cap")
                            .font(.subheadline)
                        Text("Maximum \(settingsStore.dailyCap) comments per day")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Stepper("\(settingsStore.dailyCap)", value: Binding(
                        get: { settingsStore.dailyCap },
                        set: { settingsStore.setDailyCap($0) }
                    ), in: 1...100)
                    .disabled(!settingsStore.isEnabled)
                }

                Divider()

                // Daily usage indicator & reset
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Generated Today:")
                            .font(.subheadline)
                        Text("\(settingsStore.commentsGeneratedToday) / \(settingsStore.dailyCap) comments used")
                            .font(.caption2.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("Reset Daily Counter") {
                        settingsStore.resetDailyCounter()
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .disabled(!settingsStore.isEnabled || settingsStore.commentsGeneratedToday == 0)
                }
            }
        }
    }

    private var watchedReposCard: some View {
        settingsCard(title: "Commit Signal (Opt-in)", systemImage: "arrow.triangle.branch") {
            VStack(alignment: .leading, spacing: 8) {
                Text("Bitz can use your local commit velocity to celebrate coding streaks or tease long pauses. Paths are strictly private and never sent anywhere.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                GitReposPickerView(settingsStore: settingsStore)
                    .disabled(!settingsStore.isEnabled)
            }
        }
    }

    // MARK: - Helpers

    private func presetDescription(for preset: PersonalityPreset) -> String {
        switch preset {
        case .snarky:
            return "Sharp, witty hacker feline who teases distractions, continuous coding marathons, and thermal spikes."
        case .supportive:
            return "Caring, encouraging developer companion cheering on clean code, steady progress, and hydration breaks."
        case .cute:
            return "Playful and affectionate desktop kitten offering cozy purrs, headbutts, and gentle nap suggestions."
        }
    }

    private func sampleLine(for preset: PersonalityPreset) -> String {
        switch preset {
        case .snarky:
            return "Still refactoring that one function? It's fine, I didn't want to sleep anyway."
        case .supportive:
            return "Great focus streak! Take a sip of water, you're doing awesome."
        case .cute:
            return "Purr... your code looks so neat! *paws at cursor*"
        }
    }

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
                .stroke(Color(nsColor: .separatorColor).opacity(0.35), lineWidth: 1)
        )
    }
}
