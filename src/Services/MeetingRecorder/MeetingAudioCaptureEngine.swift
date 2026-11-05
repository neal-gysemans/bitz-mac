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
    /// Writes `mic.caf` and/or `system.caf` (`MeetingTrackWriter`) into `sessionDirectoryURL`.
    func startCapture(
        sessionDirectoryURL: URL,
        captureMicrophone: Bool,
        captureSystemAudio: Bool
    ) async throws
    func stopCapture() async
}

/// The `AVAudioNode` tap API, as a seam so tests can assert the tap's format argument (D2).
protocol MeetingAudioTapInstalling: AnyObject {
    func installTap(onBus bus: AVAudioNodeBus, bufferSize: AVAudioFrameCount, format: AVAudioFormat?, block: @escaping AVAudioNodeTapBlock)
}

extension AVAudioNode: MeetingAudioTapInstalling {}

/// Captures live Microphone (`AVAudioEngine`) into `mic.caf` and System / Meeting Output (`ScreenCaptureKit` `SCStream`)
/// into `system.caf`, each placed by host time (#43).
public final class ProductionMeetingAudioCaptureEngine: NSObject, MeetingAudioCapturing, SCStreamOutput, SCStreamDelegate, @unchecked Sendable {
    private let lock = NSLock()
    private var audioEngine: AVAudioEngine?
    private var scStream: SCStream?
    private var micWriter: MeetingTrackWriter?
    private var systemWriter: MeetingTrackWriter?
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
        sessionDirectoryURL: URL,
        captureMicrophone: Bool,
        captureSystemAudio: Bool
    ) async throws {
        guard captureMicrophone || captureSystemAudio else {
            throw MeetingRecorderError.noAudioSourcesEnabled
        }

        // Shared origin of both tracks' timelines
        let sessionStart = MeetingTrackWriter.hostSecondsNow()
        let onWriteError: @Sendable (String) -> Void = { [weak self] message in
            self?.onCaptureInterrupted?(message)
        }

        do {
            let mic = try captureMicrophone ? MeetingTrackWriter(
                fileURL: sessionDirectoryURL.appendingPathComponent(MeetingTrackWriter.micFileName),
                sessionStartHostSeconds: sessionStart,
                onWriteError: onWriteError
            ) : nil
            let system = try captureSystemAudio ? MeetingTrackWriter(
                fileURL: sessionDirectoryURL.appendingPathComponent(MeetingTrackWriter.systemFileName),
                sessionStartHostSeconds: sessionStart,
                onWriteError: onWriteError
            ) : nil
            lock.withLock {
                self.micWriter = mic
                self.systemWriter = system
            }

            if captureSystemAudio {
                let shareable = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
                guard let display = shareable.displays.first else {
                    throw MeetingRecorderError.captureStartFailed("No active display found for system audio capture.")
                }

                let filter = SCContentFilter(display: display, excludingWindows: [])
                let config = SCStreamConfiguration()
                config.capturesAudio = true
                config.excludesCurrentProcessAudio = true
                config.sampleRate = Int(MeetingTrackWriter.sampleRate)
                config.channelCount = Int(MeetingTrackWriter.channelCount)
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
                // Registered before the first start, so a device change during startup still rebuilds the tap
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
                    self.audioEngine = engine
                    self.configurationObserver = observer
                }
                // On `micQueue` too, so a restart triggered during startup runs after this start, not alongside it
                try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                    micQueue.async {
                        do {
                            try self.startMicrophone(on: engine)
                            continuation.resume()
                        } catch {
                            continuation.resume(throwing: error)
                        }
                    }
                }
            }
        } catch {
            await stopCapture()
            throw MeetingRecorderError.captureStartFailed(error.localizedDescription)
        }
    }

    public func stopCapture() async {
        let (engine, stream, writers, observer) = lock.withLock {
            () -> (AVAudioEngine?, SCStream?, [MeetingTrackWriter], NSObjectProtocol?) in
            let current = (self.audioEngine, self.scStream, [self.micWriter, self.systemWriter].compactMap { $0 }, self.configurationObserver)
            self.audioEngine = nil
            self.scStream = nil
            self.micWriter = nil
            self.systemWriter = nil
            self.configurationObserver = nil
            return current
        }
        // Close first: the tracks are final even if stopping the engine or stream below hangs (quit waits only 5 s)
        writers.forEach { $0.close() }

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
    }

    /// Plain tap at the input's native format. No voice processing: its other-audio ducking cut captured system audio by ~40 dB.
    /// Runs on `micQueue`.
    private func startMicrophone(on engine: AVAudioEngine) throws {
        let inputNode = engine.inputNode
        // Validity check only: the tap itself takes `format: nil`
        let inputFormat = inputNode.outputFormat(forBus: 0)
        guard inputFormat.sampleRate > 0 && inputFormat.channelCount > 0 else {
            throw MeetingRecorderError.captureStartFailed("No valid microphone input format available.")
        }

        Self.installMicrophoneTap(on: inputNode) { [weak self] buffer, when in
            guard let self else { return }
            let writer = self.lock.withLock { self.micWriter }
            writer?.append(buffer, hostSeconds: when.isHostTimeValid ? AVAudioTime.seconds(forHostTime: when.hostTime) : nil)
        }

        engine.prepare()
        guard lock.withLock({ self.audioEngine === engine }) else {
            throw MeetingRecorderError.captureStartFailed("Capture was stopped.")
        }
        try engine.start()
    }

    /// `format: nil` taps the hardware format; a format read from `outputFormat(forBus:)` can be stale after a device
    /// change and raise an uncatchable Objective-C exception (D2).
    static func installMicrophoneTap(on node: some MeetingAudioTapInstalling, block: @escaping AVAudioNodeTapBlock) {
        node.installTap(onBus: 0, bufferSize: 4096, format: nil, block: block)
    }

    /// The input device changed (AirPods, unplugged mic): the engine has stopped, so rebuild the tap with the new format.
    /// Runs on `micQueue`.
    private func restartMicrophone(_ engine: AVAudioEngine) {
        guard lock.withLock({ self.audioEngine === engine }) else { return }
        engine.inputNode.removeTap(onBus: 0)
        // The new device may have another format; never resample it with the old device's converter state
        lock.withLock { self.micWriter }?.resetConverter()
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

        // SCStream presentation timestamps are on the host clock (probe: same clock as the mic tap's hostTime)
        let pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        let writer = lock.withLock { self.systemWriter }
        writer?.append(pcmBuffer, hostSeconds: pts.isValid ? pts.seconds : nil)
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
