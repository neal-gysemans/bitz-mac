@preconcurrency import AVFoundation
import CoreMedia
import Foundation

// MARK: - Crash-Safe Per-Source Track Writer

/// Writes one capture source (`mic.caf` or `system.caf`) as 48kHz stereo 16-bit integer PCM (Float32 in memory), placing every buffer
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
            // 16-bit on disk halves the tracks to ~1.4 GB/h for both; processing stays Float32
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
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
    /// Output-rate frames of earlier input the resampler still holds back (up to ~700 at 44.1 kHz); they come out first next time.
    private var converterBacklogFrames: Double = 0
    private let nowHostSeconds: @Sendable () -> Double
    private let sessionStartHostSeconds: Double
    /// One silence pad never exceeds this, so a single bogus timestamp cannot write hours of zeros.
    private let maxPadFrames: AVAudioFramePosition
    private let onWriteError: (@Sendable (String) -> Void)?
    private var hasReportedWriteError = false

    public init(
        fileURL: URL,
        sessionStartHostSeconds: Double,
        maxPadSeconds: Double = 600,
        nowHostSeconds: @escaping @Sendable () -> Double = MeetingTrackWriter.hostSecondsNow,
        onWriteError: (@Sendable (String) -> Void)? = nil
    ) throws {
        self.sessionStartHostSeconds = sessionStartHostSeconds
        self.nowHostSeconds = nowHostSeconds
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
        guard audioFile != nil, let converted = convertToCanonical(buffer) else { return }
        let (canonical, leadFrames) = converted

        var skipFrames: AVAudioFramePosition = 0
        // A timestamp in the future is bogus; placing it would pad silence up to the cap, so append it instead
        if let hostSeconds, hostSeconds.isFinite, hostSeconds <= nowHostSeconds() + 1 {
            let position = AVAudioFramePosition(((hostSeconds - sessionStartHostSeconds) * Self.sampleRate).rounded())
            // This buffer's audio starts after the frames the resampler held back from the previous one
            let offset = position - (writtenFrames + leadFrames)
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
        lock.withLock {
            converter = nil
            converterBacklogFrames = 0
        }
    }

    public func close() {
        lock.withLock {
            audioFile = nil
            converter = nil
        }
    }

    /// Converts an arbitrary buffer into the canonical 48kHz stereo Float32 format with this writer's own converter.
    /// `leadFrames` is how much of the output is audio held back from earlier buffers.
    func convertToCanonical(_ buffer: AVAudioPCMBuffer) -> (buffer: AVAudioPCMBuffer, leadFrames: AVAudioFramePosition)? {
        let targetFormat = Self.canonicalPCMFormat
        if buffer.format.sampleRate == targetFormat.sampleRate
            && buffer.format.channelCount == targetFormat.channelCount
            && buffer.format.commonFormat == .pcmFormatFloat32
            && !buffer.format.isInterleaved {
            return (buffer, 0)
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
            converterBacklogFrames = 0
        }
        guard let converter else { return nil }
        // The resampler works in 4096-frame slices and keeps the rest until more input comes; neither looping nor
        // `primeMethod` releases it (probe), so placement accounts for it instead
        let leadFrames = AVAudioFramePosition(converterBacklogFrames.rounded())

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
        converterBacklogFrames += Double(buffer.frameLength) * ratio - Double(outputBuffer.frameLength)
        return outputBuffer.frameLength > 0 ? (outputBuffer, leadFrames) : nil
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

enum MeetingTrackMixError: Error, LocalizedError, Equatable {
    case noAudio
    case lengthMismatch(expected: AVAudioFramePosition, actual: AVAudioFramePosition)
    case outputOccupied
    case cancelled
    case tracksChanged

    var errorDescription: String? {
        switch self {
        case .noAudio:
            return "No audio was recorded."
        case .lengthMismatch(let expected, let actual):
            return "The mixed file has \(actual) frames instead of \(expected)."
        case .outputOccupied:
            return "audio.m4a already exists and is not a damaged earlier mix."
        case .cancelled:
            return "Mixing stopped because a recording started."
        case .tracksChanged:
            return "A track was still being recorded, so this mix was discarded."
        }
    }
}

/// Mixes the per-source tracks into the AAC `audio.m4a` the rest of the recorder uses (#43).
/// Stop, quit and launch recovery all finish a session through `mixSession(in:)`.
public enum MeetingTrackMixer {
    public static let audioFileName = "audio.m4a"
    /// One read/mix/encode step (1 s).
    static let chunkFrames: AVAudioFrameCount = 48_000
    /// How far the encoded length may differ from the longest track. AVAudioFile stores the AAC priming and remainder,
    /// so the length came back exact in a probe (1 to 2.88M frames); two AAC packets of margin in case an encoder drops them.
    static let lengthToleranceFrames: AVAudioFramePosition = 2_048
    /// Two tracks sum to at most 2.0 before the clamp; applied to the whole mix so the level never jumps when one track ends.
    public static let headroomGain: Float = 0.85
    /// About 3 s per 10 min of two tracks; the quit path skips a mix that would not fit its budget.
    static let estimatedMixSecondsPerTrackSecond = 0.0025

    public static var m4aSettings: [String: Any] {
        [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: MeetingTrackWriter.sampleRate,
            AVNumberOfChannelsKey: Int(MeetingTrackWriter.channelCount),
            AVEncoderBitRateKey: 128_000
        ]
    }

    /// Pure deterministic PCM mixer: sums two 48kHz stereo Float32 buffers, scales by `headroomGain`, and hard-clamps to `[-1.0, 1.0]`.
    public static func mixBuffers(
        primary: AVAudioPCMBuffer,
        secondary: AVAudioPCMBuffer?,
        headroomGain: Float = headroomGain
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
                    dst[i] = max(-1.0, min(1.0, (pSrc[i] + sSample) * headroomGain))
                }
            } else {
                for i in 0..<Int(frameCount) {
                    dst[i] = max(-1.0, min(1.0, pSrc[i] * headroomGain))
                }
            }
        }
        return outBuffer
    }

    static func trackURLs(in sessionDirectory: URL) -> [URL] {
        [MeetingTrackWriter.micFileName, MeetingTrackWriter.systemFileName].map { sessionDirectory.appendingPathComponent($0) }
    }

    /// Where the session's audio lives right now: `audio.m4a` and/or the tracks that were not mixed (or deleted).
    static func audioFileNames(in sessionDirectory: URL) -> [String] {
        [audioFileName, MeetingTrackWriter.micFileName, MeetingTrackWriter.systemFileName].filter {
            var isDirectory: ObjCBool = false
            return FileManager.default.fileExists(atPath: sessionDirectory.appendingPathComponent($0).path, isDirectory: &isDirectory)
                && !isDirectory.boolValue
        }
    }

    /// Track lengths of the session's readable tracks, in frames.
    static func trackLengths(in sessionDirectory: URL) -> [AVAudioFramePosition] {
        trackURLs(in: sessionDirectory).compactMap { try? AVAudioFile(forReading: $0).length }
    }

    /// Length of a readable `audio.m4a`. Mixes are encoded to `audio.mixing.m4a` and renamed only once verified,
    /// so a readable `audio.m4a` is a verified mix.
    static func mixedLength(in sessionDirectory: URL) -> AVAudioFramePosition? {
        try? AVAudioFile(forReading: sessionDirectory.appendingPathComponent(audioFileName)).length
    }

    /// Metadata `audio_status` from the files: mixed (readable `audio.m4a`), empty (every track holds no frames), else unmixed.
    static func audioStatus(in sessionDirectory: URL) -> MeetingRecordingMetadata.AudioStatus {
        if mixedLength(in: sessionDirectory) != nil { return .mixed }
        let tracks = trackURLs(in: sessionDirectory).filter { FileManager.default.fileExists(atPath: $0.path) }
        return tracks.allSatisfy { (try? AVAudioFile(forReading: $0).length) == 0 } ? .empty : .unmixed
    }

    static func estimatedMixSeconds(in sessionDirectory: URL) -> Double {
        let trackSeconds = trackLengths(in: sessionDirectory).reduce(0) { $0 + Double($1) } / MeetingTrackWriter.sampleRate
        return trackSeconds * estimatedMixSecondsPerTrackSecond
    }

    /// Launch recovery: a track holds audio and there is no readable `audio.m4a` (crash, quit, failed mix).
    /// A readable `audio.m4a` is never replaced, so mixing again could only throw it away; empty or unreadable
    /// tracks have nothing to mix, so such a session is not retried at every launch.
    static func needsMix(_ sessionDirectory: URL) -> Bool {
        guard let longest = trackLengths(in: sessionDirectory).max(), longest > 0 else { return false }
        return mixedLength(in: sessionDirectory) == nil
    }

    /// Tracks a verified `audio.m4a` already covers: left over when deleting them after the mix was cut short.
    /// Only tracks the metadata lists as mixed (`mixedTracks`) count; without that list nothing is a leftover.
    static func tracksCoveredByMix(in sessionDirectory: URL, mixedTracks: [String]?) -> [URL] {
        guard let mixedTracks, let mixed = mixedLength(in: sessionDirectory) else { return [] }
        return trackURLs(in: sessionDirectory).filter { url in
            mixedTracks.contains(url.lastPathComponent)
                && (try? AVAudioFile(forReading: url).length).map { $0 <= mixed + lengthToleranceFrames } ?? false
        }
    }

    /// Each track's size and modification date; a change means a writer is still appending to it.
    static func trackStamps(in sessionDirectory: URL) -> [String] {
        trackURLs(in: sessionDirectory).map { url in
            let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
            let modified = (attributes?[.modificationDate] as? Date)?.timeIntervalSinceReferenceDate
            return "\(attributes?[.size] ?? "none") \(modified ?? 0)"
        }
    }

    /// Mixes the session's tracks into `audio.m4a`, verifies it, then deletes the tracks that went in.
    /// `recordMixedTracks` gets their names just before `audio.m4a` appears, so the caller can store them in metadata
    /// and a cleanup cut short later deletes only those. On failure the tracks stay and `mixed` is false;
    /// `warnings` also lists tracks that could not be read.
    static func mixSession(
        in sessionDirectory: URL,
        recordMixedTracks: ([String]) -> Void = { _ in }
    ) -> (mixed: Bool, mixedTracks: [String], warnings: [String]) {
        var warnings: [String] = []
        let outputURL = sessionDirectory.appendingPathComponent(audioFileName)
        let stampsBefore = trackStamps(in: sessionDirectory)
        do {
            let mixedTracks = try mixTracks(
                trackURLs(in: sessionDirectory),
                into: outputURL,
                warnings: &warnings,
                beforeCommit: { recordMixedTracks($0.map(\.lastPathComponent)) }
            )
            // Another Bitz instance may still be recording here (#43): a track that changed during the mix is never deleted
            guard trackStamps(in: sessionDirectory) == stampsBefore else {
                try? FileManager.default.removeItem(at: outputURL)
                throw MeetingTrackMixError.tracksChanged
            }
            mixedTracks.forEach { try? FileManager.default.removeItem(at: $0) }
            return (true, mixedTracks.map(\.lastPathComponent), warnings)
        } catch {
            warnings.append("Audio tracks were kept, but mixing them into audio.m4a failed: \(error.localizedDescription)")
            return (false, [], warnings)
        }
    }

    /// Mixes the readable tracks one chunk at a time (never a whole track in memory) into `outputURL` and verifies it.
    /// Encodes to `audio.mixing.m4a` first and removes it on any failure, so a failed mix never leaves a partial `audio.m4a`.
    /// Checks for cancellation every chunk (launch recovery is cancelled when a recording starts); the tracks stay.
    /// Missing tracks are skipped; tracks that exist but cannot be read are reported in `warnings` and kept.
    /// Returns the tracks that went into the mix. `outputSettings` lets tests encode PCM and check exact samples.
    @discardableResult
    static func mixTracks(
        _ trackURLs: [URL],
        into outputURL: URL,
        chunkFrames: AVAudioFrameCount = chunkFrames,
        outputSettings: [String: Any] = m4aSettings,
        warnings: inout [String],
        beforeCommit: ([URL]) -> Void = { _ in }
    ) throws -> [URL] {
        var mixedTracks: [URL] = []
        var readers: [AVAudioFile] = []
        for url in trackURLs where FileManager.default.fileExists(atPath: url.path) {
            do {
                let reader = try AVAudioFile(forReading: url)
                mixedTracks.append(url)
                if reader.length > 0 {
                    readers.append(reader)
                }
            } catch {
                warnings.append("\(url.lastPathComponent) could not be read and was left out of audio.m4a: \(error.localizedDescription)")
            }
        }
        guard let expectedFrames = readers.map(\.length).max() else { throw MeetingTrackMixError.noAudio }
        // One gain for the whole mix: headroom only when two tracks are summed
        let gain: Float = readers.count > 1 ? headroomGain : 1
        let buffers = readers.compactMap { AVAudioPCMBuffer(pcmFormat: $0.processingFormat, frameCapacity: chunkFrames) }
        guard buffers.count == readers.count else { throw MeetingTrackMixError.noAudio }

        let partialURL = outputURL.deletingPathExtension().appendingPathExtension("mixing.\(outputURL.pathExtension)")
        // A leftover from an interrupted run is never a finished file
        try? FileManager.default.removeItem(at: partialURL)
        do {
            do {
                let output = try AVAudioFile(
                    forWriting: partialURL,
                    settings: outputSettings,
                    commonFormat: .pcmFormatFloat32,
                    interleaved: false
                )
                while true {
                    guard !Task.isCancelled else { throw MeetingTrackMixError.cancelled }
                    for (reader, buffer) in zip(readers, buffers) {
                        if reader.framePosition < reader.length {
                            try reader.read(into: buffer, frameCount: chunkFrames)
                        } else {
                            buffer.frameLength = 0
                        }
                    }
                    let filled = buffers.filter { $0.frameLength > 0 }.sorted { $0.frameLength > $1.frameLength }
                    guard let primary = filled.first else { break }
                    guard let mixed = mixBuffers(primary: primary, secondary: filled.dropFirst().first, headroomGain: gain) else { break }
                    try output.write(from: mixed)
                }
            } // `output` is released here, which finishes the AAC file
            try verifyMix(at: partialURL, expectedFrames: expectedFrames)
            try replaceOutput(outputURL, with: partialURL) { beforeCommit(mixedTracks) }
        } catch {
            try? FileManager.default.removeItem(at: partialURL)
            throw error
        }
        return mixedTracks
    }

    /// The mix opens and its length matches the longest track to within `lengthToleranceFrames`.
    static func verifyMix(at url: URL, expectedFrames: AVAudioFramePosition) throws {
        let length = try AVAudioFile(forReading: url).length
        guard abs(length - expectedFrames) <= lengthToleranceFrames else {
            throw MeetingTrackMixError.lengthMismatch(expected: expectedFrames, actual: length)
        }
    }

    /// Replaces only a damaged `audio.m4a` (a regular file that does not open); a readable one is a verified mix and stays.
    /// `beforeCommit` runs only once the output is known to be replaceable, right before the rename.
    private static func replaceOutput(_ outputURL: URL, with partialURL: URL, beforeCommit: () -> Void) throws {
        guard let type = (try? FileManager.default.attributesOfItem(atPath: outputURL.path))?[.type] as? FileAttributeType else {
            beforeCommit()
            try FileManager.default.moveItem(at: partialURL, to: outputURL)
            return
        }
        guard type == .typeRegular, (try? AVAudioFile(forReading: outputURL)) == nil else { throw MeetingTrackMixError.outputOccupied }
        beforeCommit()
        _ = try FileManager.default.replaceItemAt(outputURL, withItemAt: partialURL)
    }
}
