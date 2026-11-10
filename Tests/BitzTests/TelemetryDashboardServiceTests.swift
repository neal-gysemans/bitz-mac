import XCTest
import SwiftUI
@testable import BitzCore

// MARK: - Mock Telemetry Provider for Deterministic Testing

final class MockTelemetryDataProvider: TelemetryDataProviding, @unchecked Sendable {
    var diskToReturn = DiskTelemetry(freeBytes: 157_286_400_000, totalBytes: 500_000_000_000) // ~146.5 GB of 465 GB
    var ramToReturn = RAMTelemetry(usedBytes: 17_179_869_184, totalBytes: 34_359_738_368, pressure: .normal) // 16 GB of 32 GB
    var networkToReturn = NetworkTelemetry(downloadBytesPerSec: 1_250_000, uploadBytesPerSec: 320_000)
    var batteryToReturn: BatteryTelemetry? = BatteryTelemetry(percentage: 85, isCharging: false, powerSource: "Battery")
    var displayToReturn: DisplayTelemetry? = DisplayTelemetry(name: "Studio Display", resolution: "2560×1440", refreshRate: 60.0)
    var fpsToReturn = FPSTelemetry(currentFPS: 120.0, targetFPS: 120.0, screenName: "Built-in Retina Display")
    private let lock = NSLock()
    private(set) var diskFetchCount: Int = 0

    func fetchDiskTelemetry(lowDiskThresholdPercent: Double) -> DiskTelemetry {
        lock.lock()
        diskFetchCount += 1
        let currentDisk = diskToReturn
        lock.unlock()
        return DiskTelemetry(
            freeBytes: currentDisk.freeBytes,
            totalBytes: currentDisk.totalBytes,
            lowDiskThresholdPercent: lowDiskThresholdPercent
        )
    }

    func fetchRAMTelemetry() -> RAMTelemetry {
        ramToReturn
    }

    func fetchNetworkTelemetry(elapsedSeconds: Double) -> NetworkTelemetry {
        networkToReturn
    }

    func fetchBatteryTelemetry() -> BatteryTelemetry? {
        batteryToReturn
    }

    func fetchDisplayTelemetry() -> DisplayTelemetry? {
        displayToReturn
    }

    func fetchDisplayFPSTelemetry(screen: NSScreen? = nil) -> FPSTelemetry {
        fpsToReturn
    }
}

// MARK: - Unit Tests

@MainActor
final class TelemetryDashboardServiceTests: XCTestCase {

    // MARK: - 1. TelemetrySettingsStore Tests

    func testTelemetrySettingsStoreDefaultInitialization() {
        let suiteName = "TelemetrySettingsDefaults.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let store = TelemetrySettingsStore(userDefaults: defaults)

        XCTAssertTrue(store.isMetricEnabled(.disk))
        XCTAssertTrue(store.isMetricEnabled(.ram))
        XCTAssertTrue(store.isMetricEnabled(.agents))
        XCTAssertTrue(store.isMetricEnabled(.cpu))
        XCTAssertTrue(store.isMetricEnabled(.fps))
        XCTAssertFalse(store.isMetricEnabled(.network))
        XCTAssertFalse(store.isMetricEnabled(.battery))

        XCTAssertEqual(store.pollingIntervalSeconds, 3.0)
        XCTAssertEqual(store.lowDiskWarningThresholdPercent, 10.0)
        XCTAssertTrue(store.displayInMenuBarMenu)
        XCTAssertFalse(store.displayInMenuBarTitle)
        XCTAssertTrue(store.displayInMascotCyberHUD)
        XCTAssertFalse(store.displayInSpeechBubbleCycle)
    }

    func testTelemetrySettingsStoreTogglesAndPersistence() {
        let suiteName = "TelemetrySettingsPersistence.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        var notified = false
        let store = TelemetrySettingsStore(userDefaults: defaults)
        store.onConfigurationChanged = { notified = true }

        store.setMetric(.network, enabled: true)
        XCTAssertTrue(store.isMetricEnabled(.network))
        XCTAssertTrue(notified)

        store.toggleMetric(.disk)
        XCTAssertFalse(store.isMetricEnabled(.disk))

        store.pollingIntervalSeconds = 5.0
        store.lowDiskWarningThresholdPercent = 15.0
        store.displayInMenuBarTitle = true
        store.displayInSpeechBubbleCycle = true

        // Create fresh store instance on same defaults domain
        let restoredStore = TelemetrySettingsStore(userDefaults: defaults)
        XCTAssertTrue(restoredStore.isMetricEnabled(.network))
        XCTAssertFalse(restoredStore.isMetricEnabled(.disk))
        XCTAssertEqual(restoredStore.pollingIntervalSeconds, 5.0)
        XCTAssertEqual(restoredStore.lowDiskWarningThresholdPercent, 15.0)
        XCTAssertTrue(restoredStore.displayInMenuBarTitle)
        XCTAssertTrue(restoredStore.displayInSpeechBubbleCycle)
    }

    // MARK: - 2. Model & Warning Calculation Tests

    func testDiskTelemetryCalculationsAndWarning() {
        // 5 GB free out of 100 GB = 5% free
        let lowDisk = DiskTelemetry(freeBytes: 5_368_709_120, totalBytes: 107_374_182_400, lowDiskThresholdPercent: 10.0)
        XCTAssertEqual(lowDisk.freeGB, 5.0, accuracy: 0.1)
        XCTAssertEqual(lowDisk.totalGB, 100.0, accuracy: 0.1)
        XCTAssertEqual(lowDisk.freePercentage, 5.0, accuracy: 0.1)
        XCTAssertTrue(lowDisk.isLowSpace)

        // 50 GB free out of 100 GB = 50% free
        let healthyDisk = DiskTelemetry(freeBytes: 53_687_091_200, totalBytes: 107_374_182_400, lowDiskThresholdPercent: 10.0)
        XCTAssertFalse(healthyDisk.isLowSpace)
        XCTAssertEqual(healthyDisk.compactBadge, "50GB")
    }

    func testRAMTelemetryCalculationsAndPressureWarning() {
        let normalRAM = RAMTelemetry(usedBytes: 17_179_869_184, totalBytes: 34_359_738_368, pressure: .normal)
        XCTAssertEqual(normalRAM.usedGB, 16.0, accuracy: 0.1)
        XCTAssertEqual(normalRAM.totalGB, 32.0, accuracy: 0.1)
        XCTAssertEqual(normalRAM.usedPercentage, 50.0, accuracy: 0.1)
        XCTAssertFalse(normalRAM.isWarning)

        let criticalRAM = RAMTelemetry(usedBytes: 32_212_254_720, totalBytes: 34_359_738_368, pressure: .critical)
        XCTAssertTrue(criticalRAM.isWarning)
        XCTAssertEqual(criticalRAM.compactBadge, "30.0GB RAM")
    }

    func testAgentTelemetrySummaryFormatting() {
        let emptyAgents = AgentTelemetry.empty
        XCTAssertEqual(emptyAgents.activeCount, 0)
        XCTAssertEqual(emptyAgents.formattedSummary, "No agents currently active")

        let activeAgents = AgentTelemetry(activeCount: 2, agentNames: ["Claude", "Cursor"])
        XCTAssertEqual(activeAgents.activeCount, 2)
        XCTAssertEqual(activeAgents.formattedSummary, "2 active (Claude, Cursor)")
        XCTAssertEqual(activeAgents.compactBadge, "2 AGTS")
    }

    func testNetworkTelemetryFormatting() {
        let highSpeed = NetworkTelemetry(downloadBytesPerSec: 2_500_000, uploadBytesPerSec: 500_000)
        XCTAssertEqual(highSpeed.formattedSummary, "↓ 2.4 MB/s • ↑ 488 KB/s")
        XCTAssertEqual(highSpeed.compactBadge, "↓ 2.4 MB/s")

        let lowSpeed = NetworkTelemetry(downloadBytesPerSec: 800, uploadBytesPerSec: 200)
        XCTAssertEqual(lowSpeed.formattedSummary, "↓ 800 B/s • ↑ 200 B/s")
    }

    // MARK: - 3. Live FPS Tracker Tests

    func testLiveFPSTrackerCalculations() {
        let tracker = LiveFPSTracker(targetFPS: 30.0, windowDuration: 1.0)
        XCTAssertEqual(tracker.currentFPS, 30.0) // Defaults to target when insufficient samples

        // Simulate 31 frames spaced 1/30s apart
        var time = 100.0
        for _ in 0...30 {
            tracker.recordFrame(timestamp: time)
            time += (1.0 / 30.0)
        }

        XCTAssertEqual(tracker.currentFPS, 30.0, accuracy: 1.0)
        let snap = tracker.snapshot()
        XCTAssertEqual(snap.targetFPS, 30.0)
        XCTAssertEqual(snap.compactBadge, "30 FPS")
    }

    // MARK: - 4. TelemetrySnapshot Formatting Tests

    func testSnapshotMenuBarTitleFormatting() {
        let disk = DiskTelemetry(freeBytes: 107_374_182_400, totalBytes: 536_870_912_000) // 100GB
        let ram = RAMTelemetry(usedBytes: 17_179_869_184, totalBytes: 34_359_738_368) // 50%
        let agents = AgentTelemetry(activeCount: 3, agentNames: ["Claude", "Cursor", "Antigravity"])
        let cpu = CPUTelemetry(loadPercentage: 15.0, temperatureCelsius: 48.0)
        let fps = FPSTelemetry(currentFPS: 30.0)

        let snapshot = TelemetrySnapshot(
            disk: disk,
            ram: ram,
            agents: agents,
            fps: fps,
            cpu: cpu
        )

        // Title with all core metrics
        let titleAll = snapshot.menuBarTitle(enabledMetrics: [.agents, .disk, .ram, .cpu, .fps])
        XCTAssertTrue(titleAll.contains("3 Agts"))
        XCTAssertTrue(titleAll.contains("48°C"))
        XCTAssertTrue(titleAll.contains("100GB"))
        XCTAssertTrue(titleAll.contains("50% RAM"))
        XCTAssertTrue(titleAll.contains("30 FPS"))

        // Title with empty metrics set defaults to "Bitz"
        let titleNone = snapshot.menuBarTitle(enabledMetrics: [])
        XCTAssertEqual(titleNone, "Bitz")
    }

    func testSnapshotCyberHUDFormatting() {
        let disk = DiskTelemetry(freeBytes: 107_374_182_400, totalBytes: 536_870_912_000)
        let ram = RAMTelemetry(usedBytes: 17_179_869_184, totalBytes: 34_359_738_368)
        let agents = AgentTelemetry(activeCount: 1, agentNames: ["Aider"])
        let cpu = CPUTelemetry(loadPercentage: 20.0, temperatureCelsius: 45.0)
        let fps = FPSTelemetry(currentFPS: 30.0)

        let snapshot = TelemetrySnapshot(
            disk: disk,
            ram: ram,
            agents: agents,
            fps: fps,
            cpu: cpu
        )

        let hud = snapshot.hudSummary(enabledMetrics: [.cpu, .agents, .ram, .disk, .fps], focusPoints: 85.0)
        XCTAssertTrue(hud.contains("45°C (20%)"))
        XCTAssertTrue(hud.contains("1 AGTS"))
        XCTAssertTrue(hud.contains("16.0GB RAM"))
        XCTAssertTrue(hud.contains("100GB"))
        XCTAssertTrue(hud.contains("30 FPS"))
        XCTAssertTrue(hud.contains("85 PTS"))
        XCTAssertTrue(hud.contains("\n"))
    }

    func testSnapshotCyberHUDAllMetricsEnabledFormatsAcrossThreeLinesWithoutDropping() {
        let disk = DiskTelemetry(freeBytes: 154_618_822_656, totalBytes: 500_000_000_000)
        let ram = RAMTelemetry(usedBytes: 20_615_843_020, totalBytes: 34_359_738_368)
        let agents = AgentTelemetry(activeCount: 2, agentNames: ["Claude", "Cursor"], context: AgentContextReading(agentID: "claude", agentName: "Claude", tokens: 200_000, windowTokens: 200_000))
        let cpu = CPUTelemetry(loadPercentage: 9.0, temperatureCelsius: 52.0)
        let fps = FPSTelemetry(currentFPS: 120.0)
        let battery = BatteryTelemetry(percentage: 100, isCharging: false, powerSource: "Battery")
        let network = NetworkTelemetry(downloadBytesPerSec: 0.0, uploadBytesPerSec: 0.0)

        let snapshot = TelemetrySnapshot(
            disk: disk,
            ram: ram,
            agents: agents,
            fps: fps,
            cpu: cpu,
            network: network,
            battery: battery
        )

        let allMetrics = Set(TelemetryMetric.allCases)
        let hud = snapshot.hudSummary(enabledMetrics: allMetrics, focusPoints: 100.0)

        // All 7 metrics + focusPoints must be present
        XCTAssertTrue(hud.contains("52°C (9%)"), "CPU must be present")
        XCTAssertTrue(hud.contains("19.2GB RAM"), "RAM must be present")
        XCTAssertTrue(hud.contains("2 AGTS · 100%"), "Agents must be present")
        XCTAssertTrue(hud.contains("144GB"), "Disk must be present")
        XCTAssertTrue(hud.contains("120 FPS"), "FPS must be present")
        XCTAssertTrue(hud.contains("100%"), "Battery must be present")
        XCTAssertTrue(hud.contains("↓ 0 B/s"), "Network speed must be present even when idle")
        XCTAssertTrue(hud.contains("100 PTS"), "Focus points must be present")

        // Formatted across 3 lines
        let lines = hud.split(separator: "\n", omittingEmptySubsequences: false)
        XCTAssertEqual(lines.count, 3, "All 8 items must be balanced across 3 lines")
        for line in lines {
            XCTAssertLessThanOrEqual(line.count, 42, "Line must not overflow canvas width: '\(line)'")
            XCTAssertFalse(line.hasPrefix("•"), "Line must not begin with orphan bullet: '\(line)'")
            XCTAssertFalse(line.hasSuffix("•"), "Line must not end with orphan bullet: '\(line)'")
        }
    }

    func testSnapshotSpeechBubbleCarouselMessages() {
        let disk = DiskTelemetry(freeBytes: 107_374_182_400, totalBytes: 536_870_912_000)
        let ram = RAMTelemetry(usedBytes: 17_179_869_184, totalBytes: 34_359_738_368)
        let agents = AgentTelemetry(activeCount: 2, agentNames: ["Claude", "Cursor"])
        let cpu = CPUTelemetry(loadPercentage: 10.0, temperatureCelsius: 42.0)
        let fps = FPSTelemetry(currentFPS: 30.0)

        let snapshot = TelemetrySnapshot(
            disk: disk,
            ram: ram,
            agents: agents,
            fps: fps,
            cpu: cpu
        )

        let messages = snapshot.speechBubbleCarouselMessages(enabledMetrics: [.agents, .disk, .ram, .cpu, .fps])
        XCTAssertEqual(messages.count, 5)
        XCTAssertTrue(messages[0].contains("2 active (Claude, Cursor)"))
        XCTAssertTrue(messages[1].contains("Storage: 100.0 GB free"))
        XCTAssertTrue(messages[2].contains("RAM: 16.0 / 32.0 GB"))
        XCTAssertTrue(messages[3].contains("CPU Core: 42.0°C"))
        XCTAssertTrue(messages[4].contains("Display Screen: 30 FPS"))
    }

    // MARK: - 5. TelemetryDashboardService Lifecycle & Sampling Tests

    func testTelemetryDashboardServiceSampleTickSync() {
        let suiteName = "TelemetryDashboardService.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let settings = TelemetrySettingsStore(userDefaults: defaults)
        let mockProvider = MockTelemetryDataProvider()
        let service = TelemetryDashboardService(settingsStore: settings, provider: mockProvider)

        XCTAssertEqual(service.menuBarTitleText, "Bitz")

        service.performSampleTickSync()

        XCTAssertEqual(service.snapshot.disk.freeGB, mockProvider.diskToReturn.freeGB, accuracy: 0.1)
        XCTAssertEqual(service.snapshot.ram.usedGB, mockProvider.ramToReturn.usedGB, accuracy: 0.1)
        XCTAssertEqual(service.snapshot.network.downloadBytesPerSec, mockProvider.networkToReturn.downloadBytesPerSec)
        XCTAssertEqual(service.snapshot.battery?.percentage, 85)
        XCTAssertEqual(service.snapshot.display?.name, "Studio Display")
    }

    func testTelemetryDashboardServiceWarningDetection() {
        let suiteName = "TelemetryWarningDetection.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let settings = TelemetrySettingsStore(userDefaults: defaults)
        let mockProvider = MockTelemetryDataProvider()
        // Low disk: 4 GB out of 100 GB
        mockProvider.diskToReturn = DiskTelemetry(freeBytes: 4_294_967_296, totalBytes: 107_374_182_400, lowDiskThresholdPercent: 10.0)
        mockProvider.ramToReturn = RAMTelemetry(usedBytes: 30_000_000_000, totalBytes: 32_000_000_000, pressure: .warning)

        let service = TelemetryDashboardService(settingsStore: settings, provider: mockProvider)
        service.performSampleTickSync()

        XCTAssertTrue(service.snapshot.hasActiveWarning)
        XCTAssertNotNil(service.snapshot.activeWarningSummary)
        XCTAssertTrue(service.snapshot.activeWarningSummary?.contains("LOW DISK") == true || service.snapshot.activeWarningSummary?.contains("HIGH MEMORY PRESSURE") == true)
    }

    func testTelemetryDashboardServiceMenuBarTitleToggling() {
        let suiteName = "TelemetryTitleToggling.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let settings = TelemetrySettingsStore(userDefaults: defaults)
        let mockProvider = MockTelemetryDataProvider()
        let service = TelemetryDashboardService(settingsStore: settings, provider: mockProvider)

        service.performSampleTickSync(
            agents: AgentTelemetry(activeCount: 1, agentNames: ["Claude"])
        )

        // When displayInMenuBarTitle is false, title is "Bitz"
        XCTAssertEqual(service.menuBarTitleText, "Bitz")

        // Enable displayInMenuBarTitle
        settings.displayInMenuBarTitle = true
        XCTAssertNotEqual(service.menuBarTitleText, "Bitz")
        XCTAssertTrue(service.menuBarTitleText.contains("Bitz •"))
        XCTAssertTrue(service.menuBarTitleText.contains("1 Agts"))
    }

    func testTelemetryDashboardServiceAsyncSampleTick() async {
        let suiteName = "TelemetryAsyncSample.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let settings = TelemetrySettingsStore(userDefaults: defaults)
        let mockProvider = MockTelemetryDataProvider()
        let service = TelemetryDashboardService(settingsStore: settings, provider: mockProvider)

        await service.performSampleTick()

        XCTAssertGreaterThan(service.snapshot.disk.totalBytes, 0)
        XCTAssertGreaterThan(service.snapshot.ram.totalBytes, 0)
    }

    // MARK: - 6. Agent Context Gauge (FR-006)

    private let claudeContext = AgentContextReading(agentID: "claude", agentName: "Claude", tokens: 148_000, windowTokens: 200_000)

    func testAgentsMetricShowsContextInBadgeSummaryAndTitle() {
        let agents = AgentTelemetry(activeCount: 1, agentNames: ["Claude"], context: claudeContext)
        let snapshot = TelemetrySnapshot(agents: agents)

        XCTAssertEqual(agents.compactBadge, "1 AGTS · 74%")
        XCTAssertEqual(agents.formattedSummary, "1 active (Claude) · Claude ctx 148k · 74%")
        XCTAssertEqual(snapshot.hudSummary(enabledMetrics: [.agents], focusPoints: 0), "1 AGTS · 74% • 0 PTS")
        XCTAssertEqual(snapshot.speechBubbleCarouselMessages(enabledMetrics: [.agents]), ["🤖 1 active (Claude) · Claude ctx 148k · 74%"])
        XCTAssertEqual(snapshot.menuBarTitle(enabledMetrics: [.agents]), "Bitz • 1 Agts 74%")
    }

    func testAgentsMetricUnchangedWithoutContext() {
        let agents = AgentTelemetry(activeCount: 1, agentNames: ["Claude"])
        let snapshot = TelemetrySnapshot(agents: agents)

        XCTAssertNil(agents.context)
        XCTAssertEqual(agents.compactBadge, "1 AGTS")
        XCTAssertEqual(agents.formattedSummary, "1 active (Claude)")
        XCTAssertEqual(snapshot.hudSummary(enabledMetrics: [.agents], focusPoints: 0), "1 AGTS • 0 PTS")
        XCTAssertEqual(snapshot.speechBubbleCarouselMessages(enabledMetrics: [.agents]), ["🤖 1 active (Claude)"])
        XCTAssertEqual(snapshot.menuBarTitle(enabledMetrics: [.agents]), "Bitz • 1 Agts")

        // Nothing active and no reading: agents stay out of every placement.
        let empty = TelemetrySnapshot(agents: .empty)
        XCTAssertEqual(empty.hudSummary(enabledMetrics: [.agents], focusPoints: 0), "0 PTS")
        XCTAssertEqual(empty.speechBubbleCarouselMessages(enabledMetrics: [.agents]), [])
        XCTAssertEqual(empty.menuBarTitle(enabledMetrics: [.agents]), "Bitz")
    }

    func testLastContextReadingStaysVisibleWhenNoAgentIsActive() {
        let idle = TelemetrySnapshot(agents: AgentTelemetry(activeCount: 0, context: claudeContext))

        XCTAssertEqual(idle.agents.compactBadge, "CTX 74%")
        XCTAssertEqual(idle.hudSummary(enabledMetrics: [.agents], focusPoints: 0), "CTX 74% • 0 PTS")
        XCTAssertEqual(idle.speechBubbleCarouselMessages(enabledMetrics: [.agents]),
                       ["🤖 No agents currently active · Claude ctx 148k · 74%"])
        XCTAssertEqual(idle.menuBarTitle(enabledMetrics: [.agents]), "Bitz • Ctx 74%")
    }

    func testDashboardKeepsLastContextReadingAfterTurnEnds() async {
        let suiteName = "TelemetryAgentContext.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let monitor = AgentMonitorService(adapters: [], userDefaults: defaults)
        let service = TelemetryDashboardService(
            settingsStore: TelemetrySettingsStore(userDefaults: defaults),
            provider: MockTelemetryDataProvider(),
            agentMonitor: monitor
        )

        monitor.handleEvent(AgentEvent(agentID: "claude", agentName: "Claude", kind: .working))
        monitor.handleEvent(AgentEvent(agentID: "claude", agentName: "Claude", kind: .usage,
                                       metadata: [AgentEvent.MetadataKey.contextTokens: "148000"]))
        await service.performSampleTick()
        XCTAssertEqual(service.snapshot.agents.context, claudeContext)
        XCTAssertEqual(service.snapshot.agents.compactBadge, "1 AGTS · 74%")

        // The turn ends: the reading stays, which is when it is most worth checking.
        monitor.handleEvent(AgentEvent(agentID: "claude", agentName: "Claude", kind: .done))
        await service.performSampleTick()
        XCTAssertEqual(service.snapshot.agents.activeCount, 0)
        XCTAssertEqual(service.snapshot.agents.context, claudeContext)
        XCTAssertEqual(service.snapshot.agents.compactBadge, "CTX 74%")
    }

    // MARK: - 7. Disk Telemetry Throttling & Caching (#126)

    func testDiskTelemetryThrottledWhenVisibleAndBackedOffFurtherWhenHidden() async {
        let suiteName = "TelemetryDiskThrottle.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let settings = TelemetrySettingsStore(userDefaults: defaults)
        let mockProvider = MockTelemetryDataProvider()
        // 15% free (75 GB of 500 GB)
        mockProvider.diskToReturn = DiskTelemetry(freeBytes: 75_000_000_000, totalBytes: 500_000_000_000)
        let service = TelemetryDashboardService(settingsStore: settings, provider: mockProvider)

        // Initial tick at t=100 always samples disk
        await service.performSampleTick(nowUptime: 100.0)
        XCTAssertEqual(mockProvider.diskFetchCount, 1)
        XCTAssertFalse(service.snapshot.disk.isLowSpace)

        // Subsequent 3s ticks while HUD is visible (< 30s) reuse cached disk capacity
        // while still applying updated lowDiskWarningThresholdPercent
        settings.lowDiskWarningThresholdPercent = 20.0
        await service.performSampleTick(nowUptime: 103.0)
        await service.performSampleTick(nowUptime: 115.0)
        XCTAssertEqual(mockProvider.diskFetchCount, 1)
        XCTAssertTrue(service.snapshot.disk.isLowSpace, "Threshold change must apply to cached disk reading immediately")

        // At t=130.0 (30s elapsed with HUD visible), disk is sampled again
        await service.performSampleTick(nowUptime: 130.0)
        XCTAssertEqual(mockProvider.diskFetchCount, 2)

        // Hide all disk surfaces: interval increases to 120s
        settings.displayInMascotCyberHUD = false
        settings.displayInMenuBarTitle = false
        settings.displayInSpeechBubbleCycle = false
        TelemetryDashboardService.isMenuTracking = false
        SettingsWindowManager.shared.closeSettingsWindow()
        XCTAssertFalse(service.isDiskSurfaceVisible)

        await service.performSampleTick(nowUptime: 170.0) // +40s (< 120s hidden interval)
        XCTAssertEqual(mockProvider.diskFetchCount, 2)

        await service.performSampleTick(nowUptime: 250.0) // +120s (>= 120s hidden interval)
        XCTAssertEqual(mockProvider.diskFetchCount, 3)

        // Explicit force refresh bypasses interval
        await service.performSampleTick(forceDiskRefresh: true, nowUptime: 252.0)
        XCTAssertEqual(mockProvider.diskFetchCount, 4)
    }

    func testSystemTelemetryDataProviderCachesDiskQueryAndAvoidsZeroCapacity() {
        final class UptimeBox: @unchecked Sendable {
            var now: TimeInterval = 500.0
        }
        let clock = UptimeBox()
        let provider = SystemTelemetryDataProvider(diskCacheTTL: 60.0, uptime: { clock.now })

        let first = provider.fetchDiskTelemetry(lowDiskThresholdPercent: 10.0)
        XCTAssertGreaterThan(first.totalBytes, 0)
        XCTAssertGreaterThan(first.freeBytes, 0)

        clock.now = 510.0
        let cached = provider.fetchDiskTelemetry(lowDiskThresholdPercent: 99.0)
        XCTAssertEqual(cached.totalBytes, first.totalBytes)
        XCTAssertEqual(cached.freeBytes, first.freeBytes)
        XCTAssertEqual(cached.lowDiskThresholdPercent, 99.0)
    }
}
