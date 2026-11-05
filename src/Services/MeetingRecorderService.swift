import AppKit
@preconcurrency import AVFoundation
import CoreGraphics
import CoreMedia
import Foundation
@preconcurrency import ScreenCaptureKit
import Speech

// MARK: - Permission Checking Protocol & System Implementation

public protocol MeetingPermissionChecking: Sendable {
    func currentPermissions() -> MeetingPermissionState
    func requestPermissions(
        captureMicrophone: Bool,
        captureSystemAudio: Bool,
        transcribe: Bool
    ) async -> MeetingPermissionState
}

public struct SystemMeetingPermissionChecker: MeetingPermissionChecking {
    /// `CGPreflightScreenCaptureAccess` stays false until relaunch, so remember that access was already requested.
    static let screenCaptureRequestedKey = "Bitz.MeetingRecorder.ScreenCaptureRequested"

    public init() {}

    public func currentPermissions() -> MeetingPermissionState {
        let micStatus: MeetingPermissionState.Status
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            micStatus = .authorized
        case .denied, .restricted:
            micStatus = .denied
        case .notDetermined:
            micStatus = .notDetermined
        @unknown default:
            micStatus = .notDetermined
        }

        let screenStatus: MeetingPermissionState.Status
        if CGPreflightScreenCaptureAccess() {
            screenStatus = .authorized
        } else {
            screenStatus = UserDefaults.standard.bool(forKey: Self.screenCaptureRequestedKey) ? .denied : .notDetermined
        }

        let speechStatus: MeetingPermissionState.Status
        switch SFSpeechRecognizer.authorizationStatus() {
        case .authorized:
            speechStatus = .authorized
        case .denied, .restricted:
            speechStatus = .denied
        case .notDetermined:
            speechStatus = .notDetermined
        @unknown default:
            speechStatus = .notDetermined
        }

        return MeetingPermissionState(
            microphone: micStatus,
            screenAudio: screenStatus,
            speechRecognition: speechStatus
        )
    }

    public func requestPermissions(
        captureMicrophone: Bool,
        captureSystemAudio: Bool,
        transcribe: Bool
    ) async -> MeetingPermissionState {
        var state = currentPermissions()

        if captureMicrophone && state.microphone == .notDetermined {
            let granted = await AVCaptureDevice.requestAccess(for: .audio)
            state.microphone = granted ? .authorized : .denied
        }

        if captureSystemAudio && state.screenAudio != .authorized {
            if CGPreflightScreenCaptureAccess() {
                state.screenAudio = .authorized
            } else {
                UserDefaults.standard.set(true, forKey: Self.screenCaptureRequestedKey)
                let granted = CGRequestScreenCaptureAccess()
                state.screenAudio = granted ? .authorized : .denied
            }
        }

        if transcribe && state.speechRecognition == .notDetermined {
            let authStatus = await withCheckedContinuation { continuation in
                SFSpeechRecognizer.requestAuthorization { status in
                    continuation.resume(returning: status)
                }
            }
            state.speechRecognition = (authStatus == .authorized) ? .authorized : .denied
        }

        return state
    }
}

// MARK: - Dual-Stream Audio Mixer & .m4a Writer

/// Mixes synchronized 48kHz stereo PCM frames from Microphone and System Audio and encodes them into an AAC `.m4a` file (#43).
public final class MeetingAudioStreamMixer: @unchecked Sendable {
    public static let sampleRate: Double = 48_000
    public static let channelCount: AVAudioChannelCount = 2

    public static var canonicalPCMFormat: AVAudioFormat {
        AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: sampleRate,
            channels: channelCount,
            interleaved: false
        )!
    }

    public static var m4aSettings: [String: Any] {
        [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: sampleRate,
            AVNumberOfChannelsKey: Int(channelCount),
            AVEncoderBitRateKey: 128_000
        ]
    }

    private let lock = NSLock()
    private var audioFile: AVAudioFile?
    private var converters: [String: AVAudioConverter] = [:]
    private var secondaryLeftQueue: [Float] = []
    private var secondaryRightQueue: [Float] = []
    private let maxQueuedSamples = 48_000 * 2 // 2 seconds max ring buffer
    private let onWriteError: (@Sendable (String) -> Void)?
    private var hasReportedWriteError = false

    public init(outputFileURL: URL, onWriteError: (@Sendable (String) -> Void)? = nil) throws {
        self.onWriteError = onWriteError
        if FileManager.default.fileExists(atPath: outputFileURL.path) {
            try FileManager.default.removeItem(at: outputFileURL)
        }
        self.audioFile = try AVAudioFile(
            forWriting: outputFileURL,
            settings: Self.m4aSettings,
            commonFormat: .pcmFormatFloat32,
            interleaved: false
        )
    }

    /// Pure deterministic PCM mixer: sums two 48kHz stereo Float32 buffers with headroom gain and soft-clipping to `[-1.0, 1.0]`.
    public static func mixBuffers(
        primary: AVAudioPCMBuffer,
        secondary: AVAudioPCMBuffer?,
        headroomGain: Float = 0.85
    ) -> AVAudioPCMBuffer? {
        let format = canonicalPCMFormat
        let frameCount = primary.frameLength
        guard frameCount > 0,
              let outBuffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount),
              let outChannels = outBuffer.floatChannelData,
              let primaryChannels = primary.floatChannelData else {
            return nil
        }
        outBuffer.frameLength = frameCount

        let pChCount = Int(primary.format.channelCount)
        let sChannels = secondary?.floatChannelData
        let sFrameCount = Int(secondary?.frameLength ?? 0)
        let sChCount = Int(secondary?.format.channelCount ?? 0)

        for ch in 0..<Int(channelCount) {
            let pSrc = primaryChannels[min(ch, max(0, pChCount - 1))]
            let dst = outChannels[ch]
            if let sChannels, sFrameCount > 0, sChCount > 0 {
                let sSrc = sChannels[min(ch, sChCount - 1)]
                for i in 0..<Int(frameCount) {
                    let sSample: Float = i < sFrameCount ? sSrc[i] : 0.0
                    let sum = (pSrc[i] + sSample) * headroomGain
                    dst[i] = max(-1.0, min(1.0, sum))
                }
            } else {
                for i in 0..<Int(frameCount) {
                    dst[i] = max(-1.0, min(1.0, pSrc[i]))
                }
            }
        }
        return outBuffer
    }

    /// Converts an arbitrary `AVAudioPCMBuffer` into the canonical 48kHz 2-channel Float32 format.
    public func convertToCanonical(_ buffer: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        let targetFormat = Self.canonicalPCMFormat
        if buffer.format.sampleRate == targetFormat.sampleRate
            && buffer.format.channelCount == targetFormat.channelCount
            && buffer.format.commonFormat == .pcmFormatFloat32
            && !buffer.format.isInterleaved {
            return buffer
        }

        let ratio = targetFormat.sampleRate / max(1.0, buffer.format.sampleRate)
        let capacity = AVAudioFrameCount(ceil(Double(buffer.frameLength) * ratio)) + 32
        guard let outputBuffer = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: capacity) else {
            return nil
        }

        let key = "\(buffer.format.sampleRate)-\(buffer.format.channelCount)-\(buffer.format.commonFormat.rawValue)-\(buffer.format.isInterleaved)"
        let converter: AVAudioConverter
        if let cached = converters[key] {
            converter = cached
        } else if let created = AVAudioConverter(from: buffer.format, to: targetFormat) {
            // Voice-processed mic input is 4 discrete channels; the default map is [-1, -1] (silence). Ch 0 is the processed voice.
            if buffer.format.channelCount > 2 {
                created.channelMap = [0, 0]
            }
            converters[key] = created
            converter = created
        } else {
            return nil
        }

        final class InputBox: @unchecked Sendable {
            let buffer: AVAudioPCMBuffer
            var consumed = false
            init(_ buffer: AVAudioPCMBuffer) { self.buffer = buffer }
        }
        let box = InputBox(buffer)
        var error: NSError?
        converter.convert(to: outputBuffer, error: &error) { _, outStatus in
            if box.consumed {
                outStatus.pointee = .noDataNow
                return nil
            }
            box.consumed = true
            outStatus.pointee = .haveData
            return box.buffer
        }
        return outputBuffer.frameLength > 0 ? outputBuffer : nil
    }

    /// Queues secondary (system audio) samples when dual capture is active, or writes directly if microphone is disabled.
    public func appendSystemAudioBuffer(_ buffer: AVAudioPCMBuffer, mixWithMic: Bool) {
        lock.lock()
        defer { lock.unlock() }
        guard audioFile != nil, let canonical = convertToCanonical(buffer),
              let channels = canonical.floatChannelData else { return }

        if !mixWithMic {
            write(canonical)
            return
        }

        let frames = Int(canonical.frameLength)
        guard frames > 0 else { return }
        let left = UnsafeBufferPointer(start: channels[0], count: frames)
        let right = UnsafeBufferPointer(start: channels[1], count: frames)
        secondaryLeftQueue.append(contentsOf: left)
        secondaryRightQueue.append(contentsOf: right)

        // Mic buffers stopped arriving (device change, engine stop): write the backlog unmixed instead of dropping it
        if secondaryLeftQueue.count > maxQueuedSamples,
           let overflow = dequeueSecondary(frameCount: secondaryLeftQueue.count - maxQueuedSamples) {
            write(overflow)
        }
    }

    /// Writes primary (microphone) samples, mixing in any queued secondary (system audio) samples without phase/interleaving drift.
    public func appendMicrophoneBuffer(_ buffer: AVAudioPCMBuffer) {
        lock.lock()
        defer { lock.unlock() }
        guard audioFile != nil, let canonical = convertToCanonical(buffer) else { return }

        let frames = Int(canonical.frameLength)
        guard frames > 0 else { return }

        if let secondary = dequeueSecondary(frameCount: min(frames, secondaryLeftQueue.count)) {
            guard let mixed = Self.mixBuffers(primary: canonical, secondary: secondary) else { return }
            write(mixed)
        } else {
            write(canonical)
        }
    }

    /// Writes queued system audio unmixed, so a backlog from a mic gap is never mixed against fresh mic audio.
    public func flushSecondary() {
        lock.lock()
        defer { lock.unlock() }
        flushSecondaryLocked()
    }

    private func flushSecondaryLocked() {
        if let backlog = dequeueSecondary(frameCount: secondaryLeftQueue.count) {
            write(backlog)
        }
    }

    /// Pops `frameCount` queued system-audio frames into a canonical buffer. Caller holds `lock`.
    private func dequeueSecondary(frameCount: Int) -> AVAudioPCMBuffer? {
        guard frameCount > 0,
              let buffer = AVAudioPCMBuffer(pcmFormat: Self.canonicalPCMFormat, frameCapacity: AVAudioFrameCount(frameCount)),
              let channels = buffer.floatChannelData else { return nil }
        buffer.frameLength = AVAudioFrameCount(frameCount)
        for i in 0..<frameCount {
            channels[0][i] = secondaryLeftQueue[i]
            channels[1][i] = secondaryRightQueue[i]
        }
        secondaryLeftQueue.removeFirst(frameCount)
        secondaryRightQueue.removeFirst(frameCount)
        return buffer
    }

    /// Writes to the file and reports the first failure once, so a full disk is not silent. Caller holds `lock`.
    private func write(_ buffer: AVAudioPCMBuffer) {
        do {
            try audioFile?.write(from: buffer)
        } catch {
            guard !hasReportedWriteError else { return }
            hasReportedWriteError = true
            onWriteError?("Could not write meeting audio: \(error.localizedDescription)")
        }
    }

    public func close() {
        lock.lock()
        defer { lock.unlock() }
        // Keep the system audio the mic had not consumed yet
        flushSecondaryLocked()
        audioFile = nil
        converters.removeAll()
        secondaryLeftQueue.removeAll()
        secondaryRightQueue.removeAll()
    }
}

// MARK: - Audio Capture Engine Protocol & Production Implementation

public enum MeetingRecorderError: Error, LocalizedError, Equatable, Sendable {
    case noAudioSourcesEnabled
    case permissionDenied(String)
    case captureStartFailed(String)

    public var errorDescription: String? {
        switch self {
        case .noAudioSourcesEnabled:
            return "Enable at least Microphone or System Audio before recording."
        case .permissionDenied(let detail):
            return detail
        case .captureStartFailed(let reason):
            return "Could not start audio capture: \(reason)"
        }
    }
}

public protocol MeetingAudioCapturing: AnyObject, Sendable {
    /// Called from any thread when live capture breaks mid-recording (device change, stream stop, write failure).
    var onCaptureInterrupted: (@Sendable (String) -> Void)? { get set }
    func startCapture(
        outputFileURL: URL,
        captureMicrophone: Bool,
        captureSystemAudio: Bool
    ) async throws
    func stopCapture() async
}

/// Captures live Microphone (`AVAudioEngine`) and System / Meeting Output (`ScreenCaptureKit` `SCStream`) into `audio.m4a` (#43).
public final class ProductionMeetingAudioCaptureEngine: NSObject, MeetingAudioCapturing, SCStreamOutput, SCStreamDelegate, @unchecked Sendable {
    private let lock = NSLock()
    private var audioEngine: AVAudioEngine?
    private var scStream: SCStream?
    private var mixer: MeetingAudioStreamMixer?
    private var isCapturingMic: Bool = false
    private var configurationObserver: NSObjectProtocol?
    private var interruptionHandler: (@Sendable (String) -> Void)?
    private let sampleQueue = DispatchQueue(label: "com.bitz.meetingrecorder.audio", qos: .userInitiated)
    /// Serializes device-change restarts with teardown, so a restart can never revive a stopped engine.
    private let micQueue = DispatchQueue(label: "com.bitz.meetingrecorder.mic", qos: .userInitiated)

    public var onCaptureInterrupted: (@Sendable (String) -> Void)? {
        get { lock.withLock { interruptionHandler } }
        set { lock.withLock { interruptionHandler = newValue } }
    }

    public override init() {
        super.init()
    }

    public func startCapture(
        outputFileURL: URL,
        captureMicrophone: Bool,
        captureSystemAudio: Bool
    ) async throws {
        guard captureMicrophone || captureSystemAudio else {
            throw MeetingRecorderError.noAudioSourcesEnabled
        }

        let streamMixer = try MeetingAudioStreamMixer(outputFileURL: outputFileURL) { [weak self] message in
            self?.onCaptureInterrupted?(message)
        }
        lock.withLock {
            self.mixer = streamMixer
            self.isCapturingMic = captureMicrophone
        }

        do {
            if captureSystemAudio {
                let shareable = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
                guard let display = shareable.displays.first else {
                    throw MeetingRecorderError.captureStartFailed("No active display found for system audio capture.")
                }

                let filter = SCContentFilter(display: display, excludingWindows: [])
                let config = SCStreamConfiguration()
                config.capturesAudio = true
                config.excludesCurrentProcessAudio = true
                config.sampleRate = Int(MeetingAudioStreamMixer.sampleRate)
                config.channelCount = Int(MeetingAudioStreamMixer.channelCount)
                // Minimal 2×2 video dimensions since we only attach an `.audio` SCStreamOutput
                config.width = 2
                config.height = 2
                config.minimumFrameInterval = CMTime(value: 1, timescale: 1)

                let stream = SCStream(filter: filter, configuration: config, delegate: self)
                try stream.addStreamOutput(self, type: .audio, sampleHandlerQueue: sampleQueue)
                try await stream.startCapture()

                lock.withLock {
                    self.scStream = stream
                }
            }

            if captureMicrophone {
                let engine = AVAudioEngine()
                lock.withLock {
                    self.audioEngine = engine
                }
                try startMicrophone(on: engine)

                let observer = NotificationCenter.default.addObserver(
                    forName: .AVAudioEngineConfigurationChange,
                    object: engine,
                    queue: nil
                ) { [weak self] notification in
                    guard let self, let engine = notification.object as? AVAudioEngine else { return }
                    // Off AVAudioEngine's posting thread, serialized with teardown
                    self.micQueue.async { self.restartMicrophone(engine) }
                }

                lock.withLock {
                    self.configurationObserver = observer
                }
            }
        } catch {
            await stopCapture()
            throw MeetingRecorderError.captureStartFailed(error.localizedDescription)
        }
    }

    public func stopCapture() async {
        let (engine, stream, activeMixer, observer) = lock.withLock {
            () -> (AVAudioEngine?, SCStream?, MeetingAudioStreamMixer?, NSObjectProtocol?) in
            let current = (self.audioEngine, self.scStream, self.mixer, self.configurationObserver)
            self.audioEngine = nil
            self.scStream = nil
            self.mixer = nil
            self.configurationObserver = nil
            return current
        }

        if let observer {
            NotificationCenter.default.removeObserver(observer)
        }
        if let engine {
            // Waits for an in-flight restart on `micQueue`, then stops whatever it started
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                micQueue.async {
                    engine.inputNode.removeTap(onBus: 0)
                    engine.stop()
                    continuation.resume()
                }
            }
        }
        if let stream {
            try? await stream.stopCapture()
        }
        activeMixer?.close()
    }

    private func startMicrophone(on engine: AVAudioEngine) throws {
        let inputNode = engine.inputNode
        // Echo cancellation so speaker output is not re-recorded by the mic; also re-applied on device-change restarts
        do {
            try inputNode.setVoiceProcessingEnabled(true)
            // `.min` is the lowest ducking level, not none: other audio is still lowered slightly while recording
            inputNode.voiceProcessingOtherAudioDuckingConfiguration = AVAudioVoiceProcessingOtherAudioDuckingConfiguration(
                enableAdvancedDucking: false,
                duckingLevel: .min
            )
        } catch {
            NSLog("Bitz meeting recorder: voice processing unavailable, recording without it: \(error.localizedDescription)")
        }

        do {
            try installTapAndStart(engine)
        } catch where inputNode.isVoiceProcessingEnabled {
            // Voice processing enabled but the engine would not start with it: retry once without it
            NSLog("Bitz meeting recorder: start failed with voice processing, retrying without it: \(error.localizedDescription)")
            inputNode.removeTap(onBus: 0)
            engine.stop()
            try inputNode.setVoiceProcessingEnabled(false)
            try installTapAndStart(engine)
        }
    }

    private func installTapAndStart(_ engine: AVAudioEngine) throws {
        let inputNode = engine.inputNode
        // Read after toggling voice processing, which changes the input sample rate and channel count
        let inputFormat = inputNode.outputFormat(forBus: 0)
        guard inputFormat.sampleRate > 0 && inputFormat.channelCount > 0 else {
            throw MeetingRecorderError.captureStartFailed("No valid microphone input format available.")
        }

        inputNode.installTap(onBus: 0, bufferSize: 4096, format: inputFormat) { [weak self] buffer, _ in
            guard let self else { return }
            let activeMixer = self.lock.withLock { self.mixer }
            activeMixer?.appendMicrophoneBuffer(buffer)
        }

        engine.prepare()
        guard lock.withLock({ self.audioEngine === engine }) else {
            throw MeetingRecorderError.captureStartFailed("Capture was stopped.")
        }
        try engine.start()
    }

    /// The input device changed (AirPods, unplugged mic): the engine has stopped, so rebuild the tap with the new format.
    /// Runs on `micQueue`.
    private func restartMicrophone(_ engine: AVAudioEngine) {
        let (isCurrent, activeMixer) = lock.withLock { (self.audioEngine === engine, self.mixer) }
        guard isCurrent else { return }
        // System audio queued during the gap is written unmixed, so it is not mixed later against fresh mic audio
        activeMixer?.flushSecondary()
        engine.inputNode.removeTap(onBus: 0)
        do {
            try startMicrophone(on: engine)
        } catch {
            onCaptureInterrupted?("Microphone stopped after an audio device change: \(error.localizedDescription)")
        }
    }

    public func stream(_ stream: SCStream, didStopWithError error: Error) {
        guard lock.withLock({ self.scStream === stream }) else { return }
        onCaptureInterrupted?("System audio capture stopped: \(error.localizedDescription)")
    }

    public func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of outputType: SCStreamOutputType) {
        guard outputType == .audio, CMSampleBufferDataIsReady(sampleBuffer) else { return }
        guard let pcmBuffer = Self.makePCMBuffer(from: sampleBuffer) else { return }

        let (activeMixer, mixWithMic) = lock.withLock { (self.mixer, self.isCapturingMic) }
        activeMixer?.appendSystemAudioBuffer(pcmBuffer, mixWithMic: mixWithMic)
    }

    public static func makePCMBuffer(from sampleBuffer: CMSampleBuffer) -> AVAudioPCMBuffer? {
        guard let formatDesc = CMSampleBufferGetFormatDescription(sampleBuffer),
              let asbdPtr = CMAudioFormatDescriptionGetStreamBasicDescription(formatDesc),
              let audioFormat = AVAudioFormat(streamDescription: asbdPtr) else {
            return nil
        }

        let frameCount = AVAudioFrameCount(CMSampleBufferGetNumSamples(sampleBuffer))
        guard frameCount > 0,
              let pcmBuffer = AVAudioPCMBuffer(pcmFormat: audioFormat, frameCapacity: frameCount) else {
            return nil
        }
        pcmBuffer.frameLength = frameCount

        let status = CMSampleBufferCopyPCMDataIntoAudioBufferList(
            sampleBuffer,
            at: 0,
            frameCount: Int32(frameCount),
            into: pcmBuffer.mutableAudioBufferList
        )
        return status == noErr ? pcmBuffer : nil
    }
}

// MARK: - Isolated Elapsed Timer Store (Leaf View Observation, AGENTS.md §2.5)

/// Publishes the 1-second elapsed timer exclusively to leaf subviews (`MeetingRecordingTimerBubbleView`)
/// so `MascotOverlayView` and `SpeechBubbleView` roots never re-evaluate on every elapsed second (#43, #70).
@MainActor
public final class MeetingRecordingTimerStore: ObservableObject {
    @Published public fileprivate(set) var elapsedSeconds: Int = 0

    public init() {}
}

// MARK: - Meeting Recorder Coordinator Service

/// Coordinates dual-stream meeting audio recording (`audio.m4a`), metadata export (`metadata.json`),
/// native on-device transcription (`transcript.txt` & `transcript.json`), and Finder reveal (#43).
@MainActor
public final class MeetingRecorderService: ObservableObject {
    @Published public private(set) var state: MeetingRecorderState = .idle
    @Published public private(set) var isRecording: Bool = false
    @Published public private(set) var isTranscribing: Bool = false
    @Published public private(set) var permissionState: MeetingPermissionState
    @Published public private(set) var lastCompletedResult: MeetingRecordingResult?
    @Published public private(set) var isCompletionBubbleVisible: Bool = false
    @Published public private(set) var statusMessage: String = "Ready to record meetings locally (100% on-device)."

    public let timerStore = MeetingRecordingTimerStore()
    public let settingsStore: MeetingSettingsStore
    private let captureEngine: any MeetingAudioCapturing
    private let transcriptionService: any MeetingTranscriptionProviding
    private let permissionChecker: any MeetingPermissionChecking
    private let onRevealURL: (URL) -> Void
    private let nowProvider: () -> Date

    /// Optional sound callback so Bitz chimes when recording starts/completes.
    public var onPlaySound: ((CyberSoundEvent) -> Void)?

    private var elapsedTimerTask: Task<Void, Never>?
    private var activeSessionID: String?
    private var activeSessionDirectoryURL: URL?
    private var activeAudioFileURL: URL?
    private var activeStartedAt: Date?
    private var activeDetectedApps: [String] = []
    private var activeCaptureWarning: String?
    /// Synchronous guards set before the first `await`, so a double toggle can never start or stop twice.
    private var isStarting = false
    private var isStopping = false
    private var failureDismissTask: Task<Void, Never>?
    private var transcribingMetadata: (metadata: MeetingRecordingMetadata, url: URL)?
    var failureBubbleDurationNanoseconds: UInt64 = 6_000_000_000

    private static let knownMeetingAppNames: Set<String> = [
        "zoom.us", "Zoom", "Microsoft Teams", "Slack", "FaceTime", "Discord",
        "Webex", "Around", "Tuple", "Google Chrome", "Arc", "Brave Browser", "Safari", "Firefox"
    ]

    public init(
        settingsStore: MeetingSettingsStore = MeetingSettingsStore(),
        captureEngine: (any MeetingAudioCapturing)? = nil,
        transcriptionService: (any MeetingTranscriptionProviding)? = nil,
        permissionChecker: (any MeetingPermissionChecking)? = nil,
        nowProvider: @escaping () -> Date = { Date() },
        onRevealURL: @escaping (URL) -> Void = { url in
            NSWorkspace.shared.activateFileViewerSelecting([url])
        }
    ) {
        self.settingsStore = settingsStore
        self.captureEngine = captureEngine ?? ProductionMeetingAudioCaptureEngine()
        self.transcriptionService = transcriptionService ?? SpeechFrameworkTranscriptionService()
        let resolvedPermissionChecker = permissionChecker ?? SystemMeetingPermissionChecker()
        self.permissionChecker = resolvedPermissionChecker
        self.permissionState = resolvedPermissionChecker.currentPermissions()
        self.nowProvider = nowProvider
        self.onRevealURL = onRevealURL
        self.captureEngine.onCaptureInterrupted = { [weak self] message in
            Task { @MainActor in self?.handleCaptureInterruption(message) }
        }
    }

    deinit {
        elapsedTimerTask?.cancel()
        failureDismissTask?.cancel()
    }

    /// True while capture is live or still being finalized, so quitting must wait for `finalizeForTermination()`.
    public var hasUnfinalizedRecording: Bool {
        isRecording || isStarting || isStopping
    }

    // MARK: - Derived UI State

    /// Whether the speech bubble currently shows an interactive Meeting Recorder action ("OPEN IN FINDER" / "DISMISS").
    public var isInteractiveBubbleActive: Bool {
        if case .completed = state, isCompletionBubbleVisible {
            return true
        }
        return false
    }

    /// Ambient speech bubble text displayed while recording, transcribing, or showing completion status.
    public var activeSpeechBubbleText: String? {
        switch state {
        case .idle:
            return nil
        case .recording:
            return "🔴 Recording meeting (\(MeetingSettingsStore.formatDuration(timerStore.elapsedSeconds)))..."
        case .transcribing:
            return "✨ Meeting saved! Transcribing audio..."
        case .completed(let result):
            guard isCompletionBubbleVisible else { return nil }
            return result.bubbleHeadline
        case .failed(let message):
            guard isCompletionBubbleVisible else { return nil }
            return "⚠️ \(message)"
        }
    }

    public func refreshPermissions() {
        permissionState = permissionChecker.currentPermissions()
    }

    @discardableResult
    public func requestPermissions() async -> MeetingPermissionState {
        let updated = await permissionChecker.requestPermissions(
            captureMicrophone: settingsStore.captureMicrophone,
            captureSystemAudio: settingsStore.captureSystemAudio,
            transcribe: settingsStore.autoTranscribeOnStop
        )
        permissionState = updated
        return updated
    }

    // MARK: - Recording Lifecycle

    public func toggleRecording() async {
        if isRecording {
            await stopRecording()
        } else {
            await startRecording()
        }
    }

    public func startRecording() async {
        guard !isRecording && !isTranscribing && !isStarting && !isStopping else { return }
        isStarting = true
        defer { isStarting = false }

        let captureMic = settingsStore.captureMicrophone
        let captureSys = settingsStore.captureSystemAudio
        guard captureMic || captureSys else {
            showFailure(MeetingRecorderError.noAudioSourcesEnabled.localizedDescription)
            return
        }

        let perms = await requestPermissions()
        guard perms.canRecord(captureMicrophone: captureMic, captureSystemAudio: captureSys) else {
            var missing: [String] = []
            if captureMic && perms.microphone != .authorized {
                missing.append("Microphone")
            }
            if captureSys && perms.screenAudio != .authorized {
                missing.append("Screen & System Audio Recording")
            }
            var msg = "Permission needed for \(missing.joined(separator: " & ")) in System Settings → Privacy & Security."
            if captureSys && perms.screenAudio != .authorized {
                msg += " Relaunch Bitz after granting Screen & System Audio Recording."
            }
            showFailure(msg)
            return
        }

        let startDate = nowProvider()
        let sessionID = MeetingSettingsStore.sessionFolderName(for: startDate)
        let sessionDir = settingsStore.meetingsRootDirectoryURL.appendingPathComponent(sessionID, isDirectory: true)
        let audioURL = sessionDir.appendingPathComponent("audio.m4a")
        let sessionDirExisted = FileManager.default.fileExists(atPath: sessionDir.path)

        do {
            try FileManager.default.createDirectory(at: sessionDir, withIntermediateDirectories: true)
            try await captureEngine.startCapture(
                outputFileURL: audioURL,
                captureMicrophone: captureMic,
                captureSystemAudio: captureSys
            )

            activeSessionID = sessionID
            activeSessionDirectoryURL = sessionDir
            activeAudioFileURL = audioURL
            activeStartedAt = startDate
            activeDetectedApps = Self.detectRunningMeetingApps()
            activeCaptureWarning = nil
            failureDismissTask?.cancel()
            timerStore.elapsedSeconds = 0
            isCompletionBubbleVisible = false
            isRecording = true
            state = .recording(sessionID: sessionID, startedAt: startDate, elapsedSeconds: 0)
            statusMessage = "Recording meeting into \(sessionDir.lastPathComponent)..."
            startElapsedTimer()
        } catch {
            if !sessionDirExisted {
                try? FileManager.default.removeItem(at: sessionDir)
            }
            showFailure(error.localizedDescription)
        }
    }

    /// Stops and finalizes `audio.m4a` + `metadata.json`. `transcribe: false` is the fast quit path.
    public func stopRecording(transcribe: Bool = true) async {
        guard isRecording, !isStopping,
              let sessionID = activeSessionID,
              let sessionDir = activeSessionDirectoryURL,
              let audioURL = activeAudioFileURL,
              let startedAt = activeStartedAt else {
            return
        }

        isStopping = true
        stopElapsedTimer()
        isRecording = false
        await captureEngine.stopCapture()

        let endedAt = nowProvider()
        let duration = max(0, endedAt.timeIntervalSince(startedAt))
        let metadataURL = sessionDir.appendingPathComponent("metadata.json")
        let shouldTranscribe = transcribe && settingsStore.autoTranscribeOnStop && permissionState.canTranscribe
        var warnings = [activeCaptureWarning].compactMap { $0 }

        var metadata = MeetingRecordingMetadata(
            sessionID: sessionID,
            startedAt: startedAt,
            endedAt: endedAt,
            durationSeconds: duration,
            captureMicrophone: settingsStore.captureMicrophone,
            captureSystemAudio: settingsStore.captureSystemAudio,
            detectedAppNames: activeDetectedApps,
            audioFileName: "audio.m4a",
            transcriptStatus: shouldTranscribe ? "pending" : "skipped"
        )
        Self.writeMetadata(metadata, to: metadataURL)
        // Audio and metadata are final; transcription below never blocks quit or a new start's guard
        isStopping = false

        onPlaySound?(.charging)

        var txtURL: URL?
        var jsonURL: URL?

        if shouldTranscribe {
            isTranscribing = true
            state = .transcribing(sessionID: sessionID, sessionDirectoryURL: sessionDir)
            statusMessage = "✨ Meeting saved! Transcribing audio on-device..."

            transcribingMetadata = (metadata, metadataURL)
            defer { transcribingMetadata = nil }
            do {
                let transcript = try await transcriptionService.transcribe(
                    audioFileURL: audioURL,
                    sessionID: sessionID,
                    locale: .current
                )
                let written = try MeetingTranscriptWriter.write(transcript, to: sessionDir)
                txtURL = written.txtURL
                jsonURL = written.jsonURL
                metadata.transcriptStatus = "completed"
                Self.writeMetadata(metadata, to: metadataURL)

                if settingsStore.copyTranscriptPathToClipboard {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(written.txtURL.path, forType: .string)
                }
            } catch {
                metadata.transcriptStatus = "failed"
                Self.writeMetadata(metadata, to: metadataURL)
                warnings.append("Transcript not saved: \(error.localizedDescription)")
            }
            isTranscribing = false
        }

        let result = MeetingRecordingResult(
            sessionID: sessionID,
            sessionDirectoryURL: sessionDir,
            audioFileURL: audioURL,
            metadataFileURL: metadataURL,
            transcriptTextURL: txtURL,
            transcriptJSONURL: jsonURL,
            durationSeconds: duration,
            warning: warnings.isEmpty ? nil : warnings.joined(separator: " ")
        )
        lastCompletedResult = result
        state = .completed(result)
        isCompletionBubbleVisible = true
        statusMessage = txtURL != nil
            ? "Saved audio.m4a & on-device transcript to \(sessionDir.lastPathComponent)."
            : "Saved audio.m4a to \(sessionDir.lastPathComponent)."
        if let warning = result.warning {
            statusMessage += " ⚠️ \(warning)"
        }
        onPlaySound?(.allAgentsDone)

        activeSessionID = nil
        activeSessionDirectoryURL = nil
        activeAudioFileURL = nil
        activeStartedAt = nil
        activeDetectedApps = []
        activeCaptureWarning = nil
    }

    /// Quit path: waits for an in-flight start/stop, then finalizes audio + metadata without transcribing.
    public func finalizeForTermination() async {
        while isStarting || isStopping {
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
        await stopRecording(transcribe: false)
    }

    public func revealInFinder(_ targetURL: URL? = nil) {
        let url = targetURL
            ?? lastCompletedResult?.sessionDirectoryURL
            ?? settingsStore.meetingsRootDirectoryURL
        try? FileManager.default.createDirectory(
            at: settingsStore.meetingsRootDirectoryURL,
            withIntermediateDirectories: true
        )
        onRevealURL(url)
        isCompletionBubbleVisible = false
    }

    public func dismissCompletionBubble() {
        isCompletionBubbleVisible = false
        if case .failed = state {
            state = .idle
        }
    }

    /// Quit path while transcribing: synchronously replaces the "pending" status so metadata never stays stale.
    public func markTranscriptionInterrupted() {
        guard var pending = transcribingMetadata else { return }
        pending.metadata.transcriptStatus = "interrupted"
        Self.writeMetadata(pending.metadata, to: pending.url)
    }

    // MARK: - Internal Helpers

    func handleCaptureInterruption(_ message: String) {
        guard isRecording else { return }
        activeCaptureWarning = message
        statusMessage = "⚠️ \(message)"
    }

    /// Failure bubbles have no buttons, so they dismiss themselves (one-shot, nothing runs while idle).
    private func showFailure(_ message: String) {
        state = .failed(message)
        statusMessage = message
        isCompletionBubbleVisible = true
        failureDismissTask?.cancel()
        failureDismissTask = Task { @MainActor [weak self, failureBubbleDurationNanoseconds] in
            try? await Task.sleep(nanoseconds: failureBubbleDurationNanoseconds)
            guard !Task.isCancelled, let self, case .failed = self.state else { return }
            self.dismissCompletionBubble()
        }
    }

    private func startElapsedTimer() {
        stopElapsedTimer()
        elapsedTimerTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                guard !Task.isCancelled, let self, self.isRecording,
                      let startedAt = self.activeStartedAt else {
                    break
                }
                let elapsed = max(0, Int(self.nowProvider().timeIntervalSince(startedAt).rounded(.down)))
                if self.timerStore.elapsedSeconds != elapsed {
                    self.timerStore.elapsedSeconds = elapsed
                }
            }
        }
    }

    private func stopElapsedTimer() {
        elapsedTimerTask?.cancel()
        elapsedTimerTask = nil
    }

    private static func writeMetadata(_ metadata: MeetingRecordingMetadata, to url: URL) {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        if let data = try? encoder.encode(metadata) {
            try? data.write(to: url, options: .atomic)
        }
    }

    private static func detectRunningMeetingApps() -> [String] {
        let names = NSWorkspace.shared.runningApplications.compactMap(\.localizedName)
        return Array(Set(names.filter { knownMeetingAppNames.contains($0) })).sorted()
    }
}
