import SwiftUI
import AppKit

/// Settings tab for customizing mascot size, opacity, screen placement, and multi-monitor routing.
public struct GeneralSettingsTabView: View {
    @ObservedObject public var scaleStore: AvatarScaleStore
    @ObservedObject public var opacityStore: AvatarOpacityStore
    @ObservedObject public var positionStore: AvatarPositionStore
    @ObservedObject public var displayStore: DisplayPreferenceStore
    @ObservedObject private var settingsWindowManager: SettingsWindowManager = .shared
    public var engine: WellnessPointEngine?
    @ObservedObject public var interactionSettings: MascotInteractionSettingsStore
    public var inboxDirectoryURL: URL
    @ObservedObject public var paletteStore: AvatarPaletteStore

    public init(
        scaleStore: AvatarScaleStore,
        opacityStore: AvatarOpacityStore,
        positionStore: AvatarPositionStore,
        displayStore: DisplayPreferenceStore,
        engine: WellnessPointEngine? = nil,
        interactionSettings: MascotInteractionSettingsStore = MascotInteractionSettingsStore(),
        inboxDirectoryURL: URL = FileDropInboxService.defaultInboxDirectory,
        paletteStore: AvatarPaletteStore = AvatarPaletteStore()
    ) {
        self.interactionSettings = interactionSettings
        self.inboxDirectoryURL = inboxDirectoryURL
        self.paletteStore = paletteStore
        self.scaleStore = scaleStore
        self.opacityStore = opacityStore
        self.positionStore = positionStore
        self.displayStore = displayStore
        self.engine = engine
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            // Live Interactive Avatar Preview Card
            liveAvatarPreviewCard

            // Section 1: Mascot Visibility
            settingsCard(title: "Desktop Mascot Visibility", systemImage: "eye.fill") {
                VStack(alignment: .leading, spacing: 10) {
                    Toggle("Show Mascot on Desktop", isOn: $positionStore.isMascotVisible)
                        .font(.subheadline.bold())

                    Text(positionStore.isMascotVisible
                        ? "Bitz is currently active and floating on your desktop screen."
                        : "Bitz is currently hidden from your desktop screen. Toggle on anytime to restore.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            // Section 2: Avatar Size & Scale
            settingsCard(title: "Avatar Size & Scale", systemImage: "arrow.up.left.and.arrow.down.right") {
                VStack(alignment: .leading, spacing: 12) {
                    HStack {
                        Text("Current Size:")
                            .font(.subheadline)
                        Spacer()
                        Text(scaleStore.formattedSizeSummary)
                            .font(.subheadline.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }

                    // Stepper Buttons
                    HStack(spacing: 10) {
                        Button {
                            scaleStore.stepDown()
                        } label: {
                            Label("Smaller (-10%)", systemImage: "minus")
                        }
                        .disabled(!scaleStore.canStepDown)

                        Button {
                            scaleStore.stepUp()
                        } label: {
                            Label("Larger (+10%)", systemImage: "plus")
                        }
                        .disabled(!scaleStore.canStepUp)

                        if !scaleStore.isPresetSelected(.defaultSize) {
                            Button("Reset (100%)") {
                                scaleStore.resetToDefault()
                            }
                        }
                    }

                    // Segmented Presets (Concise percentage labels to avoid horizontal overflow)
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Size Presets")
                            .font(.caption)
                            .foregroundStyle(.secondary)

                        Picker("Size Presets", selection: Binding(
                            get: { AvatarSizePreset.allCases.first(where: { scaleStore.isPresetSelected($0) }) ?? .defaultSize },
                            set: { scaleStore.selectPreset($0) }
                        )) {
                            ForEach(AvatarSizePreset.allCases, id: \.rawValue) { preset in
                                Text(preset.percentageText).tag(preset)
                            }
                        }
                        .pickerStyle(.segmented)
                        .labelsHidden()

                        if let current = AvatarSizePreset.allCases.first(where: { scaleStore.isPresetSelected($0) }) {
                            Text("Active: \(current.menuTitle)")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }

            // Section 2: Avatar Opacity & Transparency
            settingsCard(title: "Mascot Opacity & Transparency", systemImage: "circle.lefthalf.filled") {
                VStack(alignment: .leading, spacing: 12) {
                    HStack {
                        Text("Current Opacity:")
                            .font(.subheadline)
                        Spacer()
                        Text(opacityStore.formattedOpacitySummary)
                            .font(.subheadline.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }

                    HStack(spacing: 10) {
                        Button {
                            opacityStore.stepDown()
                        } label: {
                            Label("More Transparent (-10%)", systemImage: "chevron.down")
                        }
                        .disabled(!opacityStore.canStepDown)

                        Button {
                            opacityStore.stepUp()
                        } label: {
                            Label("More Solid (+10%)", systemImage: "chevron.up")
                        }
                        .disabled(!opacityStore.canStepUp)
                    }

                    // Opacity Presets (Concise labels)
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Opacity Presets")
                            .font(.caption)
                            .foregroundStyle(.secondary)

                        Picker("Opacity Presets", selection: Binding(
                            get: { AvatarOpacityPreset.allCases.first(where: { opacityStore.isPresetSelected($0) }) ?? .translucent },
                            set: { opacityStore.selectPreset($0) }
                        )) {
                            ForEach(AvatarOpacityPreset.allCases, id: \.rawValue) { preset in
                                Text(preset.percentageText).tag(preset)
                            }
                        }
                        .pickerStyle(.segmented)
                        .labelsHidden()

                        if let current = AvatarOpacityPreset.allCases.first(where: { opacityStore.isPresetSelected($0) }) {
                            Text("Active: \(current.menuTitle)")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }

            // Section 3: Position & Screen Anchoring
            settingsCard(title: "Screen Placement & Dragging", systemImage: "rectangle.inset.filled.and.cursorarrow") {
                VStack(alignment: .leading, spacing: 12) {
                    HStack {
                        Text("Placement Mode:")
                            .font(.subheadline)
                        Spacer()
                        Text(positionStore.formattedPositionSummary)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }

                    HStack(spacing: 10) {
                        if positionStore.isPositionUnlocked {
                            Button {
                                positionStore.lockPosition()
                            } label: {
                                Label("Lock Position [⎋ Esc]", systemImage: "lock.fill")
                            }
                            .buttonStyle(.borderedProminent)
                        } else {
                            Button {
                                positionStore.unlockPosition()
                            } label: {
                                Label("Unlock Position (Drag to Move)", systemImage: "lock.open.fill")
                            }
                        }

                        if positionStore.isFreeform || positionStore.cornerAnchor != .bottomRight {
                            Button("Reset to Bottom-Right") {
                                positionStore.resetToDefaultCorner()
                            }
                        }
                    }

                    HStack(spacing: 6) {
                        Image(systemName: "info.circle")
                            .foregroundStyle(.secondary)
                        Text("Hold \(interactionSettings.holdModifier.displayName) anytime to freely drag Bitz anywhere on screen.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    Picker("Corner Anchor", selection: Binding(
                        get: { positionStore.cornerAnchor },
                        set: { positionStore.selectCorner($0) }
                    )) {
                        ForEach(ScreenCornerAnchor.allCases, id: \.rawValue) { corner in
                            Text(corner.menuTitle).tag(corner)
                        }
                    }
                    .pickerStyle(.menu)
                }
            }

            // Section 3b: Theme & Colors
            AppearancePaletteSectionView(paletteStore: paletteStore)

            // Section 3c: Interaction, Petting & File Drop-Zone
            settingsCard(title: "Interaction, Petting & File Drop-Zone", systemImage: "hand.tap.fill") {
                VStack(alignment: .leading, spacing: 12) {
                    Toggle("Hold a key to interact with Bitz", isOn: $interactionSettings.isHoldToInteractEnabled)
                        .font(.subheadline)

                    Picker("Hold-to-interact key", selection: $interactionSettings.holdModifier) {
                        ForEach(HoldModifierKey.allCases) { key in
                            Text(key.displayName).tag(key)
                        }
                    }
                    .pickerStyle(.segmented)
                    .disabled(!interactionSettings.isHoldToInteractEnabled)

                    Toggle("Stroke Bitz with the cursor to pet him", isOn: $interactionSettings.isStrokeToPetEnabled)
                        .font(.subheadline)
                    Text("While interactive, sweep the cursor back and forth over Bitz. Petting gives a small, capped focus boost.")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    Toggle("Drop files on Bitz to copy their path", isOn: $interactionSettings.isFileDropEnabled)
                        .font(.subheadline)

                    Toggle("Also write a JSON entry to the agent inbox", isOn: $interactionSettings.isInboxHandoffEnabled)
                        .font(.subheadline)
                        .disabled(!interactionSettings.isFileDropEnabled)
                    Text(inboxDirectoryURL.path)
                        .font(.caption2.monospaced())
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
            }

            // Section 4: Multi-Monitor & Displays
            settingsCard(title: "Display Routing", systemImage: "display.2") {
                VStack(alignment: .leading, spacing: 12) {
                    Picker("Target Display", selection: Binding(
                        get: { displayStore.targetMode },
                        set: { displayStore.selectMode($0) }
                    )) {
                        Text("Primary Screen").tag(DisplayTargetMode.primary)
                        Text("Follow Active Screen").tag(DisplayTargetMode.followActive)
                        Text("All Screens").tag(DisplayTargetMode.allDisplays)
                    }
                    .pickerStyle(.menu)

                    if !displayStore.connectedScreens.isEmpty {
                        VStack(alignment: .leading, spacing: 6) {
                            Text("Connected Displays:")
                                .font(.caption)
                                .foregroundStyle(.secondary)

                            ForEach(displayStore.connectedScreens) { screen in
                                let isSelected = (displayStore.targetMode == .specific && displayStore.targetDisplayID == screen.id)
                                Button {
                                    displayStore.selectSpecificDisplay(id: screen.id, name: screen.name)
                                } label: {
                                    HStack {
                                        Image(systemName: isSelected ? "checkmark.circle.fill" : "display")
                                            .foregroundStyle(isSelected ? Color.accentColor : Color.secondary)
                                        Text(screen.name)
                                            .font(.subheadline)
                                        Spacer()
                                        if screen.isPrimary {
                                            Text("Primary")
                                                .font(.caption2.bold())
                                                .padding(.horizontal, 6)
                                                .padding(.vertical, 2)
                                                .background(Color.secondary.opacity(0.15))
                                                .cornerRadius(4)
                                        }
                                    }
                                    .padding(.vertical, 4)
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }
                }
            }
        }
    }

    // MARK: - Live Preview Card

    private var liveAvatarPreviewCard: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 14)
                .fill(Color(nsColor: .controlBackgroundColor))
                .overlay(
                    RoundedRectangle(cornerRadius: 14)
                        .stroke(Color.secondary.opacity(0.15), lineWidth: 1)
                )

            // Dotted Matrix Wallpaper Pattern
            Canvas { context, size in
                let spacing: CGFloat = 16
                for x in stride(from: 8, to: size.width, by: spacing) {
                    for y in stride(from: 8, to: size.height, by: spacing) {
                        let rect = CGRect(x: x, y: y, width: 2, height: 2)
                        context.fill(Path(ellipseIn: rect), with: .color(Color.secondary.opacity(0.12)))
                    }
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 14))

            // Real Bitz Cyber Mascot with reactive scale & opacity
            VStack {
                let currentState = paletteStore.previewSlot?.previewState ?? engine?.currentState ?? .balanced
                AnimatedBitzCharacterView(
                    state: currentState,
                    showParticles: true,
                    customVisorColor: paletteStore.resolvedPalette.visorColor(for: currentState),
                    isPaused: !settingsWindowManager.isWindowVisible,
                    palette: paletteStore.resolvedPalette
                )
                    .scaleEffect(0.70 * CGFloat(scaleStore.scaleFactor))
                    .frame(height: 140)
                    .opacity(opacityStore.opacityFactor)
                    .animation(.spring(response: 0.35, dampingFraction: 0.7), value: scaleStore.scaleFactor)
                    .animation(.easeInOut(duration: 0.2), value: opacityStore.opacityFactor)
            }
            .frame(height: 150)
            .padding(.top, 16)

            // Top Info Bar
            VStack {
                HStack {
                    Label("Live Mascot Preview", systemImage: "sparkles")
                        .font(.caption2.bold())
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(.ultraThinMaterial)
                        .cornerRadius(6)

                    Spacer()

                    let stateTitle = (engine?.currentState ?? .balanced).rawValue.capitalized
                    Text("\(stateTitle) • \(scaleStore.formattedSizeSummary) • \(opacityStore.formattedOpacitySummary)")
                        .font(.caption2.monospacedDigit().bold())
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(.ultraThinMaterial)
                        .cornerRadius(6)
                }
                .padding(10)
                Spacer()
            }
        }
        .frame(height: 175)
    }

    // MARK: - Reusable Settings Card Container

    private func settingsCard<Content: View>(
        title: String,
        systemImage: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Label(title, systemImage: systemImage)
                .font(.headline)
                .foregroundStyle(.primary)

            content()
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
}
