import AppKit
import Foundation

/// Modifier key that, while held, makes Bitz interactive (drag / pet / drop) without stealing focus.
public enum HoldModifierKey: String, CaseIterable, Identifiable, Sendable {
    case option, control, command, shift

    public var id: String { rawValue }

    public var flag: NSEvent.ModifierFlags {
        switch self {
        case .option: return .option
        case .control: return .control
        case .command: return .command
        case .shift: return .shift
        }
    }

    public var symbol: String {
        switch self {
        case .option: return "⌥"
        case .control: return "⌃"
        case .command: return "⌘"
        case .shift: return "⇧"
        }
    }

    public var label: String {
        switch self {
        case .option: return "Option"
        case .control: return "Control"
        case .command: return "Command"
        case .shift: return "Shift"
        }
    }

    public var displayName: String { "\(symbol) \(label)" }
}

/// `UserDefaults`-backed preferences for hold-to-interact, stroke-to-pet and the file drop-zone (#18).
@MainActor
public final class MascotInteractionSettingsStore: ObservableObject {
    public static let holdEnabledKey = "mascotHoldToInteractEnabled"
    public static let holdModifierKey = "mascotHoldModifier"
    public static let strokeToPetKey = "mascotStrokeToPetEnabled"
    public static let fileDropKey = "mascotFileDropEnabled"
    public static let inboxHandoffKey = "mascotInboxHandoffEnabled"

    private let userDefaults: UserDefaults

    @Published public var isHoldToInteractEnabled: Bool {
        didSet { userDefaults.set(isHoldToInteractEnabled, forKey: Self.holdEnabledKey) }
    }
    @Published public var holdModifier: HoldModifierKey {
        didSet { userDefaults.set(holdModifier.rawValue, forKey: Self.holdModifierKey) }
    }
    @Published public var isStrokeToPetEnabled: Bool {
        didSet { userDefaults.set(isStrokeToPetEnabled, forKey: Self.strokeToPetKey) }
    }
    @Published public var isFileDropEnabled: Bool {
        didSet { userDefaults.set(isFileDropEnabled, forKey: Self.fileDropKey) }
    }
    @Published public var isInboxHandoffEnabled: Bool {
        didSet { userDefaults.set(isInboxHandoffEnabled, forKey: Self.inboxHandoffKey) }
    }

    public init(userDefaults: UserDefaults = .standard) {
        self.userDefaults = userDefaults
        self.isHoldToInteractEnabled = userDefaults.object(forKey: Self.holdEnabledKey) as? Bool ?? true
        self.holdModifier = userDefaults.string(forKey: Self.holdModifierKey).flatMap(HoldModifierKey.init(rawValue:)) ?? .option
        self.isStrokeToPetEnabled = userDefaults.object(forKey: Self.strokeToPetKey) as? Bool ?? true
        self.isFileDropEnabled = userDefaults.object(forKey: Self.fileDropKey) as? Bool ?? true
        self.isInboxHandoffEnabled = userDefaults.object(forKey: Self.inboxHandoffKey) as? Bool ?? false
    }

    /// True when exactly the configured modifier is held (other modifiers are ignored so shortcuts stay usable).
    public func isHoldActive(for flags: NSEvent.ModifierFlags) -> Bool {
        guard isHoldToInteractEnabled else { return false }
        return flags.intersection(.deviceIndependentFlagsMask).contains(holdModifier.flag)
    }
}

/// Pure stroke detector: counts direction reversals of horizontal cursor travel. Never fires while a mouse
/// button is pressed (that is a drag-reposition, not a pet), and needs no timers, so it costs nothing at idle.
public struct PetStrokeDetector: Sendable {
    public var requiredReversals = 3
    public var minimumSegmentTravel: Double = 24
    public var window: TimeInterval = 1.5

    private var lastX: Double?
    private var direction: Double = 0
    private var segmentStartX: Double = 0
    private var reversalTimes: [TimeInterval] = []

    public init() {}

    /// Feed a hover position. Returns `true` once when a petting stroke is recognised.
    public mutating func feed(x: Double, at time: TimeInterval, mouseButtonsPressed: Int) -> Bool {
        guard mouseButtonsPressed == 0 else {
            reset()
            return false
        }
        defer { lastX = x }
        guard let previous = lastX else {
            segmentStartX = x
            return false
        }
        let delta = x - previous
        guard delta != 0 else { return false }
        let newDirection: Double = delta > 0 ? 1 : -1
        if direction == 0 {
            direction = newDirection
            segmentStartX = previous
            return false
        }
        if newDirection != direction {
            if abs(previous - segmentStartX) >= minimumSegmentTravel {
                reversalTimes.append(time)
                reversalTimes.removeAll { time - $0 > window }
            }
            direction = newDirection
            segmentStartX = previous
            if reversalTimes.count >= requiredReversals {
                reset()
                return true
            }
        }
        return false
    }

    public mutating func reset() {
        lastX = nil
        direction = 0
        segmentStartX = 0
        reversalTimes.removeAll()
    }
}
