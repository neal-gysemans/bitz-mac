import AVFoundation
import XCTest
@testable import BitzCore

// MARK: - Dual-stream audio mixer

@MainActor
final class MeetingAudioMixerTests: XCTestCase {
    private var tempDir: URL!

    override func setUp() async throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("bitz-meetings-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: tempDir)
    }

    func testDualStreamAudioMixerEncodesValidM4AWithoutClipping() throws {
        let outputURL = tempDir.appendingPathComponent("mixed.m4a")
        let mixer = try MeetingAudioStreamMixer(outputFileURL: outputURL)

        let micBuffer = try XCTUnwrap(
            MockMeetingAudioCaptureEngine.makeSineWaveBuffer(frequency: 440.0, frameCount: 4_800, amplitude: 0.75)
        )
        let sysBuffer = try XCTUnwrap(
            MockMeetingAudioCaptureEngine.makeSineWaveBuffer(frequency: 880.0, frameCount: 4_800, amplitude: 0.75)
        )

        // Verify pure buffer mixing applies headroom and clamps within [-1.0, 1.0]
        let mixed = try XCTUnwrap(MeetingAudioStreamMixer.mixBuffers(primary: micBuffer, secondary: sysBuffer))
        XCTAssertEqual(mixed.frameLength, 4_800)
        if let channel0 = mixed.floatChannelData?[0] {
            for i in 0..<Int(mixed.frameLength) {
                XCTAssertLessThanOrEqual(abs(channel0[i]), 1.0)
            }
        }

        // Write dual-stream buffers into .m4a file
        mixer.appendSystemAudioBuffer(sysBuffer, mixWithMic: true)
        mixer.appendMicrophoneBuffer(micBuffer)
        mixer.close()

        XCTAssertTrue(FileManager.default.fileExists(atPath: outputURL.path))
        let attrs = try FileManager.default.attributesOfItem(atPath: outputURL.path)
        let size = (attrs[.size] as? NSNumber)?.intValue ?? 0
        XCTAssertGreaterThan(size, 0, "Encoded .m4a file must be non-empty")

        let readFile = try AVAudioFile(forReading: outputURL)
        XCTAssertEqual(readFile.fileFormat.sampleRate, 48_000, accuracy: 1.0)
        XCTAssertEqual(readFile.fileFormat.channelCount, 2)
    }

    func testMixerKeepsSystemAudioWhenMicBuffersStop() throws {
        let outputURL = tempDir.appendingPathComponent("system-only.m4a")
        let mixer = try MeetingAudioStreamMixer(outputFileURL: outputURL)
        let oneSecond = try XCTUnwrap(MockMeetingAudioCaptureEngine.makeSineWaveBuffer(frequency: 880.0, frameCount: 48_000))

        // Mic is enabled but delivers nothing: 3 s of system audio must still reach the file
        for _ in 0..<3 {
            mixer.appendSystemAudioBuffer(oneSecond, mixWithMic: true)
        }
        mixer.close()

        let readFile = try AVAudioFile(forReading: outputURL)
        XCTAssertGreaterThanOrEqual(Double(readFile.length) / readFile.fileFormat.sampleRate, 2.9)
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

        let mixer = try MeetingAudioStreamMixer(outputFileURL: tempDir.appendingPathComponent("vp.m4a"))
        defer { mixer.close() }
        let converted = try XCTUnwrap(mixer.convertToCanonical(buffer))
        let out = try XCTUnwrap(converted.floatChannelData)
        XCTAssertEqual(converted.format.channelCount, 2)
        XCTAssertEqual(out[0][100], 0.5, accuracy: 0.01)
        XCTAssertEqual(out[1][100], 0.5, accuracy: 0.01)
    }

    func testFlushSecondaryWritesQueuedSystemAudioBeforeMicResumes() throws {
        let outputURL = tempDir.appendingPathComponent("flush.m4a")
        let mixer = try MeetingAudioStreamMixer(outputFileURL: outputURL)
        let oneSecond = try XCTUnwrap(MockMeetingAudioCaptureEngine.makeSineWaveBuffer(frequency: 880.0, frameCount: 48_000))
        let mic = try XCTUnwrap(MockMeetingAudioCaptureEngine.makeSineWaveBuffer(frequency: 440.0, frameCount: 4_800))

        // 1 s of system audio queued while the mic starts (first start or device-change restart) is flushed right after
        // `engine.start()`, so fresh mic audio is not mixed against it. Engine-level start needs a real mic, so test the mixer.
        mixer.appendSystemAudioBuffer(oneSecond, mixWithMic: true)
        mixer.flushSecondary()
        mixer.appendMicrophoneBuffer(mic)
        mixer.close()

        let readFile = try AVAudioFile(forReading: outputURL)
        XCTAssertGreaterThanOrEqual(Double(readFile.length) / readFile.fileFormat.sampleRate, 1.08)
    }
}
