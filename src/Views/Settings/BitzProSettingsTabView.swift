import SwiftUI

/// Settings tab for inspecting the active plan, entering cryptographic license keys,
/// and previewing Bitz Pro capabilities.
public struct BitzProSettingsTabView: View {
    @ObservedObject public var licensingService: LicensingService
    public var audioPlayer: (any CyberAudioPlaying)?

    @State private var licenseKeyInput: String = ""
    @State private var errorMessage: String? = nil
    @State private var successMessage: String? = nil
    @State private var isActivating: Bool = false

    public init(
        licensingService: LicensingService,
        audioPlayer: (any CyberAudioPlaying)? = nil
    ) {
        self.licensingService = licensingService
        self.audioPlayer = audioPlayer
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            headerSection
            Divider()
            planStatusCard
            Divider()
            licenseManagementSection
            Divider()
            proFeaturesShowcaseSection
        }
    }

    // MARK: - Header

    private var headerSection: some View {
        HStack(spacing: 12) {
            ZStack {
                Circle()
                    .fill(Color.cyan.opacity(0.15))
                    .frame(width: 44, height: 44)

                Image(systemName: "crown.fill")
                    .font(.system(size: 20))
                    .foregroundStyle(
                        LinearGradient(
                            colors: [.cyan, .purple],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
            }

            VStack(alignment: .leading, spacing: 2) {
                Text("Bitz Pro & Licensing")
                    .font(.title2.bold())

                Text("Offline-first cryptographic licensing. Zero accounts, zero tracking.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
        }
    }

    // MARK: - Plan Status Card

    private var planStatusCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("CURRENT PLAN")
                    .font(.caption.bold())
                    .foregroundStyle(.secondary)

                Spacer()

                if licensingService.currentTier == .pro {
                    HStack(spacing: 6) {
                        Circle()
                            .fill(Color.green)
                            .frame(width: 8, height: 8)
                        Text("PRO ACTIVE")
                            .font(.caption.bold())
                            .foregroundStyle(.green)
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(Color.green.opacity(0.12))
                    .clipShape(Capsule())
                } else {
                    HStack(spacing: 6) {
                        Circle()
                            .fill(Color.cyan)
                            .frame(width: 8, height: 8)
                        Text("FREE COMPANION")
                            .font(.caption.bold())
                            .foregroundStyle(.cyan)
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(Color.cyan.opacity(0.12))
                    .clipShape(Capsule())
                }
            }

            if licensingService.currentTier == .pro, let license = licensingService.activeLicense {
                VStack(alignment: .leading, spacing: 6) {
                    Text("All Pro companions, themes, and power tools are unlocked.")
                        .font(.body)
                        .foregroundStyle(.primary)

                    HStack(spacing: 8) {
                        Text("License ID:")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Text(license.licenseId)
                            .font(.system(.caption, design: .monospaced).bold())
                            .foregroundStyle(.primary)
                    }

                    if let expiresAt = license.expiresAt {
                        let dateString = DateFormatter.localizedString(
                            from: Date(timeIntervalSince1970: expiresAt),
                            dateStyle: .medium,
                            timeStyle: .none
                        )
                        HStack(spacing: 8) {
                            Text("Expires:")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Text(dateString)
                                .font(.caption.bold())
                                .foregroundStyle(.orange)
                        }
                    } else {
                        Text("Perpetual / Lifetime License")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            } else {
                Text("You are using the Free tier. Bitz the Cyber Cat, wellness timers, single-agent monitoring, and standard telemetry are completely free without time limits.")
                    .font(.body)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(14)
        .background(Color(nsColor: .controlBackgroundColor))
        .cornerRadius(10)
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .stroke(
                    licensingService.currentTier == .pro
                        ? Color.cyan.opacity(0.4)
                        : Color(nsColor: .separatorColor),
                    lineWidth: 1
                )
        )
    }

    // MARK: - License Management (Input / Deactivate)

    private var licenseManagementSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            if licensingService.currentTier == .free {
                Text("ACTIVATE A LICENSE KEY")
                    .font(.caption.bold())
                    .foregroundStyle(.secondary)

                HStack(spacing: 8) {
                    TextField("BITZ1.payload.signature", text: $licenseKeyInput)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(.body, design: .monospaced))
                        .autocorrectionDisabled()

                    Button {
                        activateKey()
                    } label: {
                        if isActivating {
                            ProgressView()
                                .controlSize(.small)
                        } else {
                            Text("Activate")
                                .fontWeight(.semibold)
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.cyan)
                    .disabled(licenseKeyInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isActivating)
                }

                if let errorMessage {
                    HStack(spacing: 6) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundStyle(.red)
                        Text(errorMessage)
                            .font(.caption)
                            .foregroundStyle(.red)
                    }
                }

                if let successMessage {
                    HStack(spacing: 6) {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                        Text(successMessage)
                            .font(.caption)
                            .foregroundStyle(.green)
                    }
                }

                HStack {
                    Text("Don't have a license key yet?")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    Spacer()

                    Link(destination: URL(string: "https://bitz.sh")!) {
                        Label("Upgrade to Bitz Pro", systemImage: "arrow.up.right")
                            .font(.caption.bold())
                    }
                }
                .padding(.top, 4)
            } else {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("License Management")
                            .font(.headline)
                        Text("Deactivating will return Bitz to the Free tier and remove the key from Keychain.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    Spacer()

                    Button(role: .destructive) {
                        deactivateKey()
                    } label: {
                        Text("Deactivate License")
                    }
                    .buttonStyle(.bordered)
                }
            }
        }
        .padding(14)
        .background(Color(nsColor: .controlBackgroundColor))
        .cornerRadius(10)
    }

    // MARK: - Pro Features Showcase

    private var proFeaturesShowcaseSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("PRO CAPABILITIES & ROADMAP")
                .font(.caption.bold())
                .foregroundStyle(.secondary)

            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 12) {
                featureCard(
                    icon: "pawprint.circle.fill",
                    color: .purple,
                    title: "Mascot Roster",
                    description: "Byte (Dog), Aero (Hover Drone), Pixel (Mech), and seasonal avatars."
                )

                featureCard(
                    icon: "paintpalette.fill",
                    color: .cyan,
                    title: "Palette & Visor Studio",
                    description: "Custom themes (Synthwave, Tokyo Night, Monokai) and LED matrices."
                )

                featureCard(
                    icon: "cpu.fill",
                    color: .blue,
                    title: "Multi-Agent Swarm",
                    description: "Simultaneously monitor 2+ AI coding agents with aggregated HUD alerts."
                )

                featureCard(
                    icon: "mic.fill",
                    color: .orange,
                    title: "Meeting Assistant",
                    description: "Local microphone recording with private on-device Whisper transcription."
                )

                featureCard(
                    icon: "chart.xyaxis.line",
                    color: .green,
                    title: "Deep Telemetry",
                    description: "Per-process battery drain and browser tab memory consumption."
                )

                featureCard(
                    icon: "speaker.wave.3.fill",
                    color: .pink,
                    title: "Audio Studio Packs",
                    description: "Extra sound packs: Chiptune, Mechanical Switches, and Soft Chimes."
                )
            }
        }
    }

    private func featureCard(icon: String, color: Color, title: String, description: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: icon)
                .font(.title3)
                .foregroundStyle(color)
                .frame(width: 24, height: 24)

            VStack(alignment: .leading, spacing: 2) {
                HStack {
                    Text(title)
                        .font(.subheadline.bold())
                    Spacer()
                    ProBadgeView()
                }

                Text(description)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(10)
        .background(Color(nsColor: .windowBackgroundColor))
        .cornerRadius(8)
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(Color(nsColor: .separatorColor).opacity(0.6), lineWidth: 1)
        )
    }

    // MARK: - Actions

    private func activateKey() {
        errorMessage = nil
        successMessage = nil
        isActivating = true

        defer { isActivating = false }

        do {
            try licensingService.activateLicense(key: licenseKeyInput)
            successMessage = "License successfully activated! Welcome to Bitz Pro."
            licenseKeyInput = ""
            audioPlayer?.play(.charging, bypassCooldown: true)
        } catch let error as LocalizedError {
            errorMessage = error.errorDescription ?? error.localizedDescription
            audioPlayer?.play(.overheating, bypassCooldown: true)
        } catch {
            errorMessage = error.localizedDescription
            audioPlayer?.play(.overheating, bypassCooldown: true)
        }
    }

    private func deactivateKey() {
        errorMessage = nil
        successMessage = nil

        do {
            try licensingService.deactivateLicense()
            successMessage = "License deactivated. Reverted to Free tier."
        } catch {
            errorMessage = "Failed to deactivate: \(error.localizedDescription)"
        }
    }
}
