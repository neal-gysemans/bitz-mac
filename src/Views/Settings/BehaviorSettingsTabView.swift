import SwiftUI
import AppKit

/// Settings tab for customizing mascot behavior rules, wellness scoring, and application classification.
public struct BehaviorSettingsTabView: View {
    @ObservedObject public var engine: WellnessPointEngine
    @ObservedObject public var activityMonitor: ActivityMonitorService

    public init(
        engine: WellnessPointEngine,
        activityMonitor: ActivityMonitorService
    ) {
        self.engine = engine
        self.activityMonitor = activityMonitor
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            // Section 1: Focus & Health Status
            settingsCard(title: "Focus & Wellness Engine", systemImage: "pawprint.fill") {
                VStack(alignment: .leading, spacing: 12) {
                    if activityMonitor.isManualOverrideActive {
                        HStack(spacing: 8) {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .foregroundStyle(.orange)
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Manual Simulation Override Active")
                                    .font(.caption.bold())
                                Text("Score updates and idle timers are paused.")
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            Button("Resume Live Sensors") {
                                activityMonitor.clearManualOverride()
                            }
                            .buttonStyle(.borderedProminent)
                            .controlSize(.small)
                        }
                        .padding(10)
                        .background(Color.orange.opacity(0.12))
                        .cornerRadius(8)
                    }

                    HStack {
                        Text("Current State:")
                            .font(.subheadline)
                        Spacer()
                        stateBadge(state: engine.currentState)
                    }

                    HStack {
                        Text("Continuous Focus Streak:")
                            .font(.subheadline)
                        Spacer()
                        Text(String(format: "%.0f min", engine.continuousWorkMinutes))
                            .font(.subheadline.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }

                    HStack {
                        Text("Wellness Energy Points:")
                            .font(.subheadline)
                        Spacer()
                        Text(String(format: "%.1f / 100", engine.currentPoints))
                            .font(.subheadline.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }

                    Button {
                        engine.triggerPetInteraction()
                    } label: {
                        Label("Pet Bitz (<3)", systemImage: "heart.fill")
                    }
                    .buttonStyle(.bordered)
                }
            }

            // Section 2: Application Classification Rules
            settingsCard(title: "Application Productivity Rules", systemImage: "app.badge.checkmark") {
                VStack(alignment: .leading, spacing: 12) {
                    if let frontmost = activityMonitor.lastFrontmostAppName {
                        let isProductive = activityMonitor.lastAppIsProductive
                        let customTag = activityMonitor.frontmostAppCustomRule.map { $0 ? " (Custom Rule)" : " (Custom Rule)" } ?? ""

                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Active Frontmost Application:")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                Text(frontmost + customTag)
                                    .font(.subheadline.bold())
                            }
                            Spacer()
                            Text(isProductive ? "+0.5 PTS / min" : "-1.5 PTS / min")
                                .font(.caption.bold())
                                .padding(.horizontal, 8)
                                .padding(.vertical, 4)
                                .background(isProductive ? Color.green.opacity(0.15) : Color.orange.opacity(0.15))
                                .foregroundStyle(isProductive ? Color.green : Color.orange)
                                .cornerRadius(6)
                        }

                        HStack(spacing: 10) {
                            if activityMonitor.frontmostAppCustomRule != true {
                                Button {
                                    activityMonitor.markFrontmostApp(asProductive: true)
                                } label: {
                                    Label("Classify Productive", systemImage: "arrow.up.circle.fill")
                                }
                            }
                            if activityMonitor.frontmostAppCustomRule != false {
                                Button {
                                    activityMonitor.markFrontmostApp(asProductive: false)
                                } label: {
                                    Label("Classify Distraction", systemImage: "arrow.down.circle.fill")
                                }
                            }
                            if activityMonitor.frontmostAppCustomRule != nil {
                                Button("Reset Default Rule") {
                                    activityMonitor.resetFrontmostAppRule()
                                }
                            }
                        }
                    } else {
                        Text("No active application detected")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                }
            }

            // Section 3: Hardware & Idle Sensors
            settingsCard(title: "Hardware Sensors & Idle Telemetry", systemImage: "sensor.tag.radiowaves.forward.fill") {
                VStack(alignment: .leading, spacing: 10) {
                    sensorRow(
                        title: "User Idle Time",
                        value: String(format: "%.0fs", activityMonitor.lastIdleSeconds),
                        icon: "clock.badge.checkmark"
                    )

                    if let temp = activityMonitor.lastTemperatureCelsius {
                        sensorRow(
                            title: "CPU Die Temperature",
                            value: String(format: "%.1f °C", temp),
                            icon: "thermometer.medium",
                            isWarning: temp > activityMonitor.overheatingTemperatureThresholdCelsius
                        )
                    }

                    if let load = activityMonitor.lastCPULoadPercentage {
                        sensorRow(
                            title: "CPU Total Load",
                            value: String(format: "%.1f%%", load * 100.0),
                            icon: "cpu"
                        )
                    }

                    Button {
                        activityMonitor.performSampleTick()
                    } label: {
                        Label("Sample Sensors Now", systemImage: "arrow.clockwise")
                    }
                    .padding(.top, 4)
                }
            }
        }
    }

    // MARK: - Helpers

    private func stateBadge(state: BitzState) -> some View {
        Text(state.rawValue.capitalized)
            .font(.subheadline.bold())
            .padding(.horizontal, 10)
            .padding(.vertical, 3)
            .background(Color.cyan.opacity(0.15))
            .foregroundStyle(Color.cyan)
            .cornerRadius(6)
    }

    private func sensorRow(title: String, value: String, icon: String, isWarning: Bool = false) -> some View {
        HStack {
            Image(systemName: icon)
                .foregroundStyle(isWarning ? Color.red : Color.secondary)
                .frame(width: 20)
            Text(title)
                .font(.subheadline)
            Spacer()
            Text(value)
                .font(.subheadline.monospacedDigit())
                .foregroundStyle(isWarning ? Color.red : Color.secondary)
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
