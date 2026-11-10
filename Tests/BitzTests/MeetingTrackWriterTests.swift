import AVFoundation
import XCTest
@testable import BitzCore

// MARK: - Per-source track writer & offline mix

final class MeetingTrackWriterTests: XCTestCase {
    private var tempDir: URL!
    private let start: Double = 1_000

    override func setUp() async throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("bitz-meetings-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: tempDir)
    }

    private func makeWriter(
        _ name: String = "track.caf",
        maxPadSeconds: Double = 600,
        now: Double = 1_000_000
    ) throws -> (MeetingTrackWriter, URL) {
        let url = tempDir.appendingPathComponent(name)
        return (try MeetingTrackWriter(fileURL: url, sessionStartHostSeconds: start, maxPadSeconds: maxPadSeconds, nowHostSeconds: { now }), url)
    }

    /// A finished track of `frames` frames of `value` (both channels).
    @discardableResult
    private func writeTrack(_ name: String, value: Float, frames: AVAudioFrameCount) throws -> URL {
        let (writer, url) = try makeWriter(name)
        writer.append(try constant(value, frames: frames), hostSeconds: start)
        writer.close()
        return url
    }

    private func constant(_ value: Float, frames: AVAudioFrameCount, sampleRate: Double = 48_000, channels: AVAudioChannelCount = 2) throws -> AVAudioPCMBuffer {
        let format = try XCTUnwrap(AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: sampleRate, channels: channels, interleaved: false))
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames))
        buffer.frameLength = frames
        let data = try XCTUnwrap(buffer.floatChannelData)
        for ch in 0..<Int(channels) {
            data[ch].update(repeating: value, count: Int(frames))
        }
        return buffer
    }

    /// Left channel of a finished track.
    private func readSamples(_ url: URL) throws -> [Float] {
        let file = try AVAudioFile(forReading: url)
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length)))
        try file.read(into: buffer)
        return Array(UnsafeBufferPointer(start: buffer.floatChannelData![0], count: Int(buffer.frameLength)))
    }

    // MARK: Timestamp placement

    func testGapIsPaddedWithSilenceOfExactLength() throws {
        let (writer, url) = try makeWriter()
        writer.append(try constant(0.5, frames: 4_800), hostSeconds: start)
        // Next buffer starts 0.5 s in: 0.4 s (19 200 frames) of silence between them
        writer.append(try constant(0.5, frames: 4_800), hostSeconds: start + 0.5)
        writer.close()

        let samples = try readSamples(url)
        XCTAssertEqual(samples.count, 28_800)
        XCTAssertEqual(samples[4_799], 0.5)
        XCTAssertTrue(samples[4_800..<24_000].allSatisfy { $0 == 0 })
        XCTAssertEqual(samples[24_000], 0.5)
    }

    func testFirstBufferAfterSessionStartIsPaddedSoTracksLineUp() throws {
        let (writer, url) = try makeWriter()
        writer.append(try constant(0.5, frames: 4_800), hostSeconds: start + 0.25)
        writer.close()

        let samples = try readSamples(url)
        XCTAssertEqual(samples.count, 12_000 + 4_800)
        XCTAssertEqual(samples[11_999], 0)
        XCTAssertEqual(samples[12_000], 0.5)
    }

    func testOverlapIsTrimmedAndSmallJitterStaysContiguous() throws {
        let (writer, url) = try makeWriter()
        writer.append(try constant(0.25, frames: 4_800), hostSeconds: start)
        // Starts 2 400 frames before the end of the first buffer: its first half is trimmed
        writer.append(try constant(0.5, frames: 4_800), hostSeconds: start + 0.05)
        // 100 frames (2 ms) late is jitter, written back-to-back without a pad
        writer.append(try constant(0.75, frames: 4_800), hostSeconds: start + (7_200 + 100) / 48_000)
        writer.close()

        let samples = try readSamples(url)
        XCTAssertEqual(samples.count, 4_800 + 2_400 + 4_800)
        XCTAssertEqual(samples[4_799], 0.25)
        XCTAssertEqual(samples[4_800], 0.5)
        XCTAssertEqual(samples[7_199], 0.5)
        XCTAssertEqual(samples[7_200], 0.75)
    }

    func testLateAndDuplicateBuffersAreDropped() throws {
        let (writer, url) = try makeWriter()
        writer.append(try constant(0.25, frames: 4_800), hostSeconds: start)
        writer.append(try constant(0.75, frames: 4_800), hostSeconds: start + 0.2)
        // Arrives after the buffer that follows it: its span is already written (as silence)
        writer.append(try constant(0.5, frames: 4_800), hostSeconds: start + 0.1)
        writer.append(try constant(0.25, frames: 4_800), hostSeconds: start)
        writer.close()

        let samples = try readSamples(url)
        XCTAssertEqual(samples.count, 14_400)
        XCTAssertTrue(samples[4_800..<9_600].allSatisfy { $0 == 0 })
        XCTAssertEqual(samples[9_600], 0.75)
    }

    func testSilencePadIsCappedForBogusTimestamps() throws {
        let (writer, url) = try makeWriter(maxPadSeconds: 1)
        writer.append(try constant(0.5, frames: 4_800), hostSeconds: start + 3_600)
        writer.close()

        XCTAssertEqual(try readSamples(url).count, 48_000 + 4_800)
    }

    // MARK: Conversion

    func testEachWriterOwnsItsConverterAndResetDropsIt() throws {
        let (mic, _) = try makeWriter("mic.caf")
        let (system, _) = try makeWriter("system.caf")
        defer { mic.close(); system.close() }
        mic.append(try constant(0.5, frames: 4_410, sampleRate: 44_100, channels: 1), hostSeconds: nil)
        system.append(try constant(0.5, frames: 4_410, sampleRate: 44_100, channels: 1), hostSeconds: nil)

        let micConverter = try XCTUnwrap(mic.converter)
        XCTAssertFalse(micConverter === system.converter, "Same input format must not share converter state across sources")

        mic.resetConverter()
        XCTAssertNil(mic.converter)
        XCTAssertNotNil(system.converter)
        mic.append(try constant(0.5, frames: 4_410, sampleRate: 44_100, channels: 1), hostSeconds: nil)
        XCTAssertFalse(micConverter === mic.converter)
    }

    func testMono44kConvertsTo48kStereoWithCorrectLength() throws {
        let (writer, url) = try makeWriter()
        for i in 0..<10 {
            writer.append(try constant(0.5, frames: 4_410, sampleRate: 44_100, channels: 1), hostSeconds: start + Double(i) * 0.1)
        }
        writer.close()

        let file = try AVAudioFile(forReading: url)
        XCTAssertEqual(file.fileFormat.sampleRate, 48_000)
        XCTAssertEqual(file.fileFormat.channelCount, 2)
        // One second of input; the resampler may hold back a few frames of filter latency
        XCTAssertEqual(Double(file.length), 48_000, accuracy: Double(MeetingTrackWriter.placementToleranceFrames))
        let samples = try readSamples(url)
        XCTAssertEqual(samples[24_000], 0.5, accuracy: 0.01)
    }

    func testFourChannelInputConvertsToAudibleStereo() throws {
        // Multi-channel mics report e.g. 4 discrete channels; the default converter map would emit silence
        var layout = AudioChannelLayout()
        layout.mChannelLayoutTag = kAudioChannelLayoutTag_DiscreteInOrder | 4
        let source = AVAudioFormat(standardFormatWithSampleRate: 48_000, channelLayout: AVAudioChannelLayout(layout: &layout))
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: source, frameCapacity: 1_024))
        buffer.frameLength = 1_024
        let channels = try XCTUnwrap(buffer.floatChannelData)
        for i in 0..<1_024 {
            channels[0][i] = 0.5
            for ch in 1..<4 { channels[ch][i] = 0 }
        }

        let (writer, _) = try makeWriter()
        defer { writer.close() }
        let converted = try XCTUnwrap(writer.convertToCanonical(buffer)?.buffer)
        let out = try XCTUnwrap(converted.floatChannelData)
        XCTAssertEqual(converted.format.channelCount, 2)
        XCTAssertEqual(out[0][100], 0.5, accuracy: 0.01)
        XCTAssertEqual(out[1][100], 0.5, accuracy: 0.01)
    }

    // MARK: Crash safety

    func testTrackIsReadableBeforeTheWriterCloses() throws {
        // A crash never closes the writer; the CAF must still read back up to (almost) the last write
        let (writer, url) = try makeWriter()
        defer { writer.close() }
        for i in 0..<10 {
            writer.append(try constant(0.5, frames: 4_800), hostSeconds: start + Double(i) * 0.1)
        }

        let file = try AVAudioFile(forReading: url)
        XCTAssertGreaterThan(file.length, 48_000 - 4_096)
    }

    // MARK: Microphone tap

    func testMicrophoneTapIsInstalledWithNilFormat() {
        final class RecordingNode: MeetingAudioTapInstalling {
            var calls: [(bus: AVAudioNodeBus, format: AVAudioFormat?)] = []
            func installTap(onBus bus: AVAudioNodeBus, bufferSize: AVAudioFrameCount, format: AVAudioFormat?, block: @escaping AVAudioNodeTapBlock) {
                calls.append((bus, format))
            }
        }
        let node = RecordingNode()
        ProductionMeetingAudioCaptureEngine.installMicrophoneTap(on: node) { _, _ in }

        XCTAssertEqual(node.calls.count, 1)
        XCTAssertEqual(node.calls.first?.bus, 0)
        XCTAssertNil(node.calls.first?.format)
    }

    // MARK: Offline mix

    func testMixBuffersAppliesHeadroomAndTracksEncodeToM4A() throws {
        let micBuffer = try XCTUnwrap(
            MockMeetingAudioCaptureEngine.makeSineWaveBuffer(frequency: 440.0, frameCount: 4_800, amplitude: 0.75)
        )
        let sysBuffer = try XCTUnwrap(
            MockMeetingAudioCaptureEngine.makeSineWaveBuffer(frequency: 880.0, frameCount: 4_800, amplitude: 0.75)
        )

        // Pure buffer mixing applies headroom and clamps within [-1.0, 1.0]
        let mixed = try XCTUnwrap(MeetingTrackMixer.mixBuffers(primary: micBuffer, secondary: sysBuffer))
        XCTAssertEqual(mixed.frameLength, 4_800)
        if let channel0 = mixed.floatChannelData?[0] {
            for i in 0..<Int(mixed.frameLength) {
                XCTAssertLessThanOrEqual(abs(channel0[i]), 1.0)
            }
        }

        let (mic, micURL) = try makeWriter(MeetingTrackWriter.micFileName)
        let (system, systemURL) = try makeWriter(MeetingTrackWriter.systemFileName)
        mic.append(micBuffer, hostSeconds: start)
        system.append(sysBuffer, hostSeconds: start)
        mic.close()
        system.close()

        let outputURL = tempDir.appendingPathComponent("audio.m4a")
        var warnings: [String] = []
        try MeetingTrackMixer.mixTracks([micURL, systemURL], into: outputURL, warnings: &warnings)
        XCTAssertEqual(warnings, [])

        let readFile = try AVAudioFile(forReading: outputURL)
        XCTAssertEqual(readFile.fileFormat.sampleRate, 48_000, accuracy: 1.0)
        XCTAssertEqual(readFile.fileFormat.channelCount, 2)
        XCTAssertGreaterThan(readFile.length, 0)
        XCTAssertFalse(FileManager.default.fileExists(atPath: tempDir.appendingPathComponent("audio.mixing.m4a").path))
    }

    func testMixKeepsSystemAudioBeyondAShorterMicTrack() throws {
        // Mic delivered 0.1 s, system audio 3 s (or the mic track is missing): all 3 s must reach audio.m4a
        let (mic, micURL) = try makeWriter(MeetingTrackWriter.micFileName)
        let (system, systemURL) = try makeWriter(MeetingTrackWriter.systemFileName)
        mic.append(try constant(0.25, frames: 4_800), hostSeconds: start)
        for i in 0..<3 {
            system.append(try constant(0.25, frames: 48_000), hostSeconds: start + Double(i))
        }
        mic.close()
        system.close()

        let outputURL = tempDir.appendingPathComponent("audio.m4a")
        var warnings: [String] = []
        try MeetingTrackMixer.mixTracks([micURL, systemURL], into: outputURL, warnings: &warnings)
        let readFile = try AVAudioFile(forReading: outputURL)
        XCTAssertGreaterThanOrEqual(Double(readFile.length) / readFile.fileFormat.sampleRate, 2.9)

        let systemOnlyURL = tempDir.appendingPathComponent("system-only.m4a")
        try MeetingTrackMixer.mixTracks([tempDir.appendingPathComponent("missing.caf"), systemURL], into: systemOnlyURL, warnings: &warnings)
        XCTAssertEqual(warnings, [], "A missing track is expected (source off), not a warning")
        XCTAssertGreaterThanOrEqual(Double(try AVAudioFile(forReading: systemOnlyURL).length) / 48_000, 2.9)
    }

    // MARK: Hardening (Task 3)

    func testFutureTimestampIsAppendedInsteadOfPadded() throws {
        let (writer, url) = try makeWriter(now: start + 10)
        writer.append(try constant(0.5, frames: 4_800), hostSeconds: start)
        // An hour ahead of the clock: bogus, so no silence pad up to the 10 min cap
        writer.append(try constant(0.5, frames: 4_800), hostSeconds: start + 3_600)
        writer.close()

        XCTAssertEqual(try readSamples(url).count, 9_600)
    }

    func testResamplerHoldbackDoesNotOpenASilenceGap() throws {
        // 44.1 kHz input: the converter returns 4096 of the first 4800 frames and keeps 704 for later
        let (writer, url) = try makeWriter()
        for i in 0..<10 {
            writer.append(try constant(0.5, frames: 4_410, sampleRate: 44_100, channels: 1), hostSeconds: start + Double(i) * 0.1)
        }
        writer.close()

        let samples = try readSamples(url)
        // Before the backlog was accounted for, frames 4096..<4800 were a padded silence gap
        XCTAssertTrue(samples[100..<(samples.count - 100)].allSatisfy { abs($0 - 0.5) < 0.05 }, "no gap or trim inside the track")
        XCTAssertEqual(Double(samples.count), 48_000, accuracy: 800)
    }

    func testMixBuffersUsesOneGainAndClampsWhenTheSecondaryEnds() throws {
        let primary = try constant(0.5, frames: 1_000)
        let secondary = try constant(0.75, frames: 400)
        let mixed = try XCTUnwrap(MeetingTrackMixer.mixBuffers(primary: primary, secondary: secondary, headroomGain: 0.85))
        let left = try XCTUnwrap(mixed.floatChannelData?[0])
        XCTAssertEqual(left[0], 1.0, "(0.5 + 0.75) × 0.85 = 1.0625 is clamped")
        XCTAssertEqual(left[399], 1.0)
        XCTAssertEqual(left[400], 0.425, accuracy: 1e-6, "the same 0.85 applies after the secondary ends")
        XCTAssertEqual(left[999], 0.425, accuracy: 1e-6)
    }

    func testTwoTrackMixInChunksHasConstantGainOverTracksOfDifferentLength() throws {
        let mic = try writeTrack(MeetingTrackWriter.micFileName, value: 0.5, frames: 72_000)
        let system = try writeTrack(MeetingTrackWriter.systemFileName, value: 0.25, frames: 24_000)
        let output = tempDir.appendingPathComponent("mix.caf")
        var warnings: [String] = []

        // 10 000-frame chunks against 72 000-frame tracks: the mix must stream, a single read cannot hold a track
        let mixed = try MeetingTrackMixer.mixTracks(
            [mic, system], into: output, chunkFrames: 10_000, outputSettings: MeetingTrackWriter.cafSettings, warnings: &warnings
        )

        XCTAssertEqual(mixed, [mic, system])
        let samples = try readSamples(output)
        XCTAssertEqual(samples.count, 72_000, "as long as the longer track")
        XCTAssertEqual(samples[0], 0.6375, accuracy: 0.001)
        XCTAssertEqual(samples[23_999], 0.6375, accuracy: 0.001)
        XCTAssertEqual(samples[24_000], 0.425, accuracy: 0.001, "no level jump when the system track ends")
        XCTAssertEqual(samples[71_999], 0.425, accuracy: 0.001)
        XCTAssertFalse(FileManager.default.fileExists(atPath: tempDir.appendingPathComponent("mix.mixing.caf").path))
    }

    func testMicOnlyAndSystemOnlyMixesKeepTheirLevel() throws {
        for name in [MeetingTrackWriter.micFileName, MeetingTrackWriter.systemFileName] {
            let track = try writeTrack(name, value: 0.5, frames: 30_000)
            let output = tempDir.appendingPathComponent("\(name).mix.caf")
            var warnings: [String] = []
            let missing = tempDir.appendingPathComponent("missing.caf")

            try MeetingTrackMixer.mixTracks([missing, track], into: output, outputSettings: MeetingTrackWriter.cafSettings, warnings: &warnings)

            let samples = try readSamples(output)
            XCTAssertEqual(samples.count, 30_000, name)
            XCTAssertEqual(samples[15_000], 0.5, accuracy: 0.001, "\(name): a single track is not attenuated")
            XCTAssertEqual(warnings, [])
        }
    }

    func testMixSessionDeletesTracksOnlyAfterAVerifiedMix() throws {
        try writeTrack(MeetingTrackWriter.micFileName, value: 0.25, frames: 48_000)
        try writeTrack(MeetingTrackWriter.systemFileName, value: 0.25, frames: 96_000)

        let outcome = MeetingTrackMixer.mixSession(in: tempDir)

        XCTAssertTrue(outcome.mixed)
        XCTAssertEqual(outcome.warnings, [])
        XCTAssertEqual(MeetingTrackMixer.audioFileNames(in: tempDir), ["audio.m4a"])
        let mixed = try AVAudioFile(forReading: tempDir.appendingPathComponent("audio.m4a"))
        XCTAssertEqual(Double(mixed.length), 96_000, accuracy: Double(MeetingTrackMixer.chunkFrames))
    }

    func testMixFailureKeepsTracksAndRemovesThePartialFile() throws {
        try writeTrack(MeetingTrackWriter.micFileName, value: 0.25, frames: 48_000)
        // Something that is not Bitz's own file sits at audio.m4a: it must be neither replaced nor deleted
        let occupied = tempDir.appendingPathComponent("audio.m4a", isDirectory: true)
        try FileManager.default.createDirectory(at: occupied, withIntermediateDirectories: false)

        let outcome = MeetingTrackMixer.mixSession(in: tempDir)

        XCTAssertFalse(outcome.mixed)
        XCTAssertTrue(outcome.warnings.contains { $0.contains("mixing them into audio.m4a failed") }, "\(outcome.warnings)")
        XCTAssertTrue(FileManager.default.fileExists(atPath: tempDir.appendingPathComponent(MeetingTrackWriter.micFileName).path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: tempDir.appendingPathComponent("audio.mixing.m4a").path))
        var isDirectory: ObjCBool = false
        XCTAssertTrue(FileManager.default.fileExists(atPath: occupied.path, isDirectory: &isDirectory) && isDirectory.boolValue)
    }

    func testUnreadableTrackIsReportedAndKept() throws {
        try writeTrack(MeetingTrackWriter.micFileName, value: 0.25, frames: 48_000)
        let system = tempDir.appendingPathComponent(MeetingTrackWriter.systemFileName)
        try Data("not audio".utf8).write(to: system)

        let outcome = MeetingTrackMixer.mixSession(in: tempDir)

        XCTAssertTrue(outcome.mixed)
        XCTAssertEqual(outcome.warnings.count, 1)
        XCTAssertTrue(outcome.warnings[0].hasPrefix("system.caf could not be read"), outcome.warnings[0])
        XCTAssertEqual(MeetingTrackMixer.audioFileNames(in: tempDir), ["audio.m4a", "system.caf"])
        // The next launch sees a finished mix, not a session to mix again
        XCTAssertFalse(MeetingTrackMixer.needsMix(tempDir))
        XCTAssertEqual(outcome.mixedTracks, ["mic.caf"])
        XCTAssertEqual(MeetingTrackMixer.tracksCoveredByMix(in: tempDir, mixedTracks: outcome.mixedTracks), [])
        XCTAssertEqual(MeetingTrackMixer.audioStatus(in: tempDir), .mixed)
    }

    func testCancelledMixKeepsTracksAndLeavesNoPartialFile() async throws {
        try writeTrack(MeetingTrackWriter.micFileName, value: 0.25, frames: 96_000)
        let sessionDirectory: URL = tempDir
        let outcome = await Task.detached {
            withUnsafeCurrentTask { $0?.cancel() }
            return MeetingTrackMixer.mixSession(in: sessionDirectory)
        }.value

        XCTAssertFalse(outcome.mixed)
        XCTAssertTrue(outcome.warnings.contains { $0.contains("a recording started") }, "\(outcome.warnings)")
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: tempDir.path), ["mic.caf"])
    }

    func testRetryReplacesAnEarlierInvalidMix() throws {
        try writeTrack(MeetingTrackWriter.micFileName, value: 0.25, frames: 48_000)
        try Data("truncated".utf8).write(to: tempDir.appendingPathComponent("audio.m4a"))
        try Data("leftover".utf8).write(to: tempDir.appendingPathComponent("audio.mixing.m4a"))
        XCTAssertTrue(MeetingTrackMixer.needsMix(tempDir))

        XCTAssertTrue(MeetingTrackMixer.mixSession(in: tempDir).mixed)

        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: tempDir.path), ["audio.m4a"])
        XCTAssertGreaterThan(try AVAudioFile(forReading: tempDir.appendingPathComponent("audio.m4a")).length, 0)
        XCTAssertFalse(MeetingTrackMixer.needsMix(tempDir))
    }

    func testVerifyMixChecksLengthAgainstTheLongestTrack() throws {
        let track = try writeTrack(MeetingTrackWriter.micFileName, value: 0.25, frames: 96_000)
        let output = tempDir.appendingPathComponent("audio.m4a")
        var warnings: [String] = []
        try MeetingTrackMixer.mixTracks([track], into: output, warnings: &warnings)

        XCTAssertNoThrow(try MeetingTrackMixer.verifyMix(at: output, expectedFrames: 96_000))
        XCTAssertNoThrow(try MeetingTrackMixer.verifyMix(at: output, expectedFrames: 96_000 + MeetingTrackMixer.lengthToleranceFrames))
        XCTAssertThrowsError(try MeetingTrackMixer.verifyMix(at: output, expectedFrames: 96_000 + MeetingTrackMixer.lengthToleranceFrames + 1)) { error in
            guard case MeetingTrackMixError.lengthMismatch = error else { return XCTFail("\(error)") }
        }
        XCTAssertThrowsError(try MeetingTrackMixer.verifyMix(at: tempDir.appendingPathComponent("missing.m4a"), expectedFrames: 0))
    }
}
