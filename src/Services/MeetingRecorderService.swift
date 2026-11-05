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

        let screenStatus: MeetingPermissionState.Status = CGPreflightScreenCaptureAccess() ? .authorized : .notDetermined

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

    public init(outputFileURL: URL) throws {
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
            try? audioFile?.write(from: canonical)
            return
        }

        let frames = Int(canonical.frameLength)
        guard frames > 0 else { return }
        let left = UnsafeBufferPointer(start: channels[0], count: frames)
        let right = UnsafeBufferPointer(start: channels[1], count: frames)
        secondaryLeftQueue.append(contentsOf: left)
        secondaryRightQueue.append(contentsOf: right)

        if secondaryLeftQueue.count > maxQueuedSamples {
            let overflow = secondaryLeftQueue.count - maxQueuedSamples
            secondaryLeftQueue.removeFirst(overflow)
            secondaryRightQueue.removeFirst(overflow)
        }
    }

    /// Writes primary (microphone) samples, mixing in any queued secondary (system audio) samples without phase/interleaving drift.
    public func appendMicrophoneBuffer(_ buffer: AVAudioPCMBuffer) {
        lock.lock()
        defer { lock.unlock() }
        guard let audioFile, let canonical = convertToCanonical(buffer),
              let pChannels = canonical.floatChannelData else { return }

        let frames = Int(canonical.frameLength)
        guard frames > 0 else { return }

        if !secondaryLeftQueue.isEmpty {
            let popCount = min(frames, secondaryLeftQueue.count)
            guard let mixed = AVAudioPCMBuffer(pcmFormat: Self.canonicalPCMFormat, frameCapacity: canonical.frameLength),
                  let mChannels = mixed.floatChannelData else { return }
            mixed.frameLength = canonical.frameLength

            for i in 0..<frames {
                let sL: Float = i < popCount ? secondaryLeftQueue[i] : 0.0
                let sR: Float = i < popCount ? secondaryRightQueue[i] : 0.0
                mChannels[0][i] = max(-1.0, min(1.0, (pChannels[0][i] + sL) * 0.85))
                mChannels[1][i] = max(-1.0, min(1.0, (pChannels[1][i] + sR) * 0.85))
            }
            secondaryLeftQueue.removeFirst(popCount)
            secondaryRightQueue.removeFirst(popCount)
            try? audioFile.write(from: mixed)
        } else {
            try? audioFile.write(from: canonical)
        }
    }

    public func close() {
        lock.lock()
        defer { lock.unlock() }
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
    func startCapture(
        outputFileURL: URL,
        captureMicrophone: Bool,
        captureSystemAudio: Bool
    ) async throws
    func stopCapture() async
}

/// Captures live Microphone (`AVAudioEngine`) and System / Meeting Output (`ScreenCaptureKit` `SCStream`) into `audio.m4a` (#43).
public final class ProductionMeetingAudioCaptureEngine: NSObject, MeetingAudioCapturing, SCStreamOutput, @unchecked Sendable {
    private let lock = NSLock()
    private var audioEngine: AVAudioEngine?
    private var scStream: SCStream?
    private var mixer: MeetingAudioStreamMixer?
    private var isCapturingMic: Bool = false
    private let sampleQueue = DispatchQueue(label: "com.bitz.meetingrecorder.audio", qos: .userInitiated)

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

        let streamMixer = try MeetingAudioStreamMixer(outputFileURL: outputFileURL)
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

                let stream = SCStream(filter: filter, configuration: config, delegate: nil)
                try stream.addStreamOutput(self, type: .audio, sampleHandlerQueue: sampleQueue)
                try await stream.startCapture()

                lock.withLock {
                    self.scStream = stream
                }
            }

            if captureMicrophone {
                let engine = AVAudioEngine()
                let inputNode = engine.inputNode
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
                try engine.start()

                lock.withLock {
                    self.audioEngine = engine
                }
            }
        } catch {
            await stopCapture()
            throw MeetingRecorderError.captureStartFailed(error.localizedDescription)
        }
    }

    public func stopCapture() async {
        let (engine, stream, activeMixer) = lock.withLock { () -> (AVAudioEngine?, SCStream?, MeetingAudioStreamMixer?) in
            let current = (self.audioEngine, self.scStream, self.mixer)
            self.audioEngine = nil
            self.scStream = nil
            self.mixer = nil
            return current
        }

        if let engine {
            engine.inputNode.removeTap(onBus: 0)
            engine.stop()
        }
        if let stream {
            try? await stream.stopCapture()
        }
        activeMixer?.close()
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
    }

    deinit {
        elapsedTimerTask?.cancel()
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
        case .completed:
            guard isCompletionBubbleVisible else { return nil }
            return "✨ Meeting saved & transcribed!"
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
        guard !isRecording && !isTranscribing else { return }

        let captureMic = settingsStore.captureMicrophone
        let captureSys = settingsStore.captureSystemAudio
        guard captureMic || captureSys else {
            let msg = MeetingRecorderError.noAudioSourcesEnabled.localizedDescription
            state = .failed(msg)
            statusMessage = msg
            isCompletionBubbleVisible = true
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
            let msg = "Permission needed for \(missing.joined(separator: " & ")) in System Settings → Privacy & Security."
            state = .failed(msg)
            statusMessage = msg
            isCompletionBubbleVisible = true
            return
        }

        let startDate = nowProvider()
        let sessionID = MeetingSettingsStore.sessionFolderName(for: startDate)
        let sessionDir = settingsStore.meetingsRootDirectoryURL.appendingPathComponent(sessionID, isDirectory: true)
        let audioURL = sessionDir.appendingPathComponent("audio.m4a")

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
            timerStore.elapsedSeconds = 0
            isCompletionBubbleVisible = false
            isRecording = true
            state = .recording(sessionID: sessionID, startedAt: startDate, elapsedSeconds: 0)
            statusMessage = "Recording meeting into \(sessionDir.lastPathComponent)..."
            startElapsedTimer()
        } catch {
            let msg = error.localizedDescription
            state = .failed(msg)
            statusMessage = msg
            isCompletionBubbleVisible = true
        }
    }

    public func stopRecording() async {
        guard isRecording,
              let sessionID = activeSessionID,
              let sessionDir = activeSessionDirectoryURL,
              let audioURL = activeAudioFileURL,
              let startedAt = activeStartedAt else {
            return
        }

        stopElapsedTimer()
        isRecording = false
        await captureEngine.stopCapture()

        let endedAt = nowProvider()
        let duration = max(0, endedAt.timeIntervalSince(startedAt))
        let metadataURL = sessionDir.appendingPathComponent("metadata.json")
        let shouldTranscribe = settingsStore.autoTranscribeOnStop && permissionState.canTranscribe

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

        onPlaySound?(.charging)

        var txtURL: URL?
        var jsonURL: URL?

        if shouldTranscribe {
            isTranscribing = true
            state = .transcribing(sessionID: sessionID, sessionDirectoryURL: sessionDir)
            statusMessage = "✨ Meeting saved! Transcribing audio on-device..."

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
            durationSeconds: duration
        )
        lastCompletedResult = result
        state = .completed(result)
        isCompletionBubbleVisible = true
        statusMessage = txtURL != nil
            ? "Saved audio.m4a & on-device transcript to \(sessionDir.lastPathComponent)."
            : "Saved audio.m4a to \(sessionDir.lastPathComponent)."
        onPlaySound?(.allAgentsDone)

        activeSessionID = nil
        activeSessionDirectoryURL = nil
        activeAudioFileURL = nil
        activeStartedAt = nil
        activeDetectedApps = []
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

    // MARK: - Internal Helpers

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
