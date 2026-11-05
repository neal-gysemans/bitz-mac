import SwiftUI
import UniformTypeIdentifiers

/// Non-observable holder so hover samples never invalidate the mascot view (#70).
final class PetStrokeTracker {
    var detector = PetStrokeDetector()
}

/// SwiftUI view hosted inside `MascotOverlayPanel`, rendering the transparent
/// cyberpunk mascot canvas, reactive LED visor glow, and standby `"ZZZ"` badge (`FR-001`, `FR-003`).
/// Speech bubbles live in `SpeechBubbleView` inside the panel's `SpeechBubblePanel` (#61).
public struct MascotOverlayView: View {
    @ObservedObject public var engine: WellnessPointEngine
    @ObservedObject public var scaleStore: AvatarScaleStore
    @ObservedObject public var opacityStore: AvatarOpacityStore
    @ObservedObject public var positionStore: AvatarPositionStore
    public let telemetryDashboard: TelemetryDashboardService
    @ObservedObject public var telemetrySettings: TelemetrySettingsStore
    @ObservedObject public var interactionSettings: MascotInteractionSettingsStore
    @ObservedObject public var paletteStore: AvatarPaletteStore
    @ObservedObject public var agentMonitor: AgentMonitorService
    @ObservedObject public var meetingRecorder: MeetingRecorderService

    private let explicitAttentionCue: Bool?

    public var isAttentionCueActive: Bool {
        explicitAttentionCue ?? (agentMonitor.activePopup?.kind == .needsApproval)
    }

    public var onFilesDropped: (([URL]) -> Void)?
    public var onDragChanged: ((NSPoint, NSScreen?) -> Void)?
    public var onDragEnded: ((NSPoint, NSScreen?) -> Void)?
    public var onGetOrigin: (() -> NSPoint?)?
    public var onGetSize: (() -> NSSize)?
    public var onOpenSettings: (() -> Void)?
    /// Reports how far below the 250 pt canvas top Bitz's ear tips sit (unscaled pt), so the speech bubble can sit just above them.
    public var onEarTopChanged: ((CGFloat) -> Void)?

    @State private var dragInitialOrigin: NSPoint? = nil
    @State private var isHovering: Bool = false
    @State private var strokeTracker = PetStrokeTracker()

    private static let canvasSpace = "mascotCanvas"

    public init(
        engine: WellnessPointEngine,
        scaleStore: AvatarScaleStore = AvatarScaleStore(),
        opacityStore: AvatarOpacityStore = AvatarOpacityStore(),
        positionStore: AvatarPositionStore = AvatarPositionStore(),
        telemetryDashboard: TelemetryDashboardService = TelemetryDashboardService(),
        telemetrySettings: TelemetrySettingsStore = TelemetrySettingsStore(),
        interactionSettings: MascotInteractionSettingsStore = MascotInteractionSettingsStore(),
        paletteStore: AvatarPaletteStore = AvatarPaletteStore(),
        agentMonitor: AgentMonitorService = AgentMonitorService(),
        meetingRecorder: MeetingRecorderService,
        isAttentionCueActive: Bool? = nil,
        onFilesDropped: (([URL]) -> Void)? = nil,
        onDragChanged: ((NSPoint, NSScreen?) -> Void)? = nil,
        onDragEnded: ((NSPoint, NSScreen?) -> Void)? = nil,
        onGetOrigin: (() -> NSPoint?)? = nil,
        onGetSize: (() -> NSSize)? = nil,
        onOpenSettings: (() -> Void)? = nil,
        onEarTopChanged: ((CGFloat) -> Void)? = nil
    ) {
        self.engine = engine
        self.scaleStore = scaleStore
        self.opacityStore = opacityStore
        self.positionStore = positionStore
        self.telemetryDashboard = telemetryDashboard
        self.telemetrySettings = telemetrySettings
        self.interactionSettings = interactionSettings
        self.paletteStore = paletteStore
        self.agentMonitor = agentMonitor
        self.meetingRecorder = meetingRecorder
        self.explicitAttentionCue = isAttentionCueActive
        self.onFilesDropped = onFilesDropped
        self.onDragChanged = onDragChanged
        self.onDragEnded = onDragEnded
        self.onGetOrigin = onGetOrigin
        self.onGetSize = onGetSize
        self.onOpenSettings = onOpenSettings
        self.onEarTopChanged = onEarTopChanged
    }

    /// Returns the RGB color values (`red`, `green`, `blue`) matching the current `BitzState` visor color.
    public static func visorRGB(for state: BitzState) -> (red: Double, green: Double, blue: Double) {
        switch state {
        case .balanced:
            // Electric Cyan (#00F0FF)
            return (0.0, 240.0 / 255.0, 1.0)
        case .superCharged:
            // Neon Magenta (#FF007F)
            return (1.0, 0.0, 127.0 / 255.0)
        case .dopamineSad:
            // Dopamine Overload Violet (#9D4EDD)
            return (157.0 / 255.0, 78.0 / 255.0, 221.0 / 255.0)
        case .overworked, .burnout:
            // Warning Amber (#FFB000)
            return (1.0, 176.0 / 255.0, 0.0)
        case .charging:
            // Cyber Emerald Green (#00FF88)
            return (0.0, 1.0, 136.0 / 255.0)
        case .overheating:
            // Critical Red (#FF1E1E)
            return (1.0, 30.0 / 255.0, 30.0 / 255.0)
        }
    }

    /// The warning visor is Amber except while overheating (red wins); mirrors `WellnessPointEngine.syncWithRive()`.
    public static func visorRGB(for state: BitzState, warningVisorActive: Bool) -> (red: Double, green: Double, blue: Double) {
        warningVisorActive && state != .overheating ? visorRGB(for: .overworked) : visorRGB(for: state)
    }

    public static func visorColor(for state: BitzState) -> Color {
        visorColor(for: state, warningVisorActive: false)
    }

    public static func visorColor(for state: BitzState, warningVisorActive: Bool) -> Color {
        let rgb = visorRGB(for: state, warningVisorActive: warningVisorActive)
        return Color(red: rgb.red, green: rgb.green, blue: rgb.blue)
    }

    /// State shown on the mascot: a settings "Preview Emotion" temporarily overrides the live engine state.
    private var displayedState: BitzState {
        paletteStore.previewSlot?.previewState ?? engine.currentState
    }

    private var displayedPetReaction: Bool {
        paletteStore.previewSlot == .petting || engine.isPetReactionActive
    }

    private var visorColor: Color {
        paletteStore.resolvedPalette.visorColor(
            for: displayedState,
            warningVisorActive: engine.isWarningVisorActive && paletteStore.previewSlot == nil
        )
    }

    private var animationSpeedMultiplier: Double {
        switch displayedState {
        case .superCharged:
            return 2.0
        case .balanced:
            return 1.0
        case .dopamineSad:
            return 0.35
        case .overworked:
            return 0.4
        case .burnout:
            return 0.0
        case .charging:
            return 0.6
        case .overheating:
            return 2.5
        }
    }

    private var isLoafPosture: Bool {
        !meetingRecorder.isRecording && (displayedState == .burnout || displayedState == .charging)
    }

    // Holding ⌥ alone only shows the border, so typing ⌥ shortcuts in other apps doesn't flash the HUD
    private var showsDragPill: Bool {
        positionStore.isPositionUnlocked || positionStore.isDragging
    }

    public var body: some View {
        // Read on the main actor: the geometry transform below is a Sendable closure
        let canvasSpace = Self.canvasSpace
        let earOverflow = BitzCharacterView.earOverflow(isLoafPosture: isLoafPosture)
        let isAnimationPaused = !positionStore.isMascotVisible

        VStack(spacing: 6) {
            Spacer(minLength: 0)

            // Offload continuous mascot motion to CoreAnimation (`LiveBitzCharacterView`), keeping the main thread
            // and Cyber HUD quiescent at idle (#70).
            LiveBitzCharacterView(
                state: displayedState,
                isPetReactionActive: displayedPetReaction,
                isLoafPosture: isLoafPosture,
                showParticles: true,
                customVisorColor: visorColor,
                isPaused: isAnimationPaused,
                palette: paletteStore.resolvedPalette,
                isAttentionCueActive: isAttentionCueActive,
                isRecordingMeeting: meetingRecorder.isRecording
            )
            .frame(width: 180, height: 140)
            .opacity(opacityStore.opacityFactor)
            // Layout frame excludes the breathing offset, so this only fires when the HUD or posture changes
            .onGeometryChange(for: CGFloat.self) { proxy in
                proxy.frame(in: .named(canvasSpace)).minY - earOverflow
            } action: { earTop in
                onEarTopChanged?(earTop)
            }

            // Live Cyberpunk Hardware Telemetry & Diagnostics HUD (isolated observer so 3s telemetry ticks
            // never invalidate MascotOverlayView or LiveBitzCharacterView #70)
            if telemetrySettings.displayInMascotCyberHUD {
                MascotCyberHUDContainerView(
                    telemetryDashboard: telemetryDashboard,
                    enabledMetrics: telemetrySettings.enabledMetrics,
                    focusPoints: engine.currentPoints,
                    visorColor: visorColor,
                    opacity: showsDragPill ? 0 : max(0.6, opacityStore.opacityFactor)
                )
            } else {
                Spacer().frame(height: 10)
            }
        }
        .frame(width: 250, height: 250)
        .coordinateSpace(.named(Self.canvasSpace))
        .overlay {
            if positionStore.isInteractivityEnabled {
                ZStack(alignment: .bottom) {
                    RoundedRectangle(cornerRadius: 16)
                        .stroke(
                            visorColor.opacity(positionStore.isDragging ? 0.95 : 0.65),
                            style: StrokeStyle(lineWidth: 1.5, dash: [5, 4])
                        )
                        .shadow(color: visorColor.opacity(0.4), radius: 6)

                    if showsDragPill {
                        HStack(spacing: 5) {
                            Image(systemName: positionStore.isDragging ? "arrow.up.and.down.and.arrow.left.and.right" : "lock.open.fill")
                                .font(.system(size: 8))
                            Text(positionStore.isDragging ? "DRAGGING" : "DRAG • ⎋ ESC / RIGHT-CLICK TO LOCK")
                                .font(.system(size: 8, weight: .bold, design: .monospaced))
                            if positionStore.isPositionUnlocked {
                                Button(action: { positionStore.lockPosition() }) {
                                    HStack(spacing: 3) {
                                        Image(systemName: "lock.fill")
                                            .font(.system(size: 7))
                                        Text("LOCK")
                                            .font(.system(size: 7, weight: .heavy, design: .monospaced))
                                    }
                                    .padding(.horizontal, 5)
                                    .padding(.vertical, 2)
                                    .background(Capsule().fill(visorColor))
                                    .foregroundStyle(Color.black)
                                }
                                .buttonStyle(.plain)
                            }
                        }
                        .foregroundStyle(visorColor)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(Capsule().fill(Color(red: 0.08, green: 0.09, blue: 0.13).opacity(0.92)))
                        .overlay(Capsule().stroke(visorColor.opacity(0.7), lineWidth: 1))
                        .shadow(color: visorColor.opacity(0.4), radius: 4)
                        .padding(.bottom, 10)
                    }
                }
                .allowsHitTesting(true)
            }
        }
        .scaleEffect(scaleStore.scaleFactor)
        .frame(
            width: MascotOverlayPanel.defaultPanelSize.width * scaleStore.scaleFactor,
            height: MascotOverlayPanel.defaultPanelSize.height * scaleStore.scaleFactor
        )
        .background(Color.clear)
        .contentShape(Rectangle())
        .onHover { hovering in
            isHovering = hovering
            if positionStore.isInteractivityEnabled {
                if hovering {
                    NSCursor.openHand.push()
                } else {
                    NSCursor.pop()
                }
            }
        }
        .onContinuousHover(coordinateSpace: .local) { phase in
            guard interactionSettings.isStrokeToPetEnabled, positionStore.isInteractivityEnabled else {
                strokeTracker.detector.reset()
                return
            }
            switch phase {
            case .active(let location):
                if strokeTracker.detector.feed(
                    x: Double(location.x),
                    at: ProcessInfo.processInfo.systemUptime,
                    mouseButtonsPressed: Int(NSEvent.pressedMouseButtons)
                ) {
                    engine.triggerPetInteraction()
                }
            case .ended:
                strokeTracker.detector.reset()
            }
        }
        .onDrop(of: [UTType.fileURL], isTargeted: nil) { providers in
            guard interactionSettings.isFileDropEnabled, positionStore.isInteractivityEnabled else { return false }
            final class URLAccumulator: @unchecked Sendable {
                private let lock = NSLock()
                private(set) var urls: [URL] = []
                func append(_ url: URL) {
                    lock.lock()
                    urls.append(url)
                    lock.unlock()
                }
            }
            let accumulator = URLAccumulator()
            let group = DispatchGroup()
            for provider in providers where provider.canLoadObject(ofClass: URL.self) {
                group.enter()
                _ = provider.loadObject(ofClass: URL.self) { url, _ in
                    if let url, url.isFileURL {
                        accumulator.append(url)
                    }
                    group.leave()
                }
            }
            group.notify(queue: .main) {
                if !accumulator.urls.isEmpty { onFilesDropped?(accumulator.urls) }
            }
            return !providers.isEmpty
        }
        .gesture(
            DragGesture(minimumDistance: 1, coordinateSpace: .global)
                .onChanged { gesture in
                    guard positionStore.isInteractivityEnabled else { return }
                    if !positionStore.isDragging {
                        positionStore.isDragging = true
                        NSCursor.closedHand.push()
                        dragInitialOrigin = onGetOrigin?() ?? .zero
                    }
                    guard let startOrigin = dragInitialOrigin else { return }
                    let candidateOrigin = NSPoint(
                        x: startOrigin.x + gesture.translation.width,
                        y: startOrigin.y - gesture.translation.height
                    )
                    let mouseLoc = NSEvent.mouseLocation
                    let targetScreen = NSScreen.screens.first(where: { NSPointInRect(mouseLoc, $0.frame) })
                        ?? NSScreen.main
                    let targetVisibleFrame = targetScreen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
                    let panelSize = onGetSize?() ?? MascotOverlayPanel.defaultPanelSize
                    let clamped = MascotOverlayPanel.clampOriginToVisibleFrame(
                        candidateOrigin,
                        panelSize: panelSize,
                        visibleFrame: targetVisibleFrame
                    )
                    onDragChanged?(clamped, targetScreen)
                }
                .onEnded { gesture in
                    guard positionStore.isInteractivityEnabled else { return }
                    if positionStore.isDragging {
                        NSCursor.pop()
                        positionStore.isDragging = false
                    }
                    let startOrigin = dragInitialOrigin ?? onGetOrigin?() ?? .zero
                    dragInitialOrigin = nil

                    let candidateOrigin = NSPoint(
                        x: startOrigin.x + gesture.translation.width,
                        y: startOrigin.y - gesture.translation.height
                    )
                    let mouseLoc = NSEvent.mouseLocation
                    let targetScreen = NSScreen.screens.first(where: { NSPointInRect(mouseLoc, $0.frame) })
                        ?? NSScreen.main
                    let targetVisibleFrame = targetScreen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
                    let panelSize = onGetSize?() ?? MascotOverlayPanel.defaultPanelSize
                    let finalClamped = MascotOverlayPanel.clampOriginToVisibleFrame(
                        candidateOrigin,
                        panelSize: panelSize,
                        visibleFrame: targetVisibleFrame
                    )

                    positionStore.setCustomPosition(finalClamped)
                    onDragEnded?(finalClamped, targetScreen)
                }
        )
        .onTapGesture(count: 2) {
            if positionStore.isPositionUnlocked {
                positionStore.lockPosition()
            } else {
                onOpenSettings?()
            }
        }
        .contextMenu {
            Button {
                onOpenSettings?()
            } label: {
                Label("Settings...", systemImage: "gearshape.fill")
            }

            Button {
                positionStore.toggleMascotVisibility()
            } label: {
                Label(positionStore.isMascotVisible ? "Hide Mascot" : "Show Mascot", systemImage: positionStore.isMascotVisible ? "eye.slash" : "eye")
            }

            Divider()

            if positionStore.isPositionUnlocked {
                Button {
                    positionStore.lockPosition()
                } label: {
                    Label("Lock Position [⎋ Esc]", systemImage: "lock.fill")
                }
                .accessibilityLabel("Lock Position")
            } else {
                Button {
                    positionStore.unlockPosition()
                } label: {
                    Label("Unlock Position (Drag)", systemImage: "lock.open.fill")
                }
            }

            Button {
                positionStore.resetToDefaultCorner()
            } label: {
                Label("Reset to Default Corner", systemImage: "arrow.counterclockwise")
            }

            Divider()

            Button(role: .destructive) {
                NSApplication.shared.terminate(nil)
            } label: {
                Label("Quit Bitz", systemImage: "power")
            }
        }
        .allowsHitTesting(positionStore.isInteractivityEnabled)
    }
}

private struct MascotCyberHUDContainerView: View {
    @ObservedObject var telemetryDashboard: TelemetryDashboardService
    let enabledMetrics: Set<TelemetryMetric>
    let focusPoints: Double
    let visorColor: Color
    let opacity: Double

    var body: some View {
        let hudText = telemetryDashboard.snapshot.hudSummary(
            enabledMetrics: enabledMetrics,
            focusPoints: focusPoints
        )
        let hasWarning = telemetryDashboard.snapshot.hasActiveWarning
        let hudBorderColor = hasWarning ? Color.orange : visorColor

        MascotCyberHUDPillView(
            hudText: hudText,
            hasWarning: hasWarning,
            hudBorderColor: hudBorderColor,
            opacity: opacity
        )
        .equatable()
    }
}

private struct MascotCyberHUDPillView: View, Equatable {
    let hudText: String
    let hasWarning: Bool
    let hudBorderColor: Color
    let opacity: Double

    var body: some View {
        Text(hudText)
            .font(.system(size: 8.5, weight: .bold, design: .monospaced))
            .multilineTextAlignment(.center)
            .lineLimit(4)
            .foregroundStyle(hudBorderColor)
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
            .background(
                RoundedRectangle(cornerRadius: 7)
                    .fill(Color(red: 0.05, green: 0.06, blue: 0.08).opacity(0.92))
                    .shadow(color: hudBorderColor.opacity(0.35), radius: 5)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 7)
                    .stroke(hudBorderColor.opacity(hasWarning ? 0.95 : 0.65), lineWidth: 1.2)
            )
            .padding(.bottom, 4)
            // Drag pill takes over this slot in drag mode; opacity keeps the layout stable
            .opacity(opacity)
    }
}
