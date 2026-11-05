import AppKit
import QuartzCore
import SwiftUI

/// Triangle shape used for Bitz's pointed cybernetic cat ears.
public struct CyberEarShape: Shape {
    public init() {}

    public func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.midX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.minX, y: rect.maxY))
        path.closeSubpath()
        return path
    }
}

/// Floating ambient particle overlays for Bitz's states (neon sparks, binary focus bits, sleepy ZZZs, steam puffs).
public struct AmbientParticlesOverlay: View {
    public let state: BitzState
    public let color: Color
    public let time: TimeInterval

    public init(state: BitzState, color: Color, time: TimeInterval) {
        self.state = state
        self.color = color
        self.time = time
    }

    public var body: some View {
        ZStack {
            switch state {
            case .superCharged:
                ForEach(0..<4, id: \.self) { i in
                    let offsetPhase = (time * 1.5 + Double(i) * 0.75).truncatingRemainder(dividingBy: 2.0)
                    let xOffset = (i == 0 ? -36.0 : (i == 1 ? 42.0 : (i == 2 ? -54.0 : 38.0))) + sin(time * 3.0 + Double(i)) * 6.0
                    let yOffset = -20.0 - (offsetPhase * 45.0)
                    let opacity = max(0.0, 1.0 - (offsetPhase / 2.0))
                    ZStack {
                        Circle()
                            .fill(color.opacity(0.28))
                            .frame(width: 9, height: 9)
                        Circle()
                            .fill(color)
                            .frame(width: 3.5, height: 3.5)
                    }
                    .offset(x: xOffset, y: yOffset)
                    .opacity(opacity)
                }

            case .balanced:
                ForEach(0..<3, id: \.self) { i in
                    let phase = (time * 0.8 + Double(i) * 0.9).truncatingRemainder(dividingBy: 2.5)
                    let xOffset = (i == 0 ? -42.0 : (i == 1 ? 50.0 : 20.0)) + sin(time * 1.5 + Double(i)) * 4.0
                    let yOffset = -25.0 - (phase * 30.0)
                    let opacity = max(0.0, 1.0 - (phase / 2.5))
                    Text(i % 2 == 0 ? "1" : "0")
                        .font(.system(size: 8, weight: .bold, design: .monospaced))
                        .foregroundStyle(color)
                        .offset(x: xOffset, y: yOffset)
                        .opacity(opacity)
                }

            case .charging, .burnout:
                ForEach(0..<3, id: \.self) { i in
                    let phase = (time * 0.6 + Double(i) * 1.0).truncatingRemainder(dividingBy: 3.0)
                    let xOffset = 30.0 + Double(i * 12) + sin(time * 1.2 + Double(i)) * 5.0
                    let yOffset = -35.0 - (phase * 35.0)
                    let opacity = max(0.0, 1.0 - (phase / 3.0))
                    Text(i == 0 ? "z" : (i == 1 ? "Z" : "Zz"))
                        .font(.system(size: CGFloat(8 + i * 2), weight: .bold, design: .rounded))
                        .foregroundStyle(color)
                        .offset(x: xOffset, y: yOffset)
                        .opacity(opacity)
                }

            case .overheating:
                ForEach(0..<4, id: \.self) { i in
                    let phase = (time * 2.2 + Double(i) * 0.6).truncatingRemainder(dividingBy: 1.5)
                    let isLeftEar = i % 2 == 0
                    let xOffset = (isLeftEar ? -34.0 : 34.0) + sin(time * 4.0 + Double(i)) * 5.0
                    let yOffset = -70.0 - (phase * 35.0)
                    let opacity = max(0.0, 0.85 - (phase / 1.5))
                    Circle()
                        .fill(Color(white: 0.85).opacity(0.6))
                        .frame(width: 6 + phase * 8, height: 6 + phase * 8)
                        .offset(x: xOffset, y: yOffset)
                        .opacity(opacity)
                }

            case .dopamineSad, .overworked:
                EmptyView()
            }
        }
        .frame(width: 180, height: 155, alignment: .bottom)
        .padding(.bottom, 5)
        .allowsHitTesting(false)
    }
}

/// Standalone reusable view representing the core Bitz cybernetic cat figure
/// with its signature pointed cyber ears, wrap-around LED visor, body, paws, and glowing tail.
public struct BitzCharacterView: View {
    public let state: BitzState
    public let time: TimeInterval
    public let isBlinking: Bool
    public let isPetReactionActive: Bool
    public let isLoafPosture: Bool
    public let showParticles: Bool
    public let customVisorColor: Color?
    public let palette: AvatarResolvedPalette
    public let isRecordingMeeting: Bool

    public init(
        state: BitzState = .balanced,
        time: TimeInterval = 0,
        isBlinking: Bool = false,
        isPetReactionActive: Bool = false,
        isLoafPosture: Bool? = nil,
        showParticles: Bool = true,
        customVisorColor: Color? = nil,
        palette: AvatarResolvedPalette = .cyberpunkClassic,
        isRecordingMeeting: Bool = false
    ) {
        self.palette = palette
        self.state = state
        self.time = time
        self.isBlinking = isBlinking
        self.isPetReactionActive = isPetReactionActive
        self.isLoafPosture = isLoafPosture ?? BitzCharacterView.isLoaf(state: state, isRecording: isRecordingMeeting)
        self.showParticles = showParticles
        self.customVisorColor = customVisorColor
        self.isRecordingMeeting = isRecordingMeeting
    }

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

    /// Bitz lies down as a loaf in burnout and while charging, but sits up with headphones on while recording a meeting.
    public static func isLoaf(state: BitzState, isRecording: Bool) -> Bool {
        !isRecording && (state == .burnout || state == .charging)
    }

    /// How far the head & ears assembly is lifted above its resting place in the frame.
    static func headLift(isLoafPosture: Bool) -> CGFloat {
        isLoafPosture ? 22 : 44
    }

    /// How far the ear tips rise above this view's 140 pt-high frame at rest (breathing adds up to 4.5 pt).
    /// The 116 pt ears-and-head stack sits centered in the frame, 12 pt below its top, before the lift.
    public static func earOverflow(isLoafPosture: Bool) -> CGFloat {
        headLift(isLoafPosture: isLoafPosture) - 12
    }

    public var visorColor: Color {
        if let custom = customVisorColor {
            return custom
        }
        let rgb = Self.visorRGB(for: state)
        return Color(red: rgb.red, green: rgb.green, blue: rgb.blue)
    }

    public var animationSpeedMultiplier: Double {
        switch state {
        case .superCharged: return 2.0
        case .balanced: return 1.0
        case .dopamineSad: return 0.35
        case .overworked: return 0.4
        case .burnout: return 0.0
        case .charging: return 0.6
        case .overheating: return 2.5
        }
    }

    public var body: some View {
        let breathOffset = sin(time * 2.8 * animationSpeedMultiplier) * (state == .burnout ? 0.0 : 4.5)
        let glitchOffsetX = state == .overheating ? sin(time * 45.0) * 3.0 : 0.0

        ZStack(alignment: .bottom) {
            // Glowing cybernetic tail on the right
            Capsule()
                .fill(palette.chassisColor)
                .frame(width: 48, height: 14)
                .overlay(
                    Capsule()
                        .stroke(palette.trim(over: visorColor).opacity(0.85), lineWidth: 2)
                )
                .rotationEffect(.degrees(isLoafPosture ? 0 : -22 + sin(time * 3.2 * animationSpeedMultiplier) * 10))
                .offset(x: 64, y: -14)

            // Compact cyber-cat body / loaf base (time-invariant subtree skipped via Equatable #70)
            MascotTorsoView(state: state, isLoafPosture: isLoafPosture, visorColor: visorColor, palette: palette)
                .equatable()
                .frame(width: isLoafPosture ? 136 : 108, height: isLoafPosture ? 54 : 68)

            // Front Paws (with subtle sway/trot motion when standing)
            if !isLoafPosture {
                let pawSway = sin(time * 3.0 * animationSpeedMultiplier) * 2.0
                HStack(spacing: 28) {
                    Capsule()
                        .fill(palette.chassisColor)
                        .frame(width: 18, height: 10)
                        .overlay(Capsule().stroke(palette.trim(over: visorColor).opacity(0.65), lineWidth: 1))
                        .transformEffect(CGAffineTransform(translationX: 0, y: pawSway))
                    Capsule()
                        .fill(palette.chassisColor)
                        .frame(width: 18, height: 10)
                        .overlay(Capsule().stroke(palette.trim(over: visorColor).opacity(0.65), lineWidth: 1))
                        .transformEffect(CGAffineTransform(translationX: 0, y: -pawSway))
                }
                .frame(width: 64, height: 10)
                .offset(y: -4)
                .zIndex(2)
            }

            // Head & Ears Assembly (time-invariant subtree skipped via Equatable #70)
            MascotHeadAssemblyView(
                state: state,
                isLoafPosture: isLoafPosture,
                isBlinking: isBlinking,
                isPetReactionActive: isPetReactionActive,
                visorColor: visorColor,
                palette: palette,
                isRecordingMeeting: isRecordingMeeting
            )
            .equatable()
            .frame(width: 132, height: 116)
            .offset(y: -Self.headLift(isLoafPosture: isLoafPosture))
        }
        .background(alignment: .bottom) {
            if showParticles {
                AmbientParticlesOverlay(state: state, color: visorColor, time: time)
            }
        }
        .transformEffect(CGAffineTransform(translationX: glitchOffsetX, y: breathOffset))
        .frame(width: 180, height: 140)
    }
}

private struct MascotTorsoView: View, Equatable {
    let state: BitzState
    let isLoafPosture: Bool
    let visorColor: Color
    let palette: AvatarResolvedPalette

    var body: some View {
        RoundedRectangle(cornerRadius: 28)
            .fill(palette.chassisDeepColor)
            .frame(width: isLoafPosture ? 136 : 108, height: isLoafPosture ? 54 : 68)
            .overlay(
                RoundedRectangle(cornerRadius: 28)
                    .stroke(palette.trim(over: visorColor).opacity(0.45), lineWidth: 1.5)
            )
            .overlay(
                // Chest neon core emblem
                Circle()
                    .fill(visorColor.opacity(state == .burnout ? 0.3 : 0.9))
                    .frame(width: 12, height: 12)
                    .shadow(color: visorColor, radius: 6 * palette.glowScale)
                    .offset(y: 6)
            )
    }
}

private struct MascotHeadAssemblyView: View, Equatable {
    let state: BitzState
    let isLoafPosture: Bool
    let isBlinking: Bool
    let isPetReactionActive: Bool
    let visorColor: Color
    let palette: AvatarResolvedPalette
    let isRecordingMeeting: Bool
    /// Only the live CoreAnimation path pulses; the static `ImageRenderer` path stays pure SwiftUI.
    var pulsesRecordingLED: Bool = false

    var body: some View {
        let earTilt = (state == .overworked || state == .dopamineSad) ? 14.0 : 0.0

        VStack(spacing: -10) {
            // Pointed Cybernetic Cat Ears
            HStack(spacing: 48) {
                ZStack {
                    CyberEarShape()
                        .fill(palette.chassisColor)
                        .frame(width: 36, height: 34)
                    CyberEarShape()
                        .fill(visorColor.opacity(0.85))
                        .frame(width: 18, height: 18)
                        .offset(y: 4)
                }
                .rotationEffect(.degrees(-8 - earTilt))

                ZStack {
                    CyberEarShape()
                        .fill(palette.chassisColor)
                        .frame(width: 36, height: 34)
                    CyberEarShape()
                        .fill(visorColor.opacity(0.85))
                        .frame(width: 18, height: 18)
                        .offset(y: 4)
                }
                .rotationEffect(.degrees(8 + earTilt))
            }
            .zIndex(0)

            // Matte charcoal cyber-cat head (#1A1A1D)
            // Apply shadow directly to the filled RoundedRectangle before stroke overlay to avoid CPU path unioning (#70)
            ZStack {
                RoundedRectangle(cornerRadius: 34)
                    .fill(palette.chassisColor)
                    .frame(width: 132, height: 92)
                    .shadow(color: visorColor.opacity(0.35), radius: 8 * palette.glowScale)
                    .overlay(
                        RoundedRectangle(cornerRadius: 34)
                            .stroke(palette.trim(over: visorColor).opacity(0.75), lineWidth: 2)
                    )

                // Wrap-around glossy black LED visor
                RoundedRectangle(cornerRadius: 18)
                    .fill(Color(red: 0.04, green: 0.04, blue: 0.06))
                    .frame(width: 108, height: 46)
                    .overlay(
                        RoundedRectangle(cornerRadius: 18)
                            .stroke(palette.trim(over: visorColor).opacity(0.5), lineWidth: 1)
                    )
                    .overlay(
                        visorContent
                    )

                if isRecordingMeeting {
                    CyberHeadphonesOverlay(visorColor: visorColor, palette: palette, pulsesLED: pulsesRecordingLED)
                }
            }
            .zIndex(1)
        }
    }

    @ViewBuilder
    private var visorContent: some View {
        if isPetReactionActive {
            Text("<3  <3")
                .font(.system(size: 18, weight: .heavy, design: .monospaced))
                .foregroundStyle(palette.color(for: .petting))
                .shadow(color: palette.color(for: .petting), radius: 6 * palette.glowScale)
        } else if isBlinking {
            // Natural blink slit
            HStack(spacing: 24) {
                Capsule()
                    .fill(visorColor)
                    .frame(width: 18, height: 3)
                Capsule()
                    .fill(visorColor)
                    .frame(width: 18, height: 3)
            }
            .shadow(color: visorColor, radius: 4 * palette.glowScale)
        } else if state == .charging {
            Text("⚡ Z Z")
                .font(.system(size: 17, weight: .heavy, design: .monospaced))
                .foregroundStyle(visorColor)
                .shadow(color: visorColor, radius: 6 * palette.glowScale)
        } else if state == .burnout {
            Text("X  X")
                .font(.system(size: 19, weight: .heavy, design: .monospaced))
                .foregroundStyle(visorColor.opacity(0.85))
        } else if state == .dopamineSad {
            Text("T  T")
                .font(.system(size: 19, weight: .heavy, design: .monospaced))
                .foregroundStyle(visorColor)
                .shadow(color: visorColor, radius: 6 * palette.glowScale)
        } else if state == .overheating {
            Text(">  <")
                .font(.system(size: 20, weight: .heavy, design: .monospaced))
                .foregroundStyle(visorColor)
                .shadow(color: visorColor, radius: 6 * palette.glowScale)
        } else if state == .superCharged {
            Text("^  ^")
                .font(.system(size: 21, weight: .heavy, design: .monospaced))
                .foregroundStyle(visorColor)
                .shadow(color: visorColor, radius: 8 * palette.glowScale)
        } else if state == .overworked {
            HStack(spacing: 24) {
                Rectangle()
                    .fill(visorColor)
                    .frame(width: 20, height: 5)
                Rectangle()
                    .fill(visorColor)
                    .frame(width: 20, height: 5)
            }
            .shadow(color: visorColor, radius: 4 * palette.glowScale)
        } else {
            HStack(spacing: 24) {
                Capsule()
                    .fill(visorColor)
                    .frame(width: 18, height: 11)
                Capsule()
                    .fill(visorColor)
                    .frame(width: 18, height: 11)
            }
            .shadow(color: visorColor, radius: 6 * palette.glowScale)
        }
    }
}

/// Holographic cyber-headphones with a red recording indicator LED worn by Bitz during active meeting capture (#43).
/// Entirely contained within the 132×92 pt head chassis so `earOverflow` and window bounds are never exceeded.
private struct CyberHeadphonesOverlay: View {
    let visorColor: Color
    let palette: AvatarResolvedPalette
    let pulsesLED: Bool

    private static let recRed = Color(red: 1.0, green: 0.16, blue: 0.22)

    var body: some View {
        ZStack {
            // Top headband arc resting along the upper crown of the head
            Capsule()
                .fill(palette.chassisDeepColor)
                .frame(width: 96, height: 6)
                .overlay(
                    Capsule()
                        .stroke(visorColor.opacity(0.85), lineWidth: 1.5)
                )
                .offset(y: -40)

            // Left & right cyber earcups flanking the visor
            HStack(spacing: 104) {
                RoundedRectangle(cornerRadius: 5)
                    .fill(palette.chassisDeepColor)
                    .frame(width: 10, height: 32)
                    .overlay(
                        RoundedRectangle(cornerRadius: 5)
                            .stroke(visorColor.opacity(0.9), lineWidth: 1.5)
                    )

                RoundedRectangle(cornerRadius: 5)
                    .fill(palette.chassisDeepColor)
                    .frame(width: 10, height: 32)
                    .overlay(
                        RoundedRectangle(cornerRadius: 5)
                            .stroke(visorColor.opacity(0.9), lineWidth: 1.5)
                    )
            }
            .offset(y: 2)

            // Boom mic arm + glowing red recording LED dot on the right cheek
            Capsule()
                .fill(visorColor.opacity(0.75))
                .frame(width: 20, height: 2.5)
                .rotationEffect(.degrees(-18))
                .offset(x: 47, y: 20)

            ZStack {
                Circle()
                    .fill(Self.recRed.opacity(0.35))
                    .frame(width: 11, height: 11)
                Circle()
                    .fill(Self.recRed)
                    .frame(width: 6, height: 6)
            }
            // Out-of-process opacity pulse (#43): WindowServer interpolates, 0% app CPU (AGENTS.md §2.1)
            .background(CALayerMotionBridge(kind: pulsesLED ? .opacityPulse(minOpacity: 0.25, halfPeriod: 0.7) : .none))
            .compositingGroup()
            .offset(x: 36, y: 24)
        }
        .frame(width: 132, height: 92)
        .allowsHitTesting(false)
    }
}

/// CoreAnimation-offloaded live mascot character view (#70).
/// Delegates continuous breathing, tail wag, paw sway, overheating glitch, and ambient particle drift
/// to out-of-process CoreAnimation layer animations (`0` per-frame CPU wakeups), waking the main thread
/// only twice every 4.2s for discrete natural eye-blinks.
public struct LiveBitzCharacterView: View {
    public let state: BitzState
    public let isPetReactionActive: Bool
    public let isLoafPosture: Bool
    public let showParticles: Bool
    public let customVisorColor: Color?
    public let isPaused: Bool
    public let palette: AvatarResolvedPalette
    public let isAttentionCueActive: Bool
    public let isRecordingMeeting: Bool

    @State private var isBlinking: Bool = false

    private struct MotionStageKey: Hashable {
        let state: BitzState
        let isLoafPosture: Bool
        let showParticles: Bool
        let isAttentionCueActive: Bool
        let isRecordingMeeting: Bool
    }

    public init(
        state: BitzState = .balanced,
        isPetReactionActive: Bool = false,
        isLoafPosture: Bool? = nil,
        showParticles: Bool = true,
        customVisorColor: Color? = nil,
        isPaused: Bool = false,
        palette: AvatarResolvedPalette = .cyberpunkClassic,
        isAttentionCueActive: Bool = false,
        isRecordingMeeting: Bool = false
    ) {
        self.palette = palette
        self.state = state
        self.isPetReactionActive = isPetReactionActive
        self.isLoafPosture = isLoafPosture ?? BitzCharacterView.isLoaf(state: state, isRecording: isRecordingMeeting)
        self.showParticles = showParticles
        self.customVisorColor = customVisorColor
        self.isPaused = isPaused
        self.isAttentionCueActive = isAttentionCueActive
        self.isRecordingMeeting = isRecordingMeeting
    }

    private var visorColor: Color {
        if let custom = customVisorColor {
            return custom
        }
        let rgb = BitzCharacterView.visorRGB(for: state)
        return Color(red: rgb.red, green: rgb.green, blue: rgb.blue)
    }

    public var body: some View {
        let shouldPause = isPaused || (state == .burnout && !showParticles && !isRecordingMeeting)
        let canBlink = !shouldPause && !isLoafPosture && state != .overheating && !isPetReactionActive

        Group {
            if shouldPause {
                BitzCharacterView(
                    state: state,
                    time: 0,
                    isBlinking: false,
                    isPetReactionActive: isPetReactionActive,
                    isLoafPosture: isLoafPosture,
                    showParticles: false,
                    customVisorColor: customVisorColor,
                    palette: palette,
                    isRecordingMeeting: isRecordingMeeting
                )
            } else {
                LiveMotionStageView(
                    state: state,
                    isBlinking: isBlinking,
                    isPetReactionActive: isPetReactionActive,
                    isLoafPosture: isLoafPosture,
                    showParticles: showParticles,
                    visorColor: visorColor,
                    palette: palette,
                    isAttentionCueActive: isAttentionCueActive,
                    isRecordingMeeting: isRecordingMeeting
                )
                .id(MotionStageKey(
                    state: state,
                    isLoafPosture: isLoafPosture,
                    showParticles: showParticles,
                    isAttentionCueActive: isAttentionCueActive,
                    isRecordingMeeting: isRecordingMeeting
                ))
            }
        }
        .frame(width: 180, height: 140)
        .task(id: canBlink) {
            isBlinking = false
            guard canBlink else { return }
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 4_020_000_000)
                guard !Task.isCancelled else { break }
                isBlinking = true
                try? await Task.sleep(nanoseconds: 180_000_000)
                guard !Task.isCancelled else { break }
                isBlinking = false
            }
        }
    }
}

private struct LiveMotionStageView: View {
    let state: BitzState
    let isBlinking: Bool
    let isPetReactionActive: Bool
    let isLoafPosture: Bool
    let showParticles: Bool
    let visorColor: Color
    let palette: AvatarResolvedPalette
    let isAttentionCueActive: Bool
    let isRecordingMeeting: Bool

    private var speedMultiplier: Double {
        switch state {
        case .superCharged: return 2.0
        case .balanced: return 1.0
        case .dopamineSad: return 0.35
        case .overworked: return 0.4
        case .burnout: return 0.0
        case .charging: return 0.6
        case .overheating: return 2.5
        }
    }

    var body: some View {
        let speed = speedMultiplier
        let hasMotion = speed > 0

        ZStack(alignment: .bottom) {
            // Glowing cybernetic tail on the right (wags via out-of-process CALayer transform animation)
            Capsule()
                .fill(palette.chassisColor)
                .frame(width: 48, height: 14)
                .overlay(
                    Capsule()
                        .stroke(palette.trim(over: visorColor).opacity(0.85), lineWidth: 2)
                )
                .rotationEffect(.degrees(isLoafPosture ? 0 : -22))
                .background(
                    CALayerMotionBridge(
                        kind: (!isLoafPosture && hasMotion)
                            ? .tailWag(halfPeriod: 0.98 / speed, deltaRadians: 10.0 * .pi / 180.0, center: CGPoint(x: 24, y: 7))
                            : .none
                    )
                )
                .compositingGroup()
                .offset(x: 64, y: -14)

            // Static torso subtree
            MascotTorsoView(state: state, isLoafPosture: isLoafPosture, visorColor: visorColor, palette: palette)
                .equatable()
                .frame(width: isLoafPosture ? 136 : 108, height: isLoafPosture ? 54 : 68)

            // Front Paws (sway in opposite phase via out-of-process CALayer translation animations, or paw-tap on .needsApproval)
            if !isLoafPosture {
                HStack(spacing: 28) {
                    Capsule()
                        .fill(palette.chassisColor)
                        .frame(width: 18, height: 10)
                        .overlay(Capsule().stroke(palette.trim(over: visorColor).opacity(0.65), lineWidth: 1))
                        .background(
                            CALayerMotionBridge(
                                kind: isAttentionCueActive
                                    ? .pawTap(amplitude: 3.0, halfPeriod: 0.22)
                                    : (hasMotion ? .verticalSway(amplitude: 1.8, halfPeriod: 1.05 / speed) : .none)
                            )
                        )
                        .compositingGroup()

                    Capsule()
                        .fill(palette.chassisColor)
                        .frame(width: 18, height: 10)
                        .overlay(Capsule().stroke(palette.trim(over: visorColor).opacity(0.65), lineWidth: 1))
                        .background(
                            CALayerMotionBridge(
                                kind: isAttentionCueActive
                                    ? .pawTap(amplitude: -3.0, halfPeriod: 0.22)
                                    : (hasMotion ? .verticalSway(amplitude: -1.8, halfPeriod: 1.05 / speed) : .none)
                            )
                        )
                        .compositingGroup()
                }
                .frame(width: 64, height: 10)
                .offset(y: -4)
                .zIndex(2)
            }

            // Head & Ears Assembly
            MascotHeadAssemblyView(
                state: state,
                isLoafPosture: isLoafPosture,
                isBlinking: isBlinking,
                isPetReactionActive: isPetReactionActive,
                visorColor: visorColor,
                palette: palette,
                isRecordingMeeting: isRecordingMeeting,
                pulsesRecordingLED: true
            )
            .equatable()
            .frame(width: 132, height: 116)
            .offset(y: -BitzCharacterView.headLift(isLoafPosture: isLoafPosture))
        }
        .background(alignment: .bottom) {
            if showParticles {
                CoreAnimationParticlesView(state: state, rgb: BitzCharacterView.visorRGB(for: state), customColor: visorColor)
                    .frame(width: 180, height: 155)
                    .allowsHitTesting(false)
            }
        }
        .frame(width: 180, height: 140)
        .background(
            CALayerMotionBridge(
                kind: hasMotion
                    ? .breathing(
                        liftY: -3.5,
                        halfPeriod: 1.12 / speed,
                        glitchAmplitudeX: state == .overheating ? 2.5 : 0.0
                    )
                    : .none
            )
        )
        .compositingGroup()
    }
}

/// Attaches pure CoreAnimation `CABasicAnimation`s directly onto the enclosing `.compositingGroup()` backing `CALayer`,
/// bypassing SwiftUI's `AttributeGraph` / `NSDisplayLink` so WindowServer interpolates at 0% app CPU (#70).
struct CALayerMotionBridge: NSViewRepresentable {
    enum Kind: Equatable {
        case none
        case breathing(liftY: CGFloat, halfPeriod: Double, glitchAmplitudeX: CGFloat)
        case verticalSway(amplitude: CGFloat, halfPeriod: Double)
        case tailWag(halfPeriod: Double, deltaRadians: CGFloat, center: CGPoint)
        case pawTap(amplitude: CGFloat, halfPeriod: Double)
        case opacityPulse(minOpacity: Float, halfPeriod: Double)
    }

    let kind: Kind

    final class AnchorView: NSView {
        var currentKind: Kind?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            applyIfPossible()
        }

        func applyIfPossible() {
            guard window != nil,
                  let groupView = superview?.superview,
                  groupView !== window?.contentView,
                  let layer = groupView.layer else {
                return
            }
            groupView.clipsToBounds = false
            layer.masksToBounds = false
            layer.removeAnimation(forKey: "bitz.motion.primary")
            layer.removeAnimation(forKey: "bitz.motion.glitch")

            guard let kind = currentKind else { return }
            switch kind {
            case .none:
                break

            case let .breathing(liftY, halfPeriod, glitchAmplitudeX):
                let breath = CABasicAnimation(keyPath: "transform.translation.y")
                breath.fromValue = 0.0
                breath.toValue = liftY
                breath.duration = halfPeriod
                breath.autoreverses = true
                breath.repeatCount = .infinity
                breath.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                breath.isRemovedOnCompletion = false
                layer.add(breath, forKey: "bitz.motion.primary")

                if glitchAmplitudeX > 0 {
                    let glitch = CABasicAnimation(keyPath: "transform.translation.x")
                    glitch.fromValue = -glitchAmplitudeX
                    glitch.toValue = glitchAmplitudeX
                    glitch.duration = 0.07
                    glitch.autoreverses = true
                    glitch.repeatCount = .infinity
                    glitch.timingFunction = CAMediaTimingFunction(name: .linear)
                    glitch.isRemovedOnCompletion = false
                    layer.add(glitch, forKey: "bitz.motion.glitch")
                }

            case let .verticalSway(amplitude, halfPeriod):
                let sway = CABasicAnimation(keyPath: "transform.translation.y")
                sway.fromValue = -amplitude
                sway.toValue = amplitude
                sway.duration = halfPeriod
                sway.autoreverses = true
                sway.repeatCount = .infinity
                sway.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                sway.isRemovedOnCompletion = false
                layer.add(sway, forKey: "bitz.motion.primary")

            case let .tailWag(halfPeriod, deltaRadians, center):
                let identity = CATransform3DIdentity
                var rotated = CATransform3DMakeTranslation(center.x, center.y, 0)
                rotated = CATransform3DRotate(rotated, deltaRadians, 0, 0, 1)
                rotated = CATransform3DTranslate(rotated, -center.x, -center.y, 0)

                let wag = CABasicAnimation(keyPath: "transform")
                wag.fromValue = identity
                wag.toValue = rotated
                wag.duration = halfPeriod
                wag.autoreverses = true
                wag.repeatCount = .infinity
                wag.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                wag.isRemovedOnCompletion = false
                layer.add(wag, forKey: "bitz.motion.primary")

            case let .pawTap(amplitude, halfPeriod):
                let tap = CABasicAnimation(keyPath: "transform.translation.y")
                tap.fromValue = -amplitude
                tap.toValue = amplitude
                tap.duration = halfPeriod
                tap.autoreverses = true
                tap.repeatCount = .infinity
                tap.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                tap.isRemovedOnCompletion = false
                layer.add(tap, forKey: "bitz.motion.primary")

            case let .opacityPulse(minOpacity, halfPeriod):
                let pulse = CABasicAnimation(keyPath: "opacity")
                pulse.fromValue = 1.0
                pulse.toValue = minOpacity
                pulse.duration = halfPeriod
                pulse.autoreverses = true
                pulse.repeatCount = .infinity
                pulse.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                pulse.isRemovedOnCompletion = false
                layer.add(pulse, forKey: "bitz.motion.primary")
            }
        }
    }

    func makeNSView(context: Context) -> AnchorView {
        let view = AnchorView()
        view.wantsLayer = true
        view.currentKind = kind
        return view
    }

    func updateNSView(_ nsView: AnchorView, context: Context) {
        let changed = nsView.currentKind != kind
        nsView.currentKind = kind
        if changed {
            DispatchQueue.main.async { [weak nsView] in
                nsView?.applyIfPossible()
            }
        } else if nsView.superview?.superview?.layer?.animation(forKey: "bitz.motion.primary") == nil, kind != .none {
            DispatchQueue.main.async { [weak nsView] in
                nsView?.applyIfPossible()
            }
        }
    }
}

/// Pure CoreAnimation particle host (`CALayer` + `CATextLayer` + `CAAnimationGroup`) so floating sparks,
/// binary digits, sleepy ZZZs, and steam puffs animate in `WindowServer` with 0% main-thread CPU (#70).
private struct CoreAnimationParticlesView: NSViewRepresentable {
    let state: BitzState
    let rgb: (red: Double, green: Double, blue: Double)
    let customColor: Color

    final class ParticleHostView: NSView {
        var configuredState: BitzState?
        var configuredCGColor: CGColor?

        override var isFlipped: Bool { true }

        func configure(state: BitzState, cgColor: CGColor) {
            wantsLayer = true
            guard let root = layer else { return }
            root.masksToBounds = false
            root.sublayers?.forEach { $0.removeFromSuperlayer() }
            configuredState = state
            configuredCGColor = cgColor

            let scale = window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2.0
            let centerX: CGFloat = 90.0
            let bottomY: CGFloat = 150.0
            let now = CACurrentMediaTime()

            switch state {
            case .superCharged:
                let baseXs: [CGFloat] = [-36, 42, -54, 38]
                for i in 0..<4 {
                    let container = CALayer()
                    container.frame = CGRect(x: centerX + baseXs[i] - 4.5, y: bottomY - 20 - 4.5, width: 9, height: 9)

                    let halo = CALayer()
                    halo.frame = CGRect(x: 0, y: 0, width: 9, height: 9)
                    halo.cornerRadius = 4.5
                    halo.backgroundColor = cgColor.copy(alpha: 0.28)
                    container.addSublayer(halo)

                    let core = CALayer()
                    core.frame = CGRect(x: 2.75, y: 2.75, width: 3.5, height: 3.5)
                    core.cornerRadius = 1.75
                    core.backgroundColor = cgColor
                    container.addSublayer(core)

                    root.addSublayer(container)
                    addFloatFadeGroup(
                        to: container,
                        dx: (i % 2 == 0) ? 5 : -5,
                        dy: -75,
                        duration: 1.35,
                        beginTime: now + Double(i) * 0.34,
                        startOpacity: 0.95
                    )
                }

            case .balanced:
                let baseXs: [CGFloat] = [-42, 50, 20]
                for i in 0..<3 {
                    let textLayer = makeTextLayer(
                        string: i % 2 == 0 ? "1" : "0",
                        fontSize: 8,
                        monospaced: true,
                        color: cgColor,
                        scale: scale
                    )
                    textLayer.frame = CGRect(x: centerX + baseXs[i] - 6, y: bottomY - 25 - 6, width: 12, height: 12)
                    root.addSublayer(textLayer)
                    addFloatFadeGroup(
                        to: textLayer,
                        dx: (i % 2 == 0) ? 4 : -4,
                        dy: -68,
                        duration: 2.8,
                        beginTime: now + Double(i) * 0.9,
                        startOpacity: 0.9
                    )
                }

            case .charging, .burnout:
                for i in 0..<3 {
                    let symbol = i == 0 ? "z" : (i == 1 ? "Z" : "Zz")
                    let fontSize = CGFloat(8 + i * 2)
                    let textLayer = makeTextLayer(
                        string: symbol,
                        fontSize: fontSize,
                        monospaced: false,
                        color: cgColor,
                        scale: scale
                    )
                    textLayer.frame = CGRect(
                        x: centerX + 30 + CGFloat(i * 12) - 10,
                        y: bottomY - 35 - 8,
                        width: 22,
                        height: 16
                    )
                    root.addSublayer(textLayer)
                    addFloatFadeGroup(
                        to: textLayer,
                        dx: 5,
                        dy: -75,
                        duration: 3.6,
                        beginTime: now + Double(i) * 1.15,
                        startOpacity: 0.9
                    )
                }

            case .overheating:
                let steamColor = CGColor(gray: 0.85, alpha: 0.6)
                for i in 0..<4 {
                    let isLeft = (i % 2 == 0)
                    let puff = CALayer()
                    puff.frame = CGRect(
                        x: centerX + (isLeft ? -34 : 34) - 5.5,
                        y: bottomY - 70 - 5.5,
                        width: 11,
                        height: 11
                    )
                    puff.cornerRadius = 5.5
                    puff.backgroundColor = steamColor
                    root.addSublayer(puff)
                    addFloatFadeGroup(
                        to: puff,
                        dx: isLeft ? -5 : 5,
                        dy: -45,
                        duration: 0.75,
                        beginTime: now + Double(i) * 0.19,
                        startOpacity: 0.85,
                        fromScale: 0.65,
                        toScale: 1.45
                    )
                }

            case .dopamineSad, .overworked:
                break
            }
        }

        private func makeTextLayer(
            string: String,
            fontSize: CGFloat,
            monospaced: Bool,
            color: CGColor,
            scale: CGFloat
        ) -> CATextLayer {
            let layer = CATextLayer()
            let font = monospaced
                ? NSFont.monospacedSystemFont(ofSize: fontSize, weight: .bold)
                : NSFont.systemFont(ofSize: fontSize, weight: .bold)
            layer.font = font
            layer.fontSize = fontSize
            layer.string = string
            layer.foregroundColor = color
            layer.alignmentMode = .center
            layer.contentsScale = scale
            return layer
        }

        private func addFloatFadeGroup(
            to layer: CALayer,
            dx: CGFloat,
            dy: CGFloat,
            duration: Double,
            beginTime: CFTimeInterval,
            startOpacity: Float,
            fromScale: CGFloat? = nil,
            toScale: CGFloat? = nil
        ) {
            layer.opacity = 0

            let moveX = CABasicAnimation(keyPath: "transform.translation.x")
            moveX.fromValue = 0
            moveX.toValue = dx

            let moveY = CABasicAnimation(keyPath: "transform.translation.y")
            moveY.fromValue = 0
            moveY.toValue = dy

            let fade = CABasicAnimation(keyPath: "opacity")
            fade.fromValue = startOpacity
            fade.toValue = 0.0

            var anims: [CAAnimation] = [moveX, moveY, fade]
            if let fromScale, let toScale {
                let scaleAnim = CABasicAnimation(keyPath: "transform.scale")
                scaleAnim.fromValue = fromScale
                scaleAnim.toValue = toScale
                anims.append(scaleAnim)
            }

            let group = CAAnimationGroup()
            group.animations = anims
            group.duration = duration
            group.beginTime = beginTime
            group.repeatCount = .infinity
            group.timingFunction = CAMediaTimingFunction(name: .easeOut)
            group.isRemovedOnCompletion = false
            layer.add(group, forKey: "bitz.particle.float")
        }
    }

    private func resolvedCGColor() -> CGColor {
        if let converted = NSColor(customColor).usingColorSpace(.sRGB)?.cgColor {
            return converted
        }
        return CGColor(srgbRed: rgb.red, green: rgb.green, blue: rgb.blue, alpha: 1.0)
    }

    func makeNSView(context: Context) -> ParticleHostView {
        let view = ParticleHostView(frame: NSRect(x: 0, y: 0, width: 180, height: 155))
        view.wantsLayer = true
        view.configure(state: state, cgColor: resolvedCGColor())
        return view
    }

    func updateNSView(_ nsView: ParticleHostView, context: Context) {
        let cg = resolvedCGColor()
        if nsView.configuredState != state || nsView.configuredCGColor != cg {
            nsView.configure(state: state, cgColor: cg)
        }
    }
}

/// Self-animating version of `BitzCharacterView` backed by CoreAnimation layer offloading (#70).
public struct AnimatedBitzCharacterView: View {
    public let state: BitzState
    public let isLoafPosture: Bool?
    public let showParticles: Bool
    public let customVisorColor: Color?
    public let isPaused: Bool
    public let palette: AvatarResolvedPalette

    public init(
        state: BitzState = .balanced,
        isLoafPosture: Bool? = nil,
        showParticles: Bool = true,
        customVisorColor: Color? = nil,
        isPaused: Bool = false,
        palette: AvatarResolvedPalette = .cyberpunkClassic
    ) {
        self.palette = palette
        self.state = state
        self.isLoafPosture = isLoafPosture
        self.showParticles = showParticles
        self.customVisorColor = customVisorColor
        self.isPaused = isPaused
    }

    /// Adaptive animation frame interval metadata retained for state cadence queries (#70).
    public static func frameInterval(for state: BitzState, isPetReactionActive: Bool = false) -> TimeInterval {
        if isPetReactionActive {
            return 1.0 / 30.0
        }
        switch state {
        case .superCharged, .overheating:
            return 1.0 / 30.0
        case .balanced, .dopamineSad, .overworked, .charging, .burnout:
            return 1.0 / 15.0
        }
    }

    public var body: some View {
        LiveBitzCharacterView(
            state: state,
            isPetReactionActive: false,
            isLoafPosture: isLoafPosture,
            showParticles: showParticles,
            customVisorColor: customVisorColor,
            isPaused: isPaused,
            palette: palette
        )
    }
}
