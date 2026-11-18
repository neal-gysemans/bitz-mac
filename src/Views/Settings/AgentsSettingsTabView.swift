import SwiftUI
import AppKit

/// Settings tab for managing AI Coding Agent detection, speech bubble popups, Claude Code hook installation, and GitHub notifications.
public struct AgentsSettingsTabView: View {
    @ObservedObject public var agentMonitor: AgentMonitorService
    @ObservedObject public var githubService: GitHubNotificationService
    public var claudeSettingsURL: URL
    public var licensingService: (any LicensingServiceProtocol)?

    @State private var patInput: String = ""
    @State private var patActionMessage: String? = nil
    @State private var isPATActionError: Bool = false
    @State private var isShowingAdvancedSignalThresholds: Bool = false

    /// Agents whose window picker sits on Custom; needed because a preset value would otherwise snap the picker back.
    @State private var customWindowAgentIDs: Set<String> = []

    /// Picker tag for Custom; stored windows are always > 0 (`AgentSignalSettings.clamped()`).
    static let customWindowTag = 0
    private static let contextWindowAgents = [
        (id: "claude", name: "Claude Code"),
        (id: "antigravity", name: "Antigravity"),
        (id: "gemini", name: "Gemini CLI"),
        (id: "codex", name: "Codex"),
        (id: "cursor", name: "Cursor"),
    ]

    public init(
        agentMonitor: AgentMonitorService,
        githubService: GitHubNotificationService? = nil,
        claudeSettingsURL: URL = AgentHookInstaller.defaultClaudeSettingsURL,
        licensingService: (any LicensingServiceProtocol)? = nil
    ) {
        self.agentMonitor = agentMonitor
        self.githubService = githubService ?? GitHubNotificationService()
        self.claudeSettingsURL = claudeSettingsURL
        self.licensingService = licensingService
    }

    private var isAgentPowerPackUnlocked: Bool {
        licensingService?.isFeatureUnlocked(.multiAgentSwarm) ?? true
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
                    if !isAgentPowerPackUnlocked {
                        HStack(spacing: 8) {
                            Image(systemName: "lock.fill")
                                .foregroundStyle(.cyan)
                            Text("Smart Agent Guardrails (Context Window %, Tool-Loop, Stall, 429 Quota & Runaway CPU warnings) require Bitz Pro.")
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
                        Divider()
                    }

                    Group {
                        Toggle("Almost Done Heads-Up", isOn: $agentMonitor.signalSettings.almostDoneEnabled)
                        Toggle("Context Window Warnings", isOn: $agentMonitor.signalSettings.contextWarningEnabled)
                        Toggle("Tool Loop Warnings (4 identical calls)", isOn: $agentMonitor.signalSettings.loopWarningEnabled)
                        Toggle("Stall Warnings", isOn: $agentMonitor.signalSettings.stallWarningEnabled)
                        Toggle("Usage Limit / Quota Warnings (429)", isOn: $agentMonitor.signalSettings.rateLimitWarningEnabled)
                        Toggle("Runaway CPU Warnings", isOn: $agentMonitor.signalSettings.runawayCPUWarningEnabled)
                    }
                    .disabled(!isAgentPowerPackUnlocked)

                    hint("Turning off Agent Speech Bubbles hides bubbles only; the amber visor and context gauge keep working.")

                    Divider()

                    DisclosureGroup("Customize Signal Thresholds & Context Window Sizes", isExpanded: $isShowingAdvancedSignalThresholds) {
                        VStack(alignment: .leading, spacing: 10) {
                            Stepper("Warn at \(agentMonitor.signalSettings.contextThresholdPercent)% context",
                                    value: $agentMonitor.signalSettings.contextThresholdPercent, in: 50...99, step: 5)
                                .disabled(!agentMonitor.signalSettings.contextWarningEnabled)

                            Stepper("Stall after \(agentMonitor.signalSettings.stallTimeoutMinutes) min without output",
                                    value: $agentMonitor.signalSettings.stallTimeoutMinutes, in: 1...30)
                                .disabled(!agentMonitor.signalSettings.stallWarningEnabled)

                            Stepper("Warn above \(agentMonitor.signalSettings.runawayCPUPercentThreshold)% CPU",
                                    value: $agentMonitor.signalSettings.runawayCPUPercentThreshold, in: 50...400, step: 10)
                                .disabled(!agentMonitor.signalSettings.runawayCPUWarningEnabled)
                            Stepper("Sustained for \(agentMonitor.signalSettings.runawayCPUDurationMinutes) min",
                                    value: $agentMonitor.signalSettings.runawayCPUDurationMinutes, in: 1...15)
                                .disabled(!agentMonitor.signalSettings.runawayCPUWarningEnabled)

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
                        .padding(.top, 8)
                    }
                    .font(.subheadline.weight(.medium))
                }
            }

            // Section 3: Agent Command Deck
            settingsCard(title: "Agent Command Deck", systemImage: "macwindow.on.rectangle") {
                HStack(alignment: .center, spacing: 12) {
                    VStack(alignment: .leading, spacing: 4) {
                        HStack(spacing: 6) {
                            Text("3D Cyber-Ship Squad Deck")
                                .font(.subheadline.bold())
                            if !isAgentPowerPackUnlocked {
                                ProBadgeView()
                            }
                        }
                        Text("Visualize all background agent sessions, context usage, loops, and approval alerts in a real-time isometric spacecraft.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button(isAgentPowerPackUnlocked ? "Open Command Deck" : "Preview Command Deck") {
                        NSApp.sendAction(#selector(BitzAppDelegate.showCommandDeckWindow), to: nil, from: nil)
                    }
                    .accessibilityIdentifier("AgentsTabOpenCommandDeckButton")
                }
            }

            // Section 4: Monitored Agents Catalog
            settingsCard(title: "Monitored AI Agents (\(agentMonitor.activeAgentCount) Active)", systemImage: "cpu.fill") {
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
                                let sessionCount = agentMonitor.activeSessionCount(for: agent.id)
                                if sessionCount > 0 {
                                    Text(sessionCount > 1 ? "Active • \(sessionCount) Sessions Running" : "Active • Running")
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

            // Section 5: GitHub Notifications & PR/CI Watcher (#188)
            githubSection
        }
    }

    // MARK: - GitHub Notifications Section (#188)

    private var githubSection: some View {
        settingsCard(title: "GitHub Notifications & PR Watcher", systemImage: "chevron.left.forwardslash.chevron.right") {
            VStack(alignment: .leading, spacing: 12) {
                if !isAgentPowerPackUnlocked {
                    HStack(spacing: 8) {
                        Image(systemName: "lock.fill")
                            .foregroundStyle(.cyan)
                        Text("Real-time GitHub PR review requests & CI build failure alerts require Bitz Pro.")
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
                    Divider()
                }

                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Enable GitHub Watcher")
                            .font(.subheadline.bold())
                        Text("Surfaces floating cyber-bubbles for review requests, CI failures, and PR status.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Toggle(
                        "",
                        isOn: Binding(
                            get: { isAgentPowerPackUnlocked && githubService.settingsStore.isEnabled },
                            set: { newValue in
                                guard isAgentPowerPackUnlocked else {
                                    NotificationCenter.default.post(name: .bitzOpenProSettingsTab, object: nil)
                                    return
                                }
                                githubService.settingsStore.setEnabled(newValue)
                                if newValue {
                                    githubService.start()
                                } else {
                                    githubService.stop()
                                }
                            }
                        )
                    )
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .accessibilityLabel("Enable GitHub Watcher")
                }

                HStack {
                    Text("Connection Status:")
                        .font(.subheadline)
                    Spacer()
                    githubStatusBadge
                }

                if isAgentPowerPackUnlocked && githubService.settingsStore.isEnabled {
                    Divider()

                    // Auth mode
                    HStack {
                        Text("Authentication Mode:")
                            .font(.subheadline)
                        Spacer()
                        Picker(
                            "",
                            selection: Binding(
                                get: { githubService.settingsStore.authMode },
                                set: { githubService.settingsStore.setAuthMode($0) }
                            )
                        ) {
                            Text("Auto (GitHub CLI 'gh')").tag(GitHubAuthMode.auto)
                            Text("Personal Access Token (PAT)").tag(GitHubAuthMode.manualPAT)
                        }
                        .pickerStyle(.menu)
                        .frame(width: 220)
                    }

                    if githubService.settingsStore.authMode == .manualPAT || !githubService.authState.isAuthenticated {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("Personal Access Token (PAT):")
                                .font(.caption.bold())
                            HStack(spacing: 8) {
                                SecureField("ghp_xxxxxxxxxxxx", text: $patInput)
                                    .textFieldStyle(.roundedBorder)

                                Button("Save Token") {
                                    do {
                                        try githubService.credentialsStore.saveManualPAT(patInput)
                                        patInput = ""
                                        patActionMessage = "Token saved to Keychain!"
                                        isPATActionError = false
                                        Task {
                                            await githubService.checkAuthentication()
                                            if githubService.authState.isAuthenticated {
                                                await githubService.pollNotificationsOnce()
                                            }
                                        }
                                    } catch {
                                        patActionMessage = "Save failed: \(error.localizedDescription)"
                                        isPATActionError = true
                                    }
                                }
                                .disabled(patInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)

                                if githubService.credentialsStore.hasManualPAT() {
                                    Button("Delete") {
                                        do {
                                            try githubService.credentialsStore.deleteManualPAT()
                                            patActionMessage = "Token removed from Keychain."
                                            isPATActionError = false
                                            Task { await githubService.checkAuthentication() }
                                        } catch {
                                            patActionMessage = "Delete failed: \(error.localizedDescription)"
                                            isPATActionError = true
                                        }
                                    }
                                }
                            }

                            if let msg = patActionMessage {
                                Text(msg)
                                    .font(.caption2.bold())
                                    .foregroundStyle(isPATActionError ? Color.red : Color.green)
                            }

                            hint("Stored securely in macOS Keychain. Requires 'repo', 'read:org', and 'notifications' scopes.")
                        }
                        .padding(10)
                        .background(Color.secondary.opacity(0.08))
                        .cornerRadius(8)
                    }

                    // Polling interval
                    HStack {
                        Text("Check Frequency:")
                            .font(.subheadline)
                        Spacer()
                        Picker(
                            "",
                            selection: Binding(
                                get: { githubService.settingsStore.pollIntervalSeconds },
                                set: { githubService.settingsStore.setPollIntervalSeconds($0) }
                            )
                        ) {
                            Text("Every 30 seconds").tag(30)
                            Text("Every 60 seconds (Default)").tag(60)
                            Text("Every 2 minutes").tag(120)
                        }
                        .pickerStyle(.menu)
                        .frame(width: 200)
                    }

                    // Notification types
                    Toggle(
                        "Review Requests (e.g. '@teammate requested your review')",
                        isOn: Binding(
                            get: { githubService.settingsStore.notifyReviewRequests },
                            set: { githubService.settingsStore.setNotifyReviewRequests($0) }
                        )
                    )
                    .font(.subheadline)

                    Toggle(
                        "CI / Build Failures (Actions runs, Check suites)",
                        isOn: Binding(
                            get: { githubService.settingsStore.notifyCIFailures },
                            set: { githubService.settingsStore.setNotifyCIFailures($0) }
                        )
                    )
                    .font(.subheadline)

                    Toggle(
                        "CI / Build Passes",
                        isOn: Binding(
                            get: { githubService.settingsStore.notifyCIPasses },
                            set: { githubService.settingsStore.setNotifyCIPasses($0) }
                        )
                    )
                    .font(.subheadline)

                    Toggle(
                        "PR Status Announcements (Merged, Closed, Approvals)",
                        isOn: Binding(
                            get: { githubService.settingsStore.notifyPRStatus },
                            set: { githubService.settingsStore.setNotifyPRStatus($0) }
                        )
                    )
                    .font(.subheadline)

                    Toggle(
                        "Push & Git Activity (All Repositories)",
                        isOn: Binding(
                            get: { githubService.settingsStore.notifyGitActivity },
                            set: { githubService.settingsStore.setNotifyGitActivity($0) }
                        )
                    )
                    .font(.subheadline)

                    HStack {
                        Button {
                            Task {
                                await githubService.checkAuthentication()
                                if githubService.authState.isAuthenticated {
                                    await githubService.pollNotificationsOnce()
                                }
                            }
                        } label: {
                            Label(githubService.isPolling ? "Checking..." : "Check Notifications Now", systemImage: "arrow.clockwise")
                        }
                        .controlSize(.small)
                        .disabled(githubService.isPolling)

                        Spacer()

                        Button {
                            githubService.triggerTestAlert()
                        } label: {
                            Label("Test Bubble Alert", systemImage: "sparkles")
                        }
                        .controlSize(.small)
                    }
                }
            }
        }
    }

    private var githubStatusBadge: some View {
        let (color, text): (Color, String) = {
            switch githubService.authState {
            case .authenticated(let username, let source):
                return (.green, "Connected as @\(username) (\(source.rawValue))")
            case .validating:
                return (.orange, "Validating...")
            case .unauthenticated:
                return (.secondary, "Not Connected")
            case .error(let msg):
                return (.red, "Error: \(msg)")
            }
        }()

        return Text(text)
            .font(.caption.bold())
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(color.opacity(0.15))
            .foregroundStyle(color)
            .cornerRadius(6)
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
}
