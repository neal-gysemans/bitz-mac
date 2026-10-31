import SwiftUI
import AppKit

/// Settings tab for managing AI Coding Agent detection, speech bubble popups, and Claude Code hook installation.
public struct AgentsSettingsTabView: View {
    @ObservedObject public var agentMonitor: AgentMonitorService

    @State private var hookActionMessage: String? = nil
    @State private var isHookActionError: Bool = false

    public init(agentMonitor: AgentMonitorService) {
        self.agentMonitor = agentMonitor
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

            // Section 2: Monitored Agents Catalog
            settingsCard(title: "Monitored AI Agents (\(agentMonitor.activeAgents.count) Active)", systemImage: "cpu.fill") {
                VStack(spacing: 8) {
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

            // Section 3: Claude Code Integration
            settingsCard(title: "Claude Code Hook Integration", systemImage: "terminal.fill") {
                VStack(alignment: .leading, spacing: 10) {
                    Text("Install notification hooks to `~/.claude/settings.json` for real-time task completions and tool-use approval popups.")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    HStack(spacing: 12) {
                        Button {
                            let url = URL(fileURLWithPath: ("~/.claude/settings.json" as NSString).expandingTildeInPath)
                            do {
                                try AgentHookInstaller.updateSettingsFile(at: url, AgentHookInstaller.installClaudeHooks)
                                hookActionMessage = "Claude Code hooks successfully installed!"
                                isHookActionError = false
                            } catch {
                                hookActionMessage = "Failed to install hooks: \(error.localizedDescription)"
                                isHookActionError = true
                            }
                        } label: {
                            Label("Install Hook", systemImage: "arrow.down.doc.fill")
                        }

                        Button {
                            let url = URL(fileURLWithPath: ("~/.claude/settings.json" as NSString).expandingTildeInPath)
                            do {
                                try AgentHookInstaller.updateSettingsFile(at: url, AgentHookInstaller.uninstallClaudeHooks)
                                hookActionMessage = "Claude Code hooks uninstalled."
                                isHookActionError = false
                            } catch {
                                hookActionMessage = "Failed to uninstall: \(error.localizedDescription)"
                                isHookActionError = true
                            }
                        } label: {
                            Label("Uninstall Hook", systemImage: "trash")
                        }
                    }

                    if let msg = hookActionMessage {
                        HStack(spacing: 6) {
                            Image(systemName: isHookActionError ? "xmark.circle.fill" : "checkmark.circle.fill")
                                .foregroundStyle(isHookActionError ? .red : .green)
                            Text(msg)
                                .font(.caption.bold())
                                .foregroundStyle(isHookActionError ? .red : .green)
                        }
                        .padding(.top, 4)
                    }
                }
            }
        }
    }

    // MARK: - Helpers

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
