@preconcurrency import AVFoundation
import CoreMedia
import Foundation

// MARK: - Crash-Safe Per-Source Track Writer

/// Writes one capture source (`mic.caf` or `system.caf`) as 48kHz stereo Float32 linear PCM, placing every buffer
/// by its host time so both tracks line up regardless of arrival order (#43). CAF keeps the data size open until
/// close, so a crash or force quit leaves a file that still plays up to the last flushed buffer.
public final class MeetingTrackWriter: @unchecked Sendable {
    public static let sampleRate: Double = 48_000
    public static let channelCount: AVAudioChannelCount = 2
    public static let micFileName = "mic.caf"
    public static let systemFileName = "system.caf"
    /// Timestamp jitter up to 10 ms is written back-to-back; larger gaps get silence and larger overlaps are trimmed.
    static let placementToleranceFrames: AVAudioFramePosition = 480

    public static var canonicalPCMFormat: AVAudioFormat {
        AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: sampleRate,
            channels: channelCount,
            interleaved: false
        )!
    }

    static var cafSettings: [String: Any] {
        [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: sampleRate,
            AVNumberOfChannelsKey: Int(channelCount),
            AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false
        ]
    }

    /// Host-clock seconds, the clock of both the mic tap's `AVAudioTime.hostTime` and SCStream presentation timestamps.
    public static func hostSecondsNow() -> Double {
        CMClockGetTime(CMClockGetHostTimeClock()).seconds
    }

    private let lock = NSLock()
    private var audioFile: AVAudioFile?
    private(set) var converter: AVAudioConverter?
    private var writtenFrames: AVAudioFramePosition = 0
    private let sessionStartHostSeconds: Double
    /// One silence pad never exceeds this, so a single bogus timestamp cannot write hours of zeros.
    private let maxPadFrames: AVAudioFramePosition
    private let onWriteError: (@Sendable (String) -> Void)?
    private var hasReportedWriteError = false

    public init(
        fileURL: URL,
        sessionStartHostSeconds: Double,
        maxPadSeconds: Double = 600,
        onWriteError: (@Sendable (String) -> Void)? = nil
    ) throws {
        self.sessionStartHostSeconds = sessionStartHostSeconds
        self.maxPadFrames = AVAudioFramePosition(maxPadSeconds * Self.sampleRate)
        self.onWriteError = onWriteError
        self.audioFile = try AVAudioFile(
            forWriting: fileURL,
            settings: Self.cafSettings,
            commonFormat: .pcmFormatFloat32,
            interleaved: false
        )
    }

    /// Appends `buffer` at the frame its first sample belongs to. `hostSeconds` nil appends right after the last frame.
    public func append(_ buffer: AVAudioPCMBuffer, hostSeconds: Double?) {
        lock.lock()
        defer { lock.unlock() }
        guard audioFile != nil, let canonical = convertToCanonical(buffer) else { return }

        var skipFrames: AVAudioFramePosition = 0
        if let hostSeconds, hostSeconds.isFinite {
            let position = AVAudioFramePosition(((hostSeconds - sessionStartHostSeconds) * Self.sampleRate).rounded())
            let offset = position - writtenFrames
            if offset > Self.placementToleranceFrames {
                writeSilence(frames: min(offset, maxPadFrames))
            } else if offset < -Self.placementToleranceFrames {
                skipFrames = -offset
            }
        }
        // A late or duplicate buffer whose span is already written is dropped
        guard skipFrames < AVAudioFramePosition(canonical.frameLength) else { return }
        if skipFrames == 0 {
            write(canonical)
        } else if let tail = Self.slice(canonical, from: AVAudioFrameCount(skipFrames)) {
            write(tail)
        }
    }

    /// Drops converter state, e.g. when the mic restarts after a device change.
    public func resetConverter() {
        lock.withLock { converter = nil }
    }

    public func close() {
        lock.withLock {
            audioFile = nil
            converter = nil
        }
    }

    /// Converts an arbitrary buffer into the canonical 48kHz stereo Float32 format with this writer's own converter.
    func convertToCanonical(_ buffer: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
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

        if converter?.inputFormat != buffer.format {
            guard let created = AVAudioConverter(from: buffer.format, to: targetFormat) else { return nil }
            // Multi-channel inputs (USB/aggregate mics) default to [-1, -1] (silence); take channel 0
            if buffer.format.channelCount > 2 {
                created.channelMap = [0, 0]
            }
            converter = created
        }
        guard let converter else { return nil }

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

    /// Caller holds `lock`.
    private func writeSilence(frames: AVAudioFramePosition) {
        let chunk = AVAudioFrameCount(min(frames, AVAudioFramePosition(Self.sampleRate)))
        guard chunk > 0,
              let silence = AVAudioPCMBuffer(pcmFormat: Self.canonicalPCMFormat, frameCapacity: chunk),
              let channels = silence.floatChannelData else { return }
        for ch in 0..<Int(Self.channelCount) {
            channels[ch].update(repeating: 0, count: Int(chunk))
        }
        var remaining = frames
        while remaining > 0 {
            silence.frameLength = AVAudioFrameCount(min(remaining, AVAudioFramePosition(chunk)))
            guard write(silence) else { return }
            remaining -= AVAudioFramePosition(silence.frameLength)
        }
    }

    /// Writes and advances the timeline; reports the first failure once so a full disk is not silent. Caller holds `lock`.
    @discardableResult
    private func write(_ buffer: AVAudioPCMBuffer) -> Bool {
        do {
            try audioFile?.write(from: buffer)
            writtenFrames += AVAudioFramePosition(buffer.frameLength)
            return true
        } catch {
            if !hasReportedWriteError {
                hasReportedWriteError = true
                onWriteError?("Could not write meeting audio: \(error.localizedDescription)")
            }
            return false
        }
    }

    private static func slice(_ buffer: AVAudioPCMBuffer, from start: AVAudioFrameCount) -> AVAudioPCMBuffer? {
        let frames = buffer.frameLength - start
        guard let out = AVAudioPCMBuffer(pcmFormat: buffer.format, frameCapacity: frames),
              let src = buffer.floatChannelData, let dst = out.floatChannelData else { return nil }
        out.frameLength = frames
        for ch in 0..<Int(buffer.format.channelCount) {
            dst[ch].update(from: src[ch] + Int(start), count: Int(frames))
        }
        return out
    }
}

// MARK: - Offline Track Mix

/// Mixes the per-source tracks into the AAC `audio.m4a` the rest of the recorder uses (#43).
public enum MeetingTrackMixer {
    public static var m4aSettings: [String: Any] {
        [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: MeetingTrackWriter.sampleRate,
            AVNumberOfChannelsKey: Int(MeetingTrackWriter.channelCount),
            AVEncoderBitRateKey: 128_000
        ]
    }

    /// Pure deterministic PCM mixer: sums two 48kHz stereo Float32 buffers with headroom gain and soft-clipping to `[-1.0, 1.0]`.
    public static func mixBuffers(
        primary: AVAudioPCMBuffer,
        secondary: AVAudioPCMBuffer?,
        headroomGain: Float = 0.85
    ) -> AVAudioPCMBuffer? {
        let format = MeetingTrackWriter.canonicalPCMFormat
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

        for ch in 0..<Int(MeetingTrackWriter.channelCount) {
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

    /// Mixes the readable tracks one second at a time (never a whole track in memory) into `outputURL`.
    /// Encodes to a temporary name first, so an interrupted mix never leaves a truncated `audio.m4a`.
    /// shortcut: no length verification and the CAFs are always kept; harden before deleting tracks after a mix.
    static func mixTracks(_ trackURLs: [URL], into outputURL: URL) throws {
        let readers = trackURLs.compactMap { try? AVAudioFile(forReading: $0) }
        guard !readers.isEmpty else { throw CocoaError(.fileReadNoSuchFile) }

        let chunk: AVAudioFrameCount = 48_000
        let buffers = readers.compactMap { AVAudioPCMBuffer(pcmFormat: $0.processingFormat, frameCapacity: chunk) }
        let partialURL = outputURL.deletingPathExtension().appendingPathExtension("mixing.m4a")
        try? FileManager.default.removeItem(at: partialURL)
        do {
            let output = try AVAudioFile(
                forWriting: partialURL,
                settings: m4aSettings,
                commonFormat: .pcmFormatFloat32,
                interleaved: false
            )
            while true {
                for (reader, buffer) in zip(readers, buffers) {
                    if reader.framePosition < reader.length {
                        try reader.read(into: buffer, frameCount: chunk)
                    } else {
                        buffer.frameLength = 0
                    }
                }
                let filled = buffers.filter { $0.frameLength > 0 }.sorted { $0.frameLength > $1.frameLength }
                guard let primary = filled.first else { break }
                guard let mixed = mixBuffers(primary: primary, secondary: filled.dropFirst().first) else { break }
                try output.write(from: mixed)
            }
        }
        try FileManager.default.moveItem(at: partialURL, to: outputURL)
    }
}
