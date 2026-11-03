import SwiftUI

/// Settings card: theme presets, chassis/trim/glow, and per-emotion color rows with live preview.
public struct AppearancePaletteSectionView: View {
    @ObservedObject public var paletteStore: AvatarPaletteStore

    @State private var hexDrafts: [String: String] = [:]

    public init(paletteStore: AvatarPaletteStore) {
        self.paletteStore = paletteStore
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Label("Theme & Colors", systemImage: "paintpalette.fill")
                .font(.headline)

            Picker("Theme Preset", selection: Binding(
                get: { paletteStore.selectedPreset },
                set: { paletteStore.selectPreset($0) }
            )) {
                ForEach(AvatarThemePreset.allCases) { preset in
                    Text(preset.title).tag(preset)
                }
            }
            .pickerStyle(.menu)

            Divider()

            colorRow(
                title: "Chassis (body shell)",
                key: "chassis",
                currentHex: paletteStore.resolvedPalette.chassisHex,
                isCustom: paletteStore.chassisOverride != nil,
                apply: { _ = paletteStore.setChassisHex($0) },
                reset: { paletteStore.resetChassis() },
                preview: nil
            )

            colorRow(
                title: "Trim (outlines)",
                key: "trim",
                currentHex: paletteStore.resolvedPalette.trimHex ?? "#FFFFFF",
                isCustom: paletteStore.trimOverride != nil,
                subtitle: paletteStore.trimOverride == nil ? "Following each emotion's LED color" : nil,
                apply: { _ = paletteStore.setTrimHex($0) },
                reset: { paletteStore.resetTrim() },
                preview: nil
            )

            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text("Glow intensity").font(.subheadline)
                    Spacer()
                    Text("\(Int((paletteStore.glowIntensity * 100).rounded()))%")
                        .font(.subheadline.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
                Slider(
                    value: Binding(
                        get: { paletteStore.glowIntensity },
                        set: { paletteStore.setGlowIntensity($0) }
                    ),
                    in: AvatarResolvedPalette.glowRange
                )
            }

            Divider()

            Text("Per-emotion LED, glow & particle colors")
                .font(.caption)
                .foregroundStyle(.secondary)

            ForEach(AvatarEmotionColorSlot.allCases) { slot in
                colorRow(
                    title: slot.title,
                    key: slot.rawValue,
                    currentHex: paletteStore.resolvedPalette.hex(for: slot),
                    isCustom: paletteStore.isSlotCustomized(slot),
                    apply: { _ = paletteStore.setEmotionHex($0, for: slot) },
                    reset: { paletteStore.resetSlot(slot) },
                    preview: { paletteStore.triggerPreview(for: slot) }
                )
            }

            HStack {
                Spacer()
                Button("Reset to Default Theme") {
                    hexDrafts.removeAll()
                    paletteStore.resetToDefaultTheme()
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
    private func colorRow(
        title: String,
        key: String,
        currentHex: String,
        isCustom: Bool,
        subtitle: String? = nil,
        apply: @escaping (String) -> Void,
        reset: @escaping () -> Void,
        preview: (() -> Void)?
    ) -> some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(.subheadline)
                if let subtitle {
                    Text(subtitle).font(.caption2).foregroundStyle(.secondary)
                }
            }
            Spacer()

            ColorPicker("", selection: Binding(
                get: { AvatarHex.color(currentHex) },
                set: { apply(AvatarHex.hex(from: $0)) }
            ), supportsOpacity: false)
            .labelsHidden()

            TextField("#RRGGBB", text: Binding(
                get: { hexDrafts[key] ?? currentHex },
                set: { newValue in
                    hexDrafts[key] = newValue
                    if AvatarHex.normalize(newValue) != nil {
                        apply(newValue)
                        hexDrafts[key] = nil
                    }
                }
            ))
            .textFieldStyle(.roundedBorder)
            .font(.caption.monospaced())
            .frame(width: 84)

            if let preview {
                Button("Preview", action: preview)
                    .controlSize(.small)
            }

            Button {
                hexDrafts[key] = nil
                reset()
            } label: {
                Image(systemName: "arrow.uturn.backward")
            }
            .buttonStyle(.borderless)
            .help("Reset to theme default")
            .disabled(!isCustom)
        }
    }
}
