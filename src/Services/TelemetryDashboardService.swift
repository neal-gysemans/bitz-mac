import AppKit
import Combine
import Darwin
import Foundation
import IOKit.ps

// MARK: - Live FPS Tracker

/// Thread-safe rolling frame-rate calculator for mascot rendering.
public final class LiveFPSTracker: @unchecked Sendable {
    private let lock = NSLock()
    private var frameTimestamps: [TimeInterval] = []
    private let windowDuration: TimeInterval
    public let targetFPS: Double

    public init(targetFPS: Double = 30.0, windowDuration: TimeInterval = 1.0) {
        self.targetFPS = targetFPS
        self.windowDuration = windowDuration
    }

    /// Records a rendered frame timestamp.
    public func recordFrame(timestamp: TimeInterval = ProcessInfo.processInfo.systemUptime) {
        lock.lock()
        defer { lock.unlock() }

        frameTimestamps.append(timestamp)
        let cutoff = timestamp - windowDuration
        while let first = frameTimestamps.first, first < cutoff {
            frameTimestamps.removeFirst()
        }
    }

    /// Computes the average rendering FPS over the rolling window.
    public var currentFPS: Double {
        lock.lock()
        defer { lock.unlock() }

        guard frameTimestamps.count >= 2,
              let first = frameTimestamps.first,
              let last = frameTimestamps.last else {
            return targetFPS
        }

        let elapsed = last - first
        guard elapsed > 0.05 else { return targetFPS }

        let calculated = Double(frameTimestamps.count - 1) / elapsed
        return min(max(calculated, 0.0), 120.0)
    }

    public func snapshot() -> FPSTelemetry {
        FPSTelemetry(currentFPS: currentFPS, targetFPS: targetFPS)
    }
}

// MARK: - Telemetry Data Provider Protocol

/// Interface for hardware and system metric collectors.
public protocol TelemetryDataProviding: Sendable {
    func fetchDiskTelemetry(lowDiskThresholdPercent: Double) -> DiskTelemetry
    func fetchRAMTelemetry() -> RAMTelemetry
    func fetchNetworkTelemetry(elapsedSeconds: Double) -> NetworkTelemetry
    func fetchBatteryTelemetry() -> BatteryTelemetry?
    func fetchDisplayTelemetry() -> DisplayTelemetry?
    func fetchDisplayFPSTelemetry(screen: NSScreen?) -> FPSTelemetry
}

extension TelemetryDataProviding {
    public func fetchDisplayFPSTelemetry(screen: NSScreen? = nil) -> FPSTelemetry {
        FPSTelemetry(currentFPS: 60.0, targetFPS: 60.0)
    }
}

// MARK: - Production macOS Telemetry Data Provider

/// Production implementation reading real macOS disk, Mach kernel RAM, network interfaces, and IOKit battery state.
public final class SystemTelemetryDataProvider: TelemetryDataProviding, @unchecked Sendable {
    private let lock = NSLock()
    private var previousNetworkSample: (bytesIn: UInt64, bytesOut: UInt64, timestamp: TimeInterval)?

    public init() {}

    public func fetchDiskTelemetry(lowDiskThresholdPercent: Double) -> DiskTelemetry {
        let homeURL = URL(fileURLWithPath: NSHomeDirectory())
        if let values = try? homeURL.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey, .volumeTotalCapacityKey]),
           let freeBytes = values.volumeAvailableCapacityForImportantUsage,
           let totalBytes = values.volumeTotalCapacity,
           totalBytes > 0 {
            return DiskTelemetry(
                freeBytes: UInt64(max(0, freeBytes)),
                totalBytes: UInt64(totalBytes),
                lowDiskThresholdPercent: lowDiskThresholdPercent
            )
        }

        // Fallback to statfs
        var stats = statfs()
        if statfs(NSHomeDirectory(), &stats) == 0 {
            let blockSize = UInt64(stats.f_bsize)
            let free = stats.f_bavail * blockSize
            let total = stats.f_blocks * blockSize
            return DiskTelemetry(freeBytes: free, totalBytes: total, lowDiskThresholdPercent: lowDiskThresholdPercent)
        }

        return DiskTelemetry(freeBytes: 0, totalBytes: 0, lowDiskThresholdPercent: lowDiskThresholdPercent)
    }

    public func fetchRAMTelemetry() -> RAMTelemetry {
        var stats = vm_statistics64()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64>.size / MemoryLayout<integer_t>.size)
        let hostPort = mach_host_self()
        let ret = withUnsafeMutablePointer(to: &stats) { ptr in
            ptr.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { intPtr in
                host_statistics64(hostPort, HOST_VM_INFO64, intPtr, &count)
            }
        }
        MachCompatibility.deallocateHostPort(hostPort)

        guard ret == KERN_SUCCESS else {
            return .empty
        }

        let pageSize = UInt64(getpagesize())
        let active = UInt64(stats.active_count) * pageSize
        let wired = UInt64(stats.wire_count) * pageSize
        let compressed = UInt64(stats.compressor_page_count) * pageSize
        let used = active + wired + compressed
        let total = ProcessInfo.processInfo.physicalMemory

        // Read macOS memory pressure sysctl
        var pressureInt: Int32 = 0
        var size = MemoryLayout<Int32>.size
        let pressureLevel: MemoryPressureLevel
        if sysctlbyname("kern.memorystatus_vm_pressure_level", &pressureInt, &size, nil, 0) == 0 {
            switch pressureInt {
            case 2: pressureLevel = .warning
            case 4: pressureLevel = .critical
            default: pressureLevel = .normal
            }
        } else {
            pressureLevel = .normal
        }

        return RAMTelemetry(usedBytes: used, totalBytes: total, pressure: pressureLevel)
    }

    public func fetchNetworkTelemetry(elapsedSeconds: Double) -> NetworkTelemetry {
        var ifaddr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddr) == 0, let first = ifaddr else {
            return .empty
        }
        defer { freeifaddrs(ifaddr) }

        var totalIn: UInt64 = 0
        var totalOut: UInt64 = 0

        for ptr in sequence(first: first, next: { $0.pointee.ifa_next }) {
            let flags = Int32(ptr.pointee.ifa_flags)
            let addr = ptr.pointee.ifa_addr.pointee
            guard (flags & IFF_UP) == IFF_UP, (flags & IFF_LOOPBACK) == 0 else { continue }
            if addr.sa_family == UInt8(AF_LINK), let data = ptr.pointee.ifa_data {
                let networkData = data.assumingMemoryBound(to: if_data.self).pointee
                totalIn += UInt64(networkData.ifi_ibytes)
                totalOut += UInt64(networkData.ifi_obytes)
            }
        }

        let now = ProcessInfo.processInfo.systemUptime

        lock.lock()
        defer { lock.unlock() }

        guard let previous = previousNetworkSample else {
            previousNetworkSample = (totalIn, totalOut, now)
            return .empty
        }

        let timeDelta = max(now - previous.timestamp, 0.1)
        let inDelta = totalIn >= previous.bytesIn ? totalIn - previous.bytesIn : 0
        let outDelta = totalOut >= previous.bytesOut ? totalOut - previous.bytesOut : 0

        previousNetworkSample = (totalIn, totalOut, now)

        let downRate = Double(inDelta) / timeDelta
        let upRate = Double(outDelta) / timeDelta
        return NetworkTelemetry(downloadBytesPerSec: downRate, uploadBytesPerSec: upRate)
    }

    public func fetchBatteryTelemetry() -> BatteryTelemetry? {
        guard let snapshot = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let sources = IOPSCopyPowerSourcesList(snapshot)?.takeRetainedValue() as? [CFTypeRef],
              !sources.isEmpty else {
            return nil
        }

        for source in sources {
            if let desc = IOPSGetPowerSourceDescription(snapshot, source)?.takeUnretainedValue() as? [String: Any] {
                let cur = desc[kIOPSCurrentCapacityKey] as? Int
                let isCharging = desc[kIOPSIsChargingKey] as? Bool
                let powerSource = desc[kIOPSPowerSourceStateKey] as? String
                return BatteryTelemetry(percentage: cur, isCharging: isCharging, powerSource: powerSource)
            }
        }
        return nil
    }

    public func fetchDisplayTelemetry() -> DisplayTelemetry? {
        guard let screen = NSScreen.main else { return nil }
        let name = screen.localizedName.isEmpty ? "Display" : screen.localizedName
        let frame = screen.frame
        let resolution = "\(Int(frame.width))×\(Int(frame.height))"
        let refreshRate = screen.maximumFramesPerSecond > 0 ? Double(screen.maximumFramesPerSecond) : 60.0
        return DisplayTelemetry(name: name, resolution: resolution, refreshRate: refreshRate)
    }

    public func fetchDisplayFPSTelemetry(screen: NSScreen? = nil) -> FPSTelemetry {
        guard let s = screen ?? NSScreen.main else {
            return FPSTelemetry(currentFPS: 60.0, targetFPS: 60.0, screenName: "Display")
        }
        let fps = s.maximumFramesPerSecond > 0 ? Double(s.maximumFramesPerSecond) : 60.0
        let name = s.localizedName.isEmpty ? "Display" : s.localizedName
        return FPSTelemetry(currentFPS: fps, targetFPS: fps, screenName: name)
    }
}

// MARK: - Telemetry Settings Store

/// Observable store managing user customizations, metric toggles, polling intervals, and placement options.
@MainActor
public final class TelemetrySettingsStore: ObservableObject {
    public static let enabledMetricsKey = "Bitz.Telemetry.EnabledMetrics"
    public static let pollingIntervalKey = "Bitz.Telemetry.PollingInterval"
    public static let lowDiskThresholdKey = "Bitz.Telemetry.LowDiskThresholdPercent"
    public static let displayInMenuBarMenuKey = "Bitz.Telemetry.DisplayInMenuBarMenu"
    public static let displayInMenuBarTitleKey = "Bitz.Telemetry.DisplayInMenuBarTitle"
    public static let displayInMascotCyberHUDKey = "Bitz.Telemetry.DisplayInMascotCyberHUD"
    public static let displayInSpeechBubbleCycleKey = "Bitz.Telemetry.DisplayInSpeechBubbleCycle"

    @Published public var enabledMetrics: Set<TelemetryMetric> {
        didSet {
            let rawList = enabledMetrics.map { $0.rawValue }
            userDefaults.set(rawList, forKey: Self.enabledMetricsKey)
            onConfigurationChanged?()
        }
    }

    @Published public var pollingIntervalSeconds: TimeInterval {
        didSet {
            userDefaults.set(pollingIntervalSeconds, forKey: Self.pollingIntervalKey)
            onConfigurationChanged?()
        }
    }

    @Published public var lowDiskWarningThresholdPercent: Double {
        didSet {
            userDefaults.set(lowDiskWarningThresholdPercent, forKey: Self.lowDiskThresholdKey)
            onConfigurationChanged?()
        }
    }

    @Published public var displayInMenuBarMenu: Bool {
        didSet {
            userDefaults.set(displayInMenuBarMenu, forKey: Self.displayInMenuBarMenuKey)
            onConfigurationChanged?()
        }
    }

    @Published public var displayInMenuBarTitle: Bool {
        didSet {
            userDefaults.set(displayInMenuBarTitle, forKey: Self.displayInMenuBarTitleKey)
            onConfigurationChanged?()
        }
    }

    @Published public var displayInMascotCyberHUD: Bool {
        didSet {
            userDefaults.set(displayInMascotCyberHUD, forKey: Self.displayInMascotCyberHUDKey)
            onConfigurationChanged?()
        }
    }

    @Published public var displayInSpeechBubbleCycle: Bool {
        didSet {
            userDefaults.set(displayInSpeechBubbleCycle, forKey: Self.displayInSpeechBubbleCycleKey)
            onConfigurationChanged?()
        }
    }

    public var onConfigurationChanged: (() -> Void)?
    private let userDefaults: UserDefaults

    public init(userDefaults: UserDefaults = .standard) {
        self.userDefaults = userDefaults

        if let storedMetrics = userDefaults.stringArray(forKey: Self.enabledMetricsKey) {
            let parsed = storedMetrics.compactMap { TelemetryMetric(rawValue: $0) }
            self.enabledMetrics = Set(parsed)
        } else {
            self.enabledMetrics = Set(TelemetryMetric.allCases.filter { $0.defaultEnabled })
        }

        let interval = userDefaults.double(forKey: Self.pollingIntervalKey)
        self.pollingIntervalSeconds = interval > 0 ? interval : 3.0

        let diskThreshold = userDefaults.double(forKey: Self.lowDiskThresholdKey)
        self.lowDiskWarningThresholdPercent = diskThreshold > 0 ? diskThreshold : 10.0

        self.displayInMenuBarMenu = userDefaults.object(forKey: Self.displayInMenuBarMenuKey) as? Bool ?? true
        self.displayInMenuBarTitle = userDefaults.object(forKey: Self.displayInMenuBarTitleKey) as? Bool ?? false
        self.displayInMascotCyberHUD = userDefaults.object(forKey: Self.displayInMascotCyberHUDKey) as? Bool ?? true
        self.displayInSpeechBubbleCycle = userDefaults.object(forKey: Self.displayInSpeechBubbleCycleKey) as? Bool ?? false
    }

    public func isMetricEnabled(_ metric: TelemetryMetric) -> Bool {
        enabledMetrics.contains(metric)
    }

    public func toggleMetric(_ metric: TelemetryMetric) {
        if enabledMetrics.contains(metric) {
            enabledMetrics.remove(metric)
        } else {
            enabledMetrics.insert(metric)
        }
    }

    public func setMetric(_ metric: TelemetryMetric, enabled: Bool) {
        if enabled {
            enabledMetrics.insert(metric)
        } else {
            enabledMetrics.remove(metric)
        }
    }
}

// MARK: - Telemetry Dashboard Service

/// Central coordinator for modular system telemetry, asynchronous sampling, and display bindings.
@MainActor
public final class TelemetryDashboardService: ObservableObject {
    public static var isMenuTracking: Bool = false
    public var onTitleChanged: ((String) -> Void)?

    @Published public private(set) var snapshot: TelemetrySnapshot = TelemetrySnapshot()
    @Published public private(set) var menuBarTitleText: String = "Bitz"
    @Published public private(set) var currentCarouselMessage: String? = nil

    public let settingsStore: TelemetrySettingsStore
    public let provider: TelemetryDataProviding
    public let fpsTracker: LiveFPSTracker

    private weak var agentMonitor: AgentMonitorService?
    private weak var activityMonitor: ActivityMonitorService?
    private weak var engine: WellnessPointEngine?
    private weak var displayStore: DisplayPreferenceStore?

    private var sampleTask: Task<Void, Never>?
    private var carouselTask: Task<Void, Never>?
    private var carouselIndex: Int = 0
    private var pendingSnapshot: TelemetrySnapshot?
    nonisolated(unsafe) private var menuBeginTrackingObserver: (any NSObjectProtocol)?
    nonisolated(unsafe) private var menuEndTrackingObserver: (any NSObjectProtocol)?

    public init(
        settingsStore: TelemetrySettingsStore = TelemetrySettingsStore(),
        provider: TelemetryDataProviding = SystemTelemetryDataProvider(),
        fpsTracker: LiveFPSTracker = LiveFPSTracker(),
        agentMonitor: AgentMonitorService? = nil,
        activityMonitor: ActivityMonitorService? = nil,
        engine: WellnessPointEngine? = nil
    ) {
        self.settingsStore = settingsStore
        self.provider = provider
        self.fpsTracker = fpsTracker
        self.agentMonitor = agentMonitor
        self.activityMonitor = activityMonitor
        self.engine = engine

        self.settingsStore.onConfigurationChanged = { [weak self] in
            self?.applyConfigurationChange()
        }

        self.menuBeginTrackingObserver = NotificationCenter.default.addObserver(
            forName: NSMenu.didBeginTrackingNotification,
            object: nil,
            queue: .main
        ) { _ in
            MainActor.assumeIsolated {
                Self.isMenuTracking = true
            }
        }

        self.menuEndTrackingObserver = NotificationCenter.default.addObserver(
            forName: NSMenu.didEndTrackingNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                Self.isMenuTracking = false
                guard let self, let pending = self.pendingSnapshot else { return }
                self.snapshot = pending
                self.pendingSnapshot = nil
                self.updateMenuBarTitle()
            }
        }

        updateMenuBarTitle()
    }

    deinit {
        sampleTask?.cancel()
        carouselTask?.cancel()
        if let o = menuBeginTrackingObserver {
            NotificationCenter.default.removeObserver(o)
        }
        if let o = menuEndTrackingObserver {
            NotificationCenter.default.removeObserver(o)
        }
    }

    public func bindDependencies(
        agentMonitor: AgentMonitorService,
        activityMonitor: ActivityMonitorService,
        engine: WellnessPointEngine,
        displayStore: DisplayPreferenceStore? = nil
    ) {
        self.agentMonitor = agentMonitor
        self.activityMonitor = activityMonitor
        self.engine = engine
        self.displayStore = displayStore
    }

    public func start() {
        stop()

        // Background sampling loop running off-main-thread with low CPU footprint (<1%)
        let interval = settingsStore.pollingIntervalSeconds
        sampleTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { break }
                await self.performSampleTick()
                try? await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))
            }
        }

        startCarouselTimer()
    }

    public func stop() {
        sampleTask?.cancel()
        sampleTask = nil
        carouselTask?.cancel()
        carouselTask = nil
    }

    private func applyConfigurationChange() {
        updateMenuBarTitle()
        if settingsStore.displayInSpeechBubbleCycle {
            if carouselTask == nil {
                startCarouselTimer()
            }
        } else {
            carouselTask?.cancel()
            carouselTask = nil
            currentCarouselMessage = nil
        }
    }

    private func startCarouselTimer() {
        guard settingsStore.displayInSpeechBubbleCycle else {
            currentCarouselMessage = nil
            return
        }

        carouselTask?.cancel()
        carouselTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 6_000_000_000)
                guard let self, !Task.isCancelled else { break }
                self.advanceCarousel()
            }
        }
    }

    private func advanceCarousel() {
        guard !Self.isMenuTracking else { return }
        let messages = snapshot.speechBubbleCarouselMessages(enabledMetrics: settingsStore.enabledMetrics)
        guard !messages.isEmpty else {
            currentCarouselMessage = nil
            return
        }
        carouselIndex = (carouselIndex + 1) % messages.count
        currentCarouselMessage = messages[carouselIndex]
    }

    /// Performs an asynchronous telemetry collection tick off the main thread.
    public func performSampleTick() async {
        let lowDiskThreshold = settingsStore.lowDiskWarningThresholdPercent
        let elapsed = settingsStore.pollingIntervalSeconds

        // Sample raw hardware metrics asynchronously
        let disk = await Task.detached(priority: .utility) { [provider] in
            provider.fetchDiskTelemetry(lowDiskThresholdPercent: lowDiskThreshold)
        }.value

        let ram = await Task.detached(priority: .utility) { [provider] in
            provider.fetchRAMTelemetry()
        }.value

        let net = await Task.detached(priority: .utility) { [provider] in
            provider.fetchNetworkTelemetry(elapsedSeconds: elapsed)
        }.value

        let bat = await Task.detached(priority: .utility) { [provider] in
            provider.fetchBatteryTelemetry()
        }.value

        let currentScreen = displayStore?.resolveScreen() ?? NSScreen.main
        let disp = provider.fetchDisplayTelemetry()
        let fps = provider.fetchDisplayFPSTelemetry(screen: currentScreen)

        // Gather agent metrics from bound AgentMonitorService
        let activeAgentIDs = agentMonitor?.activeAgents ?? []
        let activeAgentNames: [String] = agentMonitor?.catalog
            .filter { activeAgentIDs.contains($0.id) }
            .map { $0.displayName } ?? []
        let lastAction = agentMonitor?.activePopup?.text
        // The last reading stays after the turn ends, when context is most worth checking; a new reading replaces it.
        let context = agentMonitor?.latestContext
        let agentTelemetry = AgentTelemetry(
            activeCount: activeAgentIDs.count,
            agentNames: activeAgentNames,
            lastActionMessage: lastAction,
            context: context
        )

        // Gather CPU & Thermal metrics
        let cpuLoad = activityMonitor?.lastCPULoadPercentage
        let cpuTemp = activityMonitor?.lastTemperatureCelsius
        let thermalState = activityMonitor?.lastThermalState ?? .nominal
        let isOverheating = (cpuTemp ?? 0.0) >= 85.0 || (cpuLoad ?? 0.0) >= 90.0 || thermalState == .critical
        let cpuTelemetry = CPUTelemetry(
            loadPercentage: cpuLoad,
            temperatureCelsius: cpuTemp,
            thermalState: thermalState,
            isOverheating: isOverheating
        )

        let newSnapshot = TelemetrySnapshot(
            timestamp: Date(),
            disk: disk,
            ram: ram,
            agents: agentTelemetry,
            fps: fps,
            cpu: cpuTelemetry,
            network: net,
            battery: bat,
            display: disp
        )

        if Self.isMenuTracking {
            self.pendingSnapshot = newSnapshot
            return
        }

        self.snapshot = newSnapshot
        updateMenuBarTitle()

        if settingsStore.displayInSpeechBubbleCycle && currentCarouselMessage == nil {
            advanceCarousel()
        }
    }

    /// Synchronous sample tick suitable for unit testing without waiting for timers.
    public func performSampleTickSync(
        disk: DiskTelemetry? = nil,
        ram: RAMTelemetry? = nil,
        agents: AgentTelemetry? = nil,
        fps: FPSTelemetry? = nil,
        cpu: CPUTelemetry? = nil,
        network: NetworkTelemetry? = nil,
        battery: BatteryTelemetry? = nil
    ) {
        let d = disk ?? provider.fetchDiskTelemetry(lowDiskThresholdPercent: settingsStore.lowDiskWarningThresholdPercent)
        let r = ram ?? provider.fetchRAMTelemetry()
        let n = network ?? provider.fetchNetworkTelemetry(elapsedSeconds: 1.0)
        let b = battery ?? provider.fetchBatteryTelemetry()
        let f = fps ?? fpsTracker.snapshot()
        let c = cpu ?? CPUTelemetry()
        let a = agents ?? AgentTelemetry.empty

        self.snapshot = TelemetrySnapshot(
            timestamp: Date(),
            disk: d,
            ram: r,
            agents: a,
            fps: f,
            cpu: c,
            network: n,
            battery: b,
            display: provider.fetchDisplayTelemetry()
        )
        updateMenuBarTitle()
    }

    private func updateMenuBarTitle() {
        let newTitle: String
        if settingsStore.displayInMenuBarTitle {
            newTitle = snapshot.menuBarTitle(enabledMetrics: settingsStore.enabledMetrics)
        } else {
            newTitle = "Bitz"
        }
        if menuBarTitleText != newTitle {
            menuBarTitleText = newTitle
            onTitleChanged?(newTitle)
        }
    }
}
