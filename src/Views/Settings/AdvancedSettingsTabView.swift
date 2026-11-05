import SwiftUI
import AppKit
import ServiceManagement

/// Settings tab for diagnostic state simulations, keyboard shortcut cheatsheet, update settings, and system lifecycle.
public struct AdvancedSettingsTabView: View {
    @ObservedObject public var engine: WellnessPointEngine
    @ObservedObject public var activityMonitor: ActivityMonitorService
    @ObservedObject public var updateStore: AppUpdateStore
    public var agentMonitor: AgentMonitorService?

    @State private var launchAtLoginEnabled: Bool = (SMAppService.mainApp.status == .enabled)
    @State private var launchAtLoginMessage: String? = Self.launchAtLoginApprovalMessage(for: SMAppService.mainApp.status)

    public init(
        engine: WellnessPointEngine,
        activityMonitor: ActivityMonitorService,
        updateStore: AppUpdateStore,
        agentMonitor: AgentMonitorService? = nil
    ) {
        self.engine = engine
        self.activityMonitor = activityMonitor
        self.updateStore = updateStore
        self.agentMonitor = agentMonitor
    }

    /// Shown on open too, since macOS can already be waiting for approval before the toggle is touched.
    static func launchAtLoginApprovalMessage(for status: SMAppService.Status) -> String? {
        status == .requiresApproval ? "Approval required in System Settings → General → Login Items." : nil
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            // Section 1: Behavior State Simulation
            settingsCard(title: "Behavior State Simulation", systemImage: "sparkles") {
                VStack(alignment: .leading, spacing: 12) {
                    Text("Trigger manual emotional states to preview animations, colors, and HUD behaviors.")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    if activityMonitor.isManualOverrideActive {
                        HStack {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .foregroundStyle(.orange)
                            Text("Manual simulation override is currently active.")
                                .font(.caption.bold())
                            Spacer()
                            Button("Resume Live Sensors") {
                                activityMonitor.clearManualOverride()
                            }
                            .buttonStyle(.borderedProminent)
                            .controlSize(.small)
                        }
                        .padding(10)
                        .background(Color.orange.opacity(0.12))
                        .cornerRadius(8)
                    }

                    // 3-Column Simulation Grid
                    LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible()), GridItem(.flexible())], spacing: 10) {
                        simulationButton(
                            title: "Super Charged",
                            detail: "90 PTS",
                            icon: "bolt.fill",
                            color: .cyan
                        ) {
                            activityMonitor.startSimulation(points: 90.0, continuousWorkMinutes: 10.0)
                        }

                        simulationButton(
                            title: "Balanced",
                            detail: "50 PTS",
                            icon: "circle.circle.fill",
                            color: .blue
                        ) {
                            activityMonitor.startSimulation(points: 50.0, continuousWorkMinutes: 0.0)
                        }

                        simulationButton(
                            title: "Dopamine Sad",
                            detail: "20 PTS",
                            icon: "moon.fill",
                            color: .purple
                        ) {
                            activityMonitor.startSimulation(points: 20.0, continuousWorkMinutes: 0.0)
                        }

                        simulationButton(
                            title: "Overworked",
                            detail: "50m streak",
                            icon: "flame.fill",
                            color: .orange
                        ) {
                            activityMonitor.startSimulation(points: 75.0, continuousWorkMinutes: 50.0)
                        }

                        simulationButton(
                            title: "Burnout",
                            detail: "95m streak",
                            icon: "exclamationmark.octagon.fill",
                            color: .red
                        ) {
                            activityMonitor.startSimulation(points: 75.0, continuousWorkMinutes: 95.0)
                        }

                        simulationButton(
                            title: "Charging Mode",
                            detail: "Break recovery",
                            icon: "battery.100.bolt",
                            color: .green
                        ) {
                            activityMonitor.startChargingSimulation()
                        }
                    }

                    if let agentMonitor {
                        Divider()

                        VStack(alignment: .leading, spacing: 8) {
                            Text("Simulate Live Agent Alerts & Audio:")
                                .font(.caption.bold())
                                .foregroundStyle(.secondary)

                            HStack(spacing: 10) {
                                Button {
                                    agentMonitor.handleEvent(AgentEvent(
                                        agentID: "antigravity",
                                        agentName: "Antigravity",
                                        kind: .needsApproval,
                                        message: "Antigravity has a question for you!",
                                        timestamp: Date()
                                    ))
                                } label: {
                                    Label("Question / Chime", systemImage: "questionmark.bubble.fill")
                                }
                                .buttonStyle(.bordered)
                                .controlSize(.small)

                                Button {
                                    agentMonitor.handleEvent(AgentEvent(
                                        agentID: "antigravity",
                                        agentName: "Antigravity",
                                        kind: .done,
                                        message: "Antigravity finished all tasks!",
                                        timestamp: Date()
                                    ))
                                } label: {
                                    Label("All Done / Fanfare", systemImage: "checkmark.seal.fill")
                                }
                                .buttonStyle(.bordered)
                                .controlSize(.small)
                            }
                        }
                    }
                }
            }

            // Section 2: Keyboard Shortcuts Reference
            settingsCard(title: "Keyboard Shortcuts", systemImage: "keyboard") {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Global (Works from Any App)")
                        .font(.caption.bold())
                        .foregroundStyle(.secondary)
                    shortcutRow(action: "Toggle / Open Settings", keys: ["⌥⌘B"])
                    Divider()
                    shortcutRow(action: "Start / stop meeting recording", keys: ["⌥ ⇧ R"])
                    Divider()
                    shortcutRow(action: "Move mascot anywhere (drag)", keys: ["⌥ Option", "Drag"])
                    Divider()
                    shortcutRow(action: "Lock position when dragging", keys: ["⎋ Esc", "⏎ Return"])

                    Divider()
                        .padding(.vertical, 2)

                    Text("When Bitz or Settings is Focused")
                        .font(.caption.bold())
                        .foregroundStyle(.secondary)
                    shortcutRow(action: "Open Settings", keys: ["⌘ ,"])
                    Divider()
                    shortcutRow(action: "Pet Bitz mascot", keys: ["⌘ P", "or", "P"])
                    Divider()
                    shortcutRow(action: "Scale mascot smaller / larger", keys: ["⌘ -", "⌘ ="])
                    Divider()
                    shortcutRow(action: "Decrease / increase opacity", keys: ["⌘ [", "⌘ ]"])
                    Divider()
                    shortcutRow(action: "Quit Bitz", keys: ["⌘ Q"])
                }
            }

            // Section 3: System & Updates
            settingsCard(title: "System & Software Updates", systemImage: "gear") {
                VStack(alignment: .leading, spacing: 12) {
                    HStack {
                        Toggle("Launch Bitz automatically at Login", isOn: Binding(
                            get: { launchAtLoginEnabled },
                            set: { shouldEnable in
                                do {
                                    if shouldEnable {
                                        try SMAppService.mainApp.register()
                                    } else {
                                        try SMAppService.mainApp.unregister()
                                    }
                                    let status = SMAppService.mainApp.status
                                    launchAtLoginEnabled = (status == .enabled)
                                    launchAtLoginMessage = Self.launchAtLoginApprovalMessage(for: status)
                                } catch {
                                    launchAtLoginEnabled = (SMAppService.mainApp.status == .enabled)
                                    launchAtLoginMessage = "Could not update Login Item: \(error.localizedDescription)"
                                }
                            }
                        ))
                        Spacer()
                        Button("Open Login Items...") {
                            SMAppService.openSystemSettingsLoginItems()
                        }
                        .controlSize(.small)
                    }

                    if let launchAtLoginMessage {
                        Text(launchAtLoginMessage)
                            .font(.caption)
                            .foregroundStyle(.orange)
                    }

                    Toggle("Automatically check for updates on startup", isOn: $updateStore.automaticallyCheckForUpdates)

                    HStack {
                        Button {
                            Task {
                                await updateStore.checkForUpdates(manual: true)
                            }
                        } label: {
                            Label("Check for Updates Now...", systemImage: "arrow.clockwise")
                        }

                        if updateStore.isUpdateAvailable, let release = updateStore.latestRelease {
                            Button("Download v\(release.semanticVersion.description)") {
                                updateStore.openDownloadPage()
                            }
                            .buttonStyle(.borderedProminent)
                        }
                    }

                    Text(updateStore.statusMessage)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            // Section 4: Application Lifecycle & Exit
            settingsCard(title: "Application Lifecycle", systemImage: "power") {
                VStack(alignment: .leading, spacing: 10) {
                    Text("Completely exit Bitz, remove the mascot overlay from all displays, and stop background activity monitoring.")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    Button(role: .destructive) {
                        NSApplication.shared.terminate(nil)
                    } label: {
                        Label("Quit Bitz Completely", systemImage: "power")
                            .font(.subheadline.bold())
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.red)
                }
            }
        }
    }

    // MARK: - Helper Views

    private func simulationButton(
        title: String,
        detail: String,
        icon: String,
        color: Color,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: icon)
                    .font(.system(size: 14))
                    .foregroundStyle(color)

                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.system(size: 12, weight: .medium))
                    Text(detail)
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .background(Color(nsColor: .controlBackgroundColor))
            .cornerRadius(8)
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .stroke(color.opacity(0.3), lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
    }

    private func shortcutRow(action: String, keys: [String]) -> some View {
        HStack {
            Text(action)
                .font(.subheadline)
            Spacer()
            HStack(spacing: 4) {
                ForEach(keys, id: \.self) { key in
                    Text(key)
                        .font(.system(.caption, design: .monospaced).bold())
                        .padding(.horizontal, 6)
                        .padding(.vertical, 3)
                        .background(Color(nsColor: .windowBackgroundColor))
                        .cornerRadius(5)
                        .overlay(
                            RoundedRectangle(cornerRadius: 5)
                                .stroke(Color.secondary.opacity(0.3), lineWidth: 1)
                        )
                        .shadow(color: .black.opacity(0.08), radius: 1, x: 0, y: 1)
                }
            }
        }
        .padding(.vertical, 2)
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
                .stroke(Color.secondary.opacity(0.15), lineWidth: 1)
        )
    }
}
