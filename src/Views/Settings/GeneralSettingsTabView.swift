import SwiftUI
import AppKit

/// Settings tab for screen placement, mascot interaction, and multi-monitor routing.
public struct GeneralSettingsTabView: View {
    @ObservedObject public var positionStore: AvatarPositionStore
    @ObservedObject public var displayStore: DisplayPreferenceStore
    @ObservedObject public var interactionSettings: MascotInteractionSettingsStore
    public var inboxDirectoryURL: URL

    public init(
        positionStore: AvatarPositionStore,
        displayStore: DisplayPreferenceStore,
        interactionSettings: MascotInteractionSettingsStore = MascotInteractionSettingsStore(),
        inboxDirectoryURL: URL = FileDropInboxService.defaultInboxDirectory
    ) {
        self.interactionSettings = interactionSettings
        self.inboxDirectoryURL = inboxDirectoryURL
        self.positionStore = positionStore
        self.displayStore = displayStore
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            // Section 1: Position & Screen Anchoring
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
                            .accessibilityLabel("Lock Position")
                        } else {
                            Button {
                                positionStore.unlockPosition()
                            } label: {
                                Label("Unlock Position (Drag to Move)", systemImage: "lock.open.fill")
                            }
                            .accessibilityLabel("Unlock Position")
                        }

                        if positionStore.isFreeform || positionStore.cornerAnchor != .bottomRight {
                            Button("Reset to Bottom-Right") {
                                positionStore.resetToDefaultCorner()
                            }
                        }
                    }

                    if interactionSettings.isHoldToInteractEnabled {
                        HStack(spacing: 6) {
                            Image(systemName: "info.circle")
                                .foregroundStyle(.secondary)
                            Text("Hold \(interactionSettings.holdModifier.displayName) anytime to freely drag Bitz anywhere on screen.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
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

            // Section 2: Interaction, Petting & File Drop-Zone
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
                        // Only offered once chosen below or by dragging, since it needs a display ID
                        if displayStore.targetMode == .specific {
                            Text(displayStore.summaryTitle).tag(DisplayTargetMode.specific)
                        }
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
