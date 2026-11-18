import SwiftUI
import AppKit

/// Settings tab for customizing mascot behavior rules, wellness scoring, and application classification.
public struct BehaviorSettingsTabView: View {
    @ObservedObject public var engine: WellnessPointEngine
    @ObservedObject public var activityMonitor: ActivityMonitorService
    @ObservedObject public var flowShieldSettings: FlowShieldSettingsStore
    @ObservedObject public var flowShieldService: FlowShieldService
    @ObservedObject public var calendarService: CalendarAgendaService
    @ObservedObject public var workShiftTracker: WorkShiftTrackerService
    public var licensingService: (any LicensingServiceProtocol)?
    @State private var isShowingAdvancedSensors: Bool = false

    private var isCalendarUnlocked: Bool {
        licensingService?.isFeatureUnlocked(.meetingRecorder) ?? calendarService.isCalendarAgendaUnlocked
    }

    private var isFlowAndHistoryUnlocked: Bool {
        licensingService?.isFeatureUnlocked(.personality) ?? flowShieldService.isFlowShieldUnlocked
    }

    public init(
        engine: WellnessPointEngine,
        activityMonitor: ActivityMonitorService,
        flowShieldSettings: FlowShieldSettingsStore? = nil,
        flowShieldService: FlowShieldService? = nil,
        calendarService: CalendarAgendaService? = nil,
        workShiftTracker: WorkShiftTrackerService? = nil,
        licensingService: (any LicensingServiceProtocol)? = nil
    ) {
        self.engine = engine
        self.activityMonitor = activityMonitor
        let resolvedSettings = flowShieldSettings ?? FlowShieldSettingsStore()
        self.flowShieldSettings = resolvedSettings
        self.flowShieldService = flowShieldService ?? FlowShieldService(settingsStore: resolvedSettings)
        self.calendarService = calendarService ?? CalendarAgendaService()
        self.workShiftTracker = workShiftTracker ?? WorkShiftTrackerService()
        self.licensingService = licensingService
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            // Section 1: Work Shift & Daily Hours (#187)
            workShiftCard

            // Section 2: Application Classification Rules
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

            // Section 3: macOS Calendar & Agenda (#186)
            calendarAgendaCard

            // Section 4: Auto Flow Shield (macOS Focus)
            flowShieldCard

            // Section 5: Live Focus & Hardware Sensor Diagnostics (Collapsed by default, #211)
            DisclosureGroup("Live Wellness & Hardware Sensor Readouts", isExpanded: $isShowingAdvancedSensors) {
                VStack(alignment: .leading, spacing: 14) {
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
                .padding(.top, 8)
            }
            .font(.subheadline.weight(.medium))
        }
    }

    // MARK: - Auto Flow Shield Card

    private var workShiftCard: some View {
        settingsCard(title: "Work Shift & Daily Hours", systemImage: "clock.arrow.2.circlepath") {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Text("Daily Target:")
                        .font(.subheadline)
                    Spacer()
                    Text(WorkShiftDialogueBank.formatHours(workShiftTracker.workdayGoalHours))
                        .font(.subheadline.monospacedDigit().bold())
                        .foregroundStyle(.secondary)
                }

                Slider(
                    value: $workShiftTracker.workdayGoalHours,
                    in: WorkShiftTrackerService.minGoalHours...WorkShiftTrackerService.maxGoalHours,
                    step: 0.5
                )
                .accessibilityLabel("Daily work shift target hours")

                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text("Today's Active Work:")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Spacer()
                        Text("\(WorkShiftDialogueBank.formatDuration(workShiftTracker.dailyActiveSeconds)) / \(WorkShiftDialogueBank.formatDuration(workShiftTracker.goalSeconds))")
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(workShiftTracker.isGoalReachedToday ? .green : .secondary)
                    }
                    ProgressView(value: workShiftTracker.progressFraction)
                        .tint(workShiftTracker.isGoalReachedToday ? .green : .accentColor)
                }

                if !workShiftTracker.weeklyHistory.isEmpty {
                    if !isFlowAndHistoryUnlocked {
                        HStack(spacing: 8) {
                            Image(systemName: "lock.fill")
                                .foregroundStyle(.cyan)
                            Text("7-Day Work Shift History Analytics requires Bitz Pro.")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                            Spacer()
                            Button {
                                NotificationCenter.default.post(name: .bitzOpenProSettingsTab, object: nil)
                            } label: {
                                ProBadgeView()
                            }
                            .buttonStyle(.plain)
                        }
                        .padding(.top, 4)
                    } else {
                        let maxScale = max(
                            workShiftTracker.goalSeconds,
                            workShiftTracker.weeklyHistory.map(\.activeSeconds).max() ?? 1
                        )
                        VStack(alignment: .leading, spacing: 6) {
                            Text("Past 7 Days")
                                .font(.caption)
                                .foregroundStyle(.secondary)

                            HStack(alignment: .bottom, spacing: 8) {
                                ForEach(workShiftTracker.weeklyHistory) { record in
                                    let barHeight = max(4, CGFloat(record.activeSeconds / maxScale) * 52)
                                    let reached = record.activeSeconds >= (record.goalHours * 3600)
                                    VStack(spacing: 4) {
                                        RoundedRectangle(cornerRadius: 3)
                                            .fill(reached ? Color.green : Color.accentColor.opacity(0.75))
                                            .frame(height: barHeight)
                                        Text(String(record.dateKey.suffix(5)))
                                            .font(.system(size: 9, design: .monospaced))
                                            .foregroundStyle(.secondary)
                                    }
                                    .frame(maxWidth: .infinity)
                                }
                            }
                            .frame(height: 70, alignment: .bottom)
                        }
                        .padding(.top, 4)
                    }
                }
            }
        }
    }

    private var flowShieldCard: some View {
        settingsCard(title: "Auto Flow Shield (macOS Focus)", systemImage: "shield.checkered") {
            VStack(alignment: .leading, spacing: 12) {
                if !isFlowAndHistoryUnlocked {
                    HStack(spacing: 8) {
                        Image(systemName: "lock.fill")
                            .foregroundStyle(.cyan)
                        Text("Automatic macOS Focus / Do Not Disturb activation on deep-work streaks requires Bitz Pro.")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                        Spacer()
                        Button {
                            NotificationCenter.default.post(name: .bitzOpenProSettingsTab, object: nil)
                        } label: {
                            ProBadgeView()
                        }
                        .buttonStyle(.plain)
                    }
                    Divider()
                }

                HStack {
                    Toggle(
                        "Enable Auto Flow Shield",
                        isOn: Binding(
                            get: { isFlowAndHistoryUnlocked && flowShieldSettings.isEnabled },
                            set: { enabled in
                                guard isFlowAndHistoryUnlocked else {
                                    NotificationCenter.default.post(name: .bitzOpenProSettingsTab, object: nil)
                                    return
                                }
                                flowShieldSettings.setEnabled(enabled)
                            }
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

    // MARK: - Calendar & Agenda Section (#186)

    private var calendarAgendaCard: some View {
        settingsCard(title: "macOS Calendar & Agenda", systemImage: "calendar.badge.clock") {
            VStack(alignment: .leading, spacing: 14) {
                if !isCalendarUnlocked {
                    HStack(spacing: 8) {
                        Image(systemName: "lock.fill")
                            .foregroundStyle(.cyan)
                        Text("Upcoming meeting countdowns, 1-click Zoom/Meet/Teams join & daily schedule briefs require Bitz Pro.")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                        Spacer()
                        Button {
                            NotificationCenter.default.post(name: .bitzOpenProSettingsTab, object: nil)
                        } label: {
                            ProBadgeView()
                        }
                        .buttonStyle(.plain)
                    }
                    Divider()
                }

                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Enable Calendar Agenda")
                            .font(.subheadline.bold())
                        Text("Surfaces upcoming meeting countdowns, 1-click video join, and daily schedule briefs.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Toggle(
                        "",
                        isOn: Binding(
                            get: { isCalendarUnlocked && calendarService.settingsStore.isEnabled },
                            set: { newValue in
                                guard isCalendarUnlocked else {
                                    NotificationCenter.default.post(name: .bitzOpenProSettingsTab, object: nil)
                                    return
                                }
                                if newValue {
                                    Task {
                                        if !calendarService.authorizationStatus.isAuthorized {
                                            let granted = await calendarService.requestAuthorization()
                                            if !granted {
                                                calendarService.settingsStore.setEnabled(false)
                                            }
                                        } else {
                                            calendarService.settingsStore.setEnabled(true)
                                            await calendarService.refreshEvents()
                                        }
                                    }
                                } else {
                                    calendarService.settingsStore.setEnabled(false)
                                }
                            }
                        )
                    )
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .accessibilityLabel("Enable Calendar Agenda")
                }

                HStack {
                    Text("Permission Status:")
                        .font(.subheadline)
                    Spacer()
                    calendarStatusBadge
                    if calendarService.authorizationStatus == .notDetermined {
                        Button("Request Access") {
                            Task {
                                _ = await calendarService.requestAuthorization()
                            }
                        }
                        .controlSize(.small)
                    }
                }

                if calendarService.authorizationStatus == .denied || calendarService.authorizationStatus == .restricted {
                    HStack(spacing: 8) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Calendar Access Denied")
                                .font(.caption.bold())
                            Text("Grant access in macOS System Settings > Privacy & Security > Calendars to see upcoming meetings.")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button("Open Privacy Settings") {
                            if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Calendars") {
                                NSWorkspace.shared.open(url)
                            }
                        }
                        .controlSize(.small)
                    }
                    .padding(10)
                    .background(Color.orange.opacity(0.12))
                    .cornerRadius(8)
                }

                if isCalendarUnlocked && calendarService.settingsStore.isEnabled && calendarService.authorizationStatus.isAuthorized {
                    Divider()

                    // Reminder Notice Offset Picker
                    HStack {
                        Text("Meeting Reminder Notice:")
                            .font(.subheadline)
                        Spacer()
                        Picker(
                            "",
                            selection: Binding(
                                get: { calendarService.settingsStore.reminderOffsetMinutes },
                                set: { calendarService.settingsStore.setReminderOffsetMinutes($0) }
                            )
                        ) {
                            Text("5 minutes before").tag(5)
                            Text("10 minutes before (Default)").tag(10)
                            Text("15 minutes before").tag(15)
                        }
                        .pickerStyle(.menu)
                        .frame(width: 200)
                    }

                    // Toggles
                    Toggle(
                        "Morning Agenda Brief (after 6:00 AM)",
                        isOn: Binding(
                            get: { calendarService.settingsStore.isMorningBriefEnabled },
                            set: { calendarService.settingsStore.setMorningBriefEnabled($0) }
                        )
                    )
                    .font(.subheadline)

                    Toggle(
                        "Tomorrow Radar Preview (after 3:00 PM)",
                        isOn: Binding(
                            get: { calendarService.settingsStore.isEveningPreviewEnabled },
                            set: { calendarService.settingsStore.setEveningPreviewEnabled($0) }
                        )
                    )
                    .font(.subheadline)

                    Toggle(
                        "1-Click Join Button for Video Calls (Zoom, Meet, Teams)",
                        isOn: Binding(
                            get: { calendarService.settingsStore.showMeetingURLQuickJoin },
                            set: { calendarService.settingsStore.setShowMeetingURLQuickJoin($0) }
                        )
                    )
                    .font(.subheadline)

                    HStack {
                        if !calendarService.todayEvents.isEmpty {
                            Text("\(calendarService.todayEvents.count) event\(calendarService.todayEvents.count == 1 ? "" : "s") loaded today")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        } else {
                            Text("No events scheduled today")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button {
                            Task {
                                await calendarService.refreshEvents()
                            }
                        } label: {
                            Label(calendarService.isRefreshing ? "Refreshing..." : "Refresh Calendar", systemImage: "arrow.clockwise")
                        }
                        .controlSize(.small)
                        .disabled(calendarService.isRefreshing)
                    }
                }
            }
        }
    }

    private var calendarStatusBadge: some View {
        let status = calendarService.authorizationStatus
        let (color, text): (Color, String) = {
            switch status {
            case .fullAccess:
                return (.green, "Connected (Full Access)")
            case .notDetermined:
                return (.secondary, "Not Connected")
            case .restricted:
                return (.orange, "Restricted")
            case .denied:
                return (.red, "Access Denied")
            case .writeOnly:
                return (.orange, "Write Only")
            }
        }()

        return Text(text)
            .font(.caption.bold())
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(color.opacity(0.15))
            .foregroundStyle(color)
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
}
