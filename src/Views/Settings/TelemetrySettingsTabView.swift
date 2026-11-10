import SwiftUI
import AppKit

/// Settings tab for configuring hardware sensor metrics, display placements, sampling interval, and alert thresholds.
public struct TelemetrySettingsTabView: View {
    @ObservedObject public var telemetryDashboard: TelemetryDashboardService
    @ObservedObject public var telemetrySettings: TelemetrySettingsStore

    public init(
        telemetryDashboard: TelemetryDashboardService,
        telemetrySettings: TelemetrySettingsStore
    ) {
        self.telemetryDashboard = telemetryDashboard
        self.telemetrySettings = telemetrySettings
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            // Section 1: Display Placements
            settingsCard(title: "Telemetry Display Placements", systemImage: "macwindow.on.rectangle") {
                VStack(spacing: 8) {
                    placementToggle(
                        title: "Compact Menu Bar Title Item",
                        subtitle: "Show real-time CPU / RAM text next to the menu bar icon",
                        icon: "menubar.rectangle",
                        isOn: $telemetrySettings.displayInMenuBarTitle
                    )
                    Divider()
                    placementToggle(
                        title: "Mascot Floating Cyber HUD",
                        subtitle: "Overlay live metrics directly beside Bitz the cyber cat",
                        icon: "shield.righthalf.filled",
                        isOn: $telemetrySettings.displayInMascotCyberHUD
                    )
                    Divider()
                    placementToggle(
                        title: "Speech Bubble Metric Carousel",
                        subtitle: "Rotate periodic hardware stats inside Bitz's speech bubble",
                        icon: "bubble.left.fill",
                        isOn: $telemetrySettings.displayInSpeechBubbleCycle
                    )
                    Divider()
                    placementToggle(
                        title: "Menu Bar Dropdown Stats",
                        subtitle: "Include quick diagnostic overview inside the status menu",
                        icon: "list.bullet.rectangle",
                        isOn: $telemetrySettings.displayInMenuBarMenu
                    )
                }
            }

            // Section 2: Monitored Hardware Metrics
            settingsCard(title: "Monitored Hardware Metrics", systemImage: "gauge.with.needle.fill") {
                VStack(spacing: 8) {
                    ForEach(TelemetryMetric.allCases) { metric in
                        HStack {
                            Image(systemName: metricIcon(for: metric))
                                .foregroundStyle(Color.accentColor)
                                .frame(width: 24)

                            Text(metric.displayName)
                                .font(.subheadline)

                            Spacer()

                            Toggle("", isOn: Binding(
                                get: { telemetrySettings.isMetricEnabled(metric) },
                                set: { telemetrySettings.setMetric(metric, enabled: $0) }
                            ))
                            .labelsHidden()
                        }
                        if metric.id != TelemetryMetric.allCases.last?.id {
                            Divider()
                        }
                    }
                }
            }

            // Section 3: Sampling Cadence & Warning Limits
            settingsCard(title: "Sampling Interval & Alerts", systemImage: "timer") {
                VStack(alignment: .leading, spacing: 12) {
                    Picker("Sampling Cadence", selection: $telemetrySettings.pollingIntervalSeconds) {
                        Text("1 second (High fidelity)").tag(1.0)
                        Text("3 seconds (Balanced)").tag(3.0)
                        Text("5 seconds (Battery saver)").tag(5.0)
                        Text("10 seconds (Low power)").tag(10.0)
                    }
                    .pickerStyle(.menu)

                    Picker("Low Disk Space Alert", selection: $telemetrySettings.lowDiskWarningThresholdPercent) {
                        Text("Alert below 5% free").tag(5.0)
                        Text("Alert below 10% free").tag(10.0)
                        Text("Alert below 15% free").tag(15.0)
                        Text("Alert below 20% free").tag(20.0)
                    }
                    .pickerStyle(.menu)

                    Button {
                        Task {
                            await telemetryDashboard.performSampleTick(forceDiskRefresh: true)
                        }
                    } label: {
                        Label("Sample Telemetry Now", systemImage: "arrow.clockwise")
                    }
                    .padding(.top, 4)
                }
            }
        }
    }

    // MARK: - Helpers

    private func placementToggle(title: String, subtitle: String, icon: String, isOn: Binding<Bool>) -> some View {
        HStack {
            Image(systemName: icon)
                .foregroundStyle(Color.accentColor)
                .frame(width: 24)

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.subheadline)
                Text(subtitle)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            Toggle("", isOn: isOn)
                .labelsHidden()
        }
    }

    private func metricIcon(for metric: TelemetryMetric) -> String {
        switch metric {
        case .cpu: return "cpu"
        case .ram: return "memorychip"
        case .disk: return "internaldrive"
        case .agents: return "person.crop.circle.badge.checkmark"
        case .fps: return "speedometer"
        case .network: return "network"
        case .battery: return "battery.100"
        }
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
