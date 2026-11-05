import AppKit
import AVFoundation
import Speech
import SwiftUI
import XCTest
@testable import BitzCore

// MARK: - Test Doubles

final class MockMeetingAudioCaptureEngine: MeetingAudioCapturing, @unchecked Sendable {
    var startCallCount = 0
    var stopCallCount = 0
    var lastOutputURL: URL?
    var lastCaptureMic = false
    var lastCaptureSystem = false
    var shouldThrowOnStart: Error?

    func startCapture(
        outputFileURL: URL,
        captureMicrophone: Bool,
        captureSystemAudio: Bool
    ) async throws {
        if let error = shouldThrowOnStart {
            throw error
        }
        startCallCount += 1
        lastOutputURL = outputFileURL
        lastCaptureMic = captureMicrophone
        lastCaptureSystem = captureSystemAudio

        // Write a valid 48kHz stereo AAC .m4a file so downstream readers see a real audio container
        let mixer = try MeetingAudioStreamMixer(outputFileURL: outputFileURL)
        if let buffer = Self.makeSineWaveBuffer(frequency: 440.0, frameCount: 4_800) {
            mixer.appendMicrophoneBuffer(buffer)
        }
        mixer.close()
    }

    func stopCapture() async {
        stopCallCount += 1
    }

    static func makeSineWaveBuffer(
        frequency: Double,
        frameCount: AVAudioFrameCount,
        sampleRate: Double = 48_000,
        amplitude: Float = 0.6
    ) -> AVAudioPCMBuffer? {
        let format = MeetingAudioStreamMixer.canonicalPCMFormat
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount),
              let channels = buffer.floatChannelData else {
            return nil
        }
        buffer.frameLength = frameCount
        for i in 0..<Int(frameCount) {
            let sample = Float(sin(2.0 * .pi * frequency * Double(i) / sampleRate)) * amplitude
            channels[0][i] = sample
            channels[1][i] = sample
        }
        return buffer
    }
}

struct MockMeetingTranscriptionService: MeetingTranscriptionProviding {
    var segments: [MeetingTranscriptSegment] = [
        MeetingTranscriptSegment(text: "Hello", startTime: 0.5, endTime: 1.0, confidence: 0.96),
        MeetingTranscriptSegment(text: "team.", startTime: 1.0, endTime: 1.6, confidence: 0.94),
        MeetingTranscriptSegment(text: "Let's", startTime: 12.0, endTime: 12.4, confidence: 0.95),
        MeetingTranscriptSegment(text: "ship", startTime: 12.4, endTime: 12.8, confidence: 0.98),
        MeetingTranscriptSegment(text: "Bitz.", startTime: 12.8, endTime: 13.4, confidence: 0.97)
    ]
    var fullText: String = "Hello team. Let's ship Bitz."

    func transcribe(
        audioFileURL: URL,
        sessionID: String,
        locale: Locale
    ) async throws -> MeetingTranscript {
        MeetingTranscript(
            sessionID: sessionID,
            localeIdentifier: locale.identifier,
            generatedAt: Date(timeIntervalSince1970: 1_762_340_000),
            fullText: fullText,
            segments: segments
        )
    }
}

struct MockMeetingPermissionChecker: MeetingPermissionChecking {
    var state: MeetingPermissionState

    func currentPermissions() -> MeetingPermissionState {
        state
    }

    func requestPermissions(
        captureMicrophone: Bool,
        captureSystemAudio: Bool,
        transcribe: Bool
    ) async -> MeetingPermissionState {
        state
    }
}

// MARK: - Meeting Recorder Tests

@MainActor
final class MeetingRecorderServiceTests: XCTestCase {
    private var suiteName: String!
    private var defaults: UserDefaults!
    private var tempDir: URL!

    override func setUp() async throws {
        suiteName = "MeetingRecorderServiceTests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)!
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("bitz-meetings-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        defaults.removePersistentDomain(forName: suiteName)
        try? FileManager.default.removeItem(at: tempDir)
    }

    func testMeetingSettingsStorePersistsPreferencesAndFormatsDuration() {
        let store = MeetingSettingsStore(userDefaults: defaults)
        XCTAssertTrue(store.captureMicrophone)
        XCTAssertTrue(store.captureSystemAudio)
        XCTAssertTrue(store.autoTranscribeOnStop)
        XCTAssertFalse(store.copyTranscriptPathToClipboard)
        XCTAssertTrue(store.meetingsRootDirectoryURL.path.hasSuffix("/Documents/Bitz/Meetings"))

        store.setCaptureMicrophone(false)
        store.setCaptureSystemAudio(true)
        store.setAutoTranscribeOnStop(false)
        store.setCopyTranscriptPathToClipboard(true)
        store.setMeetingsRootDirectoryURL(tempDir)

        let reloaded = MeetingSettingsStore(userDefaults: defaults)
        XCTAssertFalse(reloaded.captureMicrophone)
        XCTAssertTrue(reloaded.captureSystemAudio)
        XCTAssertFalse(reloaded.autoTranscribeOnStop)
        XCTAssertTrue(reloaded.copyTranscriptPathToClipboard)
        XCTAssertEqual(reloaded.meetingsRootDirectoryURL.path, tempDir.path)

        XCTAssertEqual(MeetingSettingsStore.formatDuration(0), "00:00")
        XCTAssertEqual(MeetingSettingsStore.formatDuration(872), "14:32")
        XCTAssertEqual(MeetingSettingsStore.formatDuration(3_725), "01:02:05")

        let fixedDate = Date(timeIntervalSince1970: 1_762_340_700) // 2025-11-05 11:05:00 UTC
        let folder = MeetingSettingsStore.sessionFolderName(for: fixedDate, timeZone: TimeZone(secondsFromGMT: 0)!)
        XCTAssertEqual(folder, "2025-11-05_11-05-00")
    }

    func testSpeechFrameworkRequestRequiresOnDeviceRecognition() {
        let dummyURL = tempDir.appendingPathComponent("audio.m4a")
        let request = SpeechFrameworkTranscriptionService.makeRecognitionRequest(
            audioFileURL: dummyURL,
            enforceOnDevice: true
        )
        XCTAssertTrue(request.requiresOnDeviceRecognition, "Must enforce 100% offline on-device recognition")
        XCTAssertFalse(request.shouldReportPartialResults)
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

    func testEndToEndRecordingAndOnDeviceTranscriptionExportsFilesAndRevealsInFinder() async throws {
        let settings = MeetingSettingsStore(userDefaults: defaults)
        settings.setMeetingsRootDirectoryURL(tempDir)

        let captureEngine = MockMeetingAudioCaptureEngine()
        let transcriptionService = MockMeetingTranscriptionService()
        let permissions = MockMeetingPermissionChecker(
            state: MeetingPermissionState(
                microphone: .authorized,
                screenAudio: .authorized,
                speechRecognition: .authorized
            )
        )

        var currentClock = Date(timeIntervalSince1970: 1_762_340_000)
        var revealedURLs: [URL] = []
        var playedSounds: [CyberSoundEvent] = []

        let service = MeetingRecorderService(
            settingsStore: settings,
            captureEngine: captureEngine,
            transcriptionService: transcriptionService,
            permissionChecker: permissions,
            nowProvider: { currentClock },
            onRevealURL: { url in revealedURLs.append(url) }
        )
        service.onPlaySound = { event in playedSounds.append(event) }

        await service.startRecording()
        XCTAssertTrue(service.isRecording)
        XCTAssertEqual(captureEngine.startCallCount, 1)
        XCTAssertEqual(service.activeSpeechBubbleText, "🔴 Recording meeting (00:00)...")

        // Advance clock by 45 seconds and stop recording
        currentClock = currentClock.addingTimeInterval(45)
        await service.stopRecording()

        XCTAssertFalse(service.isRecording)
        XCTAssertFalse(service.isTranscribing)
        XCTAssertEqual(captureEngine.stopCallCount, 1)
        XCTAssertEqual(playedSounds, [.charging, .allAgentsDone])
        XCTAssertTrue(service.isInteractiveBubbleActive)
        XCTAssertEqual(service.activeSpeechBubbleText, "✨ Meeting saved & transcribed!")

        let result = try XCTUnwrap(service.lastCompletedResult)
        XCTAssertEqual(result.durationSeconds, 45, accuracy: 0.01)
        XCTAssertTrue(FileManager.default.fileExists(atPath: result.audioFileURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: result.metadataFileURL.path))

        let txtURL = try XCTUnwrap(result.transcriptTextURL)
        let jsonURL = try XCTUnwrap(result.transcriptJSONURL)
        let txtContent = try String(contentsOf: txtURL, encoding: .utf8)
        XCTAssertTrue(txtContent.contains("[00:00] Hello team."))
        XCTAssertTrue(txtContent.contains("[00:12] Let's ship Bitz."))

        let jsonData = try Data(contentsOf: jsonURL)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let decodedTranscript = try decoder.decode(MeetingTranscript.self, from: jsonData)
        XCTAssertEqual(decodedTranscript.segments.count, 5)
        XCTAssertEqual(decodedTranscript.fullText, "Hello team. Let's ship Bitz.")

        let metaData = try Data(contentsOf: result.metadataFileURL)
        let decodedMeta = try decoder.decode(MeetingRecordingMetadata.self, from: metaData)
        XCTAssertEqual(decodedMeta.transcriptStatus, "completed")
        XCTAssertEqual(decodedMeta.audioFileName, "audio.m4a")

        // One-click reveal in Finder dismisses completion bubble and opens session directory
        service.revealInFinder()
        XCTAssertEqual(revealedURLs, [result.sessionDirectoryURL])
        XCTAssertFalse(service.isInteractiveBubbleActive)
    }

    func testMissingPermissionsShowsGracefulErrorAndDoesNotStartCapture() async {
        let settings = MeetingSettingsStore(userDefaults: defaults)
        settings.setMeetingsRootDirectoryURL(tempDir)

        let captureEngine = MockMeetingAudioCaptureEngine()
        let permissions = MockMeetingPermissionChecker(
            state: MeetingPermissionState(
                microphone: .denied,
                screenAudio: .authorized,
                speechRecognition: .authorized
            )
        )

        let service = MeetingRecorderService(
            settingsStore: settings,
            captureEngine: captureEngine,
            transcriptionService: MockMeetingTranscriptionService(),
            permissionChecker: permissions
        )

        await service.startRecording()
        XCTAssertFalse(service.isRecording)
        XCTAssertEqual(captureEngine.startCallCount, 0)
        if case .failed(let message) = service.state {
            XCTAssertTrue(message.contains("Microphone"))
        } else {
            XCTFail("Expected .failed state when Microphone permission is denied")
        }
    }

    func testGlobalHotkeyOptionShiftRTogglesMeetingRecording() throws {
        let settings = MeetingSettingsStore(userDefaults: defaults)
        settings.setMeetingsRootDirectoryURL(tempDir)
        let captureEngine = MockMeetingAudioCaptureEngine()
        let permissions = MockMeetingPermissionChecker(
            state: MeetingPermissionState(
                microphone: .authorized,
                screenAudio: .authorized,
                speechRecognition: .authorized
            )
        )
        let recorder = MeetingRecorderService(
            settingsStore: settings,
            captureEngine: captureEngine,
            transcriptionService: MockMeetingTranscriptionService(),
            permissionChecker: permissions
        )
        let delegate = BitzAppDelegate(
            meetingSettings: settings,
            meetingRecorder: recorder,
            userDefaults: defaults
        )

        let optShiftREvent = try XCTUnwrap(
            NSEvent.keyEvent(
                with: .keyDown,
                location: .zero,
                modifierFlags: [.option, .shift],
                timestamp: 0,
                windowNumber: 0,
                context: nil,
                characters: "R",
                charactersIgnoringModifiers: "r",
                isARepeat: false,
                keyCode: 15
            )
        )

        let handled = delegate.handleKeyEvent(optShiftREvent, isGlobal: true)
        XCTAssertTrue(handled, "⌥⇧R must be handled globally from any app")
    }
}
