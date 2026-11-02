import Foundation
import AppKit

/// Individual selectable telemetry metrics available in Bitz.
public enum TelemetryMetric: String, CaseIterable, Codable, Identifiable, Sendable {
    case agents
    case disk
    case ram
    case cpu
    case fps
    case network
    case battery

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .agents: return "AI Coding Agents"
        case .disk: return "Disk Storage"
        case .ram: return "Memory (RAM) & Pressure"
        case .cpu: return "CPU Load & Temperature"
        case .fps: return "Display Screen FPS"
        case .network: return "Network Speed"
        case .battery: return "Battery & Power"
        }
    }

    public var iconName: String {
        switch self {
        case .agents: return "cpu"
        case .disk: return "internaldrive"
        case .ram: return "memorychip"
        case .cpu: return "flame"
        case .fps: return "speedometer"
        case .network: return "network"
        case .battery: return "battery.100"
        }
    }

    public var defaultEnabled: Bool {
        switch self {
        case .agents, .disk, .ram, .cpu, .fps:
            return true
        case .network, .battery:
            return false
        }
    }
}

/// macOS Memory Pressure classification.
public enum MemoryPressureLevel: String, Codable, Sendable {
    case normal = "Normal"
    case warning = "Warning"
    case critical = "Critical"

    public var isWarningOrCritical: Bool {
        self != .normal
    }
}

/// Disk storage telemetry snapshot.
public struct DiskTelemetry: Equatable, Sendable {
    public let freeBytes: UInt64
    public let totalBytes: UInt64
    public let lowDiskThresholdPercent: Double

    public init(freeBytes: UInt64, totalBytes: UInt64, lowDiskThresholdPercent: Double = 10.0) {
        self.freeBytes = freeBytes
        self.totalBytes = totalBytes
        self.lowDiskThresholdPercent = lowDiskThresholdPercent
    }

    public var freeGB: Double {
        Double(freeBytes) / 1_073_741_824.0
    }

    public var totalGB: Double {
        Double(totalBytes) / 1_073_741_824.0
    }

    public var freePercentage: Double {
        guard totalBytes > 0 else { return 0.0 }
        return (Double(freeBytes) / Double(totalBytes)) * 100.0
    }

    public var isLowSpace: Bool {
        freePercentage < lowDiskThresholdPercent || freeGB < 10.0
    }

    public var formattedSummary: String {
        String(format: "%.1f GB free (%.1f%%) of %.1f GB", freeGB, freePercentage, totalGB)
    }

    public var compactBadge: String {
        String(format: "%.0fGB", freeGB)
    }

    public static let empty = DiskTelemetry(freeBytes: 0, totalBytes: 0)
}

/// RAM and memory pressure telemetry snapshot.
public struct RAMTelemetry: Equatable, Sendable {
    public let usedBytes: UInt64
    public let totalBytes: UInt64
    public let pressure: MemoryPressureLevel

    public init(usedBytes: UInt64, totalBytes: UInt64, pressure: MemoryPressureLevel = .normal) {
        self.usedBytes = usedBytes
        self.totalBytes = totalBytes
        self.pressure = pressure
    }

    public var usedGB: Double {
        Double(usedBytes) / 1_073_741_824.0
    }

    public var totalGB: Double {
        Double(totalBytes) / 1_073_741_824.0
    }

    public var usedPercentage: Double {
        guard totalBytes > 0 else { return 0.0 }
        return (Double(usedBytes) / Double(totalBytes)) * 100.0
    }

    public var isWarning: Bool {
        pressure.isWarningOrCritical
    }

    public var formattedSummary: String {
        String(format: "%.1f / %.1f GB (%.1f%%) • %@", usedGB, totalGB, usedPercentage, pressure.rawValue)
    }

    public var compactBadge: String {
        String(format: "%.1fGB RAM", usedGB)
    }

    public static let empty = RAMTelemetry(usedBytes: 0, totalBytes: 0, pressure: .normal)
}

/// Active AI Agents telemetry snapshot.
public struct AgentTelemetry: Equatable, Sendable {
    public let activeCount: Int
    public let agentNames: [String]
    public let lastActionMessage: String?
    /// Context gauge of the most recently active agent (FR-006); nil leaves every placement unchanged.
    public let context: AgentContextReading?

    public init(activeCount: Int, agentNames: [String] = [], lastActionMessage: String? = nil, context: AgentContextReading? = nil) {
        self.activeCount = activeCount
        self.agentNames = agentNames
        self.lastActionMessage = lastActionMessage
        self.context = context
    }

    public var formattedSummary: String {
        if activeCount == 0 {
            return "No agents currently active" + (context.map { " · \($0.compactText)" } ?? "")
        }
        let names = agentNames.isEmpty ? "" : " (\(agentNames.joined(separator: ", ")))"
        return "\(activeCount) active\(names)" + (context.map { " · \($0.compactText)" } ?? "")
    }

    public var compactBadge: String {
        if activeCount == 0, let context { return "CTX \(context.percent)%" }
        return "\(activeCount) AGTS" + (context.map { " · \($0.percent)%" } ?? "")
    }

    public static let empty = AgentTelemetry(activeCount: 0, agentNames: [], lastActionMessage: nil)
}

/// Display screen frame-rate / refresh rate telemetry snapshot.
public struct FPSTelemetry: Equatable, Sendable {
    public let currentFPS: Double
    public let targetFPS: Double
    public let screenName: String?

    public init(currentFPS: Double = 60.0, targetFPS: Double = 60.0, screenName: String? = nil) {
        self.currentFPS = currentFPS
        self.targetFPS = targetFPS
        self.screenName = screenName
    }

    public var formattedSummary: String {
        if let name = screenName {
            return String(format: "%.0f FPS (%@ @ %.0fHz)", currentFPS, name, currentFPS)
        }
        return String(format: "%.0f FPS (%.0fHz)", currentFPS, currentFPS)
    }

    public var compactBadge: String {
        String(format: "%.0f FPS", currentFPS)
    }

    public static let standard = FPSTelemetry(currentFPS: 60.0, targetFPS: 60.0)
}

/// CPU load and die temperature snapshot.
public struct CPUTelemetry: Equatable, Sendable {
    public let loadPercentage: Double?
    public let temperatureCelsius: Double?
    public let thermalState: ProcessInfo.ThermalState
    public let isOverheating: Bool

    public init(
        loadPercentage: Double? = nil,
        temperatureCelsius: Double? = nil,
        thermalState: ProcessInfo.ThermalState = .nominal,
        isOverheating: Bool = false
    ) {
        self.loadPercentage = loadPercentage
        self.temperatureCelsius = temperatureCelsius
        self.thermalState = thermalState
        self.isOverheating = isOverheating
    }

    public var formattedSummary: String {
        var parts: [String] = []
        if let temp = temperatureCelsius {
            parts.append(String(format: "%.1f°C", temp))
        }
        if let load = loadPercentage {
            parts.append(String(format: "%.1f%% Load", load))
        }
        let stateName: String
        switch thermalState {
        case .nominal: stateName = "Nominal"
        case .fair: stateName = "Fair"
        case .serious: stateName = "Serious"
        case .critical: stateName = "Critical"
        @unknown default: stateName = "Unknown"
        }
        parts.append(stateName)
        return parts.joined(separator: " • ")
    }

    public var compactBadge: String {
        if let temp = temperatureCelsius {
            if let load = loadPercentage {
                return String(format: "%.0f°C • %.0f%%", temp, load)
            }
            return String(format: "%.0f°C", temp)
        } else if let load = loadPercentage {
            return String(format: "%.0f%% CPU", load)
        }
        return "CPU"
    }

    public static let empty = CPUTelemetry()
}

/// Real-time network throughput snapshot.
public struct NetworkTelemetry: Equatable, Sendable {
    public let downloadBytesPerSec: Double
    public let uploadBytesPerSec: Double

    public init(downloadBytesPerSec: Double = 0.0, uploadBytesPerSec: Double = 0.0) {
        self.downloadBytesPerSec = downloadBytesPerSec
        self.uploadBytesPerSec = uploadBytesPerSec
    }

    private static func formatRate(_ bytesPerSec: Double) -> String {
        if bytesPerSec >= 1_048_576.0 {
            return String(format: "%.1f MB/s", bytesPerSec / 1_048_576.0)
        } else if bytesPerSec >= 1024.0 {
            return String(format: "%.0f KB/s", bytesPerSec / 1024.0)
        } else {
            return String(format: "%.0f B/s", bytesPerSec)
        }
    }

    public var formattedSummary: String {
        "↓ " + Self.formatRate(downloadBytesPerSec) + " • ↑ " + Self.formatRate(uploadBytesPerSec)
    }

    public var compactBadge: String {
        "↓ " + Self.formatRate(downloadBytesPerSec)
    }

    public static let empty = NetworkTelemetry()
}

/// Battery and charging state snapshot.
public struct BatteryTelemetry: Equatable, Sendable {
    public let percentage: Int?
    public let isCharging: Bool?
    public let powerSource: String?

    public init(percentage: Int?, isCharging: Bool?, powerSource: String?) {
        self.percentage = percentage
        self.isCharging = isCharging
        self.powerSource = powerSource
    }

    public var formattedSummary: String {
        guard let pct = percentage else { return "No battery detected (Desktop)" }
        let chargingStr = (isCharging == true) ? "⚡ Charging" : (powerSource ?? "Battery")
        return "\(pct)% (\(chargingStr))"
    }

    public var compactBadge: String {
        guard let pct = percentage else { return "AC" }
        return (isCharging == true) ? "⚡\(pct)%" : "\(pct)%"
    }
}

/// Active display characteristics snapshot.
public struct DisplayTelemetry: Equatable, Sendable {
    public let name: String
    public let resolution: String
    public let refreshRate: Double?

    public init(name: String, resolution: String, refreshRate: Double? = nil) {
        self.name = name
        self.resolution = resolution
        self.refreshRate = refreshRate
    }

    public var formattedSummary: String {
        if let rate = refreshRate, rate > 0 {
            return "\(name) (\(resolution) @ \(Int(rate))Hz)"
        }
        return "\(name) (\(resolution))"
    }
}

/// Complete aggregated snapshot of all real-time system and agent metrics.
public struct TelemetrySnapshot: Equatable, Sendable {
    public let timestamp: Date
    public let disk: DiskTelemetry
    public let ram: RAMTelemetry
    public let agents: AgentTelemetry
    public let fps: FPSTelemetry
    public let cpu: CPUTelemetry
    public let network: NetworkTelemetry
    public let battery: BatteryTelemetry?
    public let display: DisplayTelemetry?

    public init(
        timestamp: Date = Date(),
        disk: DiskTelemetry = .empty,
        ram: RAMTelemetry = .empty,
        agents: AgentTelemetry = .empty,
        fps: FPSTelemetry = .standard,
        cpu: CPUTelemetry = .empty,
        network: NetworkTelemetry = .empty,
        battery: BatteryTelemetry? = nil,
        display: DisplayTelemetry? = nil
    ) {
        self.timestamp = timestamp
        self.disk = disk
        self.ram = ram
        self.agents = agents
        self.fps = fps
        self.cpu = cpu
        self.network = network
        self.battery = battery
        self.display = display
    }

    public var hasActiveWarning: Bool {
        disk.isLowSpace || ram.pressure.isWarningOrCritical || cpu.isOverheating
    }

    public var activeWarningSummary: String? {
        if cpu.isOverheating {
            return "🔥 SYSTEM HOT: Cool down recommended"
        }
        if disk.isLowSpace {
            return String(format: "⚠️ LOW DISK: %.1f GB remaining", disk.freeGB)
        }
        if ram.pressure.isWarningOrCritical {
            return "⚠️ HIGH MEMORY PRESSURE: \(ram.pressure.rawValue)"
        }
        return nil
    }

    /// Formats a single-line compact Menu Bar title representation.
    public func menuBarTitle(enabledMetrics: Set<TelemetryMetric>) -> String {
        guard !enabledMetrics.isEmpty else { return "Bitz" }

        var items: [String] = []
        if enabledMetrics.contains(.agents) {
            if agents.activeCount > 0 {
                items.append("\(agents.activeCount) Agts" + (agents.context.map { " \($0.percent)%" } ?? ""))
            } else if let context = agents.context {
                items.append("Ctx \(context.percent)%")
            }
        }
        if enabledMetrics.contains(.cpu), let temp = cpu.temperatureCelsius {
            items.append(String(format: "%.0f°C", temp))
        }
        if enabledMetrics.contains(.disk) {
            items.append(disk.compactBadge)
        }
        if enabledMetrics.contains(.ram) {
            items.append(String(format: "%.0f%% RAM", ram.usedPercentage))
        }
        if enabledMetrics.contains(.fps) {
            items.append(fps.compactBadge)
        }
        if enabledMetrics.contains(.network) && (network.downloadBytesPerSec > 10240 || network.uploadBytesPerSec > 10240) {
            items.append(network.compactBadge)
        }
        if enabledMetrics.contains(.battery), let bat = battery {
            items.append(bat.compactBadge)
        }

        if items.isEmpty {
            return "Bitz"
        }
        return "Bitz • " + items.joined(separator: " | ")
    }

    /// Formats the Cyber HUD readout string displayed underneath the mascot.
    /// Balances items across 1 or 2 clean, centered lines without trailing bullets.
    public func hudSummary(enabledMetrics: Set<TelemetryMetric>, focusPoints: Double) -> String {
        var items: [String] = []

        if enabledMetrics.contains(.cpu), let temp = cpu.temperatureCelsius {
            if let load = cpu.loadPercentage {
                items.append(String(format: "%.0f°C (%.0f%%)", temp, load))
            } else {
                items.append(String(format: "%.0f°C", temp))
            }
        }
        if enabledMetrics.contains(.ram) {
            items.append(ram.compactBadge)
        }
        if enabledMetrics.contains(.agents) && (agents.activeCount > 0 || agents.context != nil) {
            items.append(agents.compactBadge)
        }
        if enabledMetrics.contains(.disk) {
            items.append(disk.compactBadge)
        }
        if enabledMetrics.contains(.fps) {
            items.append(fps.compactBadge)
        }
        if enabledMetrics.contains(.battery), let bat = battery {
            items.append(bat.compactBadge)
        }
        if enabledMetrics.contains(.network) && (network.downloadBytesPerSec > 10240 || network.uploadBytesPerSec > 10240) {
            items.append(network.compactBadge)
        }

        items.append(String(format: "%.0f PTS", focusPoints))

        // If 3 or fewer items, keep on a single clean line
        if items.count <= 3 {
            return items.joined(separator: " • ")
        }

        // Split into 2 evenly balanced lines
        let mid = (items.count + 1) / 2
        let line1 = items[0..<mid].joined(separator: " • ")
        let line2 = items[mid..<items.count].joined(separator: " • ")
        return line1 + "\n" + line2
    }

    /// Formats rotating speech bubble carousel messages for Bitz.
    public func speechBubbleCarouselMessages(enabledMetrics: Set<TelemetryMetric>) -> [String] {
        var messages: [String] = []

        if enabledMetrics.contains(.agents) && (agents.activeCount > 0 || agents.context != nil) {
            messages.append("🤖 \(agents.formattedSummary)")
        }
        if enabledMetrics.contains(.disk) {
            if disk.isLowSpace {
                messages.append(String(format: "⚠️ Low Disk Space! %.1f GB free", disk.freeGB))
            } else {
                messages.append(String(format: "💾 Storage: %.1f GB free (%.0f%%)", disk.freeGB, disk.freePercentage))
            }
        }
        if enabledMetrics.contains(.ram) {
            if ram.pressure.isWarningOrCritical {
                messages.append("⚠️ High RAM Pressure (\(ram.pressure.rawValue))!")
            } else {
                messages.append(String(format: "🧠 RAM: %.1f / %.1f GB in use", ram.usedGB, ram.totalGB))
            }
        }
        if enabledMetrics.contains(.cpu), let temp = cpu.temperatureCelsius {
            messages.append(String(format: "⚡ CPU Core: %.1f°C", temp))
        }
        if enabledMetrics.contains(.fps) {
            messages.append(String(format: "🖥️ Display Screen: %.0f FPS", fps.currentFPS))
        }

        return messages
    }
}
