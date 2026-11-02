import AppKit
import SwiftUI
@testable import BitzCore

struct StubUpdateService: UpdateCheckingService {
    let release: GitHubReleaseInfo
    func fetchLatestRelease() async throws -> GitHubReleaseInfo { release }
}

/// Every store the overlay views observe, backed by an isolated `UserDefaults` suite.
@MainActor
final class OverlayFixture {
    let engine: WellnessPointEngine
    let scaleStore: AvatarScaleStore
    let opacityStore: AvatarOpacityStore
    let positionStore: AvatarPositionStore
    let agentMonitor: AgentMonitorService
    let updateStore: AppUpdateStore
    let telemetrySettings: TelemetrySettingsStore
    let telemetryDashboard: TelemetryDashboardService

    static let release = GitHubReleaseInfo(
        tagName: "v1.3.0",
        name: "Bitz v1.3.0",
        htmlUrl: URL(string: "https://github.com/AkramKs/bitz-mac/releases/tag/v1.3.0")!
    )

    /// `AgentMonitorService` keeps popup and per-agent switches in `UserDefaults.standard`, and other
    /// test classes leave them set; clear them so agent popups show regardless of test order.
    static func resetAgentMonitorDefaults() {
        UserDefaults.standard.removeObject(forKey: "Bitz.AgentMonitor.PopupsEnabled")
        for definition in AgentDefinition.builtInCatalog {
            UserDefaults.standard.removeObject(forKey: "Bitz.AgentMonitor.Disabled." + definition.id)
        }
    }

    init(defaults: UserDefaults) {
        engine = WellnessPointEngine(riveController: ProductionRiveController(), userDefaults: defaults)
        scaleStore = AvatarScaleStore(userDefaults: defaults)
        opacityStore = AvatarOpacityStore(userDefaults: defaults)
        positionStore = AvatarPositionStore(userDefaults: defaults)
        agentMonitor = AgentMonitorService(adapters: [], userDefaults: defaults)
        updateStore = AppUpdateStore(
            currentVersionString: "1.2.0",
            updateService: StubUpdateService(release: Self.release),
            userDefaults: defaults
        )

        // Every metric on with badge-worthy values, so the HUD wraps to its 2-line maximum
        telemetrySettings = TelemetrySettingsStore(userDefaults: defaults)
        telemetrySettings.displayInMascotCyberHUD = true
        telemetrySettings.displayInSpeechBubbleCycle = false
        telemetrySettings.enabledMetrics = Set(TelemetryMetric.allCases)
        telemetryDashboard = TelemetryDashboardService(
            settingsStore: telemetrySettings,
            provider: MockTelemetryDataProvider()
        )
        telemetryDashboard.performSampleTickSync(
            agents: AgentTelemetry(activeCount: 3),
            cpu: CPUTelemetry(loadPercentage: 12, temperatureCelsius: 52)
        )
    }

    func showApprovalPopup(_ message: String) {
        agentMonitor.handleEvent(AgentEvent(agentID: "claude", agentName: "Claude", kind: .needsApproval, message: message))
    }

    func showWarning(_ text: String) {
        agentMonitor.handleEvent(AgentEvent(agentID: "claude", agentName: "Claude", kind: .warning, message: text,
                                            metadata: [AgentEvent.MetadataKey.reason: "reported"]))
    }

    func showAlmostDone(_ text: String) {
        agentMonitor.handleEvent(AgentEvent(agentID: "claude", agentName: "Claude", kind: .almostDone, message: text))
    }

    func mascotView(onEarTopChanged: ((CGFloat) -> Void)? = nil) -> MascotOverlayView {
        MascotOverlayView(
            engine: engine,
            scaleStore: scaleStore,
            opacityStore: opacityStore,
            positionStore: positionStore,
            telemetryDashboard: telemetryDashboard,
            telemetrySettings: telemetrySettings,
            onEarTopChanged: onEarTopChanged
        )
    }

    var bubbleView: SpeechBubbleView {
        SpeechBubbleView(
            engine: engine,
            scaleStore: scaleStore,
            agentMonitor: agentMonitor,
            updateStore: updateStore,
            telemetryDashboard: telemetryDashboard,
            telemetrySettings: telemetrySettings
        )
    }
}

/// Spins the main run loop until `condition` holds or `timeout` passes, for AppKit/SwiftUI layout
/// that settles asynchronously. Returns whether the condition was met.
@MainActor
@discardableResult
func spinRunLoop(until condition: () -> Bool, timeout: TimeInterval = 2.0) -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while !condition() && Date() < deadline {
        RunLoop.main.run(until: Date().addingTimeInterval(0.02))
    }
    return condition()
}
