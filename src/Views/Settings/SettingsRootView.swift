import SwiftUI
import AppKit

/// Identifies each configurable section within the Bitz Settings window.
public enum SettingsTab: String, CaseIterable, Identifiable {
    case general = "General"
    case appearance = "Appearance"
    case behaviors = "Behaviors"
    case agents = "AI Agents"
    case personality = "Personality"
    case audio = "Audio"
    case telemetry = "Telemetry"
    case pro = "Bitz Pro"
    case advanced = "Advanced"

    public var id: String { rawValue }

    public var icon: String {
        switch self {
        case .general: return "slider.horizontal.3"
        case .appearance: return "paintbrush.fill"
        case .behaviors: return "pawprint.fill"
        case .agents: return "cpu.fill"
        case .personality: return "sparkles"
        case .audio: return "speaker.wave.2.fill"
        case .telemetry: return "chart.xyaxis.line"
        case .pro: return "crown.fill"
        case .advanced: return "gearshape.2.fill"
        }
    }

    /// The 6 consolidated top-level primary tabs displayed in the Settings toolbar header (#211).
    public static var primaryTabs: [SettingsTab] {
        [.general, .behaviors, .agents, .audio, .pro, .advanced]
    }

    /// Maps any legacy 9-tab reference onto one of the 6 primary consolidated tabs (#211).
    public var resolvedPrimaryTab: SettingsTab {
        switch self {
        case .general, .appearance, .personality:
            return .general
        case .behaviors, .telemetry:
            return .behaviors
        case .agents:
            return .agents
        case .audio:
            return .audio
        case .pro:
            return .pro
        case .advanced:
            return .advanced
        }
    }

    public var primaryDisplayTitle: String {
        switch resolvedPrimaryTab {
        case .general: return "Companion"
        case .behaviors: return "Focus & Work"
        case .agents: return "AI & Coding"
        case .audio: return "Audio & Meetings"
        case .pro: return "Bitz Pro"
        case .advanced: return "System"
        default: return rawValue
        }
    }
}

/// Root container for the Bitz Settings window, organizing configuration into native macOS tabs with high-fidelity visuals.
public struct SettingsRootView: View {
    @ObservedObject public var engine: WellnessPointEngine
    @ObservedObject public var activityMonitor: ActivityMonitorService
    @ObservedObject public var scaleStore: AvatarScaleStore
    @ObservedObject public var opacityStore: AvatarOpacityStore
    @ObservedObject public var positionStore: AvatarPositionStore
    @ObservedObject public var displayStore: DisplayPreferenceStore
    @ObservedObject public var agentMonitor: AgentMonitorService
    @ObservedObject public var updateStore: AppUpdateStore
    @ObservedObject public var telemetryDashboard: TelemetryDashboardService
    @ObservedObject public var telemetrySettings: TelemetrySettingsStore
    @ObservedObject public var audioSettings: CyberAudioSettingsStore
    public var audioPlayer: (any CyberAudioPlaying)?
    @ObservedObject public var flowShieldSettings: FlowShieldSettingsStore
    @ObservedObject public var flowShieldService: FlowShieldService
    @ObservedObject public var interactionSettings: MascotInteractionSettingsStore
    public var inboxDirectoryURL: URL
    @ObservedObject public var paletteStore: AvatarPaletteStore
    @ObservedObject public var characterStore: AvatarCharacterStore
    @ObservedObject public var personalitySettings: PersonalitySettingsStore
    @ObservedObject public var calendarService: CalendarAgendaService
    @ObservedObject public var githubService: GitHubNotificationService
    @ObservedObject public var licensingService: LicensingService
    @ObservedObject public var meetingRecorder: MeetingRecorderService
    @ObservedObject public var whisperModelManager: WhisperKitModelManager
    @ObservedObject public var workShiftTracker: WorkShiftTrackerService

    @State private var selectedTab: SettingsTab
    @State private var isShowingOnboarding: Bool

    public init(
        engine: WellnessPointEngine,
        activityMonitor: ActivityMonitorService,
        scaleStore: AvatarScaleStore,
        opacityStore: AvatarOpacityStore,
        positionStore: AvatarPositionStore,
        displayStore: DisplayPreferenceStore,
        agentMonitor: AgentMonitorService,
        updateStore: AppUpdateStore,
        telemetryDashboard: TelemetryDashboardService,
        telemetrySettings: TelemetrySettingsStore,
        audioSettings: CyberAudioSettingsStore = CyberAudioSettingsStore(),
        audioPlayer: (any CyberAudioPlaying)? = nil,
        flowShieldSettings: FlowShieldSettingsStore? = nil,
        flowShieldService: FlowShieldService? = nil,
        interactionSettings: MascotInteractionSettingsStore = MascotInteractionSettingsStore(),
        inboxDirectoryURL: URL = FileDropInboxService.defaultInboxDirectory,
        paletteStore: AvatarPaletteStore = AvatarPaletteStore(),
        characterStore: AvatarCharacterStore = AvatarCharacterStore(),
        personalitySettings: PersonalitySettingsStore? = nil,
        licensingService: LicensingService? = nil,
        meetingRecorder: MeetingRecorderService,
        whisperModelManager: WhisperKitModelManager = WhisperKitModelManager(),
        calendarService: CalendarAgendaService? = nil,
        githubService: GitHubNotificationService? = nil,
        workShiftTracker: WorkShiftTrackerService? = nil,
        initialTab: SettingsTab = .general,
        startInOnboarding: Bool = false
    ) {
        self._selectedTab = State(initialValue: initialTab.resolvedPrimaryTab)
        self._isShowingOnboarding = State(initialValue: startInOnboarding)
        self.interactionSettings = interactionSettings
        self.inboxDirectoryURL = inboxDirectoryURL
        self.paletteStore = paletteStore
        self.characterStore = characterStore
        self.personalitySettings = personalitySettings ?? PersonalitySettingsStore()
        self.calendarService = calendarService ?? CalendarAgendaService()
        self.githubService = githubService ?? GitHubNotificationService()
        self.workShiftTracker = workShiftTracker ?? WorkShiftTrackerService()
        self.licensingService = licensingService ?? LicensingService()
        self.meetingRecorder = meetingRecorder
        self.whisperModelManager = whisperModelManager
        self.engine = engine
        self.activityMonitor = activityMonitor
        self.scaleStore = scaleStore
        self.opacityStore = opacityStore
        self.positionStore = positionStore
        self.displayStore = displayStore
        self.agentMonitor = agentMonitor
        self.updateStore = updateStore
        self.telemetryDashboard = telemetryDashboard
        self.telemetrySettings = telemetrySettings
        self.audioSettings = audioSettings
        self.audioPlayer = audioPlayer
        let resolvedFlowShieldSettings = flowShieldSettings ?? FlowShieldSettingsStore()
        self.flowShieldSettings = resolvedFlowShieldSettings
        self.flowShieldService = flowShieldService ?? FlowShieldService(settingsStore: resolvedFlowShieldSettings)
    }

    public var body: some View {
        VStack(spacing: 0) {
            if !isShowingOnboarding {
                // Modern macOS Settings Toolbar Header (Consolidated 6 primary tabs, #211)
                tabHeader
                Divider()
            }

            // Active Tab View Content or First-Launch Companion Onboarding Wizard (#211)
            ScrollView(.vertical, showsIndicators: true) {
                Group {
                    if isShowingOnboarding {
                        CompanionOnboardingView(
                            engine: engine,
                            scaleStore: scaleStore,
                            opacityStore: opacityStore,
                            positionStore: positionStore,
                            characterStore: characterStore,
                            paletteStore: paletteStore,
                            personalitySettings: personalitySettings,
                            agentMonitor: agentMonitor,
                            telemetrySettings: telemetrySettings,
                            audioSettings: audioSettings,
                            workShiftTracker: workShiftTracker,
                            calendarService: calendarService,
                            meetingRecorder: meetingRecorder,
                            licensingService: licensingService,
                            audioPlayer: audioPlayer,
                            onComplete: {
                                withAnimation(.spring(response: 0.25, dampingFraction: 0.8)) {
                                    isShowingOnboarding = false
                                }
                            }
                        )
                    } else {
                        activeTabContent
                    }
                }
                .padding(20)
                .frame(maxWidth: .infinity)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            Divider()

            // Bottom Utility Footer Bar
            bottomFooterBar
        }
        .frame(
            minWidth: SettingsWindowManager.minimumContentSize.width,
            maxWidth: .infinity,
            minHeight: SettingsWindowManager.minimumContentSize.height,
            maxHeight: .infinity
        )
        .background(Color(nsColor: .windowBackgroundColor))
        .onReceive(NotificationCenter.default.publisher(for: .bitzOpenProSettingsTab)) { _ in
            isShowingOnboarding = false
            selectedTab = .pro
        }
    }

    // MARK: - Bottom Utility Footer Bar

    private var bottomFooterBar: some View {
        HStack(spacing: 14) {
            Toggle("Show Mascot on Desktop", isOn: $positionStore.isMascotVisible)
                .font(.subheadline)

            if !isShowingOnboarding {
                Button {
                    withAnimation(.spring(response: 0.25, dampingFraction: 0.8)) {
                        isShowingOnboarding = true
                    }
                } label: {
                    Label("Companion Setup Wizard…", systemImage: "sparkles")
                        .font(.caption.bold())
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }

            Spacer()

            Button("Close Settings") {
                SettingsWindowManager.shared.closeSettingsWindow()
            }
            .keyboardShortcut("w", modifiers: [.command])
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
        .background(Color(nsColor: .controlBackgroundColor).opacity(0.75))
    }

    // MARK: - Tab Header Bar

    private var tabHeader: some View {
        HStack(spacing: 8) {
            ForEach(SettingsTab.primaryTabs) { tab in
                let isSelected = (selectedTab.resolvedPrimaryTab == tab)
                Button {
                    withAnimation(.spring(response: 0.25, dampingFraction: 0.8)) {
                        selectedTab = tab
                    }
                } label: {
                    VStack(spacing: 4) {
                        Image(systemName: tab.icon)
                            .font(.system(size: 16, weight: isSelected ? .semibold : .regular))
                            .foregroundStyle(isSelected ? Color.accentColor : Color.secondary)

                        Text(tab.primaryDisplayTitle)
                            .font(.system(size: 12, weight: isSelected ? .medium : .regular))
                            .lineLimit(1)
                            .minimumScaleFactor(0.85)
                            .foregroundStyle(isSelected ? Color.primary : Color.secondary)
                    }
                    .frame(maxWidth: .infinity)
                    .frame(minHeight: 44)
                    .padding(.vertical, 6)
                    .padding(.horizontal, 6)
                    .background(
                        RoundedRectangle(cornerRadius: 8)
                            .fill(isSelected ? Color.accentColor.opacity(0.12) : Color.clear)
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 8)
                            .stroke(isSelected ? Color.accentColor.opacity(0.3) : Color.clear, lineWidth: 1)
                    )
                    // Clear backgrounds aren't hit-tested; without this only the icon and text of unselected tabs take clicks
                    .contentShape(RoundedRectangle(cornerRadius: 8))
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Color(nsColor: .controlBackgroundColor).opacity(0.5))
    }

    // MARK: - Tab Router

    @ViewBuilder
    private var activeTabContent: some View {
        switch selectedTab.resolvedPrimaryTab {
        case .general, .appearance, .personality:
            VStack(alignment: .leading, spacing: 18) {
                AppearanceSettingsTabView(
                    scaleStore: scaleStore,
                    opacityStore: opacityStore,
                    engine: engine,
                    paletteStore: paletteStore,
                    characterStore: characterStore,
                    licensingService: licensingService,
                    audioPlayer: audioPlayer
                )
                PersonalitySettingsTabView(
                    settingsStore: personalitySettings,
                    licensingService: licensingService
                )
                GeneralSettingsTabView(
                    positionStore: positionStore,
                    displayStore: displayStore,
                    interactionSettings: interactionSettings,
                    inboxDirectoryURL: inboxDirectoryURL,
                    licensingService: licensingService
                )
            }
        case .behaviors, .telemetry:
            VStack(alignment: .leading, spacing: 18) {
                BehaviorSettingsTabView(
                    engine: engine,
                    activityMonitor: activityMonitor,
                    flowShieldSettings: flowShieldSettings,
                    flowShieldService: flowShieldService,
                    calendarService: calendarService,
                    workShiftTracker: workShiftTracker,
                    licensingService: licensingService
                )
                TelemetrySettingsTabView(
                    telemetryDashboard: telemetryDashboard,
                    telemetrySettings: telemetrySettings
                )
            }
        case .agents:
            AgentsSettingsTabView(
                agentMonitor: agentMonitor,
                githubService: githubService,
                licensingService: licensingService
            )
        case .audio:
            AudioSettingsTabView(
                settingsStore: audioSettings,
                audioPlayer: audioPlayer,
                meetingRecorder: meetingRecorder,
                licensingService: licensingService,
                characterStore: characterStore,
                whisperModelManager: whisperModelManager
            )
        case .pro:
            BitzProSettingsTabView(
                licensingService: licensingService,
                audioPlayer: audioPlayer
            )
        case .advanced:
            AdvancedSettingsTabView(
                engine: engine,
                activityMonitor: activityMonitor,
                updateStore: updateStore,
                agentMonitor: agentMonitor,
                meetingRecorder: meetingRecorder,
                licensingService: licensingService
            )
        }
    }
}

public extension Notification.Name {
    static let bitzOpenProSettingsTab = Notification.Name("BitzOpenProSettingsTab")
}

extension View {
    func settingsCard<Content: View>(
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
}
