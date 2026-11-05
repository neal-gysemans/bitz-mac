import SwiftUI
import AppKit

/// Settings tab for customizing mascot behavior rules, wellness scoring, and application classification.
public struct BehaviorSettingsTabView: View {
    @ObservedObject public var engine: WellnessPointEngine
    @ObservedObject public var activityMonitor: ActivityMonitorService
    @ObservedObject public var flowShieldSettings: FlowShieldSettingsStore
    @ObservedObject public var flowShieldService: FlowShieldService

    public init(
        engine: WellnessPointEngine,
        activityMonitor: ActivityMonitorService,
        flowShieldSettings: FlowShieldSettingsStore? = nil,
        flowShieldService: FlowShieldService? = nil
    ) {
        self.engine = engine
        self.activityMonitor = activityMonitor
        let resolvedSettings = flowShieldSettings ?? FlowShieldSettingsStore()
        self.flowShieldSettings = resolvedSettings
        self.flowShieldService = flowShieldService ?? FlowShieldService(settingsStore: resolvedSettings)
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            // Section 1: Focus & Health Status
            settingsCard(title: "Focus & Wellness Engine", systemImage: "pawprint.fill") {
                VStack(alignment: .leading, spacing: 12) {
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
                }
            }

            // Section 2: Auto Flow Shield (macOS Focus)
            flowShieldCard

            // Section 3: Application Classification Rules
            settingsCard(title: "Application Productivity Rules", systemImage: "app.badge.checkmark") {
                VStack(alignment: .leading, spacing: 12) {
                    if let frontmost = activityMonitor.lastFrontmostAppName {
                        let isProductive = activityMonitor.lastAppIsProductive
                        let customTag = Self.customRuleTag(for: activityMonitor.frontmostAppCustomRule)

                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Active Frontmost Application:")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                Text(frontmost + customTag)
                                    .font(.subheadline.bold())
                            }
                            Spacer()
                            Text(Self.pointRateLabel(isProductive: isProductive))
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

    // MARK: - Auto Flow Shield Card

    private var flowShieldCard: some View {
        settingsCard(title: "Auto Flow Shield (macOS Focus)", systemImage: "shield.checkered") {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Toggle(
                        "Enable Auto Flow Shield",
                        isOn: Binding(
                            get: { flowShieldSettings.isEnabled },
                            set: { flowShieldSettings.setEnabled($0) }
                        )
                    )
                    .font(.subheadline.weight(.medium))

                    Spacer()

                    flowShieldStatusBadge
                }

                Divider()

                HStack {
                    Text("Deep-Work Streak Threshold:")
                        .font(.subheadline)
                    Spacer()
                    Stepper(
                        value: Binding(
                            get: { flowShieldSettings.streakMinutesThreshold },
                            set: { flowShieldSettings.setStreakMinutesThreshold($0) }
                        ),
                        in: FlowShieldSettingsStore.minStreakMinutesThreshold...FlowShieldSettingsStore.maxStreakMinutesThreshold,
                        step: 5.0
                    ) {
                        Text(flowShieldSettings.formattedStreakSummary)
                            .font(.subheadline.monospacedDigit().bold())
                            .foregroundStyle(.secondary)
                    }
                }
                .disabled(!flowShieldSettings.isEnabled)

                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 8) {
                        Text("Start Focus Shortcut:")
                            .font(.subheadline)
                            .frame(width: 150, alignment: .leading)
                        TextField(
                            "Start Focus",
                            text: Binding(
                                get: { flowShieldSettings.startFocusShortcutName },
                                set: { flowShieldSettings.setStartFocusShortcutName($0) }
                            )
                        )
                        .textFieldStyle(.roundedBorder)
                        Button("Test Start") {
                            Task {
                                await flowShieldService.testStartShortcut()
                            }
                        }
                        .controlSize(.small)
                    }

                    HStack(spacing: 8) {
                        Text("Stop Focus Shortcut:")
                            .font(.subheadline)
                            .frame(width: 150, alignment: .leading)
                        TextField(
                            "Stop Focus",
                            text: Binding(
                                get: { flowShieldSettings.stopFocusShortcutName },
                                set: { flowShieldSettings.setStopFocusShortcutName($0) }
                            )
                        )
                        .textFieldStyle(.roundedBorder)
                        Button("Test Stop") {
                            Task {
                                await flowShieldService.testStopShortcut()
                            }
                        }
                        .controlSize(.small)
                    }
                }
                .disabled(!flowShieldSettings.isEnabled)

                Text("Setup: Open macOS Shortcuts.app and create two 1-action Shortcuts using \"Set Focus\" — \"Start Focus\" (Turn Do Not Disturb On until Turned Off) and \"Stop Focus\" (Turn Do Not Disturb Off).")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                if flowShieldSettings.isEnabled {
                    HStack(spacing: 10) {
                        Button {
                            flowShieldService.toggleBreakShieldOverride()
                        } label: {
                            Label(
                                flowShieldSettings.isBreakShieldOverrideActive
                                    ? "Resume Auto Flow Shield"
                                    : "Break Shield (Disable Focus)",
                                systemImage: flowShieldSettings.isBreakShieldOverrideActive
                                    ? "shield.checkered"
                                    : "shield.slash.fill"
                            )
                        }
                        .buttonStyle(.bordered)

                        if flowShieldSettings.isBreakShieldOverrideActive {
                            Text("Focus auto-activation paused until resumed or next session.")
                                .font(.caption)
                                .foregroundStyle(.orange)
                        }
                    }
                }

                if let errorMessage = flowShieldService.lastErrorMessage {
                    HStack(spacing: 8) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                        Text(errorMessage)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Spacer()
                        Button("Dismiss") {
                            flowShieldService.clearError()
                        }
                        .controlSize(.mini)
                    }
                    .padding(8)
                    .background(Color.orange.opacity(0.12))
                    .cornerRadius(8)
                }
            }
        }
    }

    private var flowShieldStatusBadge: some View {
        let status = flowShieldService.currentStatus
        let badgeColor: Color = {
            switch status {
            case .active:
                return .green
            case .standby:
                return .cyan
            case .breakShieldOverride:
                return .orange
            case .disabled:
                return .secondary
            }
        }()

        return Label(status.displayTitle, systemImage: status.systemImage)
            .font(.caption.bold())
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(badgeColor.opacity(0.15))
            .foregroundStyle(badgeColor)
            .cornerRadius(6)
    }

    // MARK: - Helpers

    /// The engine applies its delta once per activity sample, so convert per-tick points to per-minute.
    static func pointRateLabel(isProductive: Bool) -> String {
        let delta = isProductive ? WellnessPointEngine.productiveTickDelta : WellnessPointEngine.unproductiveTickDelta
        return String(format: "%+.0f PTS / min", delta * 60 / ActivityMonitorService.sampleIntervalSeconds)
    }

    /// Formats the custom productivity rule suffix (#94 C11).
    static func customRuleTag(for rule: Bool?) -> String {
        guard let rule else { return "" }
        return rule ? " (Custom: Productive)" : " (Custom: Distraction)"
    }

    private func stateBadge(state: BitzState) -> some View {
        Text(state.displayName)
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
