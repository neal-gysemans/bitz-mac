import Foundation
import AVFoundation
import Combine

/// Low-latency, zero-idle-CPU cybernetic audio service for Bitz.
///
/// Uses `AVAudioEngine` with preloaded `AVAudioPCMBuffer`s for instant (< 50 ms) sound playback.
/// Stops or pauses the audio rendering engine when silent to maintain 0.0% idle CPU overhead.
/// Enforces per-event cooldowns, transition-only state sounds, and environmental suppression.
@MainActor
public final class CyberAudioService: ObservableObject, CyberAudioPlaying {
    public let settingsStore: CyberAudioSettingsStore
    public let environmentDetector: AudioEnvironmentDetecting
    public let dateProvider: @Sendable () -> Date
    public var randomPurrIntervalProvider: @Sendable () -> TimeInterval

    // Preloaded sound buffers decoded once at launch
    public private(set) var loadedBuffers: [CyberSoundEvent: AVAudioPCMBuffer] = [:]

    // Audio Engine components
    private let engine: AVAudioEngine
    private let mixerNode: AVAudioMixerNode
    private let purrNode: AVAudioPlayerNode
    private var oneShotNodes: [AVAudioPlayerNode] = []
    private let maxOneShotPlayers = 4

    @Published public private(set) var isPurring: Bool = false
    @Published public private(set) var isEngineRunning: Bool = false
    /// Last sound the environment muted (mic in use, system mute), so the UI can say why Bitz stayed silent (#95).
    /// Cleared by the next played sound or any settings change.
    @Published public private(set) var lastEnvironmentSuppression: (reason: AudioSuppressionReason, date: Date)?

    // Cooldown & Rate Limiting state
    public private(set) var lastOneShotPlayedAt: Date?
    public private(set) var agentChimeCooldowns: [String: Date] = [:]
    public private(set) var lastFanfarePlayedAt: Date?
    public private(set) var lastObservedState: BitzState?
    public var minOneShotInterval: TimeInterval = 1.5

    private var purrFadeTask: Task<Void, Never>?
    private var periodicPurrTask: Task<Void, Never>?
    public private(set) var isPettingActive: Bool = false
    private var cancellables = Set<AnyCancellable>()

    public init(
        settingsStore: CyberAudioSettingsStore = CyberAudioSettingsStore(),
        environmentDetector: AudioEnvironmentDetecting = AudioEnvironmentDetector(),
        dateProvider: @escaping @Sendable () -> Date = { Date() },
        randomPurrIntervalProvider: @escaping @Sendable () -> TimeInterval = { Double.random(in: 45.0...90.0) },
        engine: AVAudioEngine = AVAudioEngine()
    ) {
        self.settingsStore = settingsStore
        self.environmentDetector = environmentDetector
        self.dateProvider = dateProvider
        self.randomPurrIntervalProvider = randomPurrIntervalProvider
        self.engine = engine
        self.mixerNode = engine.mainMixerNode
        self.purrNode = AVAudioPlayerNode()

        setupEngine()
        preloadBuffers()
        bindSettings()
    }

    deinit {
        purrFadeTask?.cancel()
        periodicPurrTask?.cancel()
    }

    // MARK: - Setup & Configuration

    private func setupEngine() {
        engine.attach(purrNode)
        engine.connect(purrNode, to: mixerNode, format: nil)

        for _ in 0..<maxOneShotPlayers {
            let node = AVAudioPlayerNode()
            engine.attach(node)
            engine.connect(node, to: mixerNode, format: nil)
            oneShotNodes.append(node)
        }

        mixerNode.outputVolume = Float(settingsStore.volume)
    }

    private func bindSettings() {
        settingsStore.$volume
            .sink { [weak self] newVolume in
                guard let self else { return }
                self.mixerNode.outputVolume = Float(newVolume)
            }
            .store(in: &cancellables)

        settingsStore.$isEnabled
            .sink { [weak self] enabled in
                guard let self else { return }
                if !enabled {
                    self.stopAll()
                }
            }
            .store(in: &cancellables)

        settingsStore.objectWillChange
            .sink { [weak self] _ in
                guard let self, self.lastEnvironmentSuppression != nil else { return }
                self.lastEnvironmentSuppression = nil
            }
            .store(in: &cancellables)
    }

    // MARK: - Asset Preloading

    public func preloadBuffers() {
        for event in CyberSoundEvent.allCases {
            if let url = resolveAssetURL(for: event.assetFileName) {
                do {
                    let audioFile = try AVAudioFile(forReading: url)
                    let format = audioFile.processingFormat
                    let frameCount = AVAudioFrameCount(audioFile.length)
                    guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount) else {
                        continue
                    }
                    try audioFile.read(into: buffer)
                    loadedBuffers[event] = buffer
                } catch {
                    #if DEBUG
                    print("[CyberAudioService] Failed to decode \(event.assetFileName): \(error)")
                    #endif
                }
            }
        }

        if let purrFormat = loadedBuffers[.purr]?.format {
            engine.disconnectNodeOutput(purrNode)
            engine.connect(purrNode, to: mixerNode, format: purrFormat)
        }
    }

    public func resolveAssetURL(for fileName: String) -> URL? {
        let name = (fileName as NSString).deletingPathExtension
        let ext = (fileName as NSString).pathExtension

        #if SWIFT_PACKAGE
        if let moduleURL = Bundle.module.url(forResource: name, withExtension: ext) {
            return moduleURL
        }
        if let moduleSubURL = Bundle.module.url(forResource: name, withExtension: ext, subdirectory: "Sounds") {
            return moduleSubURL
        }
        #endif

        if let mainURL = Bundle.main.url(forResource: name, withExtension: ext) {
            return mainURL
        }
        if let mainSubURL = Bundle.main.url(forResource: name, withExtension: ext, subdirectory: "Sounds") {
            return mainSubURL
        }

        let candidatePaths = [
            "Resources/Sounds/\(fileName)",
            "src/Resources/Sounds/\(fileName)",
            "../Resources/Sounds/\(fileName)"
        ]

        for path in candidatePaths {
            let fileURL = URL(fileURLWithPath: path)
            if FileManager.default.fileExists(atPath: fileURL.path) {
                return fileURL
            }
        }

        return nil
    }

    // MARK: - Engine Lifecycle & Power Gating

    private func ensureEngineRunning() -> Bool {
        if !engine.isRunning {
            do {
                try engine.start()
                isEngineRunning = true
            } catch {
                #if DEBUG
                print("[CyberAudioService] Could not start AVAudioEngine: \(error)")
                #endif
                return false
            }
        }
        return true
    }

    private func evaluateIdlePowerGating() {
        guard !isPurring else { return }

        let anyOneShotPlaying = oneShotNodes.contains { $0.isPlaying }
        if !anyOneShotPlaying && engine.isRunning {
            engine.pause()
            isEngineRunning = false
        }
    }

    // MARK: - Cooldown & Suppression Evaluation

    public func canPlay(
        _ event: CyberSoundEvent,
        agentId: String? = nil,
        now: Date? = nil,
        bypassCooldown: Bool = false
    ) -> (allowed: Bool, reason: AudioSuppressionReason?) {
        guard settingsStore.isEnabled || event.ignoresMasterAndFocus else {
            return (false, .masterDisabled)
        }

        guard settingsStore.isEventEnabled(event) else {
            return (false, .eventDisabled)
        }

        // Environmental suppression
        if environmentDetector.isSystemOutputMuted() {
            return (false, .systemMuted)
        }

        if !event.ignoresCallSuppression && settingsStore.isCallSuppressionEnabled && environmentDetector.isMicrophoneOrScreenCaptureActive() {
            return (false, .callOrScreenSharingActive)
        }

        if !event.ignoresMasterAndFocus && settingsStore.isFocusDNDSuppressionEnabled && environmentDetector.isFocusOrDNDActive() {
            return (false, .focusActive)
        }

        guard loadedBuffers[event] != nil else {
            return (false, .assetMissing)
        }

        if bypassCooldown {
            return (true, nil)
        }

        let currentTime = now ?? dateProvider()

        // Global rate limit check (for non-looping sounds)
        if !event.isLooping, let lastPlayed = lastOneShotPlayedAt {
            if currentTime.timeIntervalSince(lastPlayed) < minOneShotInterval {
                return (false, .rateLimited)
            }
        }

        // Event-specific cooldowns
        if event == .agentNeedsApproval, let agentId {
            if let lastChime = agentChimeCooldowns[agentId] {
                if currentTime.timeIntervalSince(lastChime) < event.defaultCooldown {
                    return (false, .cooldownActive)
                }
            }
        } else if event == .allAgentsDone {
            if let lastFanfare = lastFanfarePlayedAt {
                if currentTime.timeIntervalSince(lastFanfare) < event.defaultCooldown {
                    return (false, .cooldownActive)
                }
            }
        }

        return (true, nil)
    }

    // MARK: - Playback API

    public func play(_ event: CyberSoundEvent) {
        play(event, agentId: nil, bypassCooldown: false)
    }

    public func play(_ event: CyberSoundEvent, bypassCooldown: Bool) {
        play(event, agentId: nil, bypassCooldown: bypassCooldown)
    }

    public func play(_ event: CyberSoundEvent, agentId: String?) {
        play(event, agentId: agentId, bypassCooldown: false)
    }

    public func play(_ event: CyberSoundEvent, agentId: String?, bypassCooldown: Bool) {
        let now = dateProvider()
        let check = canPlay(event, agentId: agentId, now: now, bypassCooldown: bypassCooldown)
        guard check.allowed else {
            if let reason = check.reason, reason.environmentDescription != nil {
                lastEnvironmentSuppression = (reason, now)
            }
            return
        }

        guard let buffer = loadedBuffers[event] else {
            return
        }

        guard ensureEngineRunning() else {
            return
        }

        if lastEnvironmentSuppression != nil {
            lastEnvironmentSuppression = nil
        }

        // Record cooldowns only for live operational playback (not UI previews)
        if !bypassCooldown {
            lastOneShotPlayedAt = now
            if event == .agentNeedsApproval, let agentId {
                agentChimeCooldowns[agentId] = now
            } else if event == .allAgentsDone {
                lastFanfarePlayedAt = now
            }
        }

        let playerIndex = oneShotNodes.firstIndex { !$0.isPlaying } ?? 0
        let playerNode = oneShotNodes[playerIndex]

        if playerNode.isPlaying {
            playerNode.stop()
        }

        if playerNode.outputFormat(forBus: 0).channelCount != buffer.format.channelCount {
            engine.disconnectNodeOutput(playerNode)
            engine.connect(playerNode, to: mixerNode, format: buffer.format)
        }

        playerNode.scheduleBuffer(buffer, at: nil, options: []) { [weak self] in
            Task { @MainActor [weak self] in
                guard let self else { return }
                if playerIndex < self.oneShotNodes.count {
                    self.oneShotNodes[playerIndex].stop()
                }
                self.evaluateIdlePowerGating()
            }
        }

        playerNode.play()
    }

    public func setPurring(_ on: Bool) {
        if on {
            startPeriodicPurrScheduler()
        } else {
            stopPeriodicPurrScheduler()
        }
    }

    /// Starts periodic random purring during high wellness (`superCharged`), playing an initial purr
    /// followed by subsequent soothing purrs at natural random intervals (45s–90s).
    public func startPeriodicPurrScheduler() {
        stopPeriodicPurrScheduler()
        guard settingsStore.isEnabled, settingsStore.isPurrEnabled else { return }

        playPurrBurst()

        periodicPurrTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                guard let self else { break }
                let interval = self.randomPurrIntervalProvider()
                try? await Task.sleep(nanoseconds: UInt64(max(0.05, interval) * 1_000_000_000))
                guard !Task.isCancelled else { break }
                guard self.lastObservedState == .superCharged || self.isPettingActive else { break }
                self.playPurrBurst()
            }
        }
    }

    /// Halts the periodic purr scheduler and stops active purr audio.
    public func stopPeriodicPurrScheduler() {
        periodicPurrTask?.cancel()
        periodicPurrTask = nil
        if !isPettingActive {
            stopPurr()
        }
    }

    /// Plays a single natural purr cycle (~3.0s), automatically pausing the engine when complete.
    public func playPurrBurst() {
        guard settingsStore.isEnabled, settingsStore.isPurrEnabled else { return }
        if environmentDetector.isSystemOutputMuted() { return }
        if settingsStore.isCallSuppressionEnabled && environmentDetector.isMicrophoneOrScreenCaptureActive() { return }
        if settingsStore.isFocusDNDSuppressionEnabled && environmentDetector.isFocusOrDNDActive() { return }

        guard let buffer = loadedBuffers[.purr] else { return }
        guard ensureEngineRunning() else { return }

        isPurring = true
        purrNode.stop()
        purrFadeTask?.cancel()

        purrNode.volume = 0.50
        purrNode.scheduleBuffer(buffer, at: nil, options: []) { [weak self] in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.purrNode.stop()
                self.isPurring = false
                self.evaluateIdlePowerGating()
            }
        }
        purrNode.play()
    }

    /// Stops any active purr audio immediately and evaluates power gating.
    public func stopPurr() {
        purrFadeTask?.cancel()
        if purrNode.isPlaying {
            purrNode.stop()
        }
        isPurring = false
        evaluateIdlePowerGating()
    }

    public func stopAll() {
        periodicPurrTask?.cancel()
        periodicPurrTask = nil
        purrFadeTask?.cancel()
        isPurring = false
        isPettingActive = false
        purrNode.stop()
        purrNode.volume = 0.0

        for node in oneShotNodes {
            if node.isPlaying {
                node.stop()
            }
        }

        if engine.isRunning {
            engine.pause()
            isEngineRunning = false
        }
    }

    // MARK: - State & Event Observation

    /// Handles state transition from WellnessPointEngine, firing state sounds ONLY on transition.
    public func handleStateTransition(from oldState: BitzState?, to newState: BitzState) {
        guard oldState != newState else { return }
        lastObservedState = newState

        switch newState {
        case .superCharged:
            setPurring(true)
        case .burnout:
            if oldState == .superCharged {
                setPurring(false)
            }
            play(.burnout)
        case .overheating:
            if oldState == .superCharged {
                setPurring(false)
            }
            play(.overheating)
        case .charging:
            if oldState == .superCharged {
                setPurring(false)
            }
            play(.charging)
        case .balanced, .dopamineSad, .overworked:
            if oldState == .superCharged {
                setPurring(false)
            }
        }
    }

    /// Attaches observations to WellnessPointEngine.
    public func observe(wellnessEngine: WellnessPointEngine) {
        lastObservedState = wellnessEngine.currentState

        wellnessEngine.$currentState
            .sink { [weak self] newState in
                guard let self else { return }
                let oldState = self.lastObservedState
                self.handleStateTransition(from: oldState, to: newState)
            }
            .store(in: &cancellables)

        // Observe user petting interaction ("Pet Bitz (<3)")
        wellnessEngine.$isPetReactionActive
            .sink { [weak self] isPetting in
                guard let self else { return }
                self.isPettingActive = isPetting
                if isPetting {
                    self.playPurrBurst()
                } else {
                    if self.lastObservedState != .superCharged {
                        self.stopPurr()
                    }
                }
            }
            .store(in: &cancellables)
    }

    /// Attaches observations to AgentMonitorService.
    public func observe(agentMonitor: AgentMonitorService) {
        var previousActiveCount = agentMonitor.activeAgents.count

        agentMonitor.onEventHandled = { [weak self] event in
            guard let self else { return }
            if event.kind == .needsApproval {
                self.play(.agentNeedsApproval, agentId: event.agentID)
            } else if event.kind == .done {
                self.play(.allAgentsDone)
            }
        }

        agentMonitor.$activeAgents
            .sink { [weak self] currentAgents in
                guard let self else { return }
                let currentCount = currentAgents.count

                // All agents finished detection: transition from non-empty to empty
                if previousActiveCount > 0 && currentCount == 0 {
                    self.play(.allAgentsDone)
                }

                previousActiveCount = currentCount
            }
            .store(in: &cancellables)
    }
}
