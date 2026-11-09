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

/// Diamond shape used for Byte the Cyber Hound's glowing collar emblem and Drako's dragon core accents.
public struct CyberDiamondShape: Shape {
    public init() {}

    public func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.midX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.midY))
        path.addLine(to: CGPoint(x: rect.midX, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.minX, y: rect.midY))
        path.closeSubpath()
        return path
    }
}

/// Swept-back segmented plasma dragon horn with apex at `rect.minY` for Drako (`MascotCharacter.cyberDragon`).
public struct DragonHornShape: Shape {
    public let isLeft: Bool
    public init(isLeft: Bool) { self.isLeft = isLeft }

    public func path(in rect: CGRect) -> Path {
        var path = Path()
        let w = rect.width
        let h = rect.height
        if isLeft {
            path.move(to: CGPoint(x: rect.minX + w * 0.08, y: rect.minY))
            path.addLine(to: CGPoint(x: rect.minX + w * 0.65, y: rect.minY + h * 0.34))
            path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
            path.addLine(to: CGPoint(x: rect.minX + w * 0.32, y: rect.maxY))
            path.addLine(to: CGPoint(x: rect.minX + w * 0.14, y: rect.minY + h * 0.56))
        } else {
            path.move(to: CGPoint(x: rect.maxX - w * 0.08, y: rect.minY))
            path.addLine(to: CGPoint(x: rect.maxX - w * 0.14, y: rect.minY + h * 0.56))
            path.addLine(to: CGPoint(x: rect.maxX - w * 0.32, y: rect.maxY))
            path.addLine(to: CGPoint(x: rect.minX, y: rect.maxY))
            path.addLine(to: CGPoint(x: rect.maxX - w * 0.65, y: rect.minY + h * 0.34))
        }
        path.closeSubpath()
        return path
    }
}

/// Faceted draconic helmet silhouette with swept temporal cheek spikes and armored jaw for Drako (`MascotCharacter.cyberDragon`).
public struct DragonHeadChassisShape: Shape {
    public init() {}

    public func path(in rect: CGRect) -> Path {
        var path = Path()
        let w = rect.width
        let h = rect.height
        path.move(to: CGPoint(x: rect.midX, y: rect.minY + h * 0.03))
        path.addLine(to: CGPoint(x: rect.maxX - w * 0.14, y: rect.minY + h * 0.08))
        path.addLine(to: CGPoint(x: rect.maxX - w * 0.02, y: rect.minY + h * 0.38))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.minY + h * 0.56))
        path.addLine(to: CGPoint(x: rect.maxX - w * 0.10, y: rect.minY + h * 0.82))
        path.addLine(to: CGPoint(x: rect.midX + w * 0.22, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.midX - w * 0.22, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.minX + w * 0.10, y: rect.minY + h * 0.82))
        path.addLine(to: CGPoint(x: rect.minX, y: rect.minY + h * 0.56))
        path.addLine(to: CGPoint(x: rect.minX + w * 0.02, y: rect.minY + h * 0.38))
        path.addLine(to: CGPoint(x: rect.minX + w * 0.14, y: rect.minY + h * 0.08))
        path.closeSubpath()
        return path
    }
}

/// Aggressive V-slanted gull-wing dragon visor screen for Drako (`MascotCharacter.cyberDragon`).
public struct DragonVisorShape: Shape {
    public init() {}

    public func path(in rect: CGRect) -> Path {
        var path = Path()
        let w = rect.width
        let h = rect.height
        path.move(to: CGPoint(x: rect.midX, y: rect.minY + h * 0.16))
        path.addLine(to: CGPoint(x: rect.maxX - w * 0.08, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.minY + h * 0.42))
        path.addLine(to: CGPoint(x: rect.maxX - w * 0.12, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.midX, y: rect.maxY - h * 0.08))
        path.addLine(to: CGPoint(x: rect.minX + w * 0.12, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.minX, y: rect.minY + h * 0.42))
        path.addLine(to: CGPoint(x: rect.minX + w * 0.08, y: rect.minY))
        path.closeSubpath()
        return path
    }
}

/// Spread cyber-wyvern wing with upper spar and scalloped plasma membrane points for Drako (`MascotCharacter.cyberDragon`).
public struct DragonWingShape: Shape {
    public let isLeft: Bool
    public init(isLeft: Bool) { self.isLeft = isLeft }

    public func path(in rect: CGRect) -> Path {
        var path = Path()
        let w = rect.width
        let h = rect.height
        if isLeft {
            path.move(to: CGPoint(x: rect.maxX, y: rect.minY + h * 0.25))
            path.addLine(to: CGPoint(x: rect.minX + w * 0.28, y: rect.minY))
            path.addLine(to: CGPoint(x: rect.minX, y: rect.minY + h * 0.36))
            path.addLine(to: CGPoint(x: rect.minX + w * 0.22, y: rect.minY + h * 0.72))
            path.addLine(to: CGPoint(x: rect.minX + w * 0.56, y: rect.maxY))
            path.addLine(to: CGPoint(x: rect.maxX, y: rect.minY + h * 0.78))
        } else {
            path.move(to: CGPoint(x: rect.minX, y: rect.minY + h * 0.25))
            path.addLine(to: CGPoint(x: rect.maxX - w * 0.28, y: rect.minY))
            path.addLine(to: CGPoint(x: rect.maxX, y: rect.minY + h * 0.36))
            path.addLine(to: CGPoint(x: rect.maxX - w * 0.22, y: rect.minY + h * 0.72))
            path.addLine(to: CGPoint(x: rect.maxX - w * 0.56, y: rect.maxY))
            path.addLine(to: CGPoint(x: rect.minX, y: rect.minY + h * 0.78))
        }
        path.closeSubpath()
        return path
    }
}

/// Sculpted K9 mecha-hound head with wide lupine cheek jowl armor for Byte (`MascotCharacter.cyberDog`).
public struct CyberHoundHeadShape: Shape {
    public init() {}

    public func path(in rect: CGRect) -> Path {
        var path = Path()
        let w = rect.width
        let h = rect.height
        path.move(to: CGPoint(x: rect.minX + w * 0.20, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX - w * 0.20, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX - w * 0.04, y: rect.minY + h * 0.28))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.minY + h * 0.64))
        path.addLine(to: CGPoint(x: rect.maxX - w * 0.16, y: rect.maxY - h * 0.06))
        path.addLine(to: CGPoint(x: rect.midX, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.minX + w * 0.16, y: rect.maxY - h * 0.06))
        path.addLine(to: CGPoint(x: rect.minX, y: rect.minY + h * 0.64))
        path.addLine(to: CGPoint(x: rect.minX + w * 0.04, y: rect.minY + h * 0.28))
        path.closeSubpath()
        return path
    }
}

/// Articulated folded K9 acoustic drop-ear peaking at `rect.minY` for Byte (`MascotCharacter.cyberDog`).
public struct CyberHoundEarShape: Shape {
    public let isLeft: Bool
    public init(isLeft: Bool) { self.isLeft = isLeft }

    public func path(in rect: CGRect) -> Path {
        var path = Path()
        let w = rect.width
        let h = rect.height
        if isLeft {
            path.move(to: CGPoint(x: rect.minX + w * 0.55, y: rect.minY))
            path.addLine(to: CGPoint(x: rect.maxX, y: rect.minY + h * 0.30))
            path.addLine(to: CGPoint(x: rect.maxX - w * 0.18, y: rect.maxY))
            path.addLine(to: CGPoint(x: rect.minX, y: rect.maxY - h * 0.12))
            path.addLine(to: CGPoint(x: rect.minX + w * 0.12, y: rect.minY + h * 0.22))
        } else {
            path.move(to: CGPoint(x: rect.maxX - w * 0.55, y: rect.minY))
            path.addLine(to: CGPoint(x: rect.maxX - w * 0.12, y: rect.minY + h * 0.22))
            path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY - h * 0.12))
            path.addLine(to: CGPoint(x: rect.minX + w * 0.18, y: rect.maxY))
            path.addLine(to: CGPoint(x: rect.minX, y: rect.minY + h * 0.30))
        }
        path.closeSubpath()
        return path
    }
}

/// Precision 8-sided chamfered anti-gravity sentinel core for Aero (`MascotCharacter.hoverDrone`).
public struct AeroOctaDomeShape: Shape {
    public init() {}

    public func path(in rect: CGRect) -> Path {
        var path = Path()
        let w = rect.width
        let h = rect.height
        let cutX = w * 0.24
        let cutY = h * 0.26
        path.move(to: CGPoint(x: rect.minX + cutX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX - cutX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.minY + cutY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY - cutY))
        path.addLine(to: CGPoint(x: rect.maxX - cutX, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.minX + cutX, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.minX, y: rect.maxY - cutY))
        path.addLine(to: CGPoint(x: rect.minX, y: rect.minY + cutY))
        path.closeSubpath()
        return path
    }
}

/// Inverted-trapezoid anti-gravity turbine/repulsor skirt for Aero (`MascotCharacter.hoverDrone`).
public struct AeroRepulsorSkirtShape: Shape {
    public init() {}

    public func path(in rect: CGRect) -> Path {
        var path = Path()
        let w = rect.width
        let h = rect.height
        path.move(to: CGPoint(x: rect.minX + w * 0.08, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX - w * 0.08, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.minY + h * 0.34))
        path.addLine(to: CGPoint(x: rect.midX + w * 0.26, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.midX - w * 0.26, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.minX, y: rect.minY + h * 0.34))
        path.closeSubpath()
        return path
    }
}

/// Beveled 1980s trapezoidal CRT monitor head casing for Pixel (`MascotCharacter.retroMech`).
public struct RetroCRTMonitorShape: Shape {
    public init() {}

    public func path(in rect: CGRect) -> Path {
        var path = Path()
        let w = rect.width
        let h = rect.height
        path.move(to: CGPoint(x: rect.minX + w * 0.08, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX - w * 0.08, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.minY + h * 0.14))
        path.addLine(to: CGPoint(x: rect.maxX - w * 0.03, y: rect.maxY - h * 0.12))
        path.addLine(to: CGPoint(x: rect.maxX - w * 0.12, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.minX + w * 0.12, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.minX + w * 0.03, y: rect.maxY - h * 0.12))
        path.addLine(to: CGPoint(x: rect.minX, y: rect.minY + h * 0.14))
        path.closeSubpath()
        return path
    }
}

/// Broad-shouldered industrial mecha torso with stepped pauldron armor for Pixel (`MascotCharacter.retroMech`).
public struct RetroMechaTorsoShape: Shape {
    public init() {}

    public func path(in rect: CGRect) -> Path {
        var path = Path()
        let w = rect.width
        let h = rect.height
        path.move(to: CGPoint(x: rect.minX, y: rect.minY + h * 0.10))
        path.addLine(to: CGPoint(x: rect.minX + w * 0.12, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX - w * 0.12, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.minY + h * 0.10))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.minY + h * 0.42))
        path.addLine(to: CGPoint(x: rect.maxX - w * 0.10, y: rect.minY + h * 0.48))
        path.addLine(to: CGPoint(x: rect.maxX - w * 0.14, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.minX + w * 0.14, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.minX + w * 0.10, y: rect.minY + h * 0.48))
        path.addLine(to: CGPoint(x: rect.minX, y: rect.minY + h * 0.42))
        path.closeSubpath()
        return path
    }
}

/// Plush pear/teardrop lagomorph head silhouette (sleek upper brow flaring into wide lower cheeks) for Volt (`MascotCharacter.cyberBunny`).
public struct CyberBunnyHeadShape: Shape {
    public init() {}

    public func path(in rect: CGRect) -> Path {
        var path = Path()
        let w = rect.width
        let h = rect.height
        path.move(to: CGPoint(x: rect.midX, y: rect.minY))
        path.addCurve(
            to: CGPoint(x: rect.maxX, y: rect.minY + h * 0.62),
            control1: CGPoint(x: rect.maxX - w * 0.12, y: rect.minY),
            control2: CGPoint(x: rect.maxX, y: rect.minY + h * 0.30)
        )
        path.addCurve(
            to: CGPoint(x: rect.midX, y: rect.maxY),
            control1: CGPoint(x: rect.maxX, y: rect.maxY - h * 0.04),
            control2: CGPoint(x: rect.midX + w * 0.32, y: rect.maxY)
        )
        path.addCurve(
            to: CGPoint(x: rect.minX, y: rect.minY + h * 0.62),
            control1: CGPoint(x: rect.midX - w * 0.32, y: rect.maxY),
            control2: CGPoint(x: rect.minX, y: rect.maxY - h * 0.04)
        )
        path.addCurve(
            to: CGPoint(x: rect.midX, y: rect.minY),
            control1: CGPoint(x: rect.minX, y: rect.minY + h * 0.30),
            control2: CGPoint(x: rect.minX + w * 0.12, y: rect.minY)
        )
        path.closeSubpath()
        return path
    }
}

/// Sculpted speedster bunny ear blade peaking at `rect.minY` for Volt (`MascotCharacter.cyberBunny`).
public struct CyberBunnyEarBladeShape: Shape {
    public let isLeft: Bool
    public init(isLeft: Bool) { self.isLeft = isLeft }

    public func path(in rect: CGRect) -> Path {
        var path = Path()
        let w = rect.width
        let h = rect.height
        if isLeft {
            path.move(to: CGPoint(x: rect.minX + w * 0.25, y: rect.minY))
            path.addLine(to: CGPoint(x: rect.maxX, y: rect.minY + h * 0.28))
            path.addLine(to: CGPoint(x: rect.maxX - w * 0.16, y: rect.maxY))
            path.addLine(to: CGPoint(x: rect.minX + w * 0.22, y: rect.maxY))
            path.addLine(to: CGPoint(x: rect.minX, y: rect.minY + h * 0.36))
        } else {
            path.move(to: CGPoint(x: rect.maxX - w * 0.25, y: rect.minY))
            path.addLine(to: CGPoint(x: rect.maxX, y: rect.minY + h * 0.36))
            path.addLine(to: CGPoint(x: rect.maxX - w * 0.22, y: rect.maxY))
            path.addLine(to: CGPoint(x: rect.minX + w * 0.16, y: rect.maxY))
            path.addLine(to: CGPoint(x: rect.minX, y: rect.minY + h * 0.28))
        }
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

/// Deterministic SwiftUI vector renderer for all 6 companions in the Bitz Multi-Mascot Roster (#30):
/// - `.cyberCat` (Bitz — pointed cyber ears, wrap-around visor, swishing tail)
/// - `.cyberDragon` (Drako — swept plasma horns, articulated cyber-wings, scale plastron, bladed tail)
/// - `.cyberDog` (Byte — articulated floppy ears, snout muzzle, diamond collar tag, rapid antenna tail)
/// - `.hoverDrone` (Aero — dorsal radar beacon, spherical orb dome, 360° cyclops optic, thruster ring)
/// - `.retroMech` (Pixel — dual antenna status beacons, boxy CRT scanline head, servo clamp hands)
/// - `.cyberBunny` (Volt — tall dual-channel antenna ears, rounded bunny head, cotton capacitor tail puff)
public struct BitzCharacterView: View {
    public let state: BitzState
    public let time: TimeInterval
    public let isBlinking: Bool
    public let isPetReactionActive: Bool
    public let isLoafPosture: Bool
    public let showParticles: Bool
    public let customVisorColor: Color?
    public let palette: AvatarResolvedPalette
    public let character: MascotCharacter

    public init(
        state: BitzState = .balanced,
        time: TimeInterval = 0,
        isBlinking: Bool = false,
        isPetReactionActive: Bool = false,
        isLoafPosture: Bool? = nil,
        showParticles: Bool = true,
        customVisorColor: Color? = nil,
        palette: AvatarResolvedPalette = .cyberpunkClassic,
        character: MascotCharacter = .cyberCat
    ) {
        self.palette = palette
        self.state = state
        self.time = time
        self.isBlinking = isBlinking
        self.isPetReactionActive = isPetReactionActive
        self.isLoafPosture = isLoafPosture ?? (state == .burnout || state == .charging)
        self.showParticles = showParticles
        self.customVisorColor = customVisorColor
        self.character = character
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

    /// How far the head & ears/antenna assembly is lifted above its resting place in the frame.
    public static func headLift(for character: MascotCharacter = .cyberCat, isLoafPosture: Bool) -> CGFloat {
        isLoafPosture ? 22 : 44
    }

    /// How far the ear/antenna tips rise above this view's 140 pt-high frame at rest (breathing adds up to 4.5 pt).
    /// The 116 pt headgear-and-head stack sits centered in the frame, 12 pt below its top, before the lift.
    public static func earOverflow(for character: MascotCharacter = .cyberCat, isLoafPosture: Bool) -> CGFloat {
        headLift(for: character, isLoafPosture: isLoafPosture) - 12
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
            // Character-specific tail / propulsion / rear appendage
            MascotRearAppendageView(
                character: character,
                isLoafPosture: isLoafPosture,
                visorColor: visorColor,
                palette: palette,
                wagAngleDegrees: isLoafPosture ? 0 : sin(time * 3.2 * animationSpeedMultiplier) * 10
            )

            // Character-specific torso / chassis base (time-invariant subtree skipped via Equatable #70)
            MascotTorsoView(
                character: character,
                state: state,
                isLoafPosture: isLoafPosture,
                visorColor: visorColor,
                palette: palette
            )
            .equatable()
            .frame(width: isLoafPosture ? 136 : 108, height: isLoafPosture ? 54 : 68)

            // Front Limbs / Paws / Servo Clamps / Hover Pods
            if !isLoafPosture {
                let pawSway = sin(time * 3.0 * animationSpeedMultiplier) * 2.0
                MascotFrontLimbsDeterministicView(
                    character: character,
                    visorColor: visorColor,
                    palette: palette,
                    sway: pawSway
                )
                .offset(y: -4)
                .zIndex(2)
            }

            // Head & Ears/Antennas Assembly (time-invariant subtree skipped via Equatable #70)
            MascotHeadAssemblyView(
                character: character,
                state: state,
                isLoafPosture: isLoafPosture,
                isBlinking: isBlinking,
                isPetReactionActive: isPetReactionActive,
                visorColor: visorColor,
                palette: palette
            )
            .equatable()
            .frame(width: 132, height: 116)
            .offset(y: -Self.headLift(for: character, isLoafPosture: isLoafPosture))
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

// MARK: - Character Rear Appendages (Tail / Dragon Blade Tail / Antenna Tail / Thruster / Exhaust / Cotton Puff)

private struct MascotRearAppendageView: View {
    let character: MascotCharacter
    let isLoafPosture: Bool
    let visorColor: Color
    let palette: AvatarResolvedPalette
    let wagAngleDegrees: Double

    var body: some View {
        let trimColor = palette.trim(over: visorColor)
        switch character {
        case .cyberCat:
            Capsule()
                .fill(palette.chassisColor)
                .frame(width: 48, height: 14)
                .overlay(
                    Capsule()
                        .stroke(trimColor.opacity(0.85), lineWidth: 2)
                )
                .rotationEffect(.degrees((isLoafPosture ? 0 : -22) + wagAngleDegrees))
                .offset(x: 64, y: -14)

        case .cyberDragon:
            // Segmented draconic tail tipped with a glowing diamond plasma spearhead
            HStack(spacing: -3) {
                Capsule()
                    .fill(palette.chassisColor)
                    .frame(width: 34, height: 12)
                    .overlay(
                        Capsule()
                            .stroke(trimColor.opacity(0.85), lineWidth: 1.8)
                    )
                CyberDiamondShape()
                    .fill(visorColor)
                    .frame(width: 18, height: 14)
                    .overlay(
                        CyberDiamondShape()
                            .stroke(trimColor.opacity(0.95), lineWidth: 1.2)
                    )
            }
            .rotationEffect(.degrees((isLoafPosture ? -6 : -26) + wagAngleDegrees * 1.15))
            .offset(x: 62, y: -18)

        case .cyberDog:
            // High-energy K9 whip-antenna tail with dual signal rings and glowing beacon orb
            HStack(spacing: -2) {
                Capsule()
                    .fill(palette.chassisColor)
                    .frame(width: 36, height: 10)
                    .overlay(
                        Capsule()
                            .stroke(trimColor.opacity(0.85), lineWidth: 1.8)
                    )
                Capsule()
                    .fill(visorColor.opacity(0.85))
                    .frame(width: 5, height: 14)
                Circle()
                    .fill(visorColor)
                    .frame(width: 11, height: 11)
            }
            .rotationEffect(.degrees((isLoafPosture ? -8 : -36) + wagAngleDegrees * 1.4))
            .offset(x: 62, y: -20)

        case .hoverDrone:
            // Floating rear telemetry stabilizer fin with plasma trail node
            HStack(spacing: 3) {
                AeroOctaDomeShape()
                    .fill(palette.chassisColor)
                    .frame(width: 26, height: 14)
                    .overlay(
                        AeroOctaDomeShape()
                            .stroke(trimColor.opacity(0.85), lineWidth: 1.5)
                    )
                CyberDiamondShape()
                    .fill(visorColor)
                    .frame(width: 10, height: 10)
            }
            .rotationEffect(.degrees((isLoafPosture ? 0 : -10) + wagAngleDegrees * 0.6))
            .offset(x: 60, y: -22)

        case .retroMech:
            // Twin-nozzle retro jetpack exhaust manifold
            HStack(spacing: 0) {
                Rectangle()
                    .fill(palette.chassisColor)
                    .frame(width: 18, height: 16)
                    .overlay(Rectangle().stroke(trimColor.opacity(0.85), lineWidth: 1.5))
                VStack(spacing: 2) {
                    RoundedRectangle(cornerRadius: 3)
                        .fill(visorColor.opacity(0.9))
                        .frame(width: 14, height: 8)
                    RoundedRectangle(cornerRadius: 3)
                        .fill(visorColor.opacity(0.9))
                        .frame(width: 14, height: 8)
                }
            }
            .rotationEffect(.degrees(wagAngleDegrees * 0.45))
            .offset(x: 62, y: -18)

        case .cyberBunny:
            // Glowing double-layered star-puff plasma cottontail
            ZStack {
                Circle()
                    .fill(palette.chassisColor)
                    .frame(width: 28, height: 28)
                    .overlay(
                        Circle()
                            .stroke(trimColor.opacity(0.85), lineWidth: 2)
                    )
                CyberDiamondShape()
                    .fill(visorColor.opacity(0.85))
                    .frame(width: 16, height: 16)
                Circle()
                    .fill(Color.white.opacity(0.85))
                    .frame(width: 6, height: 6)
            }
            .rotationEffect(.degrees(wagAngleDegrees))
            .offset(x: 58, y: -14)
        }
    }
}

// MARK: - Character Front Limbs (Paws / Dragon Talons / Levitation Rings / Pincer Clamps / Hopper Feet)

private struct MascotLimbPairShape: View {
    let character: MascotCharacter
    let visorColor: Color
    let palette: AvatarResolvedPalette

    var body: some View {
        let trimColor = palette.trim(over: visorColor)
        switch character {
        case .cyberCat:
            Capsule()
                .fill(palette.chassisColor)
                .frame(width: 18, height: 10)
                .overlay(Capsule().stroke(trimColor.opacity(0.65), lineWidth: 1))

        case .cyberDragon:
            // Three-taloned armored dragon claw
            ZStack(alignment: .bottom) {
                RoundedRectangle(cornerRadius: 4)
                    .fill(palette.chassisColor)
                    .frame(width: 22, height: 11)
                    .overlay(RoundedRectangle(cornerRadius: 4).stroke(trimColor.opacity(0.85), lineWidth: 1.4))
                HStack(spacing: 3) {
                    ForEach(0..<3, id: \.self) { _ in
                        CyberEarShape()
                            .fill(visorColor)
                            .frame(width: 4, height: 5)
                            .rotationEffect(.degrees(180))
                    }
                }
                .offset(y: 2)
            }

        case .cyberDog:
            // Heavy-treaded K9 digi-paw with glowing knuckle pad
            ZStack {
                RoundedRectangle(cornerRadius: 5)
                    .fill(palette.chassisColor)
                    .frame(width: 22, height: 12)
                    .overlay(RoundedRectangle(cornerRadius: 5).stroke(trimColor.opacity(0.8), lineWidth: 1.4))
                HStack(spacing: 4) {
                    Circle().fill(visorColor.opacity(0.85)).frame(width: 3.5, height: 3.5)
                    Circle().fill(visorColor.opacity(0.85)).frame(width: 3.5, height: 3.5)
                }
                .offset(y: 1)
            }

        case .hoverDrone:
            // Floating antigravity plasma thruster ring (no legs!)
            ZStack {
                Capsule()
                    .stroke(visorColor, lineWidth: 2)
                    .frame(width: 24, height: 8)
                Capsule()
                    .fill(visorColor.opacity(0.45))
                    .frame(width: 14, height: 4)
            }

        case .retroMech:
            // Industrial U-shaped hydraulic pincer clamp
            ZStack(alignment: .bottom) {
                RoundedRectangle(cornerRadius: 3)
                    .fill(palette.chassisColor)
                    .frame(width: 22, height: 13)
                    .overlay(RoundedRectangle(cornerRadius: 3).stroke(trimColor.opacity(0.9), lineWidth: 1.6))
                Rectangle()
                    .fill(Color(red: 0.04, green: 0.04, blue: 0.06))
                    .frame(width: 10, height: 6)
            }

        case .cyberBunny:
            // Long spring-loaded bionic bunny hopper foot with neon sole stripe
            ZStack(alignment: .bottom) {
                Capsule()
                    .fill(palette.chassisColor)
                    .frame(width: 26, height: 11)
                    .overlay(Capsule().stroke(trimColor.opacity(0.85), lineWidth: 1.4))
                Capsule()
                    .fill(visorColor.opacity(0.9))
                    .frame(width: 16, height: 3)
                    .offset(y: -1.5)
            }
        }
    }
}

private struct MascotFrontLimbsDeterministicView: View {
    let character: MascotCharacter
    let visorColor: Color
    let palette: AvatarResolvedPalette
    let sway: Double

    var body: some View {
        HStack(spacing: character == .hoverDrone ? 32 : (character == .cyberBunny ? 24 : 28)) {
            MascotLimbPairShape(character: character, visorColor: visorColor, palette: palette)
                .transformEffect(CGAffineTransform(translationX: 0, y: sway))
            MascotLimbPairShape(character: character, visorColor: visorColor, palette: palette)
                .transformEffect(CGAffineTransform(translationX: 0, y: -sway))
        }
        .frame(width: 84, height: 13)
    }
}

// MARK: - Character Torso View (Bespoke Body Silhouettes, Dragon Wings, Drone Repulsor Skirt, Mecha Pauldrons)

private struct MascotTorsoView: View, Equatable {
    let character: MascotCharacter
    let state: BitzState
    let isLoafPosture: Bool
    let visorColor: Color
    let palette: AvatarResolvedPalette

    var body: some View {
        let trimColor = palette.trim(over: visorColor)
        let width: CGFloat = isLoafPosture ? 136 : 108
        let height: CGFloat = isLoafPosture ? 54 : 68

        switch character {
        case .cyberCat:
            RoundedRectangle(cornerRadius: 28)
                .fill(palette.chassisDeepColor)
                .frame(width: width, height: height)
                .overlay(
                    RoundedRectangle(cornerRadius: 28)
                        .stroke(trimColor.opacity(0.45), lineWidth: 1.5)
                )
                .overlay(torsoEmblem.offset(y: 6))

        case .cyberDragon:
            // Armored dragon torso flanked by spread cyber-wyvern energy wings
            ZStack {
                HStack(spacing: isLoafPosture ? 62 : 48) {
                    ZStack {
                        DragonWingShape(isLeft: true)
                            .fill(palette.chassisDeepColor)
                        DragonWingShape(isLeft: true)
                            .fill(visorColor.opacity(0.28))
                            .padding(4)
                        DragonWingShape(isLeft: true)
                            .stroke(trimColor.opacity(0.85), lineWidth: 1.6)
                    }
                    .frame(width: 48, height: isLoafPosture ? 40 : 52)

                    ZStack {
                        DragonWingShape(isLeft: false)
                            .fill(palette.chassisDeepColor)
                        DragonWingShape(isLeft: false)
                            .fill(visorColor.opacity(0.28))
                            .padding(4)
                        DragonWingShape(isLeft: false)
                            .stroke(trimColor.opacity(0.85), lineWidth: 1.6)
                    }
                    .frame(width: 48, height: isLoafPosture ? 40 : 52)
                }
                .offset(y: -4)

                DragonHeadChassisShape()
                    .fill(palette.chassisDeepColor)
                    .frame(width: width, height: height)
                    .overlay(
                        DragonHeadChassisShape()
                            .stroke(trimColor.opacity(0.65), lineWidth: 1.8)
                    )
                    .overlay(torsoEmblem.offset(y: 6))
            }
            .frame(width: width, height: height)

        case .cyberDog:
            // Tactical K9 harness chassis with angled chest armor & collar strap
            ZStack {
                CyberHoundHeadShape()
                    .fill(palette.chassisDeepColor)
                    .frame(width: width, height: height)
                    .overlay(
                        CyberHoundHeadShape()
                            .stroke(trimColor.opacity(0.6), lineWidth: 1.8)
                    )
                torsoEmblem
                    .offset(y: 5)
            }
            .frame(width: width, height: height)

        case .hoverDrone:
            // Tapered anti-gravity repulsor turbine cone + floating side winglet pods + levitation halo
            ZStack {
                HStack(spacing: isLoafPosture ? 96 : 82) {
                    Capsule()
                        .fill(palette.chassisColor)
                        .frame(width: 24, height: 10)
                        .overlay(Capsule().stroke(visorColor.opacity(0.85), lineWidth: 1.4))
                        .rotationEffect(.degrees(-18))
                    Capsule()
                        .fill(palette.chassisColor)
                        .frame(width: 24, height: 10)
                        .overlay(Capsule().stroke(visorColor.opacity(0.85), lineWidth: 1.4))
                        .rotationEffect(.degrees(18))
                }
                .offset(y: -8)

                AeroRepulsorSkirtShape()
                    .fill(palette.chassisDeepColor)
                    .frame(width: isLoafPosture ? 116 : 94, height: height - 8)
                    .overlay(
                        AeroRepulsorSkirtShape()
                            .stroke(trimColor.opacity(0.75), lineWidth: 1.8)
                    )
                    .overlay(torsoEmblem.offset(y: 2))

                Capsule()
                    .stroke(visorColor.opacity(0.75), lineWidth: 2)
                    .frame(width: isLoafPosture ? 128 : 106, height: 12)
                    .offset(y: 12)
            }
            .frame(width: width, height: height)

        case .retroMech:
            // Broad-shouldered industrial mecha torso with stepped pauldron armor
            ZStack {
                RetroMechaTorsoShape()
                    .fill(palette.chassisDeepColor)
                    .frame(width: isLoafPosture ? 136 : 118, height: height)
                    .overlay(
                        RetroMechaTorsoShape()
                            .stroke(trimColor.opacity(0.75), lineWidth: 2)
                    )
                torsoEmblem
                    .offset(y: 6)
            }
            .frame(width: width, height: height)

        case .cyberBunny:
            // Sleek pear-shaped speedster dynamo pod torso
            ZStack {
                CyberBunnyHeadShape()
                    .fill(palette.chassisDeepColor)
                    .frame(width: isLoafPosture ? 128 : 100, height: height)
                    .overlay(
                        CyberBunnyHeadShape()
                            .stroke(trimColor.opacity(0.6), lineWidth: 1.6)
                    )
                torsoEmblem
                    .offset(y: 6)
            }
            .frame(width: width, height: height)
        }
    }

    @ViewBuilder
    private var torsoEmblem: some View {
        let activeOpacity = state == .burnout ? 0.3 : 0.9
        switch character {
        case .cyberCat:
            Circle()
                .fill(visorColor.opacity(activeOpacity))
                .frame(width: 12, height: 12)
                .shadow(color: visorColor, radius: 6 * palette.glowScale)

        case .cyberDragon:
            // Stacked draconic plasma scale plastron chevrons + diamond dragon heart
            VStack(spacing: 3) {
                CyberDiamondShape()
                    .fill(visorColor.opacity(activeOpacity))
                    .frame(width: 14, height: 14)
                Capsule()
                    .fill(visorColor.opacity(activeOpacity * 0.8))
                    .frame(width: 28, height: 3.5)
                Capsule()
                    .fill(visorColor.opacity(activeOpacity * 0.6))
                    .frame(width: 20, height: 3)
            }
            .shadow(color: visorColor, radius: 6 * palette.glowScale)

        case .cyberDog:
            // Tactical K9 collar strap + glowing diamond ID tag
            VStack(spacing: 2) {
                Capsule()
                    .fill(visorColor.opacity(activeOpacity * 0.8))
                    .frame(width: 54, height: 4)
                CyberDiamondShape()
                    .fill(visorColor.opacity(activeOpacity))
                    .frame(width: 14, height: 14)
                    .shadow(color: visorColor, radius: 5 * palette.glowScale)
            }

        case .hoverDrone:
            // Concentric anti-gravity turbine core
            ZStack {
                Circle()
                    .stroke(visorColor.opacity(activeOpacity), lineWidth: 2)
                    .frame(width: 22, height: 22)
                CyberDiamondShape()
                    .fill(visorColor.opacity(activeOpacity))
                    .frame(width: 10, height: 10)
            }
            .shadow(color: visorColor, radius: 5 * palette.glowScale)

        case .retroMech:
            // 80s cassette deck window with 3 equalizer power bars
            ZStack {
                RoundedRectangle(cornerRadius: 4)
                    .fill(Color(red: 0.04, green: 0.04, blue: 0.06))
                    .frame(width: 42, height: 18)
                    .overlay(
                        RoundedRectangle(cornerRadius: 4)
                            .stroke(visorColor.opacity(activeOpacity * 0.7), lineWidth: 1.2)
                    )
                HStack(spacing: 4) {
                    RoundedRectangle(cornerRadius: 1.5)
                        .fill(visorColor.opacity(activeOpacity))
                        .frame(width: 8, height: 8)
                    RoundedRectangle(cornerRadius: 1.5)
                        .fill(visorColor.opacity(activeOpacity))
                        .frame(width: 8, height: 8)
                    Circle()
                        .fill(visorColor.opacity(activeOpacity))
                        .frame(width: 6, height: 6)
                }
            }
            .shadow(color: visorColor, radius: 4 * palette.glowScale)

        case .cyberBunny:
            // High-voltage dynamo diamond-heart capacitor
            HStack(spacing: 4) {
                Capsule()
                    .fill(visorColor.opacity(activeOpacity * 0.75))
                    .frame(width: 4, height: 12)
                CyberDiamondShape()
                    .fill(visorColor.opacity(activeOpacity))
                    .frame(width: 14, height: 14)
                Capsule()
                    .fill(visorColor.opacity(activeOpacity * 0.75))
                    .frame(width: 4, height: 12)
            }
            .shadow(color: visorColor, radius: 5 * palette.glowScale)
        }
    }
}

// MARK: - Character Head & Ears/Antennas Assembly (Bespoke Head Silhouettes & Visor Shapes)

private struct MascotHeadAssemblyView: View, Equatable {
    let character: MascotCharacter
    let state: BitzState
    let isLoafPosture: Bool
    let isBlinking: Bool
    let isPetReactionActive: Bool
    let visorColor: Color
    let palette: AvatarResolvedPalette

    var body: some View {
        let earTilt = (state == .overworked || state == .dopamineSad) ? 14.0 : 0.0

        VStack(spacing: -10) {
            // 34 pt Top Headgear Band (Cat Ears / Dragon Horns / K9 Drop-Ears / Drone Spire / Mecha Dish / Bunny Blades)
            headgearBand(earTilt: earTilt)
                .frame(height: 34)
                .zIndex(0)

            // 92 pt Bespoke Head Chassis (34 + 92 - 10 = 116 pt total assembly height)
            ZStack {
                headChassisLayer
                visorScreenLayer
                facialAccent
            }
            .frame(width: 132, height: 92)
            .zIndex(1)
        }
    }

    @ViewBuilder
    private var headChassisLayer: some View {
        let trimColor = palette.trim(over: visorColor)
        switch character {
        case .cyberCat:
            RoundedRectangle(cornerRadius: 34)
                .fill(palette.chassisColor)
                .frame(width: 132, height: 92)
                .shadow(color: visorColor.opacity(0.35), radius: 8 * palette.glowScale)
                .overlay(
                    RoundedRectangle(cornerRadius: 34)
                        .stroke(trimColor.opacity(0.75), lineWidth: 2)
                )

        case .cyberDragon:
            // Faceted draconic helmet with swept temporal cheek spikes
            DragonHeadChassisShape()
                .fill(palette.chassisColor)
                .frame(width: 136, height: 92)
                .shadow(color: visorColor.opacity(0.42), radius: 8 * palette.glowScale)
                .overlay(
                    DragonHeadChassisShape()
                        .stroke(trimColor.opacity(0.88), lineWidth: 2.2)
                )

        case .cyberDog:
            // Sculpted K9 mecha-hound helmet with wide angular lupine cheek jowl armor
            CyberHoundHeadShape()
                .fill(palette.chassisColor)
                .frame(width: 134, height: 92)
                .shadow(color: visorColor.opacity(0.35), radius: 8 * palette.glowScale)
                .overlay(
                    CyberHoundHeadShape()
                        .stroke(trimColor.opacity(0.8), lineWidth: 2)
                )

        case .hoverDrone:
            // 8-sided chamfered anti-gravity sentinel core with equatorial gyro ring
            ZStack {
                Capsule()
                    .stroke(visorColor.opacity(0.65), lineWidth: 2)
                    .frame(width: 146, height: 18)
                AeroOctaDomeShape()
                    .fill(palette.chassisColor)
                    .frame(width: 124, height: 90)
                    .shadow(color: visorColor.opacity(0.4), radius: 8 * palette.glowScale)
                    .overlay(
                        AeroOctaDomeShape()
                            .stroke(trimColor.opacity(0.85), lineWidth: 2.2)
                    )
            }

        case .retroMech:
            // 1980s beveled CRT monitor head with side transceiver bolts
            ZStack {
                HStack(spacing: 130) {
                    RoundedRectangle(cornerRadius: 3)
                        .fill(visorColor.opacity(0.85))
                        .frame(width: 6, height: 22)
                    RoundedRectangle(cornerRadius: 3)
                        .fill(visorColor.opacity(0.85))
                        .frame(width: 6, height: 22)
                }
                RetroCRTMonitorShape()
                    .fill(palette.chassisColor)
                    .frame(width: 132, height: 92)
                    .shadow(color: visorColor.opacity(0.35), radius: 8 * palette.glowScale)
                    .overlay(
                        RetroCRTMonitorShape()
                            .stroke(trimColor.opacity(0.85), lineWidth: 2.2)
                    )
            }

        case .cyberBunny:
            // Plush pear/teardrop lagomorph head flaring into wide rounded cheeks
            CyberBunnyHeadShape()
                .fill(palette.chassisColor)
                .frame(width: 134, height: 92)
                .shadow(color: visorColor.opacity(0.35), radius: 8 * palette.glowScale)
                .overlay(
                    CyberBunnyHeadShape()
                        .stroke(trimColor.opacity(0.8), lineWidth: 2)
                )
        }
    }

    @ViewBuilder
    private var visorScreenLayer: some View {
        let trimColor = palette.trim(over: visorColor)
        let screenFill = Color(red: 0.04, green: 0.04, blue: 0.06)

        switch character {
        case .cyberDragon:
            // Fierce V-slanted gull-wing dragon visor
            DragonVisorShape()
                .fill(screenFill)
                .frame(width: 112, height: 46)
                .overlay(
                    DragonVisorShape()
                        .stroke(trimColor.opacity(0.7), lineWidth: 1.5)
                )
                .overlay(visorContent)
                .offset(y: -2)

        case .hoverDrone:
            // Circular/octagonal panoramic sensor dome aperture
            AeroOctaDomeShape()
                .fill(screenFill)
                .frame(width: 98, height: 52)
                .overlay(
                    AeroOctaDomeShape()
                        .stroke(trimColor.opacity(0.65), lineWidth: 1.5)
                )
                .overlay(visorContent)

        case .retroMech:
            // Deep-recessed rectangular CRT monitor screen with corner frame
            RoundedRectangle(cornerRadius: 6)
                .fill(screenFill)
                .frame(width: 106, height: 48)
                .overlay(
                    RoundedRectangle(cornerRadius: 6)
                        .stroke(trimColor.opacity(0.75), lineWidth: 1.6)
                )
                .overlay(visorContent)
                .offset(y: -4)

        case .cyberDog:
            // Tactical K9 wrap-goggle visor raised above protruding cyber-muzzle
            RoundedRectangle(cornerRadius: 16)
                .fill(screenFill)
                .frame(width: 108, height: 42)
                .overlay(
                    RoundedRectangle(cornerRadius: 16)
                        .stroke(trimColor.opacity(0.6), lineWidth: 1.4)
                )
                .overlay(visorContent)
                .offset(y: -5)

        case .cyberBunny:
            // Wide pill-dome visor screen
            Capsule()
                .fill(screenFill)
                .frame(width: 106, height: 46)
                .overlay(
                    Capsule()
                        .stroke(trimColor.opacity(0.55), lineWidth: 1.3)
                )
                .overlay(visorContent)
                .offset(y: -2)

        case .cyberCat:
            RoundedRectangle(cornerRadius: 18)
                .fill(screenFill)
                .frame(width: 108, height: 46)
                .overlay(
                    RoundedRectangle(cornerRadius: 18)
                        .stroke(trimColor.opacity(0.5), lineWidth: 1)
                )
                .overlay(visorContent)
        }
    }

    @ViewBuilder
    private func headgearBand(earTilt: Double) -> some View {
        let trimColor = palette.trim(over: visorColor)
        switch character {
        case .cyberCat:
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

        case .cyberDragon:
            // Swept-back twin segmented plasma horns + central dorsal spine crest
            HStack(alignment: .bottom, spacing: 14) {
                ZStack {
                    DragonHornShape(isLeft: true)
                        .fill(palette.chassisColor)
                        .frame(width: 38, height: 34)
                    DragonHornShape(isLeft: true)
                        .fill(visorColor.opacity(0.85))
                        .frame(width: 24, height: 22)
                        .offset(x: 2, y: 3)
                    DragonHornShape(isLeft: true)
                        .stroke(trimColor.opacity(0.9), lineWidth: 1.5)
                        .frame(width: 38, height: 34)
                }
                .rotationEffect(.degrees(-earTilt * 0.7))

                CyberEarShape()
                    .fill(visorColor)
                    .frame(width: 16, height: 24)
                    .overlay(
                        CyberEarShape()
                            .stroke(trimColor.opacity(0.9), lineWidth: 1.2)
                    )

                ZStack {
                    DragonHornShape(isLeft: false)
                        .fill(palette.chassisColor)
                        .frame(width: 38, height: 34)
                    DragonHornShape(isLeft: false)
                        .fill(visorColor.opacity(0.85))
                        .frame(width: 24, height: 22)
                        .offset(x: -2, y: 3)
                    DragonHornShape(isLeft: false)
                        .stroke(trimColor.opacity(0.9), lineWidth: 1.5)
                        .frame(width: 38, height: 34)
                }
                .rotationEffect(.degrees(earTilt * 0.7))
            }

        case .cyberDog:
            // Articulated folded K9 acoustic drop-ears with glowing vent slits
            HStack(spacing: 42) {
                ZStack {
                    CyberHoundEarShape(isLeft: true)
                        .fill(palette.chassisColor)
                        .frame(width: 38, height: 34)
                    CyberHoundEarShape(isLeft: true)
                        .stroke(trimColor.opacity(0.88), lineWidth: 1.6)
                        .frame(width: 38, height: 34)
                    Capsule()
                        .fill(visorColor.opacity(0.88))
                        .frame(width: 12, height: 15)
                        .rotationEffect(.degrees(-14))
                        .offset(x: 2, y: 4)
                }
                .rotationEffect(.degrees(-earTilt * 0.8))

                ZStack {
                    CyberHoundEarShape(isLeft: false)
                        .fill(palette.chassisColor)
                        .frame(width: 38, height: 34)
                    CyberHoundEarShape(isLeft: false)
                        .stroke(trimColor.opacity(0.88), lineWidth: 1.6)
                        .frame(width: 38, height: 34)
                    Capsule()
                        .fill(visorColor.opacity(0.88))
                        .frame(width: 12, height: 15)
                        .rotationEffect(.degrees(14))
                        .offset(x: -2, y: 4)
                }
                .rotationEffect(.degrees(earTilt * 0.8))
            }

        case .hoverDrone:
            // Orbital dorsal radar spire with floating energy halo & twin swept sensor fins
            HStack(alignment: .bottom, spacing: 14) {
                CyberEarShape()
                    .fill(palette.chassisColor)
                    .frame(width: 22, height: 22)
                    .overlay(CyberEarShape().stroke(trimColor.opacity(0.85), lineWidth: 1.4))
                    .rotationEffect(.degrees(-22 - earTilt * 0.5))

                VStack(spacing: -2) {
                    CyberDiamondShape()
                        .fill(visorColor)
                        .frame(width: 14, height: 14)
                    AeroOctaDomeShape()
                        .fill(palette.chassisColor)
                        .frame(width: 22, height: 22)
                        .overlay(
                            AeroOctaDomeShape()
                                .stroke(trimColor.opacity(0.88), lineWidth: 1.5)
                        )
                }

                CyberEarShape()
                    .fill(palette.chassisColor)
                    .frame(width: 22, height: 22)
                    .overlay(CyberEarShape().stroke(trimColor.opacity(0.85), lineWidth: 1.4))
                    .rotationEffect(.degrees(22 + earTilt * 0.5))
            }

        case .retroMech:
            // Dual status beacon antennas + central industrial radar dish mount
            HStack(alignment: .bottom, spacing: 14) {
                VStack(spacing: -2) {
                    Circle()
                        .fill(visorColor)
                        .frame(width: 12, height: 12)
                    RoundedRectangle(cornerRadius: 2)
                        .fill(palette.chassisColor)
                        .frame(width: 6, height: 24)
                }
                .rotationEffect(.degrees(-earTilt * 0.5))

                VStack(spacing: 0) {
                    Capsule()
                        .fill(visorColor.opacity(0.9))
                        .frame(width: 28, height: 6)
                    RoundedRectangle(cornerRadius: 4)
                        .fill(palette.chassisColor)
                        .frame(width: 42, height: 14)
                        .overlay(
                            RoundedRectangle(cornerRadius: 4)
                                .stroke(trimColor.opacity(0.85), lineWidth: 1.5)
                        )
                }

                VStack(spacing: -2) {
                    Circle()
                        .fill(visorColor)
                        .frame(width: 12, height: 12)
                    RoundedRectangle(cornerRadius: 2)
                        .fill(palette.chassisColor)
                        .frame(width: 6, height: 24)
                }
                .rotationEffect(.degrees(earTilt * 0.5))
            }

        case .cyberBunny:
            // Sculpted twin-blade speedster bunny ears with glowing neon inner energy blades
            HStack(spacing: 28) {
                ZStack {
                    CyberBunnyEarBladeShape(isLeft: true)
                        .fill(palette.chassisColor)
                        .frame(width: 30, height: 34)
                    CyberBunnyEarBladeShape(isLeft: true)
                        .stroke(trimColor.opacity(0.88), lineWidth: 1.6)
                        .frame(width: 30, height: 34)
                    Capsule()
                        .fill(visorColor.opacity(0.9))
                        .frame(width: 8, height: 22)
                        .rotationEffect(.degrees(-8))
                        .offset(y: 2)
                }
                .rotationEffect(.degrees(-earTilt * 0.9))

                ZStack {
                    CyberBunnyEarBladeShape(isLeft: false)
                        .fill(palette.chassisColor)
                        .frame(width: 30, height: 34)
                    CyberBunnyEarBladeShape(isLeft: false)
                        .stroke(trimColor.opacity(0.88), lineWidth: 1.6)
                        .frame(width: 30, height: 34)
                    Capsule()
                        .fill(visorColor.opacity(0.9))
                        .frame(width: 8, height: 22)
                        .rotationEffect(.degrees(8))
                        .offset(y: 2)
                }
                .rotationEffect(.degrees(earTilt * 0.9))
            }
        }
    }

    @ViewBuilder
    private var facialAccent: some View {
        let trimColor = palette.trim(over: visorColor)
        switch character {
        case .cyberCat:
            // Sleek feline neon whisker-fin accents flanking the visor
            HStack(spacing: 112) {
                Capsule()
                    .fill(visorColor.opacity(0.65))
                    .frame(width: 6, height: 3)
                Capsule()
                    .fill(visorColor.opacity(0.65))
                    .frame(width: 6, height: 3)
            }
            .offset(y: 8)

        case .cyberDragon:
            // Armored draconic snout ridge with twin glowing plasma nostril vents & fang tips
            VStack(spacing: 2) {
                HStack(spacing: 14) {
                    CyberDiamondShape()
                        .fill(visorColor)
                        .frame(width: 7, height: 5)
                    CyberDiamondShape()
                        .fill(visorColor)
                        .frame(width: 7, height: 5)
                }
                HStack(spacing: 18) {
                    CyberEarShape()
                        .fill(visorColor.opacity(0.9))
                        .frame(width: 5, height: 5)
                        .rotationEffect(.degrees(180))
                    CyberEarShape()
                        .fill(visorColor.opacity(0.9))
                        .frame(width: 5, height: 5)
                        .rotationEffect(.degrees(180))
                }
            }
            .offset(y: 28)

        case .cyberDog:
            // Prominent 3D protruding K9 cyber-muzzle with diamond nose sensor & fang trim
            ZStack {
                RoundedRectangle(cornerRadius: 8)
                    .fill(palette.chassisDeepColor)
                    .frame(width: 42, height: 18)
                    .overlay(
                        RoundedRectangle(cornerRadius: 8)
                            .stroke(trimColor.opacity(0.85), lineWidth: 1.4)
                    )
                VStack(spacing: 2) {
                    CyberDiamondShape()
                        .fill(visorColor)
                        .frame(width: 11, height: 7)
                    Capsule()
                        .fill(visorColor.opacity(0.75))
                        .frame(width: 16, height: 2.5)
                }
            }
            .offset(y: 27)

        case .hoverDrone:
            // Lower panoramic telemetry aperture nodes
            HStack(spacing: 16) {
                Circle().fill(visorColor.opacity(0.85)).frame(width: 5, height: 5)
                Capsule().fill(visorColor.opacity(0.65)).frame(width: 22, height: 3)
                Circle().fill(visorColor.opacity(0.85)).frame(width: 5, height: 5)
            }
            .offset(y: 33)

        case .retroMech:
            // Tactile 80s arcade micro-buttons & speaker grille slots below CRT screen
            HStack(spacing: 10) {
                HStack(spacing: 4) {
                    Circle().fill(visorColor).frame(width: 6, height: 6)
                    Circle().fill(visorColor.opacity(0.6)).frame(width: 6, height: 6)
                }
                HStack(spacing: 4) {
                    ForEach(0..<3, id: \.self) { _ in
                        Capsule()
                            .fill(visorColor.opacity(0.7))
                            .frame(width: 8, height: 3)
                    }
                }
            }
            .offset(y: 29)

        case .cyberBunny:
            // Plush neon cheek blush bolts & cute lagomorph nose-node
            ZStack {
                HStack(spacing: 94) {
                    Capsule()
                        .fill(visorColor.opacity(0.85))
                        .frame(width: 10, height: 5)
                    Capsule()
                        .fill(visorColor.opacity(0.85))
                        .frame(width: 10, height: 5)
                }
                .offset(y: 12)

                CyberDiamondShape()
                    .fill(visorColor.opacity(0.9))
                    .frame(width: 8, height: 6)
                    .offset(y: 26)
            }
        }
    }

    @ViewBuilder
    private var visorContent: some View {
        if isPetReactionActive {
            Text(character.petVisorText)
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
            Text(character == .retroMech ? "[^  ^]" : "^  ^")
                .font(.system(size: character == .retroMech ? 18 : 21, weight: .heavy, design: .monospaced))
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
            balancedVisorEyes
        }
    }

    @ViewBuilder
    private var balancedVisorEyes: some View {
        switch character {
        case .cyberDragon:
            // Fierce angled slitted dragon eyes with vertical diamond pupils
            HStack(spacing: 22) {
                ZStack {
                    CyberDiamondShape()
                        .fill(visorColor)
                        .frame(width: 22, height: 12)
                        .rotationEffect(.degrees(14))
                    Capsule()
                        .fill(Color(red: 0.04, green: 0.04, blue: 0.06))
                        .frame(width: 3, height: 8)
                }
                ZStack {
                    CyberDiamondShape()
                        .fill(visorColor)
                        .frame(width: 22, height: 12)
                        .rotationEffect(.degrees(-14))
                    Capsule()
                        .fill(Color(red: 0.04, green: 0.04, blue: 0.06))
                        .frame(width: 3, height: 8)
                }
            }
            .shadow(color: visorColor, radius: 6 * palette.glowScale)

        case .hoverDrone:
            // 360° concentric targeting reticle optic + twin telemetry dots
            HStack(spacing: 12) {
                CyberDiamondShape()
                    .fill(visorColor.opacity(0.8))
                    .frame(width: 7, height: 7)
                ZStack {
                    Circle()
                        .stroke(visorColor, lineWidth: 2.5)
                        .frame(width: 24, height: 24)
                    CyberDiamondShape()
                        .fill(visorColor)
                        .frame(width: 10, height: 10)
                }
                CyberDiamondShape()
                    .fill(visorColor.opacity(0.8))
                    .frame(width: 7, height: 7)
            }
            .shadow(color: visorColor, radius: 6 * palette.glowScale)

        case .retroMech:
            // Retro CRT pixel-block eyes with scanline bracket accents
            HStack(spacing: 18) {
                RoundedRectangle(cornerRadius: 2)
                    .fill(visorColor)
                    .frame(width: 18, height: 13)
                RoundedRectangle(cornerRadius: 2)
                    .fill(visorColor)
                    .frame(width: 18, height: 13)
            }
            .shadow(color: visorColor, radius: 6 * palette.glowScale)

        case .cyberDog:
            // Expressive K9 goggle eyes with loyal upper brow arcs
            HStack(spacing: 22) {
                VStack(spacing: 2) {
                    Capsule()
                        .fill(visorColor.opacity(0.8))
                        .frame(width: 14, height: 3)
                        .rotationEffect(.degrees(-8))
                    RoundedRectangle(cornerRadius: 5)
                        .fill(visorColor)
                        .frame(width: 17, height: 11)
                }
                VStack(spacing: 2) {
                    Capsule()
                        .fill(visorColor.opacity(0.8))
                        .frame(width: 14, height: 3)
                        .rotationEffect(.degrees(8))
                    RoundedRectangle(cornerRadius: 5)
                        .fill(visorColor)
                        .frame(width: 17, height: 11)
                }
            }
            .shadow(color: visorColor, radius: 6 * palette.glowScale)

        case .cyberBunny:
            // Tall glossy vertical-oval anime-cyber eyes with starlight specular highlights
            HStack(spacing: 24) {
                ZStack(alignment: .topLeading) {
                    Capsule()
                        .fill(visorColor)
                        .frame(width: 13, height: 17)
                    Circle()
                        .fill(Color.white.opacity(0.9))
                        .frame(width: 4.5, height: 4.5)
                        .offset(x: 2.5, y: 2.5)
                }
                ZStack(alignment: .topLeading) {
                    Capsule()
                        .fill(visorColor)
                        .frame(width: 13, height: 17)
                    Circle()
                        .fill(Color.white.opacity(0.9))
                        .frame(width: 4.5, height: 4.5)
                        .offset(x: 2.5, y: 2.5)
                }
            }
            .shadow(color: visorColor, radius: 6 * palette.glowScale)

        case .cyberCat:
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

/// CoreAnimation-offloaded live mascot character view (#70, #30).
/// Delegates continuous breathing, tail wag, paw/limb sway, overheating glitch, and ambient particle drift
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
    public let character: MascotCharacter

    @State private var isBlinking: Bool = false

    private struct MotionStageKey: Hashable {
        let character: MascotCharacter
        let state: BitzState
        let isLoafPosture: Bool
        let showParticles: Bool
        let isAttentionCueActive: Bool
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
        character: MascotCharacter = .cyberCat
    ) {
        self.palette = palette
        self.state = state
        self.isPetReactionActive = isPetReactionActive
        self.isLoafPosture = isLoafPosture ?? (state == .burnout || state == .charging)
        self.showParticles = showParticles
        self.customVisorColor = customVisorColor
        self.isPaused = isPaused
        self.isAttentionCueActive = isAttentionCueActive
        self.character = character
    }

    private var visorColor: Color {
        if let custom = customVisorColor {
            return custom
        }
        let rgb = BitzCharacterView.visorRGB(for: state)
        return Color(red: rgb.red, green: rgb.green, blue: rgb.blue)
    }

    public var body: some View {
        let shouldPause = isPaused || (state == .burnout && !showParticles)
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
                    character: character
                )
            } else {
                LiveMotionStageView(
                    character: character,
                    state: state,
                    isBlinking: isBlinking,
                    isPetReactionActive: isPetReactionActive,
                    isLoafPosture: isLoafPosture,
                    showParticles: showParticles,
                    visorColor: visorColor,
                    palette: palette,
                    isAttentionCueActive: isAttentionCueActive
                )
                .id(MotionStageKey(
                    character: character,
                    state: state,
                    isLoafPosture: isLoafPosture,
                    showParticles: showParticles,
                    isAttentionCueActive: isAttentionCueActive
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
    let character: MascotCharacter
    let state: BitzState
    let isBlinking: Bool
    let isPetReactionActive: Bool
    let isLoafPosture: Bool
    let showParticles: Bool
    let visorColor: Color
    let palette: AvatarResolvedPalette
    let isAttentionCueActive: Bool

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
            // Character-specific tail/thruster/appendage animated via out-of-process CALayer transform
            MascotRearAppendageView(
                character: character,
                isLoafPosture: isLoafPosture,
                visorColor: visorColor,
                palette: palette,
                wagAngleDegrees: 0
            )
            .background(
                CALayerMotionBridge(
                    kind: (!isLoafPosture && hasMotion)
                        ? .tailWag(
                            halfPeriod: (character == .cyberDog ? 0.72 : 0.98) / speed,
                            deltaRadians: (character == .cyberDog ? 14.0 : 10.0) * .pi / 180.0,
                            center: CGPoint(x: 24, y: 7)
                        )
                        : .none
                )
            )
            .compositingGroup()

            // Static torso subtree
            MascotTorsoView(
                character: character,
                state: state,
                isLoafPosture: isLoafPosture,
                visorColor: visorColor,
                palette: palette
            )
            .equatable()
            .frame(width: isLoafPosture ? 136 : 108, height: isLoafPosture ? 54 : 68)

            // Front Limbs (sway in opposite phase via out-of-process CALayer translation animations, or tap on .needsApproval)
            if !isLoafPosture {
                HStack(spacing: character == .hoverDrone ? 36 : 28) {
                    MascotLimbPairShape(character: character, visorColor: visorColor, palette: palette)
                        .background(
                            CALayerMotionBridge(
                                kind: isAttentionCueActive
                                    ? .pawTap(amplitude: 3.0, halfPeriod: 0.22)
                                    : (hasMotion ? .verticalSway(amplitude: 1.8, halfPeriod: 1.05 / speed) : .none)
                            )
                        )
                        .compositingGroup()

                    MascotLimbPairShape(character: character, visorColor: visorColor, palette: palette)
                        .background(
                            CALayerMotionBridge(
                                kind: isAttentionCueActive
                                    ? .pawTap(amplitude: -3.0, halfPeriod: 0.22)
                                    : (hasMotion ? .verticalSway(amplitude: -1.8, halfPeriod: 1.05 / speed) : .none)
                            )
                        )
                        .compositingGroup()
                }
                .frame(width: 76, height: 12)
                .offset(y: -4)
                .zIndex(2)
            }

            // Head & Ears/Antennas Assembly
            MascotHeadAssemblyView(
                character: character,
                state: state,
                isLoafPosture: isLoafPosture,
                isBlinking: isBlinking,
                isPetReactionActive: isPetReactionActive,
                visorColor: visorColor,
                palette: palette
            )
            .equatable()
            .frame(width: 132, height: 116)
            .offset(y: -BitzCharacterView.headLift(for: character, isLoafPosture: isLoafPosture))
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
                        liftY: character == .hoverDrone ? -5.0 : -3.5,
                        halfPeriod: (character == .cyberBunny ? 0.92 : 1.12) / speed,
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

/// Self-animating version of `BitzCharacterView` backed by CoreAnimation layer offloading (#70, #30).
public struct AnimatedBitzCharacterView: View {
    public let state: BitzState
    public let isLoafPosture: Bool?
    public let showParticles: Bool
    public let customVisorColor: Color?
    public let isPaused: Bool
    public let palette: AvatarResolvedPalette
    public let character: MascotCharacter

    public init(
        state: BitzState = .balanced,
        isLoafPosture: Bool? = nil,
        showParticles: Bool = true,
        customVisorColor: Color? = nil,
        isPaused: Bool = false,
        palette: AvatarResolvedPalette = .cyberpunkClassic,
        character: MascotCharacter = .cyberCat
    ) {
        self.palette = palette
        self.state = state
        self.isLoafPosture = isLoafPosture
        self.showParticles = showParticles
        self.customVisorColor = customVisorColor
        self.isPaused = isPaused
        self.character = character
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
            palette: palette,
            character: character
        )
    }
}
