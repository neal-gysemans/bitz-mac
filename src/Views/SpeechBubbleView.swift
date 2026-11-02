import SwiftUI

/// What Bitz's speech bubble shows, in priority order: Agent Monitor popup, update alert,
/// wellness text (e.g. the `"SYSTEM HOT! > <"` thermal warning, `FR-004`), then telemetry carousel (T016).
public enum SpeechBubbleContent {
    case agentPopup(AgentPopupState)
    case update(GitHubReleaseInfo)
    case wellness(String)
    case carousel(String)

    /// Update alert and agent warning bubbles have buttons, so they are the only bubbles that take clicks.
    public var isInteractive: Bool {
        switch self {
        case .update:
            return true
        case .agentPopup(let popup):
            return popup.kind == .warning
        case .wellness, .carousel:
            return false
        }
    }

    @MainActor
    public static func current(
        engine: WellnessPointEngine,
        agentMonitor: AgentMonitorService,
        updateStore: AppUpdateStore,
        telemetryDashboard: TelemetryDashboardService,
        telemetrySettings: TelemetrySettingsStore
    ) -> SpeechBubbleContent? {
        if let popup = agentMonitor.activePopup {
            return .agentPopup(popup)
        }
        if updateStore.isSpeechBubbleAlertActive, let release = updateStore.latestRelease {
            return .update(release)
        }
        if let text = engine.activeSpeechBubbleText {
            return .wellness(text)
        }
        if telemetrySettings.displayInSpeechBubbleCycle, let text = telemetryDashboard.currentCarouselMessage {
            return .carousel(text)
        }
        return nil
    }
}

/// SwiftUI view hosted inside `SpeechBubblePanel`, rendering Bitz's speech bubble in its own window
/// so it is never clipped by the fixed-size mascot canvas (#61).
public struct SpeechBubbleView: View {
    /// Widest the bubble may grow before its text wraps (unscaled pt).
    public static let maxBubbleWidth: CGFloat = 236
    /// Transparent margin so the bubble's glow is not clipped by its window edges.
    public static let glowPadding: CGFloat = 8

    @ObservedObject public var engine: WellnessPointEngine
    @ObservedObject public var scaleStore: AvatarScaleStore
    @ObservedObject public var agentMonitor: AgentMonitorService
    @ObservedObject public var updateStore: AppUpdateStore
    @ObservedObject public var telemetryDashboard: TelemetryDashboardService
    @ObservedObject public var telemetrySettings: TelemetrySettingsStore

    public init(
        engine: WellnessPointEngine,
        scaleStore: AvatarScaleStore,
        agentMonitor: AgentMonitorService,
        updateStore: AppUpdateStore,
        telemetryDashboard: TelemetryDashboardService,
        telemetrySettings: TelemetrySettingsStore
    ) {
        self.engine = engine
        self.scaleStore = scaleStore
        self.agentMonitor = agentMonitor
        self.updateStore = updateStore
        self.telemetryDashboard = telemetryDashboard
        self.telemetrySettings = telemetrySettings
    }

    public var body: some View {
        let scale = CGFloat(scaleStore.scaleFactor)
        BubbleWindowLayout(width: Self.maxBubbleWidth + Self.glowPadding * 2, scale: scale) {
            bubble
                .padding(Self.glowPadding)
                .scaleEffect(scale, anchor: .topLeading)
        }
    }

    // Speech Bubble Notification (always 100% solid contrast for legibility)
    @ViewBuilder
    private var bubble: some View {
        let visorColor = MascotOverlayView.visorColor(for: engine.currentState)
        switch SpeechBubbleContent.current(
            engine: engine,
            agentMonitor: agentMonitor,
            updateStore: updateStore,
            telemetryDashboard: telemetryDashboard,
            telemetrySettings: telemetrySettings
        ) {
        case .agentPopup(let popup) where popup.kind == .warning:
            warningBubbleView(popup)
        case .agentPopup(let popup):
            let colors = agentPopupColors(for: popup.kind)
            textBubble(popup.text, fill: colors.fill, stroke: colors.stroke)
        case .update(let release):
            updateBubbleView(for: release)
        case .wellness(let text):
            textBubble(
                text,
                fill: engine.currentState == .overheating
                    ? Color(red: 0.75, green: 0.06, blue: 0.10).opacity(0.95)
                    : Color(red: 0.08, green: 0.09, blue: 0.13).opacity(0.94),
                stroke: visorColor
            )
        case .carousel(let text):
            textBubble(text, fill: Color(red: 0.08, green: 0.09, blue: 0.13).opacity(0.94), stroke: visorColor)
        case nil:
            EmptyView()
        }
    }

    private func textBubble(_ text: String, fill: Color, stroke: Color) -> some View {
        Text(text)
            .font(.system(size: 10, weight: .bold, design: .monospaced))
            .multilineTextAlignment(.center)
            .lineLimit(4)
            .minimumScaleFactor(0.75)
            .foregroundStyle(Color.white)
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .frame(maxWidth: Self.maxBubbleWidth)
            .background(RoundedRectangle(cornerRadius: 8).fill(fill))
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(stroke, lineWidth: 1.5))
            .shadow(color: stroke.opacity(0.7), radius: 6)
    }

    private func agentPopupColors(for kind: AgentEventKind) -> (stroke: Color, fill: Color) {
        switch kind {
        case .needsApproval:
            return (Color.yellow, Color(red: 0.85, green: 0.45, blue: 0.05).opacity(0.96))
        case .done:
            return (Color.green, Color(red: 0.05, green: 0.65, blue: 0.35).opacity(0.96))
        case .almostDone:
            // Neon Magenta (#FF007F) on violet: eager, no button
            return (MascotOverlayView.visorColor(for: .superCharged), Color(red: 0.42, green: 0.10, blue: 0.55).opacity(0.96))
        case .warning:
            // Warning Amber (#FFB000), the same colour as the warning visor
            return (MascotOverlayView.visorColor(for: .overworked), Color(red: 0.45, green: 0.12, blue: 0.04).opacity(0.96))
        case .started, .working, .usage:
            // `.usage` never reaches the bubble
            return (Color.cyan, Color(red: 0.12, green: 0.45, blue: 0.85).opacity(0.96))
        }
    }

    private func warningBubbleView(_ popup: AgentPopupState) -> some View {
        let colors = agentPopupColors(for: .warning)
        return VStack(spacing: 5) {
            Text(popup.text)
                .font(.system(size: 10, weight: .bold, design: .monospaced))
                .multilineTextAlignment(.center)
                .lineLimit(4)
                .minimumScaleFactor(0.75)
                .foregroundStyle(Color.white)

            Button(action: { agentMonitor.acknowledgeWarning() }) {
                Text("GOT IT")
                    .font(.system(size: 8, weight: .heavy, design: .monospaced))
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Capsule().fill(colors.stroke))
                    .foregroundStyle(Color.black)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .frame(maxWidth: Self.maxBubbleWidth)
        .background(RoundedRectangle(cornerRadius: 8).fill(colors.fill))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(colors.stroke, lineWidth: 1.5))
        .shadow(color: colors.stroke.opacity(0.6), radius: 6)
    }

    private func updateBubbleView(for release: GitHubReleaseInfo) -> some View {
        let accentColor = Color(red: 0.0, green: 0.94, blue: 1.0)
        let bgColor = Color(red: 0.06, green: 0.08, blue: 0.12).opacity(0.96)
        return VStack(spacing: 5) {
            Text("UPDATE READY: v\(release.semanticVersion.description) 🚀")
                .font(.system(size: 10, weight: .bold, design: .monospaced))
                .foregroundStyle(Color.white)
                .multilineTextAlignment(.center)

            HStack(spacing: 6) {
                Button(action: { updateStore.openDownloadPage() }) {
                    Text("DOWNLOAD")
                        .font(.system(size: 8, weight: .heavy, design: .monospaced))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Capsule().fill(accentColor))
                        .foregroundStyle(Color.black)
                }
                .buttonStyle(.plain)

                Button(action: { updateStore.dismissAlert() }) {
                    Text("LATER")
                        .font(.system(size: 8, weight: .bold, design: .monospaced))
                        .padding(.horizontal, 5)
                        .padding(.vertical, 2)
                        .background(Capsule().stroke(Color.gray.opacity(0.6), lineWidth: 1))
                        .foregroundStyle(Color.white.opacity(0.8))
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .frame(maxWidth: Self.maxBubbleWidth)
        .background(RoundedRectangle(cornerRadius: 8).fill(bgColor))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(accentColor, lineWidth: 1.5))
        .shadow(color: accentColor.opacity(0.6), radius: 6)
    }
}

/// Measures its content as if offered `width` (then scaled), ignoring the window's current size,
/// so the hosting panel resizes to fit the wrapped bubble instead of clipping it.
private struct BubbleWindowLayout: Layout {
    let width: CGFloat
    let scale: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        guard let size = subviews.first?.sizeThatFits(ProposedViewSize(width: width, height: nil)) else {
            return .zero
        }
        return CGSize(width: size.width * scale, height: size.height * scale)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        subviews.first?.place(at: bounds.origin, proposal: ProposedViewSize(width: width, height: nil))
    }
}
