import SwiftUI

/// What Bitz's speech bubble shows, in priority order: Agent Monitor popup, calendar agenda alert (#186),
/// GitHub notifications alert (#188), update alert, thermal warning (`FR-004`), meeting recorder bubble (#43 D5),
/// other wellness text and personality commentary, then telemetry carousel (T016).
public enum SpeechBubbleContent: Equatable {
    case agentPopup(AgentPopupState)
    case agenda(CalendarAgendaAlert)
    case github(GitHubEventAlert)
    case update(GitHubReleaseInfo)
    case workShift(WorkShiftAlert)
    case meeting(MeetingBubble)
    case wellness(String)
    case carousel(String)

    /// Update alert, agent warning, calendar agenda alerts, GitHub alerts, work-shift alerts, and meeting bubbles with buttons are the only bubbles that take clicks.
    public var isInteractive: Bool {
        switch self {
        case .update:
            return true
        case .agentPopup(let popup):
            return popup.kind == .warning
        case .agenda(let alert):
            return alert.isInteractive
        case .github(let alert):
            return alert.isInteractive
        case .workShift(let alert):
            return alert.isInteractive
        case .meeting(let bubble):
            return bubble.isInteractive
        case .wellness, .carousel:
            return false
        }
    }

    /// The thermal warning outranks meeting bubbles; other wellness text does not,
    /// so a 45-minute "take a break" never hides a recording that failed to start.
    @MainActor
    public static func thermalWarning(_ engine: WellnessPointEngine) -> String? {
        engine.currentState == .overheating ? engine.activeSpeechBubbleText : nil
    }

    @MainActor
    public static func current(
        engine: WellnessPointEngine,
        agentMonitor: AgentMonitorService,
        calendarService: CalendarAgendaService? = nil,
        githubService: GitHubNotificationService? = nil,
        updateStore: AppUpdateStore,
        telemetryDashboard: TelemetryDashboardService,
        telemetrySettings: TelemetrySettingsStore,
        meetingRecorder: MeetingRecorderService? = nil,
        workShiftTracker: WorkShiftTrackerService? = nil
    ) -> SpeechBubbleContent? {
        if let popup = agentMonitor.activePopup {
            return .agentPopup(popup)
        }
        if let alert = calendarService?.activeAlert {
            return .agenda(alert)
        }
        if let alert = githubService?.activeAlert {
            return .github(alert)
        }
        if updateStore.isSpeechBubbleAlertActive, let release = updateStore.latestRelease {
            return .update(release)
        }
        if let text = thermalWarning(engine) {
            return .wellness(text)
        }
        if let alert = workShiftTracker?.activeAlert {
            return .workShift(alert)
        }
        if let bubble = meetingRecorder?.bubble {
            return .meeting(bubble)
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
    @ObservedObject public var calendarService: CalendarAgendaService
    @ObservedObject public var githubService: GitHubNotificationService
    @ObservedObject public var meetingRecorder: MeetingRecorderService
    public let workShiftTracker: WorkShiftTrackerService
    @State private var workShiftAlert: WorkShiftAlert?

    public init(
        engine: WellnessPointEngine,
        scaleStore: AvatarScaleStore,
        agentMonitor: AgentMonitorService,
        updateStore: AppUpdateStore,
        telemetryDashboard: TelemetryDashboardService,
        telemetrySettings: TelemetrySettingsStore,
        paletteStore: AvatarPaletteStore = AvatarPaletteStore(),
        meetingRecorder: MeetingRecorderService,
        calendarService: CalendarAgendaService? = nil,
        githubService: GitHubNotificationService? = nil,
        workShiftTracker: WorkShiftTrackerService? = nil
    ) {
        self.paletteStore = paletteStore
        self.meetingRecorder = meetingRecorder
        self.engine = engine
        self.scaleStore = scaleStore
        self.agentMonitor = agentMonitor
        self.updateStore = updateStore
        self.telemetryDashboard = telemetryDashboard
        self.telemetrySettings = telemetrySettings
        self.calendarService = calendarService ?? CalendarAgendaService(storeProvider: MockCalendarEventStore())
        self.githubService = githubService ?? GitHubNotificationService()
        let resolvedWorkShiftTracker = workShiftTracker ?? WorkShiftTrackerService()
        self.workShiftTracker = resolvedWorkShiftTracker
        self._workShiftAlert = State(initialValue: resolvedWorkShiftTracker.activeAlert)
    }

    public var body: some View {
        let scale = CGFloat(scaleStore.scaleFactor)
        BubbleWindowLayout(width: Self.maxBubbleWidth + Self.glowPadding * 2, scale: scale) {
            bubble
                .padding(Self.glowPadding)
                .scaleEffect(scale, anchor: .topLeading)
        }
        .onReceive(workShiftTracker.$activeAlert.removeDuplicates()) { alert in
            workShiftAlert = alert
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
        } else if let alert = calendarService.activeAlert {
            agendaBubbleView(for: alert)
        } else if let alert = githubService.activeAlert {
            githubBubbleView(for: alert)
        } else if updateStore.isSpeechBubbleAlertActive, let release = updateStore.latestRelease {
            updateBubbleView(for: release)
        } else if let thermal = SpeechBubbleContent.thermalWarning(engine) {
            textBubble(thermal, fill: Color(red: 0.75, green: 0.06, blue: 0.10).opacity(0.95), stroke: visorColor)
        } else if let alert = workShiftAlert {
            workShiftBubbleView(for: alert)
        } else if let meeting = meetingRecorder.bubble {
            meetingBubbleView(meeting, visorColor: visorColor)
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

    private func agendaBubbleView(for alert: CalendarAgendaAlert) -> some View {
        let accentColor = Color(red: 0.20, green: 0.70, blue: 1.0)
        let bgColor = Color(red: 0.05, green: 0.08, blue: 0.14).opacity(0.96)
        return VStack(spacing: 5) {
            Text(alert.message)
                .font(.system(size: 10, weight: .bold, design: .monospaced))
                .multilineTextAlignment(.center)
                .lineLimit(4)
                .minimumScaleFactor(0.75)
                .foregroundStyle(Color.white)

            HStack(spacing: 6) {
                if let event = alert.event, let _ = alert.meetingURL {
                    Button(action: { calendarService.joinMeeting(for: event) }) {
                        HStack(spacing: 3) {
                            Image(systemName: "video.fill")
                                .font(.system(size: 8))
                            Text("JOIN")
                                .font(.system(size: 8, weight: .heavy, design: .monospaced))
                        }
                        .padding(.horizontal, 7)
                        .padding(.vertical, 2)
                        .background(Capsule().fill(Color(red: 0.10, green: 0.85, blue: 0.45)))
                        .foregroundStyle(Color.black)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Join Meeting")
                }

                Button(action: { calendarService.dismissAlert() }) {
                    Text(alert.meetingURL != nil ? "LATER" : "GOT IT")
                        .font(.system(size: 8, weight: .bold, design: .monospaced))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(
                            Group {
                                if alert.meetingURL != nil {
                                    Capsule().stroke(Color.gray.opacity(0.6), lineWidth: 1)
                                } else {
                                    Capsule().fill(accentColor)
                                }
                            }
                        )
                        .foregroundStyle(alert.meetingURL != nil ? Color.white.opacity(0.85) : Color.black)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(alert.meetingURL != nil ? "Dismiss meeting alert later" : "Acknowledge alert")
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .frame(maxWidth: Self.maxBubbleWidth)
        .background(RoundedRectangle(cornerRadius: 8).fill(bgColor))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(accentColor, lineWidth: 1.5))
        .shadow(color: accentColor.opacity(0.6), radius: 6)
    }

    private func workShiftBubbleView(for alert: WorkShiftAlert) -> some View {
        let accentColor = Color(red: 0.15, green: 0.90, blue: 0.65)
        let bgColor = Color(red: 0.06, green: 0.09, blue: 0.14).opacity(0.96)
        return VStack(spacing: 5) {
            Text(alert.message)
                .font(.system(size: 10, weight: .bold, design: .monospaced))
                .multilineTextAlignment(.center)
                .lineLimit(5)
                .minimumScaleFactor(0.75)
                .foregroundStyle(Color.white)

            HStack(spacing: 6) {
                Button(action: {
                    workShiftTracker.logOffForToday()
                    engine.triggerPetInteraction()
                }) {
                    Text("LOGGING OFF")
                        .font(.system(size: 8, weight: .heavy, design: .monospaced))
                        .padding(.horizontal, 7)
                        .padding(.vertical, 2)
                        .background(Capsule().fill(accentColor))
                        .foregroundStyle(Color.black)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Log off for today")

                Button(action: { workShiftTracker.snooze() }) {
                    Text("SNOOZE 30M")
                        .font(.system(size: 8, weight: .bold, design: .monospaced))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Capsule().stroke(Color.gray.opacity(0.6), lineWidth: 1))
                        .foregroundStyle(Color.white.opacity(0.85))
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Snooze clock-out reminder for 30 minutes")
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .frame(maxWidth: Self.maxBubbleWidth)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(bgColor)
                .shadow(color: accentColor.opacity(0.6), radius: 6)
        )
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(accentColor, lineWidth: 1.5))
    }

    private func githubAccentColor(for kind: GitHubEventAlert.Kind) -> Color {
        switch kind {
        case .reviewRequested:
            return Color(red: 0.65, green: 0.45, blue: 1.0)
        case .ciFailed:
            return Color(red: 1.0, green: 0.25, blue: 0.30)
        case .ciPassed:
            return Color(red: 0.10, green: 0.85, blue: 0.45)
        case .prStatus:
            return Color(red: 0.20, green: 0.70, blue: 1.0)
        case .mention:
            return Color(red: 1.0, green: 0.80, blue: 0.20)
        case .general:
            return Color(red: 0.65, green: 0.45, blue: 1.0)
        }
    }

    private func githubBubbleView(for alert: GitHubEventAlert) -> some View {
        let accentColor = githubAccentColor(for: alert.kind)
        let bgColor = Color(red: 0.05, green: 0.07, blue: 0.12).opacity(0.96)

        return VStack(spacing: 5) {
            Text(alert.message)
                .font(.system(size: 10, weight: .bold, design: .monospaced))
                .multilineTextAlignment(.center)
                .lineLimit(4)
                .minimumScaleFactor(0.75)
                .foregroundStyle(Color.white)

            HStack(spacing: 6) {
                if alert.targetURL != nil {
                    Button(action: { githubService.openTargetURL(for: alert) }) {
                        Text(alert.actionTitle)
                            .font(.system(size: 8, weight: .heavy, design: .monospaced))
                            .padding(.horizontal, 7)
                            .padding(.vertical, 2)
                            .background(Capsule().fill(accentColor))
                            .foregroundStyle(Color.black)
                    }
                    .buttonStyle(.plain)
                    .help("Open \(alert.actionTitle) in browser")
                    .accessibilityLabel(alert.actionTitle)
                }

                Button(action: { githubService.dismissAlert() }) {
                    Text("GOT IT")
                        .font(.system(size: 8, weight: .bold, design: .monospaced))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(
                            Group {
                                if alert.targetURL != nil {
                                    Capsule().stroke(Color.gray.opacity(0.6), lineWidth: 1)
                                } else {
                                    Capsule().fill(accentColor)
                                }
                            }
                        )
                        .foregroundStyle(alert.targetURL != nil ? Color.white.opacity(0.85) : Color.black)
                }
                .buttonStyle(.plain)
                .help("Dismiss GitHub alert")
                .accessibilityLabel("Dismiss GitHub Alert")
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .frame(maxWidth: Self.maxBubbleWidth)
        .background(RoundedRectangle(cornerRadius: 8).fill(bgColor).shadow(color: accentColor.opacity(0.6), radius: 6))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(accentColor, lineWidth: 1.5))
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
            // Shadow on the filled shape before the stroke overlay (AGENTS.md §2.6)
            .background(RoundedRectangle(cornerRadius: 8).fill(fill).shadow(color: stroke.opacity(0.7), radius: 6))
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(stroke, lineWidth: 1.5))
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
        // Shadow on the filled shape before the stroke overlay (AGENTS.md §2.6)
        .background(RoundedRectangle(cornerRadius: 8).fill(colors.fill).shadow(color: colors.stroke.opacity(0.6), radius: 6))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(colors.stroke, lineWidth: 1.5))
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
        // Shadow on the filled shape before the stroke overlay (AGENTS.md §2.6)
        .background(RoundedRectangle(cornerRadius: 8).fill(bgColor).shadow(color: accentColor.opacity(0.6), radius: 6))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(accentColor, lineWidth: 1.5))
    }

    /// (stroke, fill) per meeting bubble kind.
    private func meetingColors(for kind: MeetingBubble.Kind, visorColor: Color) -> (stroke: Color, fill: Color) {
        switch kind {
        case .recording:
            return (Color(red: 1.0, green: 0.20, blue: 0.26), Color(red: 0.35, green: 0.05, blue: 0.09).opacity(0.95))
        case .interruption:
            return agentPopupColors(for: .warning)
        case .saving, .transcribing:
            return (visorColor, Color(red: 0.08, green: 0.09, blue: 0.13).opacity(0.95))
        case .completion:
            return (Color(red: 0.0, green: 1.0, blue: 0.53), Color(red: 0.05, green: 0.12, blue: 0.09).opacity(0.96))
        case .failure:
            return (Color.red, Color(red: 0.55, green: 0.08, blue: 0.12).opacity(0.95))
        }
    }

    private func meetingBubbleView(_ meeting: MeetingBubble, visorColor: Color) -> some View {
        let colors = meetingColors(for: meeting.kind, visorColor: visorColor)
        let primaryActions = meeting.actions.filter { $0 == .openDictationSettings || $0 == .transcribeAgain }
        let secondaryActions = meeting.actions.filter { $0 != .openDictationSettings && $0 != .transcribeAgain }
        return VStack(spacing: 5) {
            Text(meeting.text)
                .font(.system(size: 10, weight: .bold, design: .monospaced))
                .multilineTextAlignment(.center)
                .foregroundStyle(Color.white)
                // The headline is one short clause and never truncates; only the detail may
                .fixedSize(horizontal: false, vertical: true)

            if let detail = meeting.detail {
                Text(detail)
                    .font(.system(size: 9, weight: .medium, design: .monospaced))
                    .multilineTextAlignment(.center)
                    .lineLimit(3)
                    .minimumScaleFactor(0.75)
                    .foregroundStyle(Color.white.opacity(0.85))
            }

            // Split primary vs utility actions across two rows (at most 2 buttons per row for maxBubbleWidth)
            if !primaryActions.isEmpty {
                HStack(spacing: 6) {
                    ForEach(primaryActions, id: \.self) { action in
                        meetingButton(action, accent: colors.stroke)
                    }
                }
            }
            if !secondaryActions.isEmpty {
                HStack(spacing: 6) {
                    ForEach(secondaryActions, id: \.self) { action in
                        meetingButton(action, accent: colors.stroke)
                    }
                }
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, meeting.actions.isEmpty ? 5 : 6)
        .frame(maxWidth: Self.maxBubbleWidth)
        // Shadow on the filled shape before the stroke overlay (AGENTS.md §2.6)
        .background(RoundedRectangle(cornerRadius: 8).fill(colors.fill).shadow(color: colors.stroke.opacity(0.6), radius: 6))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(colors.stroke, lineWidth: 1.5))
    }

    /// DISMISS is the quiet outlined button; every other action is filled with the bubble's accent.
    @ViewBuilder
    private func meetingButton(_ action: MeetingBubble.Action, accent: Color) -> some View {
        Button(action: { meetingRecorder.perform(action) }) {
            if action == .dismiss {
                Text(action.title)
                    .font(.system(size: 8, weight: .bold, design: .monospaced))
                    .padding(.horizontal, 5)
                    .padding(.vertical, 2)
                    .background(Capsule().stroke(Color.gray.opacity(0.6), lineWidth: 1))
                    .foregroundStyle(Color.white.opacity(0.8))
            } else {
                Text(action.title)
                    .font(.system(size: 8, weight: .heavy, design: .monospaced))
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Capsule().fill(accent))
                    .foregroundStyle(Color.black)
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel(action.accessibilityLabel)
    }
}

/// Measures its content as if offered `width` (then scaled), ignoring the window's current size,
/// so the hosting panel resizes to fit the wrapped bubble instead of clipping it.
struct BubbleWindowLayout: Layout {
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
