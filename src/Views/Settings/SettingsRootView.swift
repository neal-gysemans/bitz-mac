import SwiftUI
import AppKit

/// Identifies each configurable section within the Bitz Settings window.
public enum SettingsTab: String, CaseIterable, Identifiable {
    case general = "General"
    case behaviors = "Behaviors"
    case agents = "AI Agents"
    case audio = "Audio"
    case telemetry = "Telemetry"
    case advanced = "Advanced"

    public var id: String { rawValue }

    public var icon: String {
        switch self {
        case .general: return "paintbrush.fill"
        case .behaviors: return "pawprint.fill"
        case .agents: return "cpu.fill"
        case .audio: return "speaker.wave.2.fill"
        case .telemetry: return "chart.xyaxis.line"
        case .advanced: return "gearshape.2.fill"
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

    @State private var selectedTab: SettingsTab = .general

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
        audioPlayer: (any CyberAudioPlaying)? = nil
    ) {
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
    }

    public var body: some View {
        VStack(spacing: 0) {
            // Modern macOS Settings Toolbar Header
            tabHeader
            Divider()

            // Active Tab View Content
            ScrollView(.vertical, showsIndicators: true) {
                activeTabContent
                    .padding(20)
            }

            Divider()

            // Bottom Utility Footer Bar
            bottomFooterBar
        }
        .frame(minWidth: 660, minHeight: 560)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    // MARK: - Bottom Utility Footer Bar

    private var bottomFooterBar: some View {
        HStack(spacing: 14) {
            Toggle("Show Mascot on Desktop", isOn: $positionStore.isMascotVisible)
                .font(.subheadline)

            Spacer()

            Button("Close Settings") {
                SettingsWindowManager.shared.closeSettingsWindow()
            }
            .keyboardShortcut("w", modifiers: [.command])

            Button(role: .destructive) {
                NSApplication.shared.terminate(nil)
            } label: {
                Label("Quit Bitz", systemImage: "power")
                    .font(.subheadline.bold())
            }
            .buttonStyle(.borderedProminent)
            .tint(.red)
            .keyboardShortcut("q", modifiers: [.command])

            // Window-scoped shortcut listeners
            Group {
                Button("") { scaleStore.stepDown() }
                    .keyboardShortcut("-", modifiers: [.command])
                Button("") { scaleStore.stepUp() }
                    .keyboardShortcut("=", modifiers: [.command])
                Button("") { opacityStore.stepDown() }
                    .keyboardShortcut("[", modifiers: [.command])
                Button("") { opacityStore.stepUp() }
                    .keyboardShortcut("]", modifiers: [.command])
                Button("") { engine.triggerPetInteraction() }
                    .keyboardShortcut("p", modifiers: [.command])
            }
            .frame(width: 0, height: 0)
            .opacity(0)
            .allowsHitTesting(false)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
        .background(Color(nsColor: .controlBackgroundColor).opacity(0.75))
    }

    // MARK: - Tab Header Bar

    private var tabHeader: some View {
        HStack(spacing: 8) {
            ForEach(SettingsTab.allCases) { tab in
                let isSelected = (selectedTab == tab)
                Button {
                    withAnimation(.spring(response: 0.25, dampingFraction: 0.8)) {
                        selectedTab = tab
                    }
                } label: {
                    VStack(spacing: 4) {
                        Image(systemName: tab.icon)
                            .font(.system(size: 17, weight: isSelected ? .semibold : .regular))
                            .foregroundStyle(isSelected ? Color.accentColor : Color.secondary)

                        Text(tab.rawValue)
                            .font(.system(size: 11, weight: isSelected ? .medium : .regular))
                            .foregroundStyle(isSelected ? Color.primary : Color.secondary)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 8)
                    .padding(.horizontal, 6)
                    .background(
                        RoundedRectangle(cornerRadius: 8)
                            .fill(isSelected ? Color.accentColor.opacity(0.12) : Color.clear)
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 8)
                            .stroke(isSelected ? Color.accentColor.opacity(0.3) : Color.clear, lineWidth: 1)
                    )
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(Color(nsColor: .controlBackgroundColor).opacity(0.5))
    }

    // MARK: - Tab Router

    @ViewBuilder
    private var activeTabContent: some View {
        switch selectedTab {
        case .general:
            GeneralSettingsTabView(
                scaleStore: scaleStore,
                opacityStore: opacityStore,
                positionStore: positionStore,
                displayStore: displayStore,
                engine: engine
            )
        case .behaviors:
            BehaviorSettingsTabView(
                engine: engine,
                activityMonitor: activityMonitor
            )
        case .agents:
            AgentsSettingsTabView(
                agentMonitor: agentMonitor
            )
        case .audio:
            AudioSettingsTabView(
                settingsStore: audioSettings,
                audioPlayer: audioPlayer
            )
        case .telemetry:
            TelemetrySettingsTabView(
                telemetryDashboard: telemetryDashboard,
                telemetrySettings: telemetrySettings
            )
        case .advanced:
            AdvancedSettingsTabView(
                engine: engine,
                activityMonitor: activityMonitor,
                updateStore: updateStore
            )
        }
    }
}
