import SwiftUI

/// Visual Character Roster Gallery inside Settings -> Appearance (`FR-004`, `#30`).
/// Displays live animated previews, character names, archetype badges, personality bios, and Pro tier gating.
public struct AppearanceCharacterRosterSectionView: View {
    @ObservedObject public var characterStore: AvatarCharacterStore
    @ObservedObject public var paletteStore: AvatarPaletteStore
    @ObservedObject private var settingsWindowManager: SettingsWindowManager = .shared
    public var engine: WellnessPointEngine?
    public var licensingService: (any LicensingServiceProtocol)?

    @State private var showingProPopover: Bool = false
    @State private var proPopoverTitle: String = "Bitz Pro Companion"
    @State private var proPopoverDescription: String = ""

    private var isMultiMascotUnlocked: Bool {
        licensingService?.isFeatureUnlocked(.multiMascot) ?? true
    }

    public init(
        characterStore: AvatarCharacterStore,
        paletteStore: AvatarPaletteStore = AvatarPaletteStore(),
        engine: WellnessPointEngine? = nil,
        licensingService: (any LicensingServiceProtocol)? = nil
    ) {
        self.characterStore = characterStore
        self.paletteStore = paletteStore
        self.engine = engine
        self.licensingService = licensingService
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Label("Companion Character Roster", systemImage: "person.2.crop.square.stack.fill")
                    .font(.headline)

                Spacer()

                if !isMultiMascotUnlocked {
                    Button {
                        proPopoverTitle = "Multi-Mascot Roster (Pro)"
                        proPopoverDescription = "Unlock Byte the Cyber Dog, Aero the Hover Sentinel, Pixel the Retro Mech, and Volt the Cyber Bunny with Bitz Pro."
                        showingProPopover = true
                    } label: {
                        ProBadgeView()
                    }
                    .buttonStyle(.plain)
                }
            }
            .popover(isPresented: $showingProPopover) {
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Image(systemName: "lock.fill")
                            .foregroundColor(.cyan)
                        Text(proPopoverTitle)
                            .font(.headline)
                    }

                    Text(proPopoverDescription)
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .fixedSize(horizontal: false, vertical: true)

                    Divider()

                    HStack {
                        Spacer()
                        Button("View Bitz Pro Perks") {
                            showingProPopover = false
                            NotificationCenter.default.post(name: .bitzOpenProSettingsTab, object: nil)
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(.cyan)
                        .controlSize(.small)
                    }
                }
                .padding(14)
                .frame(width: 270)
            }

            Text("Choose your desktop companion. All characters share your focus streak, wellness PTS state, and custom color palette.")
                .font(.caption)
                .foregroundStyle(.secondary)

            VStack(spacing: 10) {
                ForEach(MascotCharacter.allCases) { character in
                    characterCard(for: character)
                }
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(Color(nsColor: .controlBackgroundColor))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(Color.secondary.opacity(0.15), lineWidth: 1)
        )
    }

    @ViewBuilder
    private func characterCard(for character: MascotCharacter) -> some View {
        let isSelected = (characterStore.selectedCharacter == character)
        let isLocked = character.isPro && !isMultiMascotUnlocked
        let currentState = paletteStore.previewSlot?.previewState ?? engine?.currentState ?? .balanced

        Button {
            if isLocked {
                proPopoverTitle = "\(character.title) (Pro)"
                proPopoverDescription = "\(character.bio) Unlock the full Multi-Mascot Roster with Bitz Pro."
                showingProPopover = true
            } else {
                characterStore.selectCharacter(character)
            }
        } label: {
            HStack(spacing: 14) {
                // Miniature live animated character rig preview
                ZStack {
                    RoundedRectangle(cornerRadius: 10)
                        .fill(Color(nsColor: .windowBackgroundColor))
                        .overlay(
                            RoundedRectangle(cornerRadius: 10)
                                .stroke(isSelected ? Color.accentColor.opacity(0.6) : Color.secondary.opacity(0.15), lineWidth: 1)
                        )

                    AnimatedBitzCharacterView(
                        state: currentState,
                        showParticles: false,
                        customVisorColor: paletteStore.resolvedPalette.visorColor(for: currentState),
                        isPaused: !settingsWindowManager.isWindowVisible,
                        palette: paletteStore.resolvedPalette,
                        character: character
                    )
                    .scaleEffect(0.38)
                    .frame(width: 78, height: 64)
                    .clipped()
                }
                .frame(width: 78, height: 64)

                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 6) {
                        Image(systemName: character.menuBarSymbolName)
                            .font(.caption.bold())
                            .foregroundStyle(isSelected ? Color.accentColor : Color.secondary)

                        Text(character.name)
                            .font(.subheadline.bold())
                            .foregroundStyle(.primary)

                        Text("• \(character.archetype)")
                            .font(.caption)
                            .foregroundStyle(.secondary)

                        Spacer()

                        if isSelected {
                            Label("Active", systemImage: "checkmark.circle.fill")
                                .font(.caption2.bold())
                                .foregroundStyle(Color.accentColor)
                                .padding(.horizontal, 8)
                                .padding(.vertical, 3)
                                .background(
                                    Capsule()
                                        .fill(Color.accentColor.opacity(0.14))
                                )
                        } else if isLocked {
                            ProBadgeView()
                        } else {
                            Text("Select")
                                .font(.caption2.weight(.semibold))
                                .foregroundStyle(.secondary)
                                .padding(.horizontal, 8)
                                .padding(.vertical, 3)
                                .background(
                                    Capsule()
                                        .stroke(Color.secondary.opacity(0.3), lineWidth: 1)
                                )
                        }
                    }

                    Text(character.bio)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.leading)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 10)
                    .fill(isSelected ? Color.accentColor.opacity(0.08) : Color(nsColor: .windowBackgroundColor).opacity(0.5))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 10)
                    .stroke(isSelected ? Color.accentColor.opacity(0.45) : Color.secondary.opacity(0.12), lineWidth: isSelected ? 1.5 : 1)
            )
            .contentShape(RoundedRectangle(cornerRadius: 10))
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Select \(character.title)")
    }
}
