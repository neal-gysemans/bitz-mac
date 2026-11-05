import SwiftUI

/// What Bitz's speech bubble shows, in priority order: Agent Monitor popup, update alert,
/// active meeting recorder status, wellness text (e.g. the `"SYSTEM HOT! > <"` thermal warning, `FR-004`), then telemetry carousel (T016).
public enum SpeechBubbleContent {
    case agentPopup(AgentPopupState)
    case update(GitHubReleaseInfo)
    case meetingRecorder(text: String, isInteractive: Bool)
    case wellness(String)
    case carousel(String)

    /// Update alert, agent warning, and completed meeting recording bubbles have buttons, so they are the only bubbles that take clicks.
    public var isInteractive: Bool {
        switch self {
        case .update:
            return true
        case .agentPopup(let popup):
            return popup.kind == .warning
        case .meetingRecorder(_, let interactive):
            return interactive
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
        telemetrySettings: TelemetrySettingsStore,
        meetingRecorder: MeetingRecorderService? = nil
    ) -> SpeechBubbleContent? {
        if let popup = agentMonitor.activePopup {
            return .agentPopup(popup)
        }
        if updateStore.isSpeechBubbleAlertActive, let release = updateStore.latestRelease {
            return .update(release)
        }
        if let meetingRecorder, let text = meetingRecorder.activeSpeechBubbleText {
            return .meetingRecorder(text: text, isInteractive: meetingRecorder.isInteractiveBubbleActive)
        }
        if let text = engine.displayedSpeechBubbleText {
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
    public let telemetryDashboard: TelemetryDashboardService
    @ObservedObject public var telemetrySettings: TelemetrySettingsStore
    @ObservedObject public var paletteStore: AvatarPaletteStore
    @ObservedObject public var meetingRecorder: MeetingRecorderService

    public init(
        engine: WellnessPointEngine,
        scaleStore: AvatarScaleStore,
        agentMonitor: AgentMonitorService,
        updateStore: AppUpdateStore,
        telemetryDashboard: TelemetryDashboardService,
        telemetrySettings: TelemetrySettingsStore,
        paletteStore: AvatarPaletteStore = AvatarPaletteStore(),
        meetingRecorder: MeetingRecorderService = MeetingRecorderService()
    ) {
        self.paletteStore = paletteStore
        self.meetingRecorder = meetingRecorder
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
        let visorColor = paletteStore.resolvedPalette.visorColor(for: engine.currentState)
        if let popup = agentMonitor.activePopup {
            if popup.kind == .warning {
                warningBubbleView(popup)
            } else {
                let colors = agentPopupColors(for: popup.kind)
                textBubble(popup.text, fill: colors.fill, stroke: colors.stroke)
            }
        } else if updateStore.isSpeechBubbleAlertActive, let release = updateStore.latestRelease {
            updateBubbleView(for: release)
        } else if meetingRecorder.isRecording {
            MeetingRecordingTimerBubbleObserver(timerStore: meetingRecorder.timerStore) { text in
                textBubble(
                    text,
                    fill: Color(red: 0.35, green: 0.05, blue: 0.09).opacity(0.95),
                    stroke: Color(red: 1.0, green: 0.20, blue: 0.26)
                )
            }
        } else if meetingRecorder.isTranscribing {
            textBubble(
                "✨ Meeting saved! Transcribing audio...",
                fill: Color(red: 0.08, green: 0.09, blue: 0.13).opacity(0.95),
                stroke: visorColor
            )
        } else if case .completed(let result) = meetingRecorder.state, meetingRecorder.isCompletionBubbleVisible {
            meetingCompletedBubbleView(for: result)
        } else if case .failed(let message) = meetingRecorder.state, meetingRecorder.isCompletionBubbleVisible {
            textBubble(
                "⚠️ \(message)",
                fill: Color(red: 0.55, green: 0.08, blue: 0.12).opacity(0.95),
                stroke: Color.red
            )
        } else if let text = engine.displayedSpeechBubbleText {
            textBubble(
                text,
                fill: engine.currentState == .overheating
                    ? Color(red: 0.75, green: 0.06, blue: 0.10).opacity(0.95)
                    : Color(red: 0.08, green: 0.09, blue: 0.13).opacity(0.94),
                stroke: visorColor
            )
        } else if telemetrySettings.displayInSpeechBubbleCycle {
            CarouselSpeechBubbleObserver(telemetryDashboard: telemetryDashboard) { text in
                textBubble(text, fill: Color(red: 0.08, green: 0.09, blue: 0.13).opacity(0.94), stroke: visorColor)
            }
        } else {
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
        case .failed:
            // High-contrast crimson on red stroke for critical failure
            return (Color.red, Color(red: 0.65, green: 0.08, blue: 0.12).opacity(0.96))
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
            .help("Acknowledge and dismiss this warning")
            .accessibilityLabel("Dismiss Warning")
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
                .help("Download the latest update")
                .accessibilityLabel("Download Update")

                Button(action: { updateStore.dismissAlert() }) {
                    Text("LATER")
                        .font(.system(size: 8, weight: .bold, design: .monospaced))
                        .padding(.horizontal, 5)
                        .padding(.vertical, 2)
                        .background(Capsule().stroke(Color.gray.opacity(0.6), lineWidth: 1))
                        .foregroundStyle(Color.white.opacity(0.8))
                }
                .buttonStyle(.plain)
                .help("Dismiss the update alert for now")
                .accessibilityLabel("Dismiss Update Alert")
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .frame(maxWidth: Self.maxBubbleWidth)
        .background(RoundedRectangle(cornerRadius: 8).fill(bgColor))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(accentColor, lineWidth: 1.5))
        .shadow(color: accentColor.opacity(0.6), radius: 6)
    }

    private func meetingCompletedBubbleView(for result: MeetingRecordingResult) -> some View {
        let accentColor = Color(red: 0.0, green: 1.0, blue: 0.53)
        let bgColor = Color(red: 0.05, green: 0.12, blue: 0.09).opacity(0.96)
        return VStack(spacing: 5) {
            Text(result.bubbleHeadline)
                .font(.system(size: 10, weight: .bold, design: .monospaced))
                .foregroundStyle(Color.white)
                .multilineTextAlignment(.center)
                .lineLimit(4)
                .minimumScaleFactor(0.75)

            HStack(spacing: 6) {
                Button(action: { meetingRecorder.revealInFinder(result.sessionDirectoryURL) }) {
                    Text("OPEN IN FINDER")
                        .font(.system(size: 8, weight: .heavy, design: .monospaced))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Capsule().fill(accentColor))
                        .foregroundStyle(Color.black)
                }
                .buttonStyle(.plain)
                .help("Reveal the meeting audio and transcript in Finder")
                .accessibilityLabel("Open Meeting in Finder")

                Button(action: { meetingRecorder.dismissCompletionBubble() }) {
                    Text("DISMISS")
                        .font(.system(size: 8, weight: .bold, design: .monospaced))
                        .padding(.horizontal, 5)
                        .padding(.vertical, 2)
                        .background(Capsule().stroke(Color.gray.opacity(0.6), lineWidth: 1))
                        .foregroundStyle(Color.white.opacity(0.8))
                }
                .buttonStyle(.plain)
                .help("Dismiss the meeting completion notice")
                .accessibilityLabel("Dismiss Meeting Notice")
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .frame(maxWidth: Self.maxBubbleWidth)
        // Shadow on the filled shape before the stroke overlay (AGENTS.md §2.6)
        .background(RoundedRectangle(cornerRadius: 8).fill(bgColor).shadow(color: accentColor.opacity(0.6), radius: 6))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(accentColor, lineWidth: 1.5))
    }
}

/// Leaf observer for the 1s recording timer so only the timer text re-renders while recording (#43, #70).
private struct MeetingRecordingTimerBubbleObserver<Content: View>: View {
    @ObservedObject var timerStore: MeetingRecordingTimerStore
    @ViewBuilder let content: (String) -> Content

    var body: some View {
        let formatted = MeetingSettingsStore.formatDuration(timerStore.elapsedSeconds)
        content("🔴 Recording meeting (\(formatted))...")
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

/// Only subscribes to `TelemetryDashboardService` when the speech-bubble telemetry carousel is enabled,
/// keeping `SpeechBubblePanel` completely quiescent during normal operation (#70).
private struct CarouselSpeechBubbleObserver<Content: View>: View {
    @ObservedObject var telemetryDashboard: TelemetryDashboardService
    @ViewBuilder let content: (String) -> Content

    var body: some View {
        if let text = telemetryDashboard.currentCarouselMessage {
            content(text)
        }
    }
}
