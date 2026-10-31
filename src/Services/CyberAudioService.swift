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

    // Cooldown & Rate Limiting state
    public private(set) var lastOneShotPlayedAt: Date?
    public private(set) var agentChimeCooldowns: [String: Date] = [:]
    public private(set) var lastFanfarePlayedAt: Date?
    public private(set) var lastObservedState: BitzState?
    public var minOneShotInterval: TimeInterval = 1.5

    private var purrFadeTask: Task<Void, Never>?
    private var cancellables = Set<AnyCancellable>()

    public init(
        settingsStore: CyberAudioSettingsStore = CyberAudioSettingsStore(),
        environmentDetector: AudioEnvironmentDetecting = AudioEnvironmentDetector(),
        dateProvider: @escaping @Sendable () -> Date = { Date() },
        engine: AVAudioEngine = AVAudioEngine()
    ) {
        self.settingsStore = settingsStore
        self.environmentDetector = environmentDetector
        self.dateProvider = dateProvider
        self.engine = engine
        self.mixerNode = engine.mainMixerNode
        self.purrNode = AVAudioPlayerNode()

        setupEngine()
        preloadBuffers()
        bindSettings()
    }

    deinit {
        purrFadeTask?.cancel()
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
        guard settingsStore.isEnabled else {
            return (false, .masterDisabled)
        }

        guard settingsStore.isEventEnabled(event) else {
            return (false, .eventDisabled)
        }

        // Environmental suppression
        if environmentDetector.isSystemOutputMuted() {
            return (false, .systemMuted)
        }

        if settingsStore.isCallSuppressionEnabled && environmentDetector.isMicrophoneOrScreenCaptureActive() {
            return (false, .callOrScreenSharingActive)
        }

        if settingsStore.isFocusDNDSuppressionEnabled && environmentDetector.isFocusOrDNDActive() {
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
            return
        }

        guard let buffer = loadedBuffers[event] else {
            return
        }

        guard ensureEngineRunning() else {
            return
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

        let playerNode = oneShotNodes.first { !$0.isPlaying } ?? oneShotNodes[0]

        if playerNode.isPlaying {
            playerNode.stop()
        }

        if playerNode.outputFormat(forBus: 0).channelCount != buffer.format.channelCount {
            engine.disconnectNodeOutput(playerNode)
            engine.connect(playerNode, to: mixerNode, format: buffer.format)
        }

        playerNode.scheduleBuffer(buffer, at: nil, options: []) { [weak self, weak playerNode] in
            Task { @MainActor [weak self] in
                playerNode?.stop()
                self?.evaluateIdlePowerGating()
            }
        }

        playerNode.play()
    }

    public func setPurring(_ on: Bool) {
        guard on != isPurring else { return }

        if on {
            guard settingsStore.isEnabled, settingsStore.isPurrEnabled else { return }
            if environmentDetector.isSystemOutputMuted() { return }
            if settingsStore.isCallSuppressionEnabled && environmentDetector.isMicrophoneOrScreenCaptureActive() { return }
            if settingsStore.isFocusDNDSuppressionEnabled && environmentDetector.isFocusOrDNDActive() { return }

            guard let buffer = loadedBuffers[.purr] else { return }
            guard ensureEngineRunning() else { return }

            isPurring = true
            purrNode.stop()
            purrFadeTask?.cancel()

            purrNode.volume = 0.0
            purrNode.scheduleBuffer(buffer, at: nil, options: .loops, completionHandler: nil)
            purrNode.play()

            let targetVol: Float = 0.35
            let step: Float = targetVol / 10.0
            purrFadeTask = Task { @MainActor [weak self] in
                while !Task.isCancelled {
                    try? await Task.sleep(nanoseconds: 25_000_000)
                    guard !Task.isCancelled, let self else { return }
                    let nextVol = min(self.purrNode.volume + step, targetVol)
                    self.purrNode.volume = nextVol
                    if nextVol >= targetVol { break }
                }
            }
        } else {
            isPurring = false
            purrFadeTask?.cancel()

            let step: Float = 0.35 / 10.0
            purrFadeTask = Task { @MainActor [weak self] in
                while !Task.isCancelled {
                    try? await Task.sleep(nanoseconds: 25_000_000)
                    guard !Task.isCancelled, let self else { return }
                    let nextVol = max(self.purrNode.volume - step, 0.0)
                    self.purrNode.volume = nextVol
                    if nextVol <= 0.0 {
                        self.purrNode.stop()
                        self.evaluateIdlePowerGating()
                        break
                    }
                }
            }
        }
    }

    public func stopAll() {
        purrFadeTask?.cancel()
        isPurring = false
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
                if isPetting {
                    if !self.isPurring {
                        self.setPurring(true)
                    }
                } else {
                    if self.lastObservedState != .superCharged {
                        self.setPurring(false)
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
