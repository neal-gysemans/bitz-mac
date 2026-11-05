@preconcurrency import AVFoundation
import CoreMedia
import Foundation
@preconcurrency import ScreenCaptureKit

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

    /// Plain tap at the input's native format. No voice processing: its other-audio ducking cut captured system audio by ~40 dB.
    private func startMicrophone(on engine: AVAudioEngine) throws {
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
        guard lock.withLock({ self.audioEngine === engine }) else {
            throw MeetingRecorderError.captureStartFailed("Capture was stopped.")
        }
        try engine.start()
        // System audio queued while the mic was starting (first start or restart) is written unmixed;
        // left in the queue it would offset every later mic buffer for the rest of the recording
        lock.withLock { self.mixer }?.flushSecondary()
    }

    /// The input device changed (AirPods, unplugged mic): the engine has stopped, so rebuild the tap with the new format.
    /// Runs on `micQueue`.
    private func restartMicrophone(_ engine: AVAudioEngine) {
        guard lock.withLock({ self.audioEngine === engine }) else { return }
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
