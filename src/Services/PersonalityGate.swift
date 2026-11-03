import Foundation

/// Protocol abstracting power, battery and thermal state for commentary gating.
public protocol PowerStateProviding: Sendable {
    /// Battery level in percent (0...100), or `nil` if running on AC power / desktop Mac.
    var batteryLevelPercentage: Double? { get }
    /// Whether Low Power Mode is currently enabled.
    var isLowPowerModeEnabled: Bool { get }
    /// Current system thermal state.
    var thermalState: ProcessInfo.ThermalState { get }
}

/// Production system power state provider querying Foundation `ProcessInfo`.
public struct SystemPowerStateProvider: PowerStateProviding {
    public init() {}

    public var batteryLevelPercentage: Double? {
        // Default system provider; desktop Macs and AC-tethered Macs return nil
        nil
    }

    public var isLowPowerModeEnabled: Bool {
        ProcessInfo.processInfo.isLowPowerModeEnabled
    }

    public var thermalState: ProcessInfo.ThermalState {
        ProcessInfo.processInfo.thermalState
    }
}

/// Outcome of evaluating hardware power and thermal gates.
public enum GateDecision: Equatable, Sendable {
    case allowed
    case blocked(PersonalityError)

    public var isAllowed: Bool {
        if case .allowed = self { return true }
        return false
    }

    public var error: PersonalityError? {
        if case .blocked(let err) = self { return err }
        return nil
    }
}

/// Pure evaluation gate protecting battery, thermal headroom and low-power modes.
public struct PersonalityGate: Sendable {
    public static let defaultLowBatteryThresholdPercent: Double = 20.0

    public let lowBatteryThresholdPercent: Double

    public init(lowBatteryThresholdPercent: Double = PersonalityGate.defaultLowBatteryThresholdPercent) {
        self.lowBatteryThresholdPercent = lowBatteryThresholdPercent
    }

    /// Evaluates whether on-device generation is safe to run.
    public func evaluate(powerState: PowerStateProviding, context: PersonalityContext) -> GateDecision {
        if powerState.isLowPowerModeEnabled {
            return .blocked(.gated("Low Power Mode is active"))
        }

        if powerState.thermalState == .serious || powerState.thermalState == .critical {
            return .blocked(.gated("Thermal state is \(powerState.thermalState == .critical ? "critical" : "serious")"))
        }

        if let battery = powerState.batteryLevelPercentage, battery < lowBatteryThresholdPercent {
            return .blocked(.gated("Battery is low (\(Int(battery))%)"))
        }

        if context.wellnessState == .overheating {
            return .blocked(.gated("System is overheating"))
        }

        return .allowed
    }
}
