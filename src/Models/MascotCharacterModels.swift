import Foundation

// MARK: - Mascot Character Roster (#30)

/// Represents the selectable companion character archetype in the Bitz multi-mascot roster (`FR-001`, `#30`).
/// All characters bind to the same `WellnessPointEngine`, `AvatarPaletteStore`, and CoreAnimation motion pipeline.
public enum MascotCharacter: String, CaseIterable, Identifiable, Codable, Sendable, Equatable {
    case cyberCat = "cyber_cat"
    case cyberDragon = "cyber_dragon"
    case cyberDog = "cyber_dog"
    case hoverDrone = "hover_drone"
    case retroMech = "retro_mech"
    case cyberBunny = "cyber_bunny"

    public static let defaultCharacter: MascotCharacter = .cyberCat

    public var id: String { rawValue }

    /// Short character name shown in badges, headers, and quick actions.
    public var name: String {
        switch self {
        case .cyberCat: return "Bitz"
        case .cyberDragon: return "Drako"
        case .cyberDog: return "Byte"
        case .hoverDrone: return "Aero"
        case .retroMech: return "Pixel"
        case .cyberBunny: return "Volt"
        }
    }

    /// Descriptive archetype subtitle shown in the Settings Character Gallery.
    public var archetype: String {
        switch self {
        case .cyberCat: return "The Cyber Cat"
        case .cyberDragon: return "The Cyber Dragon"
        case .cyberDog: return "The Cyber Hound"
        case .hoverDrone: return "The Hover Sentinel"
        case .retroMech: return "The Retro Mech"
        case .cyberBunny: return "The Cyber Bunny"
        }
    }

    /// Combined display title for menus and pickers (e.g., `"Bitz (The Cyber Cat)"`).
    public var title: String {
        "\(name) (\(archetype))"
    }

    /// Personality and visual anatomy blurb displayed in the Settings Character Gallery (`FR-004`).
    public var bio: String {
        switch self {
        case .cyberCat:
            return "Sleek cyber-feline with pointed neon ears, wrap-around LED visor, arc-reactor chest core, and swishing tail."
        case .cyberDragon:
            return "Apex mecha-wyvern with swept plasma horns, spread cyber-wings, V-slanted dragon visor, armored scale plastron, and blade-tipped tail."
        case .cyberDog:
            return "Tactical K9 mecha-hound with sculpted jowl armor, protruding cyber-muzzle, folded acoustic drop-ears, and twin-ring antenna tail."
        case .hoverDrone:
            return "Legless antigravity octagon-core sentinel with floating winglet nacelles, 360° targeting reticle optic, and concentric levitation rings."
        case .retroMech:
            return "Chunky 80s mecha-cassette robot with beveled CRT monitor head, shoulder pauldrons, cassette power deck, and hydraulic pincer clamps."
        case .cyberBunny:
            return "Aerodynamic lagomorph speedster with sculpted twin-blade energy ears, plush pear-shaped cheeks, dynamo heart core, and bionic hopper feet."
        }
    }

    /// SF Symbol used for the macOS Menu Bar status item and UI badges (`FR-005`).
    public var menuBarSymbolName: String {
        switch self {
        case .cyberCat: return "cat.fill"
        case .cyberDragon: return "flame.fill"
        case .cyberDog: return "dog.fill"
        case .hoverDrone: return "circle.hexagongrid.fill"
        case .retroMech: return "cpu.fill"
        case .cyberBunny: return "hare.fill"
        }
    }

    /// Whether this companion requires the `BitzFeature.multiMascot` Pro entitlement (`FR-002`, `#117`).
    /// Bitz the Cyber Cat is always free; additional roster companions are part of Bitz Pro.
    public var isPro: Bool {
        switch self {
        case .cyberCat:
            return false
        case .cyberDragon, .cyberDog, .hoverDrone, .retroMech, .cyberBunny:
            return true
        }
    }

    /// LED visor expression displayed during a petting interaction (`FR-006`).
    public var petVisorText: String {
        switch self {
        case .cyberCat: return "<3  <3"
        case .cyberDragon: return "🔥 <3 🔥"
        case .cyberDog: return "^ w ^"
        case .hoverDrone: return "◎ <3 ◎"
        case .retroMech: return "[ <3 ]"
        case .cyberBunny: return "* ^ *"
        }
    }

    /// Transient speech bubble text shown when the user pets the companion (`FR-006`).
    public var petReactionBubble: String {
        switch self {
        case .cyberCat: return "💚 *purrrr* Systems happy!"
        case .cyberDragon: return "🐉 *plasma rumble* Reactor core blazing!"
        case .cyberDog: return "🐶 *wag wag* Loyal K9 circuits charged!"
        case .hoverDrone: return "🛸 *harmonic chime* Levitation rings locked!"
        case .retroMech: return "🤖 *beep-boop* Cassette deck at max power!"
        case .cyberBunny: return "🐰 *boing!* Twin blade ears at 100%!"
        }
    }
}
