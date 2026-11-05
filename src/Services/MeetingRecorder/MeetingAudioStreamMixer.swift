@preconcurrency import AVFoundation
import Foundation

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
            // Multi-channel inputs (USB/aggregate mics) default to [-1, -1] (silence); take channel 0
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
