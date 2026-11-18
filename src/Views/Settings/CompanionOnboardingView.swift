import SwiftUI
import AppKit

// MARK: - Companion Onboarding Preset Mode (#211)

/// High-level companion setup preset modes offered during first-launch onboarding.
public enum CompanionOnboardingMode: String, CaseIterable, Identifiable, Sendable {
    case aiCodingCopilot = "ai_coding_copilot"
    case focusAndWellness = "focus_and_wellness"
    case meetingAssistant = "meeting_assistant"
    case minimalistPet = "minimalist_pet"

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .aiCodingCopilot:
            return "AI Coding Copilot"
        case .focusAndWellness:
            return "Focus & Wellness Guardian"
        case .meetingAssistant:
            return "Local Meeting Assistant"
        case .minimalistPet:
            return "Minimalist Desktop Pet"
        }
    }

    public var subtitle: String {
        switch self {
        case .aiCodingCopilot:
            return "Alerts you when Claude Code, Cursor, Codex, or Antigravity finish tasks or need approval."
        case .focusAndWellness:
            return "Tracks your daily coding shift goal, burnout streaks, and Apple Silicon thermal health."
        case .meetingAssistant:
            return "Records mic + system audio with 100% private on-device Whisper transcription."
        case .minimalistPet:
            return "Quiet, 100% click-through cyber companion with zero HUD clutter or background popups."
        }
    }

    public var iconName: String {
        switch self {
        case .aiCodingCopilot:
            return "cpu.fill"
        case .focusAndWellness:
            return "bolt.heart.fill"
        case .meetingAssistant:
            return "waveform.badge.mic"
        case .minimalistPet:
            return "pawprint.fill"
        }
    }

    public var accentColor: Color {
        switch self {
        case .aiCodingCopilot:
            return .cyan
        case .focusAndWellness:
            return .green
        case .meetingAssistant:
            return .orange
        case .minimalistPet:
            return .purple
        }
    }

    /// Applies sensible zero-config defaults across Bitz stores when the user completes onboarding.
    @MainActor
    public static func apply(
        selectedModes: Set<CompanionOnboardingMode>,
        agentMonitor: AgentMonitorService,
        telemetrySettings: TelemetrySettingsStore,
        audioSettings: CyberAudioSettingsStore,
        personalitySettings: PersonalitySettingsStore,
        licensingService: (any LicensingServiceProtocol)?
    ) {
        if selectedModes.contains(.minimalistPet) && selectedModes.count == 1 {
            agentMonitor.popupsEnabled = false
            telemetrySettings.displayInMascotCyberHUD = false
            telemetrySettings.displayInSpeechBubbleCycle = false
            telemetrySettings.displayInMenuBarTitle = false
            personalitySettings.setEnabled(false)
            return
        }

        agentMonitor.popupsEnabled = selectedModes.contains(.aiCodingCopilot)
        let focusEnabled = selectedModes.contains(.focusAndWellness)
        telemetrySettings.displayInMascotCyberHUD = focusEnabled
        if focusEnabled && (licensingService?.isFeatureUnlocked(.personality) ?? true) {
            personalitySettings.setEnabled(true)
        } else if !focusEnabled {
            personalitySettings.setEnabled(false)
        }

        if selectedModes.contains(.meetingAssistant) {
            audioSettings.setMeetingStartChimeEnabled(true)
        }
    }
}

// MARK: - CompanionOnboardingView (#211)

/// Interactive 4-step first-launch Companion Setup Wizard presented inside `SettingsRootView`
/// when `startInOnboarding` is true or when the user clicks "Companion Setup Wizard…".
public struct CompanionOnboardingView: View {
    @ObservedObject public var engine: WellnessPointEngine
    @ObservedObject public var scaleStore: AvatarScaleStore
    @ObservedObject public var opacityStore: AvatarOpacityStore
    @ObservedObject public var positionStore: AvatarPositionStore
    @ObservedObject public var characterStore: AvatarCharacterStore
    @ObservedObject public var paletteStore: AvatarPaletteStore
    @ObservedObject public var personalitySettings: PersonalitySettingsStore
    @ObservedObject public var agentMonitor: AgentMonitorService
    @ObservedObject public var telemetrySettings: TelemetrySettingsStore
    @ObservedObject public var audioSettings: CyberAudioSettingsStore
    @ObservedObject public var workShiftTracker: WorkShiftTrackerService
    @ObservedObject public var calendarService: CalendarAgendaService
    @ObservedObject public var meetingRecorder: MeetingRecorderService
    public var licensingService: (any LicensingServiceProtocol)?
    public var audioPlayer: (any CyberAudioPlaying)?
    public var claudeSettingsURL: URL
    public var onComplete: () -> Void

    @ObservedObject private var settingsWindowManager: SettingsWindowManager = .shared
    @State public var currentStep: Int = 0
    @State public var selectedModes: Set<CompanionOnboardingMode> = [.aiCodingCopilot, .focusAndWellness]
    @State private var claudeHookMessage: String? = nil

    public static let totalSteps = 4

    public init(
        engine: WellnessPointEngine,
        scaleStore: AvatarScaleStore,
        opacityStore: AvatarOpacityStore,
        positionStore: AvatarPositionStore,
        characterStore: AvatarCharacterStore,
        paletteStore: AvatarPaletteStore,
        personalitySettings: PersonalitySettingsStore,
        agentMonitor: AgentMonitorService,
        telemetrySettings: TelemetrySettingsStore,
        audioSettings: CyberAudioSettingsStore,
        workShiftTracker: WorkShiftTrackerService,
        calendarService: CalendarAgendaService,
        meetingRecorder: MeetingRecorderService,
        licensingService: (any LicensingServiceProtocol)? = nil,
        audioPlayer: (any CyberAudioPlaying)? = nil,
        claudeSettingsURL: URL = AgentHookInstaller.defaultClaudeSettingsURL,
        onComplete: @escaping () -> Void
    ) {
        self.engine = engine
        self.scaleStore = scaleStore
        self.opacityStore = opacityStore
        self.positionStore = positionStore
        self.characterStore = characterStore
        self.paletteStore = paletteStore
        self.personalitySettings = personalitySettings
        self.agentMonitor = agentMonitor
        self.telemetrySettings = telemetrySettings
        self.audioSettings = audioSettings
        self.workShiftTracker = workShiftTracker
        self.calendarService = calendarService
        self.meetingRecorder = meetingRecorder
        self.licensingService = licensingService
        self.audioPlayer = audioPlayer
        self.claudeSettingsURL = claudeSettingsURL
        self.onComplete = onComplete
    }

    public var body: some View {
        VStack(spacing: 18) {
            headerBanner
            liveCompanionPreview

            Group {
                switch currentStep {
                case 0:
                    step1ChooseCompanion
                case 1:
                    step2ChooseMode
                case 2:
                    step3QuickIntegrations
                default:
                    step4ReadyToLaunch
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            navigationFooter
        }
    }

    // MARK: - Header & Step Dots

    private var headerBanner: some View {
        HStack {
            VStack(alignment: .leading, spacing: 3) {
                Text("Welcome to Bitz — Set Up Your Companion")
                    .font(.title3.bold())
                Text(stepSubtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            HStack(spacing: 6) {
                ForEach(0..<Self.totalSteps, id: \.self) { index in
                    Capsule()
                        .fill(index == currentStep ? Color.accentColor : Color.secondary.opacity(0.25))
                        .frame(width: index == currentStep ? 22 : 8, height: 8)
                }
            }

            Button("Skip Setup") {
                finishOnboarding()
            }
            .buttonStyle(.plain)
            .font(.caption.bold())
            .foregroundStyle(.secondary)
            .padding(.leading, 8)
        }
    }

    private var stepSubtitle: String {
        switch currentStep {
        case 0:
            return "Step 1 of 4 • Choose your companion character, theme palette, and personality voice."
        case 1:
            return "Step 2 of 4 • Pick how you want your companion to assist your daily workflow."
        case 2:
            return "Step 3 of 4 • Optional 1-click integrations for the workflow modes you picked."
        default:
            return "Step 4 of 4 • Master the ⌥ Option gesture & desktop placement."
        }
    }

    // MARK: - Live Mascot Preview

    private var liveCompanionPreview: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 12)
                .fill(Color(nsColor: .controlBackgroundColor))
                .overlay(
                    RoundedRectangle(cornerRadius: 12)
                        .stroke(Color.accentColor.opacity(0.25), lineWidth: 1)
                )

            HStack(spacing: 16) {
                AnimatedBitzCharacterView(
                    state: engine.currentState,
                    showParticles: true,
                    customVisorColor: paletteStore.resolvedPalette.visorColor(for: engine.currentState),
                    isPaused: !settingsWindowManager.isWindowVisible,
                    palette: paletteStore.resolvedPalette,
                    character: characterStore.selectedCharacter
                )
                .scaleEffect(0.50)
                .frame(width: 110, height: 110)

                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 8) {
                        Label(characterStore.selectedCharacter.name, systemImage: characterStore.selectedCharacter.menuBarSymbolName)
                            .font(.headline)
                        Text("• \(characterStore.selectedCharacter.archetype)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    Text(characterStore.selectedCharacter.bio)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)

                    HStack(spacing: 10) {
                        Button {
                            engine.triggerPetInteraction()
                            audioPlayer?.playReactionSound(for: characterStore.selectedCharacter)
                        } label: {
                            Label("Pet \(characterStore.selectedCharacter.name)", systemImage: "heart.fill")
                                .font(.caption.bold())
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)

                        Text("Theme: \(paletteStore.selectedPreset.title)")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer()
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
        }
        .frame(height: 125)
    }

    // MARK: - Step 1: Companion, Theme & Voice

    private var step1ChooseCompanion: some View {
        VStack(alignment: .leading, spacing: 14) {
            settingsCard(title: "1. Pick Your Companion Character", systemImage: "pawprint.fill") {
                LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible()), GridItem(.flexible())], spacing: 10) {
                    ForEach(MascotCharacter.allCases) { character in
                        let isSelected = (characterStore.selectedCharacter == character)
                        let isUnlocked = !character.isPro || (licensingService?.isFeatureUnlocked(.multiMascot) ?? true)
                        Button {
                            if isUnlocked {
                                characterStore.selectCharacter(character)
                                audioPlayer?.playReactionSound(for: character)
                            }
                        } label: {
                            HStack(spacing: 8) {
                                Image(systemName: character.menuBarSymbolName)
                                    .foregroundStyle(isSelected ? Color.accentColor : Color.secondary)
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(isUnlocked ? character.name : "\(character.name) (Pro 🔒)")
                                        .font(.subheadline.bold())
                                    Text(character.archetype)
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                        .lineLimit(1)
                                }
                                Spacer()
                                if isSelected {
                                    Image(systemName: "checkmark.circle.fill")
                                        .foregroundStyle(Color.accentColor)
                                }
                            }
                            .padding(10)
                            .background(
                                RoundedRectangle(cornerRadius: 8)
                                    .fill(isSelected ? Color.accentColor.opacity(0.14) : Color(nsColor: .windowBackgroundColor))
                            )
                            .overlay(
                                RoundedRectangle(cornerRadius: 8)
                                    .stroke(isSelected ? Color.accentColor : Color.secondary.opacity(0.2), lineWidth: 1)
                            )
                        }
                        .buttonStyle(.plain)
                    }
                }
            }

            settingsCard(title: "2. Theme Palette & Personality Tone", systemImage: "paintpalette.fill") {
                let isThemesUnlocked = licensingService?.isFeatureUnlocked(.customThemes) ?? true
                let isPersonalityUnlocked = licensingService?.isFeatureUnlocked(.personality) ?? true
                VStack(alignment: .leading, spacing: 12) {
                    HStack {
                        Text("Color Palette:")
                            .font(.subheadline)
                        Spacer()
                        Picker("Color Palette", selection: Binding(
                            get: { paletteStore.selectedPreset },
                            set: { preset in
                                if !preset.isPro || isThemesUnlocked {
                                    paletteStore.selectPreset(preset)
                                }
                            }
                        )) {
                            ForEach(AvatarThemePreset.allCases) { preset in
                                let label = (preset.isPro && !isThemesUnlocked) ? "\(preset.title) (Pro 🔒)" : preset.title
                                Text(label).tag(preset)
                            }
                        }
                        .labelsHidden()
                        .frame(width: 220)
                    }

                    HStack {
                        Text(isPersonalityUnlocked ? "Personality Voice:" : "Personality Voice (Pro 🔒):")
                            .font(.subheadline)
                        Spacer()
                        Picker("Voice Tone", selection: Binding(
                            get: { personalitySettings.preset },
                            set: {
                                guard isPersonalityUnlocked else { return }
                                personalitySettings.setPreset($0)
                                personalitySettings.setEnabled(true)
                            }
                        )) {
                            ForEach(PersonalityPreset.allCases) { preset in
                                Text(preset.displayName).tag(preset)
                            }
                        }
                        .pickerStyle(.segmented)
                        .disabled(!isPersonalityUnlocked)
                        .frame(width: 260)
                    }
                }
            }
        }
    }

    // MARK: - Step 2: Workflow Mode

    private var step2ChooseMode: some View {
        settingsCard(title: "How Should Bitz Help You? (Select Any)", systemImage: "sparkles") {
            VStack(alignment: .leading, spacing: 10) {
                Text("Bitz will pre-configure notifications, HUD stats, and shortcuts based on what you pick:")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 10) {
                    ForEach(CompanionOnboardingMode.allCases) { mode in
                        let isSelected = selectedModes.contains(mode)
                        Button {
                            toggleMode(mode)
                        } label: {
                            HStack(alignment: .top, spacing: 10) {
                                Image(systemName: mode.iconName)
                                    .font(.title3)
                                    .foregroundStyle(mode.accentColor)
                                    .frame(width: 24)

                                VStack(alignment: .leading, spacing: 3) {
                                    HStack {
                                        Text(mode.title)
                                            .font(.subheadline.bold())
                                        Spacer()
                                        Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                                            .foregroundStyle(isSelected ? mode.accentColor : .secondary)
                                    }
                                    Text(mode.subtitle)
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                        .fixedSize(horizontal: false, vertical: true)
                                }
                            }
                            .padding(12)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(
                                RoundedRectangle(cornerRadius: 10)
                                    .fill(isSelected ? mode.accentColor.opacity(0.1) : Color(nsColor: .windowBackgroundColor))
                            )
                            .overlay(
                                RoundedRectangle(cornerRadius: 10)
                                    .stroke(isSelected ? mode.accentColor : Color.secondary.opacity(0.2), lineWidth: isSelected ? 1.5 : 1)
                            )
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
    }

    private func toggleMode(_ mode: CompanionOnboardingMode) {
        if mode == .minimalistPet {
            selectedModes = [.minimalistPet]
            return
        }
        selectedModes.remove(.minimalistPet)
        if selectedModes.contains(mode) {
            if selectedModes.count > 1 {
                selectedModes.remove(mode)
            }
        } else {
            selectedModes.insert(mode)
        }
    }

    // MARK: - Step 3: Quick Integrations

    private var step3QuickIntegrations: some View {
        VStack(alignment: .leading, spacing: 14) {
            if selectedModes.contains(.aiCodingCopilot) {
                settingsCard(title: "AI Coding Agent Setup", systemImage: "terminal.fill") {
                    let installed = AgentHookInstaller.claudeHookStatus(at: claudeSettingsURL).all
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Claude Code Instant Approval & Completion Hooks")
                                    .font(.subheadline.bold())
                                Text("Antigravity, Cursor, Codex, and Gemini CLI are detected automatically. Click to enable instant Claude Code hooks.")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            Button(installed ? "Hooks Installed ✓" : "Install Claude Hooks") {
                                do {
                                    try AgentHookInstaller.updateSettingsFile(at: claudeSettingsURL, AgentHookInstaller.installClaudeHooks)
                                    claudeHookMessage = "Claude Code hooks installed!"
                                } catch {
                                    claudeHookMessage = "Could not install hooks: \(error.localizedDescription)"
                                }
                            }
                            .buttonStyle(.borderedProminent)
                            .controlSize(.small)
                            .disabled(installed)
                        }
                        if let claudeHookMessage {
                            Text(claudeHookMessage)
                                .font(.caption2.bold())
                                .foregroundStyle(.green)
                        }
                    }
                }
            }

            if selectedModes.contains(.focusAndWellness) {
                settingsCard(title: "Daily Work Shift & Calendar Reminders", systemImage: "clock.arrow.2.circlepath") {
                    VStack(alignment: .leading, spacing: 10) {
                        HStack {
                            Text("Daily Coding Goal:")
                                .font(.subheadline)
                            Spacer()
                            Text(WorkShiftDialogueBank.formatHours(workShiftTracker.workdayGoalHours))
                                .font(.subheadline.monospacedDigit().bold())
                        }
                        Slider(
                            value: $workShiftTracker.workdayGoalHours,
                            in: WorkShiftTrackerService.minGoalHours...WorkShiftTrackerService.maxGoalHours,
                            step: 0.5
                        )

                        HStack {
                            Text("Upcoming Meeting Countdowns (macOS Calendar)")
                                .font(.subheadline)
                            Spacer()
                            Button(calendarService.authorizationStatus.isAuthorized ? "Calendar Connected ✓" : "Connect Calendar") {
                                Task {
                                    let granted = await calendarService.requestAuthorization()
                                    if granted {
                                        calendarService.settingsStore.setEnabled(true)
                                        await calendarService.refreshEvents()
                                    }
                                }
                            }
                            .controlSize(.small)
                            .disabled(calendarService.authorizationStatus.isAuthorized)
                        }
                    }
                }
            }

            if selectedModes.contains(.meetingAssistant) {
                settingsCard(title: "Local Meeting Recorder Permissions", systemImage: "waveform.badge.mic") {
                    HStack {
                        Text("Grant Microphone & System Audio access to record meetings locally with \(meetingRecorder.settingsStore.recordingHotkey.displayString).")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Spacer()
                        Button("Grant Audio Permissions") {
                            Task {
                                await meetingRecorder.requestPermissions()
                            }
                        }
                        .controlSize(.small)
                    }
                }
            }

            if selectedModes == [.minimalistPet] {
                settingsCard(title: "Minimalist Mode Ready", systemImage: "checkmark.seal.fill") {
                    Text("No special permissions needed! Bitz will sit quietly on your desktop with zero popups or HUD bars.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    // MARK: - Step 4: Placement & Gesture Tip

    private var step4ReadyToLaunch: some View {
        settingsCard(title: "You're All Set! How to Interact with Bitz", systemImage: "hand.tap.fill") {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 10) {
                    Image(systemName: "cursorarrow.click.badge.clock")
                        .font(.title2)
                        .foregroundStyle(Color.accentColor)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("100% Click-Through by Default")
                            .font(.subheadline.bold())
                        Text("Bitz never blocks your IDE, browser, or terminal clicks. Hold ⌥ Option anytime to drag Bitz or sweep your cursor across him to pet him.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                Divider()

                HStack {
                    Text("Screen Corner Anchor:")
                        .font(.subheadline)
                    Spacer()
                    Picker("Corner Anchor", selection: Binding(
                        get: { positionStore.cornerAnchor },
                        set: { positionStore.selectCorner($0) }
                    )) {
                        ForEach(ScreenCornerAnchor.allCases, id: \.rawValue) { corner in
                            Text(corner.menuTitle).tag(corner)
                        }
                    }
                    .labelsHidden()
                    .frame(width: 220)
                }

                HStack {
                    Text("Companion Size:")
                        .font(.subheadline)
                    Spacer()
                    Picker("Size Preset", selection: Binding<AvatarSizePreset?>(
                        get: { AvatarSizePreset.allCases.first(where: { scaleStore.isPresetSelected($0) }) },
                        set: { if let preset = $0 { scaleStore.selectPreset(preset) } }
                    )) {
                        ForEach(AvatarSizePreset.allCases, id: \.rawValue) { preset in
                            Text(preset.percentageText).tag(Optional(preset))
                        }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .frame(width: 260)
                }
            }
        }
    }

    // MARK: - Navigation Footer

    private var navigationFooter: some View {
        HStack {
            if currentStep > 0 {
                Button("Back") {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        currentStep -= 1
                    }
                }
            }

            Spacer()

            if currentStep < Self.totalSteps - 1 {
                Button("Continue →") {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        currentStep += 1
                    }
                }
                .buttonStyle(.borderedProminent)
            } else {
                Button("Finish & Start Using Bitz") {
                    finishOnboarding()
                }
                .buttonStyle(.borderedProminent)
                .tint(.cyan)
            }
        }
        .padding(.top, 4)
    }

    public func finishOnboarding() {
        CompanionOnboardingMode.apply(
            selectedModes: selectedModes,
            agentMonitor: agentMonitor,
            telemetrySettings: telemetrySettings,
            audioSettings: audioSettings,
            personalitySettings: personalitySettings,
            licensingService: licensingService
        )
        onComplete()
    }
}
