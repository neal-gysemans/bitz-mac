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

    private func makeWriter(_ name: String = "track.caf", maxPadSeconds: Double = 600) throws -> (MeetingTrackWriter, URL) {
        let url = tempDir.appendingPathComponent(name)
        return (try MeetingTrackWriter(fileURL: url, sessionStartHostSeconds: start, maxPadSeconds: maxPadSeconds), url)
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
        let converted = try XCTUnwrap(writer.convertToCanonical(buffer))
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
        try MeetingTrackMixer.mixTracks([micURL, systemURL], into: outputURL)

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
        try MeetingTrackMixer.mixTracks([micURL, systemURL], into: outputURL)
        let readFile = try AVAudioFile(forReading: outputURL)
        XCTAssertGreaterThanOrEqual(Double(readFile.length) / readFile.fileFormat.sampleRate, 2.9)

        let systemOnlyURL = tempDir.appendingPathComponent("system-only.m4a")
        try MeetingTrackMixer.mixTracks([tempDir.appendingPathComponent("missing.caf"), systemURL], into: systemOnlyURL)
        XCTAssertGreaterThanOrEqual(Double(try AVAudioFile(forReading: systemOnlyURL).length) / 48_000, 2.9)
    }
}
