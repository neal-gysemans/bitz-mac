import SwiftUI
import AppKit

/// Settings tab for managing AI Coding Agent detection, speech bubble popups, and Claude Code hook installation.
public struct AgentsSettingsTabView: View {
    @ObservedObject public var agentMonitor: AgentMonitorService
    public var claudeSettingsURL: URL
    public var licensingService: (any LicensingServiceProtocol)?

    /// Agents whose window picker sits on Custom; needed because a preset value would otherwise snap the picker back.
    @State private var customWindowAgentIDs: Set<String> = []

    /// Picker tag for Custom; stored windows are always > 0 (`AgentSignalSettings.clamped()`).
    static let customWindowTag = 0
    private static let contextWindowAgents = [(id: "claude", name: "Claude Code"), (id: "antigravity", name: "Antigravity")]

    public init(
        agentMonitor: AgentMonitorService,
        claudeSettingsURL: URL = AgentHookInstaller.defaultClaudeSettingsURL,
        licensingService: (any LicensingServiceProtocol)? = nil
    ) {
        self.agentMonitor = agentMonitor
        self.claudeSettingsURL = claudeSettingsURL
        self.licensingService = licensingService
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            // Section 1: Notifications
            settingsCard(title: "Agent Notifications & Alerts", systemImage: "bubble.left.and.bubble.right.fill") {
                VStack(alignment: .leading, spacing: 10) {
                    Toggle("Show Agent Speech Bubbles", isOn: $agentMonitor.popupsEnabled)

                    HStack(spacing: 6) {
                        Image(systemName: "info.circle")
                            .foregroundStyle(.secondary)
                        Text("Displays a floating alert bubble when a background AI agent completes a task or requests human confirmation.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }

            // Section 2: Agent Signals (FR-012); WP02's didSet clamps and persists every change.
            settingsCard(title: "Agent Signals & Warnings", systemImage: "exclamationmark.triangle.fill") {
                VStack(alignment: .leading, spacing: 10) {
                    Toggle("Almost Done Heads-Up", isOn: $agentMonitor.signalSettings.almostDoneEnabled)

                    Toggle("Context Window Warnings", isOn: $agentMonitor.signalSettings.contextWarningEnabled)
                    Stepper("Warn at \(agentMonitor.signalSettings.contextThresholdPercent)% context",
                            value: $agentMonitor.signalSettings.contextThresholdPercent, in: 50...99, step: 5)
                        .disabled(!agentMonitor.signalSettings.contextWarningEnabled)
                        .padding(.leading, 20)

                    Toggle("Tool Loop Warnings (4 identical calls)", isOn: $agentMonitor.signalSettings.loopWarningEnabled)

                    Toggle("Stall Warnings", isOn: $agentMonitor.signalSettings.stallWarningEnabled)
                    Stepper("Stall after \(agentMonitor.signalSettings.stallTimeoutMinutes) min without output",
                            value: $agentMonitor.signalSettings.stallTimeoutMinutes, in: 1...30)
                        .disabled(!agentMonitor.signalSettings.stallWarningEnabled)
                        .padding(.leading, 20)

                    Toggle("Usage Limit Warnings (Claude Code)", isOn: $agentMonitor.signalSettings.rateLimitWarningEnabled)

                    hint("Turning off Agent Speech Bubbles hides bubbles only; the amber visor and context gauge keep working.")

                    Divider()

                    ForEach(Self.contextWindowAgents, id: \.id) { agent in
                        HStack {
                            Picker("\(agent.name) context window", selection: windowPresetBinding(agent.id)) {
                                Text("200k").tag(200_000)
                                Text("1M").tag(1_000_000)
                                Text("Custom").tag(Self.customWindowTag)
                            }
                            .fixedSize()

                            if windowPresetBinding(agent.id).wrappedValue == Self.customWindowTag {
                                TextField("Tokens", value: windowBinding(agent.id), format: .number)
                                    .frame(width: 110)
                                    .accessibilityLabel("\(agent.name) context window in tokens")
                            }
                        }
                    }

                    hint("Bitz can't read the model's window size from session logs. Pick 1M if you use a 1M-context model.")
                }
            }

            // Section 3: Monitored Agents Catalog
            settingsCard(title: "Monitored AI Agents (\(agentMonitor.activeAgents.count) Active)", systemImage: "cpu.fill") {
                VStack(spacing: 8) {
                    if !(licensingService?.isFeatureUnlocked(.multiAgentSwarm) ?? false) {
                        HStack(spacing: 8) {
                            Image(systemName: "info.circle")
                                .foregroundStyle(.secondary)
                            Text("Free tier monitors 1 active agent at a time. Monitoring multiple agents concurrently (Multi-Agent Swarm) requires Bitz Pro.")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                            Spacer()
                            Button {
                                NotificationCenter.default.post(name: .bitzOpenProSettingsTab, object: nil)
                            } label: {
                                ProBadgeView()
                            }
                            .buttonStyle(.plain)
                        }
                        .padding(.vertical, 4)

                        Divider()
                    }

                    ForEach(agentMonitor.catalog) { agent in
                        HStack {
                            Image(systemName: agentIcon(for: agent.displayName))
                                .foregroundStyle(agentColor(for: agent.displayName))
                                .frame(width: 24)

                            VStack(alignment: .leading, spacing: 1) {
                                Text(agent.displayName)
                                    .font(.subheadline.bold())
                                if agentMonitor.activeAgents.contains(agent.id) {
                                    Text("Active • Running")
                                        .font(.caption2)
                                        .foregroundStyle(.green)
                                }
                            }

                            Spacer()

                            Toggle("", isOn: Binding(
                                get: { agent.isEnabled },
                                set: { isEnabled in
                                    agentMonitor.setAgentEnabled(id: agent.id, isEnabled: isEnabled)
                                }
                            ))
                            .labelsHidden()
                        }
                        if agent.id != agentMonitor.catalog.last?.id {
                            Divider()
                        }
                    }
                }
            }

            // Section 4: Claude Code Integration
            settingsCard(title: "Claude Code Hook Integration", systemImage: "terminal.fill") {
                let hookStatus = AgentHookInstaller.claudeHookStatus(at: claudeSettingsURL)
                let isInstalled = hookStatus.all

                VStack(alignment: .leading, spacing: 10) {
                    HStack {
                        Text("Install notification hooks to `~/.claude/settings.json` for real-time task completions and tool-use approval popups.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Spacer()
                        Text(isInstalled ? "Installed" : "Not Installed")
                            .font(.caption.bold())
                            .padding(.horizontal, 8)
                            .padding(.vertical, 3)
                            .background((isInstalled ? Color.green : Color.secondary).opacity(0.15))
                            .foregroundStyle(isInstalled ? Color.green : Color.secondary)
                            .cornerRadius(6)
                    }

                    HStack(spacing: 12) {
                        Button {
                            do {
                                try AgentHookInstaller.updateSettingsFile(at: claudeSettingsURL, AgentHookInstaller.installClaudeHooks)
                                agentMonitor.hookActionMessage = "Claude Code hooks successfully installed!"
                                agentMonitor.isHookActionError = false
                            } catch {
                                agentMonitor.hookActionMessage = "Failed to install hooks: \(error.localizedDescription)"
                                agentMonitor.isHookActionError = true
                            }
                        } label: {
                            Label("Install Hook", systemImage: "arrow.down.doc.fill")
                        }
                        .disabled(isInstalled)

                        Button {
                            do {
                                try AgentHookInstaller.updateSettingsFile(at: claudeSettingsURL, AgentHookInstaller.uninstallClaudeHooks)
                                agentMonitor.hookActionMessage = "Claude Code hooks uninstalled."
                                agentMonitor.isHookActionError = false
                            } catch {
                                agentMonitor.hookActionMessage = "Failed to uninstall: \(error.localizedDescription)"
                                agentMonitor.isHookActionError = true
                            }
                        } label: {
                            Label("Uninstall Hook", systemImage: "trash")
                        }
                        .disabled(!hookStatus.any)
                    }

                    if let msg = agentMonitor.hookActionMessage {
                        HStack(spacing: 6) {
                            Image(systemName: agentMonitor.isHookActionError ? "xmark.circle.fill" : "checkmark.circle.fill")
                                .foregroundStyle(agentMonitor.isHookActionError ? .red : .green)
                            Text(msg)
                                .font(.caption.bold())
                                .foregroundStyle(agentMonitor.isHookActionError ? .red : .green)
                        }
                        .padding(.top, 4)
                    }
                }
            }
        }
    }

    // MARK: - Helpers

    /// Custom window field; ignores `<= 0` so a half-typed value never reaches the store.
    func windowBinding(_ id: String) -> Binding<Int> {
        Binding(get: { agentMonitor.signalSettings.contextWindow(for: id) },
                set: { if $0 > 0 { agentMonitor.signalSettings.contextWindowTokens[id] = $0 } })
    }

    /// Picker selection: the stored window when it is a preset (200k / 1M), else `customWindowTag`.
    func windowPresetBinding(_ id: String) -> Binding<Int> {
        Binding(
            get: {
                let tokens = agentMonitor.signalSettings.contextWindow(for: id)
                let isPreset = tokens == 200_000 || tokens == 1_000_000
                return isPreset && !customWindowAgentIDs.contains(id) ? tokens : Self.customWindowTag
            },
            set: { tag in
                if tag == Self.customWindowTag {
                    customWindowAgentIDs.insert(id)
                } else {
                    customWindowAgentIDs.remove(id)
                    agentMonitor.signalSettings.contextWindowTokens[id] = tag
                }
            }
        )
    }

    private func hint(_ text: String) -> some View {
        HStack(spacing: 6) {
            Image(systemName: "info.circle")
                .foregroundStyle(.secondary)
            Text(text)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private func agentIcon(for name: String) -> String {
        let lower = name.lowercased()
        if lower.contains("claude") { return "sparkle" }
        if lower.contains("gemini") { return "sun.max.fill" }
        if lower.contains("antigravity") { return "airplane.departure" }
        if lower.contains("cursor") { return "cursorarrow.rays" }
        if lower.contains("windsurf") { return "wind" }
        return "terminal"
    }

    private func agentColor(for name: String) -> Color {
        let lower = name.lowercased()
        if lower.contains("claude") { return .purple }
        if lower.contains("gemini") { return .blue }
        if lower.contains("antigravity") { return .cyan }
        if lower.contains("cursor") { return .green }
        if lower.contains("windsurf") { return .teal }
        return .accentColor
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
