import SwiftUI

/// SwiftUI view hosted inside `MascotOverlayPanel`, rendering the transparent
/// cyberpunk mascot canvas, reactive LED visor glow, and standby `"ZZZ"` badge (`FR-001`, `FR-003`).
/// Speech bubbles live in `SpeechBubbleView` inside the panel's `SpeechBubblePanel` (#61).
public struct MascotOverlayView: View {
    @ObservedObject public var engine: WellnessPointEngine
    @ObservedObject public var scaleStore: AvatarScaleStore
    @ObservedObject public var opacityStore: AvatarOpacityStore
    @ObservedObject public var positionStore: AvatarPositionStore
    @ObservedObject public var telemetryDashboard: TelemetryDashboardService
    @ObservedObject public var telemetrySettings: TelemetrySettingsStore

    public var onDragChanged: ((NSPoint, NSScreen?) -> Void)?
    public var onDragEnded: ((NSPoint, NSScreen?) -> Void)?
    public var onGetOrigin: (() -> NSPoint?)?
    public var onGetSize: (() -> NSSize)?
    public var onOpenSettings: (() -> Void)?
    /// Reports how far below the 250 pt canvas top Bitz's ear tips sit (unscaled pt), so the speech bubble can sit just above them.
    public var onEarTopChanged: ((CGFloat) -> Void)?

    @State private var dragInitialOrigin: NSPoint? = nil
    @State private var isHovering: Bool = false

    private static let canvasSpace = "mascotCanvas"

    public init(
        engine: WellnessPointEngine,
        scaleStore: AvatarScaleStore = AvatarScaleStore(),
        opacityStore: AvatarOpacityStore = AvatarOpacityStore(),
        positionStore: AvatarPositionStore = AvatarPositionStore(),
        telemetryDashboard: TelemetryDashboardService = TelemetryDashboardService(),
        telemetrySettings: TelemetrySettingsStore = TelemetrySettingsStore(),
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

    private var visorColor: Color {
        Self.visorColor(for: engine.currentState, warningVisorActive: engine.isWarningVisorActive)
    }

    private var animationSpeedMultiplier: Double {
        switch engine.currentState {
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
        engine.currentState == .burnout || engine.currentState == .charging
    }

    // Holding ⌥ alone only shows the border, so typing ⌥ shortcuts in other apps doesn't flash the HUD
    private var showsDragPill: Bool {
        positionStore.isPositionUnlocked || positionStore.isDragging
    }

    public var body: some View {
        // 30 fps is plenty for breathing/blink; the uncapped display rate cost ~25-30% of a core at idle (#10)
        TimelineView(.animation(minimumInterval: 1.0 / 30.0)) { timeline in
            let t = timeline.date.timeIntervalSinceReferenceDate
            let _ = telemetryDashboard.fpsTracker.recordFrame(timestamp: t)

            // Periodic natural eye-blink (every ~4.2s for ~0.15s)
            let blinkRemainder = t.truncatingRemainder(dividingBy: 4.2)
            let isBlinking = blinkRemainder < 0.16 && !isLoafPosture && engine.currentState != .overheating && !engine.isPetReactionActive
            // Read on the main actor: the geometry transform below is a Sendable closure
            let canvasSpace = Self.canvasSpace
            let earOverflow = BitzCharacterView.earOverflow(isLoafPosture: isLoafPosture)

            VStack(spacing: 6) {
                Spacer(minLength: 0)

                // Mascot Composition with user-selected see-through opacity
                BitzCharacterView(
                    state: engine.currentState,
                    time: t,
                    isBlinking: isBlinking,
                    isPetReactionActive: engine.isPetReactionActive,
                    isLoafPosture: isLoafPosture,
                    showParticles: true,
                    customVisorColor: visorColor
                )
                .opacity(opacityStore.opacityFactor)
                // Layout frame excludes the breathing offset, so this only fires when the HUD or posture changes
                .onGeometryChange(for: CGFloat.self) { proxy in
                    proxy.frame(in: .named(canvasSpace)).minY - earOverflow
                } action: { earTop in
                    onEarTopChanged?(earTop)
                }

                // Live Cyberpunk Hardware Telemetry & Diagnostics HUD
                if telemetrySettings.displayInMascotCyberHUD {
                    let hudText = telemetryDashboard.snapshot.hudSummary(
                        enabledMetrics: telemetrySettings.enabledMetrics,
                        focusPoints: engine.currentPoints
                    )
                    let hasWarning = telemetryDashboard.snapshot.hasActiveWarning
                    let hudBorderColor = hasWarning ? Color.orange : visorColor

                    Text(hudText)
                        .font(.system(size: 8.5, weight: .bold, design: .monospaced))
                        .multilineTextAlignment(.center)
                        .lineLimit(2)
                        .foregroundStyle(hudBorderColor)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 4)
                        .background(
                            RoundedRectangle(cornerRadius: 7)
                                .fill(Color(red: 0.05, green: 0.06, blue: 0.08).opacity(0.92))
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 7)
                                .stroke(hudBorderColor.opacity(hasWarning ? 0.95 : 0.65), lineWidth: 1.2)
                        )
                        .shadow(color: hudBorderColor.opacity(0.35), radius: 5)
                        .padding(.bottom, 4)
                        // Drag pill takes over this slot in drag mode; opacity keeps the layout stable
                        .opacity(showsDragPill ? 0 : max(0.6, opacityStore.opacityFactor))
                } else {
                    Spacer().frame(height: 10)
                }
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
