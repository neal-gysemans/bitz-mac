import Combine
import Foundation

// MARK: - Shortcuts Execution Seam

/// Sendable protocol seam for running user-configured macOS Shortcuts (`#22`).
public protocol ShortcutsRunning: Sendable {
    func runShortcut(named name: String) async throws
}

/// Thread-safe one-shot gate ensuring an async continuation resumes at most once.
private final class ShortcutContinuationGate: @unchecked Sendable {
    private let lock = NSLock()
    private var hasResumed = false

    func tryResume(_ body: () -> Void) {
        lock.lock()
        defer { lock.unlock() }
        guard !hasResumed else { return }
        hasResumed = true
        body()
    }
}

/// Box allowing `@Sendable` cancellation/timeout closures to terminate a launched `Process`.
private final class RunningProcessBox: @unchecked Sendable {
    let process: Process

    init(_ process: Process) {
        self.process = process
    }

    func terminateIfRunning() {
        if process.isRunning {
            process.terminate()
        }
    }
}

/// Production macOS Shortcuts runner invoking `/usr/bin/shortcuts run <name>` off `@MainActor`
/// with direct `Process.arguments` (zero shell interpolation), trimmed-name validation, and timeout protection.
public struct ProcessShortcutsRunner: ShortcutsRunning {
    public let executableURL: URL
    public let timeoutSeconds: TimeInterval

    public init(
        executableURL: URL = URL(fileURLWithPath: "/usr/bin/shortcuts"),
        timeoutSeconds: TimeInterval = 15.0
    ) {
        self.executableURL = executableURL
        self.timeoutSeconds = max(0.1, timeoutSeconds)
    }

    public func runShortcut(named name: String) async throws {
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty else {
            throw FlowShieldShortcutError.emptyShortcutName
        }

        let execPath = executableURL.path
        guard FileManager.default.isExecutableFile(atPath: execPath) else {
            throw FlowShieldShortcutError.executableNotFound(execPath)
        }

        let process = Process()
        process.executableURL = executableURL
        process.arguments = ["run", trimmedName]
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice

        let stderrPipe = Pipe()
        process.standardError = stderrPipe

        let processBox = RunningProcessBox(process)
        let gate = ShortcutContinuationGate()
        let timeout = timeoutSeconds

        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                process.terminationHandler = { terminatedProcess in
                    let stderrData = (try? stderrPipe.fileHandleForReading.readToEnd()) ?? Data()
                    let stderrText = String(data: stderrData, encoding: .utf8) ?? ""
                    let status = terminatedProcess.terminationStatus

                    gate.tryResume {
                        if status == 0 {
                            continuation.resume(returning: ())
                        } else {
                            continuation.resume(
                                throwing: FlowShieldShortcutError.executionFailed(
                                    shortcutName: trimmedName,
                                    exitCode: status,
                                    stderr: stderrText
                                )
                            )
                        }
                    }
                }

                do {
                    try process.run()
                } catch {
                    gate.tryResume {
                        continuation.resume(
                            throwing: FlowShieldShortcutError.executionFailed(
                                shortcutName: trimmedName,
                                exitCode: -1,
                                stderr: error.localizedDescription
                            )
                        )
                    }
                    return
                }

                DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + timeout) {
                    guard processBox.process.isRunning else { return }
                    processBox.terminateIfRunning()
                    gate.tryResume {
                        continuation.resume(
                            throwing: FlowShieldShortcutError.timedOut(shortcutName: trimmedName)
                        )
                    }
                }
            }
        } onCancel: {
            processBox.terminateIfRunning()
        }
    }
}

/// Deterministic test spy recording Shortcut invocations without spawning `/usr/bin/shortcuts`.
public final class SpyShortcutsRunner: ShortcutsRunning, @unchecked Sendable {
    private let lock = NSLock()
    private var _invokedShortcutNames: [String] = []
    private var _simulatedError: (any Error)?

    public init(simulatedError: (any Error)? = nil) {
        self._simulatedError = simulatedError
    }

    public var invokedShortcutNames: [String] {
        lock.lock()
        defer { lock.unlock() }
        return _invokedShortcutNames
    }

    public var simulatedError: (any Error)? {
        get {
            lock.lock()
            defer { lock.unlock() }
            return _simulatedError
        }
        set {
            lock.lock()
            defer { lock.unlock() }
            _simulatedError = newValue
        }
    }

    public func reset() {
        lock.lock()
        defer { lock.unlock() }
        _invokedShortcutNames.removeAll()
        _simulatedError = nil
    }

    public func runShortcut(named name: String) async throws {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw FlowShieldShortcutError.emptyShortcutName
        }

        let maybeError: (any Error)? = {
            lock.lock()
            defer { lock.unlock() }
            _invokedShortcutNames.append(trimmed)
            return _simulatedError
        }()

        if let error = maybeError {
            throw error
        }
    }
}

// MARK: - FlowShieldService

/// `@MainActor` coordinator observing `WellnessPointEngine` to engage macOS Focus once per deep-work streak
/// and disengage Focus on break completion or manual Break Shield override (`#22`).
@MainActor
public final class FlowShieldService: ObservableObject {
    public let settingsStore: FlowShieldSettingsStore
    public let shortcutsRunner: any ShortcutsRunning

    @Published public private(set) var isFlowShieldActive: Bool = false
    @Published public private(set) var lastErrorMessage: String? = nil

    private weak var observedEngine: WellnessPointEngine?
    private var hasTriggeredForCurrentStreak: Bool = false
    private var wasInChargingState: Bool = false
    private var engineCancellables = Set<AnyCancellable>()
    private var settingsCancellables = Set<AnyCancellable>()
    private var shortcutQueueTask: Task<Void, Never>?

    public init(
        settingsStore: FlowShieldSettingsStore = FlowShieldSettingsStore(),
        shortcutsRunner: any ShortcutsRunning = ProcessShortcutsRunner()
    ) {
        self.settingsStore = settingsStore
        self.shortcutsRunner = shortcutsRunner
        bindSettings()
    }

    public var currentStatus: FlowShieldStatus {
        guard settingsStore.isEnabled else {
            return .disabled
        }
        if settingsStore.isBreakShieldOverrideActive {
            return .breakShieldOverride
        }
        return isFlowShieldActive ? .active : .standby
    }

    // MARK: - Engine Observation

    /// Subscribes to `WellnessPointEngine` state transitions without adding any extra timers.
    public func observe(wellnessEngine: WellnessPointEngine) {
        engineCancellables.removeAll()
        observedEngine = wellnessEngine
        wasInChargingState = (wellnessEngine.currentState == .charging)

        // WellnessPointEngine updates currentPoints, continuousWorkMinutes, and lastTickWasProductive
        // before assigning currentState inside evaluateState(), making $currentState atomic per tick.
        wellnessEngine.$currentState
            .sink { [weak self, weak wellnessEngine] newState in
                guard let self, let engine = wellnessEngine else { return }
                self.evaluateTransition(
                    state: newState,
                    continuousWorkMinutes: engine.continuousWorkMinutes,
                    lastTickWasProductive: engine.lastTickWasProductive
                )
            }
            .store(in: &engineCancellables)

        // When thermal overheating override is active, WellnessPointEngine skips evaluateState();
        // observe $continuousWorkMinutes in that mode so streak/break transitions remain responsive.
        wellnessEngine.$continuousWorkMinutes
            .dropFirst()
            .sink { [weak self, weak wellnessEngine] newMinutes in
                guard let self, let engine = wellnessEngine, engine.currentState == .overheating else { return }
                self.evaluateTransition(
                    state: .overheating,
                    continuousWorkMinutes: newMinutes,
                    lastTickWasProductive: engine.lastTickWasProductive
                )
            }
            .store(in: &engineCancellables)
    }

    // MARK: - Break Shield Manual Override & Settings Actions

    /// Immediately disables active Flow Shield (running `stopFocusShortcutName` if active)
    /// and prevents automatic re-activation until cleared or next opted-in session.
    public func activateBreakShieldOverride() {
        let shouldStop = isFlowShieldActive
        if isFlowShieldActive {
            isFlowShieldActive = false
        }
        settingsStore.setBreakShieldOverrideActive(true)
        if shouldStop {
            enqueueStopFocusShortcut()
        }
    }

    /// Clears Break Shield manual override so future deep-work streaks can engage Focus again.
    public func clearBreakShieldOverride() {
        hasTriggeredForCurrentStreak = false
        settingsStore.setBreakShieldOverrideActive(false)
    }

    /// Toggles Break Shield override state.
    public func toggleBreakShieldOverride() {
        if settingsStore.isBreakShieldOverrideActive {
            clearBreakShieldOverride()
        } else {
            activateBreakShieldOverride()
        }
    }

    /// Runs the configured `"Start Focus"` Shortcut once for verification in Settings.
    public func testStartShortcut() async {
        let name = settingsStore.startFocusShortcutName
        await enqueueAndAwaitShortcut(named: name, revertActiveOnError: false)
    }

    /// Runs the configured `"Stop Focus"` Shortcut once for verification in Settings.
    public func testStopShortcut() async {
        let name = settingsStore.stopFocusShortcutName
        await enqueueAndAwaitShortcut(named: name, revertActiveOnError: false)
    }

    public func clearError() {
        lastErrorMessage = nil
    }

    /// Awaits completion of all queued Shortcut executions (deterministic test synchronization helper).
    public func waitForPendingShortcuts() async {
        await shortcutQueueTask?.value
    }

    // MARK: - Internal State Machine

    private func bindSettings() {
        settingsStore.$isEnabled
            .dropFirst()
            .removeDuplicates()
            .sink { [weak self] enabled in
                guard let self else { return }
                if !enabled {
                    self.hasTriggeredForCurrentStreak = false
                    if self.isFlowShieldActive {
                        self.isFlowShieldActive = false
                        self.enqueueStopFocusShortcut()
                    }
                } else if let engine = self.observedEngine {
                    self.hasTriggeredForCurrentStreak = false
                    self.evaluateTransition(
                        state: engine.currentState,
                        continuousWorkMinutes: engine.continuousWorkMinutes,
                        lastTickWasProductive: engine.lastTickWasProductive
                    )
                }
            }
            .store(in: &settingsCancellables)

        settingsStore.$isBreakShieldOverrideActive
            .dropFirst()
            .removeDuplicates()
            .sink { [weak self] overrideActive in
                guard let self else { return }
                if overrideActive {
                    if self.isFlowShieldActive {
                        self.isFlowShieldActive = false
                        self.enqueueStopFocusShortcut()
                    }
                } else {
                    self.hasTriggeredForCurrentStreak = false
                }
            }
            .store(in: &settingsCancellables)

        settingsStore.$streakMinutesThreshold
            .dropFirst()
            .removeDuplicates()
            .sink { [weak self] newThreshold in
                guard let self, let engine = self.observedEngine else { return }
                if !self.isFlowShieldActive && engine.continuousWorkMinutes < newThreshold {
                    self.hasTriggeredForCurrentStreak = false
                }
                self.evaluateTransition(
                    state: engine.currentState,
                    continuousWorkMinutes: engine.continuousWorkMinutes,
                    lastTickWasProductive: engine.lastTickWasProductive
                )
            }
            .store(in: &settingsCancellables)
    }

    private func evaluateTransition(
        state: BitzState,
        continuousWorkMinutes: Double,
        lastTickWasProductive: Bool
    ) {
        if state == .charging {
            wasInChargingState = true
            if !isFlowShieldActive && continuousWorkMinutes < settingsStore.streakMinutesThreshold {
                hasTriggeredForCurrentStreak = false
            }
            return
        }

        // Detect return from a completed break:
        // 1) Transitioning out of `.charging` back to active/idle-awake state, OR
        // 2) Direct offline break (`applyOfflineBreak` / reset) resetting `continuousWorkMinutes` to 0
        //    without being an unproductive distraction tick (`lastTickWasProductive == true`).
        let returnedFromChargingBreak = wasInChargingState
        if wasInChargingState {
            wasInChargingState = false
        }
        let completedDirectOfflineBreak = isFlowShieldActive
            && continuousWorkMinutes == 0.0
            && lastTickWasProductive

        if returnedFromChargingBreak || completedDirectOfflineBreak {
            if isFlowShieldActive {
                isFlowShieldActive = false
                enqueueStopFocusShortcut()
            }
            if continuousWorkMinutes < settingsStore.streakMinutesThreshold {
                hasTriggeredForCurrentStreak = false
            }
            return
        }

        if !isFlowShieldActive && continuousWorkMinutes < settingsStore.streakMinutesThreshold {
            hasTriggeredForCurrentStreak = false
        }

        guard settingsStore.isEnabled,
              !settingsStore.isBreakShieldOverrideActive,
              !isFlowShieldActive,
              !hasTriggeredForCurrentStreak,
              continuousWorkMinutes >= settingsStore.streakMinutesThreshold else {
            return
        }

        isFlowShieldActive = true
        hasTriggeredForCurrentStreak = true
        enqueueStartFocusShortcut()
    }

    private func enqueueStartFocusShortcut() {
        let shortcutName = settingsStore.startFocusShortcutName
        enqueueShortcut(named: shortcutName, revertActiveOnError: true)
    }

    private func enqueueStopFocusShortcut() {
        let shortcutName = settingsStore.stopFocusShortcutName
        enqueueShortcut(named: shortcutName, revertActiveOnError: false)
    }

    private func enqueueShortcut(named name: String, revertActiveOnError: Bool) {
        let previousTask = shortcutQueueTask
        let runner = shortcutsRunner
        shortcutQueueTask = Task { @MainActor [weak self] in
            await previousTask?.value
            do {
                try await runner.runShortcut(named: name)
                self?.lastErrorMessage = nil
            } catch {
                guard let self else { return }
                self.lastErrorMessage = error.localizedDescription
                if revertActiveOnError && self.isFlowShieldActive {
                    self.isFlowShieldActive = false
                }
            }
        }
    }

    private func enqueueAndAwaitShortcut(named name: String, revertActiveOnError: Bool) async {
        enqueueShortcut(named: name, revertActiveOnError: revertActiveOnError)
        await shortcutQueueTask?.value
    }
}
