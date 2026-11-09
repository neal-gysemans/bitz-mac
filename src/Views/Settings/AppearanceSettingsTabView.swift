import SwiftUI
import AppKit

/// Settings tab for customizing mascot appearance: live preview, size, opacity, theme presets, and custom colors (#94 C3).
public struct AppearanceSettingsTabView: View {
    @ObservedObject public var scaleStore: AvatarScaleStore
    @ObservedObject public var opacityStore: AvatarOpacityStore
    @ObservedObject private var settingsWindowManager: SettingsWindowManager = .shared
    public var engine: WellnessPointEngine?
    @ObservedObject public var paletteStore: AvatarPaletteStore
    public var licensingService: (any LicensingServiceProtocol)?

    public init(
        scaleStore: AvatarScaleStore,
        opacityStore: AvatarOpacityStore,
        engine: WellnessPointEngine? = nil,
        paletteStore: AvatarPaletteStore = AvatarPaletteStore(),
        licensingService: (any LicensingServiceProtocol)? = nil
    ) {
        self.scaleStore = scaleStore
        self.opacityStore = opacityStore
        self.engine = engine
        self.paletteStore = paletteStore
        self.licensingService = licensingService
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            // Live Interactive Avatar Preview Card
            liveAvatarPreviewCard

            // Section 1: Avatar Size & Scale
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

                    VStack(alignment: .leading, spacing: 6) {
                        Text("Size Presets")
                            .font(.caption)
                            .foregroundStyle(.secondary)

                        Picker("Size Presets", selection: Binding<AvatarSizePreset?>(
                            get: { AvatarSizePreset.allCases.first(where: { scaleStore.isPresetSelected($0) }) },
                            set: { if let preset = $0 { scaleStore.selectPreset(preset) } }
                        )) {
                            ForEach(AvatarSizePreset.allCases, id: \.rawValue) { preset in
                                Text(preset.percentageText).tag(Optional(preset))
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

            // Section 2:Mascot Opacity & Transparency
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

                    VStack(alignment: .leading, spacing: 6) {
                        Text("Opacity Presets")
                            .font(.caption)
                            .foregroundStyle(.secondary)

                        Picker("Opacity Presets", selection: Binding<AvatarOpacityPreset?>(
                            get: { AvatarOpacityPreset.allCases.first(where: { opacityStore.isPresetSelected($0) }) },
                            set: { if let preset = $0 { opacityStore.selectPreset(preset) } }
                        )) {
                            ForEach(AvatarOpacityPreset.allCases, id: \.rawValue) { preset in
                                Text(preset.percentageText).tag(Optional(preset))
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

            // Section 3: Theme & Colors
            AppearancePaletteSectionView(paletteStore: paletteStore, licensingService: licensingService)
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

            VStack(spacing: 8) {
                HStack {
                    Label("Live Mascot Preview", systemImage: "sparkles")
                        .font(.caption2.bold())
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(.ultraThinMaterial)
                        .cornerRadius(6)

                    Spacer()

                    let stateTitle = paletteStore.previewSlot?.title ?? (engine?.currentState ?? .balanced).displayName
                    Text("\(stateTitle) • \(scaleStore.formattedSizeSummary) • \(opacityStore.formattedOpacitySummary)")
                        .font(.caption2.monospacedDigit().bold())
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(.ultraThinMaterial)
                        .cornerRadius(6)
                }
                .padding(.horizontal, 12)
                .padding(.top, 10)

                ZStack {
                    let currentState = paletteStore.previewSlot?.previewState ?? engine?.currentState ?? .balanced
                    let previewScale = 0.65 * CGFloat(scaleStore.scaleFactor)
                    AnimatedBitzCharacterView(
                        state: currentState,
                        showParticles: true,
                        customVisorColor: paletteStore.resolvedPalette.visorColor(for: currentState),
                        isPaused: !settingsWindowManager.isWindowVisible,
                        palette: paletteStore.resolvedPalette
                    )
                    .scaleEffect(previewScale)
                    .opacity(opacityStore.opacityFactor)
                    .animation(.spring(response: 0.35, dampingFraction: 0.7), value: scaleStore.scaleFactor)
                    .animation(.easeInOut(duration: 0.2), value: opacityStore.opacityFactor)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding(.bottom, 6)
            }
        }
        .frame(height: 185)
        .clipped()
    }

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
