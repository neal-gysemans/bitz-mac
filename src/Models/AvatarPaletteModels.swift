import AppKit
import SwiftUI

// MARK: - Hex helpers

public enum AvatarHex {
    /// Normalizes `#RRGGBB` / `RRGGBB` (case-insensitive) to uppercase `#RRGGBB`; returns nil when invalid.
    public static func normalize(_ raw: String) -> String? {
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.hasPrefix("#") { text.removeFirst() }
        guard text.count == 6, text.allSatisfy({ $0.isHexDigit }) else { return nil }
        return "#" + text.uppercased()
    }

    public static func rgb(_ hex: String) -> (red: Double, green: Double, blue: Double)? {
        guard let normalized = normalize(hex), let value = UInt32(normalized.dropFirst(), radix: 16) else { return nil }
        return (
            Double((value >> 16) & 0xFF) / 255.0,
            Double((value >> 8) & 0xFF) / 255.0,
            Double(value & 0xFF) / 255.0
        )
    }

    public static func color(_ hex: String) -> Color {
        let c = rgb(hex) ?? (0.5, 0.5, 0.5)
        return Color(red: c.red, green: c.green, blue: c.blue)
    }

    public static func hex(from color: Color) -> String {
        let ns = NSColor(color).usingColorSpace(.sRGB) ?? NSColor.gray
        let r = Int((ns.redComponent * 255).rounded())
        let g = Int((ns.greenComponent * 255).rounded())
        let b = Int((ns.blueComponent * 255).rounded())
        return String(format: "#%02X%02X%02X", min(max(r, 0), 255), min(max(g, 0), 255), min(max(b, 0), 255))
    }
}

// MARK: - Emotion slots

/// Every state (plus the petting `<3` visor) that has its own configurable LED/glow/particle color.
public enum AvatarEmotionColorSlot: String, CaseIterable, Identifiable, Sendable {
    case balanced, superCharged, dopamineSad, overworked, burnout, charging, overheating, petting

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .balanced: return "Balanced"
        case .superCharged: return "Super Charged"
        case .dopamineSad: return "Dopamine Sad"
        case .overworked: return "Overworked"
        case .burnout: return "Burnout"
        case .charging: return "Charging"
        case .overheating: return "Overheating"
        case .petting: return "Petting (<3)"
        }
    }

    public init(state: BitzState) {
        switch state {
        case .balanced: self = .balanced
        case .superCharged: self = .superCharged
        case .dopamineSad: self = .dopamineSad
        case .overworked: self = .overworked
        case .burnout: self = .burnout
        case .charging: self = .charging
        case .overheating: self = .overheating
        }
    }

    /// The mascot state previewed for this slot (`nil` for petting, which is a visor overlay, not a state).
    public var previewState: BitzState? {
        switch self {
        case .balanced: return .balanced
        case .superCharged: return .superCharged
        case .dopamineSad: return .dopamineSad
        case .overworked: return .overworked
        case .burnout: return .burnout
        case .charging: return .charging
        case .overheating: return .overheating
        case .petting: return nil
        }
    }
}

extension BitzState {
    /// Human-readable state name ("Super Charged", not "superCharged").
    public var displayName: String { AvatarEmotionColorSlot(state: self).title }
}

// MARK: - Resolved palette

/// Fully resolved colors used for rendering. Equatable so views only update when values really change.
public struct AvatarResolvedPalette: Equatable, Sendable {
    public static let glowRange: ClosedRange<Double> = 0.0...1.5

    public var chassisHex: String
    public var chassisDeepHex: String
    /// `nil` keeps the trim following each emotion's visor color (the classic look).
    public var trimHex: String?
    public var glowIntensity: Double
    public var emotionHex: [AvatarEmotionColorSlot: String]

    public init(
        chassisHex: String,
        chassisDeepHex: String,
        trimHex: String? = nil,
        glowIntensity: Double = 1.0,
        emotionHex: [AvatarEmotionColorSlot: String]
    ) {
        self.chassisHex = chassisHex
        self.chassisDeepHex = chassisDeepHex
        self.trimHex = trimHex
        self.glowIntensity = min(max(glowIntensity, Self.glowRange.lowerBound), Self.glowRange.upperBound)
        self.emotionHex = emotionHex
    }

    public var chassisColor: Color { AvatarHex.color(chassisHex) }
    public var chassisDeepColor: Color { AvatarHex.color(chassisDeepHex) }
    public var glowScale: CGFloat { CGFloat(glowIntensity) }

    public func hex(for slot: AvatarEmotionColorSlot) -> String {
        emotionHex[slot] ?? Self.cyberpunkClassic.emotionHex[slot] ?? "#00F0FF"
    }

    public func color(for slot: AvatarEmotionColorSlot) -> Color {
        AvatarHex.color(hex(for: slot))
    }

    public func visorColor(for state: BitzState, warningVisorActive: Bool = false) -> Color {
        let effective: BitzState = (warningVisorActive && state != .overheating) ? .overworked : state
        return color(for: AvatarEmotionColorSlot(state: effective))
    }

    /// Trim stroke color: the explicit trim override, otherwise the live visor color.
    public func trim(over visor: Color) -> Color {
        trimHex.map(AvatarHex.color) ?? visor
    }

    public static var cyberpunkClassic: AvatarResolvedPalette { AvatarThemePreset.cyberpunkClassic.palette }
}

// MARK: - Presets

public enum AvatarThemePreset: String, CaseIterable, Identifiable, Sendable {
    case cyberpunkClassic, tokyoNight, catppuccinMocha, dracula, nord, matrix, stealth, solarized, colorblindSafe

    public static let defaultPreset: AvatarThemePreset = .cyberpunkClassic

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .cyberpunkClassic: return "Cyberpunk Classic"
        case .tokyoNight: return "Tokyo Night"
        case .catppuccinMocha: return "Catppuccin Mocha"
        case .dracula: return "Dracula / Synthwave '80s"
        case .nord: return "Nord / Arctic"
        case .matrix: return "Matrix / Retro CRT"
        case .stealth: return "Stealth / Monochrome"
        case .solarized: return "Solarized / Warm Amber"
        case .colorblindSafe: return "Colorblind-Safe (Okabe-Ito)"
        }
    }

    public var palette: AvatarResolvedPalette {
        func make(
            _ chassis: String, _ deep: String,
            balanced: String, superCharged: String, dopamineSad: String, overworked: String,
            burnout: String, charging: String, overheating: String, petting: String
        ) -> AvatarResolvedPalette {
            AvatarResolvedPalette(
                chassisHex: chassis,
                chassisDeepHex: deep,
                emotionHex: [
                    .balanced: balanced, .superCharged: superCharged, .dopamineSad: dopamineSad,
                    .overworked: overworked, .burnout: burnout, .charging: charging,
                    .overheating: overheating, .petting: petting
                ]
            )
        }
        switch self {
        case .cyberpunkClassic:
            return make("#1A1A1D", "#141418", balanced: "#00F0FF", superCharged: "#FF007F", dopamineSad: "#9D4EDD",
                        overworked: "#FFB000", burnout: "#FFB000", charging: "#00FF88", overheating: "#FF1E1E", petting: "#FF007F")
        case .tokyoNight:
            return make("#1A1B26", "#16161E", balanced: "#7AA2F7", superCharged: "#BB9AF7", dopamineSad: "#9D7CD8",
                        overworked: "#E0AF68", burnout: "#FF9E64", charging: "#9ECE6A", overheating: "#F7768E", petting: "#FF9CDB")
        case .catppuccinMocha:
            return make("#1E1E2E", "#181825", balanced: "#89DCEB", superCharged: "#F5C2E7", dopamineSad: "#CBA6F7",
                        overworked: "#F9E2AF", burnout: "#FAB387", charging: "#A6E3A1", overheating: "#F38BA8", petting: "#F2CDCD")
        case .dracula:
            return make("#282A36", "#21222C", balanced: "#8BE9FD", superCharged: "#FF79C6", dopamineSad: "#BD93F9",
                        overworked: "#FFB86C", burnout: "#F1FA8C", charging: "#50FA7B", overheating: "#FF5555", petting: "#FF92DF")
        case .nord:
            return make("#2E3440", "#242933", balanced: "#88C0D0", superCharged: "#B48EAD", dopamineSad: "#81A1C1",
                        overworked: "#EBCB8B", burnout: "#D08770", charging: "#A3BE8C", overheating: "#BF616A", petting: "#E5B8D8")
        case .matrix:
            return make("#0A0F0A", "#030603", balanced: "#00FF66", superCharged: "#66FF99", dopamineSad: "#00AA44",
                        overworked: "#CCFF00", burnout: "#88AA00", charging: "#00FFAA", overheating: "#FF3300", petting: "#99FFCC")
        case .stealth:
            return make("#2B2B2E", "#1F1F22", balanced: "#FFFFFF", superCharged: "#E6E6E6", dopamineSad: "#9A9A9A",
                        overworked: "#CCCCCC", burnout: "#8A8A8A", charging: "#D9D9D9", overheating: "#F5F5F5", petting: "#FFFFFF")
        case .solarized:
            return make("#262626", "#1C1C1C", balanced: "#B58900", superCharged: "#D33682", dopamineSad: "#6C71C4",
                        overworked: "#CB4B16", burnout: "#DC322F", charging: "#859900", overheating: "#DC322F", petting: "#D33682")
        case .colorblindSafe:
            return make("#14141A", "#0E0E13", balanced: "#56B4E9", superCharged: "#CC79A7", dopamineSad: "#0072B2",
                        overworked: "#E69F00", burnout: "#F0E442", charging: "#009E73", overheating: "#D55E00", petting: "#CC79A7")
        }
    }
}
