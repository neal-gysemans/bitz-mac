import Foundation

/// `@MainActor` store managing the active companion character selection (`MascotCharacter`),
/// persisted in `UserDefaults` under `"avatarSelectedCharacter"` and integrated with `BitzFeature.multiMascot` Pro licensing (`FR-002`, `#30`).
@MainActor
public final class AvatarCharacterStore: ObservableObject {
    public static let selectedCharacterKey = "avatarSelectedCharacter"

    private let userDefaults: UserDefaults
    private let licensingService: (any LicensingServiceProtocol)?

    @Published public private(set) var selectedCharacter: MascotCharacter
    public var onCharacterChanged: ((MascotCharacter) -> Void)?

    public init(
        userDefaults: UserDefaults = .standard,
        licensingService: (any LicensingServiceProtocol)? = nil
    ) {
        self.userDefaults = userDefaults
        self.licensingService = licensingService

        var storedCharacter = userDefaults
            .string(forKey: Self.selectedCharacterKey)
            .flatMap(MascotCharacter.init(rawValue:)) ?? .defaultCharacter

        if let licensingService, !licensingService.isFeatureUnlocked(.multiMascot), storedCharacter.isPro {
            storedCharacter = .defaultCharacter
        }

        self.selectedCharacter = storedCharacter
    }

    /// Whether the given companion character is unlocked for the current user tier.
    public func isCharacterUnlocked(_ character: MascotCharacter) -> Bool {
        guard character.isPro else { return true }
        return licensingService?.isFeatureUnlocked(.multiMascot) ?? true
    }

    /// Selects a companion character and persists it to `UserDefaults`.
    /// Returns `false` and leaves `selectedCharacter` unchanged if the character requires Bitz Pro and `.multiMascot` is locked.
    @discardableResult
    public func selectCharacter(_ character: MascotCharacter) -> Bool {
        guard isCharacterUnlocked(character) else {
            return false
        }
        let changed = (selectedCharacter != character)
        selectedCharacter = character
        userDefaults.set(character.rawValue, forKey: Self.selectedCharacterKey)
        if changed {
            onCharacterChanged?(character)
        }
        return true
    }

    /// Re-evaluates tier entitlement (e.g., after license activation, deactivation, or QA override) and falls back to `.cyberCat` if locked.
    /// Leaves `UserDefaults` untouched while `licensingService?.isSimulatingFreeTier == true` so switching back restores Pro preferences.
    public func validateTierEntitlement() {
        if !isCharacterUnlocked(selectedCharacter) {
            selectedCharacter = .defaultCharacter
            if licensingService?.isSimulatingFreeTier != true {
                userDefaults.set(MascotCharacter.defaultCharacter.rawValue, forKey: Self.selectedCharacterKey)
            }
            onCharacterChanged?(.defaultCharacter)
        } else if licensingService?.isFeatureUnlocked(.multiMascot) == true {
            let stored = userDefaults
                .string(forKey: Self.selectedCharacterKey)
                .flatMap(MascotCharacter.init(rawValue:)) ?? .defaultCharacter
            if stored != selectedCharacter {
                selectedCharacter = stored
                onCharacterChanged?(stored)
            }
        }
    }

    /// Resets the companion character back to the default Bitz Cyber Cat (`.cyberCat`).
    public func resetToDefault() {
        _ = selectCharacter(.defaultCharacter)
    }
}
