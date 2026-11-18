import SwiftUI
import AppKit

/// Host SwiftUI view for the 3D Cyber-Ship Agent Command Deck window.
///
/// Serves as the primary container integrating:
/// - 3D SceneKit Cyber-Ship viewport (Code Bay, Emergency Table, Reactor, Airlock, MedBay)
/// - Multi-Agent Swarm tier gating banner (`BitzFeature.multiAgentSwarm`)
/// - Tactical Option B HUD action bar with live crewmate selection
public struct AgentCommandDeckView: View {
    @ObservedObject public var agentMonitor: AgentMonitorService
    public var approvalStore: AgentApprovalStore?
    public var licensingService: (any LicensingServiceProtocol)?
    public var appActivator: (any AppActivating)?
    public var diffViewer: (any DiffViewing)?
    public var taskKittenRunner: TaskKittenRunnerService?

    @ObservedObject private var windowManager: AgentCommandDeckWindowManager = AgentCommandDeckWindowManager.shared
    @State public var selectedSessionKey: String? = nil
    @State private var pendingCommsRequest: AgentCommsRequest? = nil
    @State public var isTaskLauncherPresented: Bool = false
    @State private var selectedProvider: TaskKittenCLIProvider = .claude
    @State private var customPrompt: String = ""
    @State private var fallbackTaskRunner: TaskKittenRunnerService? = nil

    public init(
        agentMonitor: AgentMonitorService,
        approvalStore: AgentApprovalStore? = nil,
        licensingService: (any LicensingServiceProtocol)? = nil,
        appActivator: (any AppActivating)? = nil,
        diffViewer: (any DiffViewing)? = nil,
        taskKittenRunner: TaskKittenRunnerService? = nil
    ) {
        self.agentMonitor = agentMonitor
        self.approvalStore = approvalStore
        self.licensingService = licensingService
        self.appActivator = appActivator
        self.diffViewer = diffViewer
        self.taskKittenRunner = taskKittenRunner
    }

    /// Whether concurrent multi-agent squad monitoring is unlocked by the active license.
    public var isSwarmUnlocked: Bool {
        licensingService?.isFeatureUnlocked(.multiAgentSwarm) ?? false
    }

    /// The list of session snapshots visible in the Command Deck based on tier entitlement.
    /// Free tier allows monitoring only 1 active session crewmate (the highest priority one).
    /// Bitz Pro unlocks the entire concurrent squad.
    public var visibleSessions: [AgentSessionSnapshot] {
        if isSwarmUnlocked {
            return agentMonitor.sessionSnapshots
        } else {
            return Array(agentMonitor.sessionSnapshots.prefix(1))
        }
    }

    /// True if 2 or more sessions are active while on the Free tier, triggering the upgrade banner.
    public var showsUpgradeBanner: Bool {
        !isSwarmUnlocked && agentMonitor.sessionSnapshots.count >= 2
    }

    /// Effective selected session key, defaulting to the first visible session if unselected.
    public var effectiveSelectedSessionKey: String? {
        if let key = selectedSessionKey, visibleSessions.contains(where: { $0.stateKey == key }) {
            return key
        }
        return visibleSessions.first?.stateKey
    }

    public var body: some View {
        ZStack(alignment: .top) {
            Color(nsColor: .windowBackgroundColor)
                .ignoresSafeArea()

            GeometryReader { geo in
                VStack(spacing: 0) {
                    if showsUpgradeBanner {
                        upgradeBannerView
                            .frame(width: max(0, geo.size.width))
                    }

                    ZStack {
                        CyberShipSceneView(
                            sessions: visibleSessions,
                            selectedSessionKey: effectiveSelectedSessionKey,
                            isWindowVisible: windowManager.isWindowVisible,
                            pendingCommsRequest: pendingCommsRequest,
                            onSelectSession: { key in
                                selectedSessionKey = key
                            }
                        )
                        .accessibilityIdentifier("CommandDeckSceneView")

                        if visibleSessions.isEmpty {
                            emptySquadOverlay
                        }
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)

                    if isTaskLauncherPresented {
                        taskLauncherBar
                            .frame(width: max(0, geo.size.width - 32))
                    }

                    TacticalActionBarView(
                        sessions: visibleSessions,
                        selectedSessionKey: Binding(
                            get: { effectiveSelectedSessionKey },
                            set: { selectedSessionKey = $0 }
                        ),
                        agentMonitor: agentMonitor,
                        approvalStore: approvalStore,
                        appActivator: appActivator,
                        diffViewer: diffViewer,
                        onTriggerComms: { sender in
                            guard let recipient = visibleSessions.first(where: { $0.stateKey != sender.stateKey }) else {
                                return
                            }
                            pendingCommsRequest = AgentCommsRequest(
                                id: UUID(),
                                senderKey: sender.stateKey,
                                recipientKey: recipient.stateKey
                            )
                        },
                        onToggleTaskLauncher: {
                            guard isSwarmUnlocked else {
                                NotificationCenter.default.post(name: .bitzOpenProSettingsTab, object: nil)
                                return
                            }
                            isTaskLauncherPresented.toggle()
                        }
                    )
                    .frame(width: max(0, geo.size.width - 32))
                }
                .frame(width: geo.size.width, height: geo.size.height)
            }
        }
        .frame(
            minWidth: AgentCommandDeckWindowManager.minimumContentSize.width,
            maxWidth: .infinity,
            minHeight: AgentCommandDeckWindowManager.minimumContentSize.height,
            maxHeight: .infinity
        )
    }

    // MARK: - Subviews

    private var emptySquadOverlay: some View {
        VStack(spacing: 12) {
            Image(systemName: "cpu")
                .font(.system(size: 40))
                .foregroundStyle(Color.cyan)
            Text("NO ACTIVE AGENT SESSIONS")
                .font(.system(size: 14, weight: .bold, design: .monospaced))
                .foregroundStyle(Color.white)
            Text("Background agents (Claude Code, Antigravity, etc.) will report here as crewmates.")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(Color.white.opacity(0.7))
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 16)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(Color.black.opacity(0.85))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(Color.cyan.opacity(0.4), lineWidth: 1)
        )
        .accessibilityIdentifier("CommandDeckEmptySquadOverlay")
    }

    public var upgradeBannerView: some View {
        HStack(spacing: 12) {
            Image(systemName: "crown.fill")
                .foregroundStyle(.yellow)
                .font(.system(size: 14, weight: .bold))

            Text("Multi-Agent Swarm is a Bitz Pro feature. Free tier displays 1 active crewmate.")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.white)

            Spacer()

            Button {
                NotificationCenter.default.post(name: .bitzOpenProSettingsTab, object: nil)
            } label: {
                Text("UPGRADE TO PRO")
                    .font(.system(size: 11, weight: .heavy, design: .monospaced))
                    .padding(.horizontal, 10)
                    .padding(.vertical, 4)
                    .background(Capsule().fill(Color.yellow))
                    .foregroundStyle(Color.black)
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("CommandDeckUpgradeToProButton")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(Color.black.opacity(0.85))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(Color.yellow.opacity(0.8), lineWidth: 1)
        )
        .padding(.horizontal, 16)
        .padding(.top, 12)
        .accessibilityIdentifier("CommandDeckUpgradeBanner")
    }

    private var taskLauncherBar: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Text("PHASE 2 · SPAWN CLI TASK-KITTEN")
                    .font(.system(size: 10, weight: .heavy, design: .monospaced))
                    .foregroundStyle(Color.cyan)

                ForEach(TaskKittenCLIProvider.allCases) { provider in
                    let isSelected = (provider == selectedProvider)
                    Button {
                        selectedProvider = provider
                    } label: {
                        Text(provider.displayName)
                            .font(.system(size: 10, weight: .bold, design: .monospaced))
                            .padding(.horizontal, 8)
                            .padding(.vertical, 3)
                            .background(Capsule().fill(isSelected ? Color.cyan : Color.white.opacity(0.08)))
                            .foregroundStyle(isSelected ? Color.black : Color.white.opacity(0.85))
                    }
                    .buttonStyle(.plain)
                }

                Spacer()

                ForEach(TaskKittenPreset.allCases) { preset in
                    Button {
                        launchKitten(title: preset.title, prompt: preset.prompt)
                    } label: {
                        Text("🐾 \(preset.title)")
                            .font(.system(size: 10, weight: .bold, design: .monospaced))
                            .padding(.horizontal, 8)
                            .padding(.vertical, 3)
                            .background(Capsule().fill(Color.purple.opacity(0.35)))
                            .overlay(Capsule().stroke(Color.purple.opacity(0.7), lineWidth: 1))
                            .foregroundStyle(Color.white)
                    }
                    .buttonStyle(.plain)
                }

                Button {
                    isTaskLauncherPresented = false
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 13))
                        .foregroundStyle(Color.white.opacity(0.65))
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Close Task-Kitten Launcher")
            }

            HStack(spacing: 8) {
                TextField("Custom task prompt for \(selectedProvider.displayName)...", text: $customPrompt)
                    .textFieldStyle(.plain)
                    .font(.system(size: 11, weight: .medium, design: .monospaced))
                    .foregroundStyle(Color.white)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(RoundedRectangle(cornerRadius: 6).fill(Color.white.opacity(0.08)))
                    .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.white.opacity(0.18), lineWidth: 1))
                    .onSubmit {
                        submitCustomPrompt()
                    }

                Button {
                    submitCustomPrompt()
                } label: {
                    Text("LAUNCH")
                        .font(.system(size: 10, weight: .heavy, design: .monospaced))
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .background(Capsule().fill(Color.cyan))
                        .foregroundStyle(Color.black)
                }
                .buttonStyle(.plain)
                .disabled(customPrompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color.black.opacity(0.92)))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.cyan.opacity(0.45), lineWidth: 1))
        .padding(.bottom, 8)
        .accessibilityIdentifier("CommandDeckTaskLauncherBar")
    }

    private func submitCustomPrompt() {
        let trimmed = customPrompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let title = String(trimmed.prefix(24))
        customPrompt = ""
        launchKitten(title: title, prompt: trimmed)
    }

    private func launchKitten(title: String, prompt: String) {
        let runner: TaskKittenRunnerService
        if let provided = taskKittenRunner {
            runner = provided
        } else if let cached = fallbackTaskRunner {
            runner = cached
        } else {
            let created = TaskKittenRunnerService(agentMonitor: agentMonitor)
            fallbackTaskRunner = created
            runner = created
        }

        let workingDir = visibleSessions.compactMap(\.workingDir).first
            ?? agentMonitor.sessionSnapshots.compactMap(\.workingDir).first
        let sessionID = runner.launchTask(
            title: title,
            prompt: prompt,
            provider: selectedProvider,
            workingDirectory: workingDir
        )
        selectedSessionKey = AgentMonitorService.makeStateKey(
            agentID: selectedProvider.agentID,
            sessionID: sessionID
        )
        isTaskLauncherPresented = false
    }
}
