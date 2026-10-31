import Foundation
import AVFoundation
import Combine

/// Low-latency, zero-idle-CPU cybernetic audio service for Bitz.
///
/// Uses `AVAudioEngine` with preloaded `AVAudioPCMBuffer`s for instant (< 50 ms) sound playback.
/// Stops or pauses the audio rendering engine when silent to maintain 0.0% idle CPU overhead.
/// Conforms to `CyberAudioPlaying` so clients can interact with it via protocol or test spy.
@MainActor
public final class CyberAudioService: ObservableObject, CyberAudioPlaying {
    public let settingsStore: CyberAudioSettingsStore

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

    private var purrFadeTask: Task<Void, Never>?
    private var cancellables = Set<AnyCancellable>()

    public init(
        settingsStore: CyberAudioSettingsStore = CyberAudioSettingsStore(),
        engine: AVAudioEngine = AVAudioEngine()
    ) {
        self.settingsStore = settingsStore
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

    /// Preloads and decodes all sound assets into memory as PCM buffers.
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
                    // Graceful fallback: log warning without crashing
                    #if DEBUG
                    print("[CyberAudioService] Failed to decode \(event.assetFileName): \(error)")
                    #endif
                }
            }
        }

        // Configure purr node with its specific buffer format
        if let purrFormat = loadedBuffers[.purr]?.format {
            engine.disconnectNodeOutput(purrNode)
            engine.connect(purrNode, to: mixerNode, format: purrFormat)
        }
    }

    /// Resolves the URL for an audio asset across SPM bundle, AppKit bundle, and local paths.
    public func resolveAssetURL(for fileName: String) -> URL? {
        let name = (fileName as NSString).deletingPathExtension
        let ext = (fileName as NSString).pathExtension

        // 1. Try Bundle.module (SwiftPM resource bundle)
        #if SWIFT_PACKAGE
        if let moduleURL = Bundle.module.url(forResource: name, withExtension: ext) {
            return moduleURL
        }
        if let moduleSubURL = Bundle.module.url(forResource: name, withExtension: ext, subdirectory: "Sounds") {
            return moduleSubURL
        }
        #endif

        // 2. Try Bundle.main (Packaged .app bundle)
        if let mainURL = Bundle.main.url(forResource: name, withExtension: ext) {
            return mainURL
        }
        if let mainSubURL = Bundle.main.url(forResource: name, withExtension: ext, subdirectory: "Sounds") {
            return mainSubURL
        }

        // 3. Fallback to direct relative paths (Development & Test worktrees)
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

    // MARK: - Engine Lifecycle & Zero-Idle-CPU Power Gating

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

    /// Checks if any audio is actively rendering. If completely silent, pauses the engine.
    private func evaluateIdlePowerGating() {
        guard !isPurring else { return }

        let anyOneShotPlaying = oneShotNodes.contains { $0.isPlaying }
        if !anyOneShotPlaying && engine.isRunning {
            engine.pause()
            isEngineRunning = false
        }
    }

    // MARK: - Playback API

    public func play(_ event: CyberSoundEvent) {
        guard settingsStore.isEnabled, settingsStore.isEventEnabled(event) else {
            return
        }

        guard let buffer = loadedBuffers[event] else {
            return
        }

        guard ensureEngineRunning() else {
            return
        }

        // Find an idle one-shot player node, or round-robin to the first
        let playerNode = oneShotNodes.first { !$0.isPlaying } ?? oneShotNodes[0]

        if playerNode.isPlaying {
            playerNode.stop()
        }

        if playerNode.outputFormat(forBus: 0).channelCount != buffer.format.channelCount {
            engine.disconnectNodeOutput(playerNode)
            engine.connect(playerNode, to: mixerNode, format: buffer.format)
        }

        playerNode.scheduleBuffer(buffer, at: nil, options: []) { [weak self] in
            Task { @MainActor [weak self] in
                self?.evaluateIdlePowerGating()
            }
        }

        playerNode.play()
    }

    public func setPurring(_ on: Bool) {
        guard on != isPurring else { return }

        if on {
            guard settingsStore.isEnabled, settingsStore.isPurrEnabled else { return }
            guard let buffer = loadedBuffers[.purr] else { return }
            guard ensureEngineRunning() else { return }

            isPurring = true
            purrNode.stop()
            purrFadeTask?.cancel()

            purrNode.volume = 0.0
            purrNode.scheduleBuffer(buffer, at: nil, options: .loops, completionHandler: nil)
            purrNode.play()

            // Fade in over ~250 ms
            let targetVol: Float = 0.35 // Purr stays gentle
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

            // Fade out over ~250 ms, then stop
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
}
