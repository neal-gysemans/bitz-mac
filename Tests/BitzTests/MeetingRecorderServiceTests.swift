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
    var lastSessionDirectoryURL: URL?
    var lastCaptureMic = false
    var lastCaptureSystem = false
    var shouldThrowOnStart: Error?
    var startDelayNanoseconds: UInt64 = 0
    var stopDelayNanoseconds: UInt64 = 0
    var trackFileName = MeetingTrackWriter.micFileName
    var trackFrameCount: AVAudioFrameCount = 4_800
    /// Puts a folder at audio.m4a, so the stop-time mix fails and the track is kept.
    var blocksMixOutput = false
    var onCaptureInterrupted: (@Sendable (MeetingCaptureSource, String) -> Void)?

    func startCapture(
        sessionDirectoryURL: URL,
        captureMicrophone: Bool,
        captureSystemAudio: Bool
    ) async throws {
        if startDelayNanoseconds > 0 {
            try? await Task.sleep(nanoseconds: startDelayNanoseconds)
        }
        if let error = shouldThrowOnStart {
            throw error
        }
        startCallCount += 1
        lastSessionDirectoryURL = sessionDirectoryURL
        lastCaptureMic = captureMicrophone
        lastCaptureSystem = captureSystemAudio

        // Write a real track, so the stop-time mix produces a valid audio.m4a
        let writer = try MeetingTrackWriter(
            fileURL: sessionDirectoryURL.appendingPathComponent(trackFileName),
            sessionStartHostSeconds: 0
        )
        if trackFrameCount > 0, let buffer = Self.makeSineWaveBuffer(frequency: 440.0, frameCount: trackFrameCount) {
            writer.append(buffer, hostSeconds: nil)
        }
        writer.close()
        if blocksMixOutput {
            try FileManager.default.createDirectory(at: sessionDirectoryURL.appendingPathComponent("audio.m4a"), withIntermediateDirectories: false)
        }
    }

    func stopCapture() async {
        stopCallCount += 1
        if stopDelayNanoseconds > 0 {
            try? await Task.sleep(nanoseconds: stopDelayNanoseconds)
        }
    }

    static func makeSineWaveBuffer(
        frequency: Double,
        frameCount: AVAudioFrameCount,
        sampleRate: Double = 48_000,
        amplitude: Float = 0.6
    ) -> AVAudioPCMBuffer? {
        let format = MeetingTrackWriter.canonicalPCMFormat
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
    var error: Error?
    var delayNanoseconds: UInt64 = 0
    var onTranscribe: (@Sendable (URL) -> Void)?
    /// Checked on each call, so one service can succeed first and fail later; nil means `error` always applies.
    var failsNow: (@Sendable () -> Bool)?

    func transcribe(
        audioFileURL: URL,
        sessionID: String,
        locale: Locale?
    ) async throws -> MeetingTranscript {
        onTranscribe?(audioFileURL)
        if delayNanoseconds > 0 {
            try? await Task.sleep(nanoseconds: delayNanoseconds)
        }
        if let error, failsNow?() ?? true { throw error }
        return MeetingTranscript(
            sessionID: sessionID,
            localeIdentifier: locale?.identifier ?? "en-US",
            generatedAt: Date(timeIntervalSince1970: 1_762_340_000),
            fullText: fullText,
            segments: segments
        )
    }
}

struct MockMeetingPermissionChecker: MeetingPermissionChecking {
    var state: MeetingPermissionState
    /// What a request returns (the user answered the prompts); `state` when nil.
    var stateAfterRequest: MeetingPermissionState?
    /// Called with (captureMicrophone, captureSystemAudio, transcribe) on each request.
    var onRequest: (@Sendable (Bool, Bool, Bool) -> Void)?

    func currentPermissions() -> MeetingPermissionState {
        state
    }

    func requestPermissions(
        captureMicrophone: Bool,
        captureSystemAudio: Bool,
        transcribe: Bool
    ) async -> MeetingPermissionState {
        onRequest?(captureMicrophone, captureSystemAudio, transcribe)
        return stateAfterRequest ?? state
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
        XCTAssertTrue(store.meetingsRootDirectoryURL.path.hasSuffix("/Library/Application Support/Bitz/Meetings"))
        XCTAssertTrue(store.isUsingDefaultMeetingsDirectory)

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
        XCTAssertFalse(reloaded.isUsingDefaultMeetingsDirectory)

        reloaded.setMeetingsRootDirectoryURL(nil)
        XCTAssertEqual(MeetingSettingsStore(userDefaults: defaults).meetingsRootDirectoryURL, MeetingSettingsStore.defaultMeetingsDirectoryURL)
        XCTAssertTrue(MeetingSettingsStore(userDefaults: defaults).isUsingDefaultMeetingsDirectory)

        XCTAssertEqual(MeetingFormatting.formatDuration(0), "00:00")
        XCTAssertEqual(MeetingFormatting.formatDuration(872), "14:32")
        XCTAssertEqual(MeetingFormatting.formatDuration(3_725), "01:02:05")

        let fixedDate = Date(timeIntervalSince1970: 1_762_340_700) // 2025-11-05 11:05:00 UTC
        let folder = MeetingFormatting.sessionFolderName(for: fixedDate, timeZone: TimeZone(secondsFromGMT: 0)!)
        XCTAssertEqual(folder, "2025-11-05_11-05-00")
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
        XCTAssertEqual(service.bubble, .recording)
        XCTAssertEqual(playedSounds, [.meetingRecordingStarted])

        // Advance clock by 45 seconds and stop recording
        currentClock = currentClock.addingTimeInterval(45)
        await service.stopRecording()

        XCTAssertFalse(service.isRecording)
        XCTAssertFalse(service.isTranscribing)
        XCTAssertEqual(captureEngine.stopCallCount, 1)
        XCTAssertEqual(playedSounds, [.meetingRecordingStarted, .meetingRecordingSaved], "each chime exactly once")
        XCTAssertEqual(service.bubble?.text, MeetingBubble.savedAndTranscribedText)
        XCTAssertEqual(service.bubble?.actions, [.openInFinder, .dismiss])

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

        // Meeting data is owner-only: 0700 session dir, 0600 files (atomic rewrites included)
        func posixMode(_ url: URL) throws -> Int {
            try XCTUnwrap(FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? NSNumber).intValue
        }
        XCTAssertEqual(try posixMode(result.sessionDirectoryURL), 0o700)
        for file in [result.audioFileURL, result.metadataFileURL, txtURL, jsonURL] {
            XCTAssertEqual(try posixMode(file), 0o600, file.lastPathComponent)
        }
        XCTAssertEqual(decodedMeta.transcriptLocale, "en-US", "metadata.json records the locale actually used")
        XCTAssertEqual(decodedMeta.audioFileNames, ["audio.m4a"], "the verified mix replaced the tracks")
        XCTAssertEqual(decodedMeta.audioStatus, "mixed")
        XCTAssertNil(decodedMeta.recovered)

        // One-click reveal in Finder dismisses completion bubble and opens session directory
        service.revealInFinder()
        XCTAssertEqual(revealedURLs, [result.sessionDirectoryURL])
        XCTAssertNil(service.bubble)
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
        XCTAssertEqual(service.bubble, .failure(MeetingBubble.needsPermissionText, detail: "Microphone"))
        XCTAssertEqual(service.bubble?.actions, [.openSettings, .dismiss])
    }

    // MARK: - Recording lifecycle and failure handling

    private func makeService(
        captureEngine: MockMeetingAudioCaptureEngine,
        transcription: MockMeetingTranscriptionService = MockMeetingTranscriptionService(),
        microphone: MeetingPermissionState.Status = .authorized,
        speechRecognition: MeetingPermissionState.Status = .authorized,
        nowProvider: @escaping () -> Date = { Date() },
        freeBytes: Int64? = .max,
        permissionChecker: MockMeetingPermissionChecker? = nil
    ) -> MeetingRecorderService {
        let settings = MeetingSettingsStore(userDefaults: defaults)
        settings.setMeetingsRootDirectoryURL(tempDir)
        return MeetingRecorderService(
            settingsStore: settings,
            captureEngine: captureEngine,
            transcriptionService: transcription,
            permissionChecker: permissionChecker ?? MockMeetingPermissionChecker(
                state: MeetingPermissionState(microphone: microphone, screenAudio: .authorized, speechRecognition: speechRecognition)
            ),
            nowProvider: nowProvider,
            freeBytesProvider: { _ in freeBytes },
            onRevealURL: { _ in }
        )
    }

    private func decodeMetadata(_ url: URL) throws -> MeetingRecordingMetadata {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(MeetingRecordingMetadata.self, from: Data(contentsOf: url))
    }

    func testDoubleStartOnlyStartsCaptureOnce() async {
        let captureEngine = MockMeetingAudioCaptureEngine()
        captureEngine.startDelayNanoseconds = 50_000_000
        let service = makeService(captureEngine: captureEngine)

        let first = Task { await service.startRecording() }
        let second = Task { await service.startRecording() }
        await first.value
        await second.value

        XCTAssertEqual(captureEngine.startCallCount, 1)
        XCTAssertTrue(service.isRecording)
    }

    func testStartDuringStopIsRejectedAndRecordingStaysStoppable() async {
        let captureEngine = MockMeetingAudioCaptureEngine()
        let service = makeService(captureEngine: captureEngine)
        await service.startRecording()
        XCTAssertTrue(service.isRecording)

        captureEngine.stopDelayNanoseconds = 50_000_000
        let stop = Task { await service.stopRecording() }
        while captureEngine.stopCallCount == 0 {
            await Task.yield()
        }
        await service.startRecording()
        await stop.value

        XCTAssertEqual(captureEngine.startCallCount, 1, "A start landing mid-stop must be rejected")
        XCTAssertFalse(service.isRecording)
        XCTAssertFalse(service.hasUnfinalizedRecording)

        // A later start/stop cycle still works end to end
        captureEngine.stopDelayNanoseconds = 0
        await service.startRecording()
        XCTAssertTrue(service.isRecording)
        await service.stopRecording()
        XCTAssertFalse(service.isRecording)
        XCTAssertEqual(captureEngine.stopCallCount, 2)
    }

    func testFinalizeForTerminationWritesMetadataWithoutTranscribing() async throws {
        let captureEngine = MockMeetingAudioCaptureEngine()
        let service = makeService(captureEngine: captureEngine)
        await service.startRecording()
        XCTAssertTrue(service.hasUnfinalizedRecording)

        await service.finalizeForTermination()

        XCTAssertFalse(service.hasUnfinalizedRecording)
        let result = try XCTUnwrap(service.lastCompletedResult)
        XCTAssertNil(result.transcriptTextURL)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let meta = try decoder.decode(MeetingRecordingMetadata.self, from: Data(contentsOf: result.metadataFileURL))
        XCTAssertEqual(meta.transcriptStatus, "skipped")
    }

    func testFailureBubbleStaysUntilDismissedAndOpenSettingsOpensAudioSettings() async throws {
        let sleeper = ManualSleeper()
        let service = makeService(captureEngine: MockMeetingAudioCaptureEngine(), microphone: .denied)
        service.sleep = sleeper.sleep
        var openedSettings = 0
        service.onOpenSettings = { openedSettings += 1 }

        await service.startRecording()
        XCTAssertEqual(service.bubble?.kind, .failure)
        XCTAssertNil(service.bubbleHideTask, "no auto-dismiss is scheduled")
        XCTAssertTrue(sleeper.requested.isEmpty)

        service.perform(.openSettings)
        XCTAssertEqual(openedSettings, 1)
        XCTAssertNil(service.bubble)
        XCTAssertEqual(service.state, .idle)

        await service.startRecording()
        service.perform(.dismiss)
        XCTAssertNil(service.bubble)
        XCTAssertEqual(openedSettings, 1)
    }

    func testFailureTextsAreSingleClauseHeadlines() async throws {
        let noSource = makeService(captureEngine: MockMeetingAudioCaptureEngine())
        noSource.settingsStore.setCaptureMicrophone(false)
        noSource.settingsStore.setCaptureSystemAudio(false)
        await noSource.startRecording()
        XCTAssertEqual(noSource.bubble?.text, MeetingBubble.noSourceText)
        noSource.settingsStore.setCaptureMicrophone(true)
        noSource.settingsStore.setCaptureSystemAudio(true)

        let full = makeService(captureEngine: MockMeetingAudioCaptureEngine(), freeBytes: 1_000)
        await full.startRecording()
        XCTAssertEqual(full.bubble?.text, MeetingBubble.lowDiskText)

        let broken = MockMeetingAudioCaptureEngine()
        broken.shouldThrowOnStart = MeetingRecorderError.captureStartFailed("No active display found.")
        let failing = makeService(captureEngine: broken)
        await failing.startRecording()
        XCTAssertEqual(failing.bubble?.text, MeetingBubble.couldNotStartText)
        XCTAssertEqual(failing.bubble?.detail, "No active display found.", "no stacked \"Could not start audio capture:\" prefix")
        XCTAssertEqual(failing.statusMessage, "Could not start audio capture: No active display found.")
    }

    // MARK: - Bubble visibility and timing (D5)

    func testRecordingBubbleHidesAfterFiveSecondsAndCompletionAfterFortyFive() async throws {
        let sleeper = ManualSleeper()
        let service = makeService(captureEngine: MockMeetingAudioCaptureEngine())
        service.sleep = sleeper.sleep

        await service.startRecording()
        XCTAssertEqual(service.bubble, .recording)
        await sleeper.waitForRequests(1)
        XCTAssertEqual(sleeper.requested, [.seconds(5)])
        sleeper.releaseAll()
        await service.bubbleHideTask?.value
        XCTAssertNil(service.bubble, "the start bubble hides; LED and menu bar REC stay")
        XCTAssertTrue(service.isRecording)

        await service.stopRecording()
        XCTAssertEqual(service.bubble?.kind, .completion)
        await sleeper.waitForRequests(2)
        XCTAssertEqual(sleeper.requested.last, .seconds(45))
        sleeper.releaseAll()
        await service.bubbleHideTask?.value
        XCTAssertNil(service.bubble)
    }

    func testANewBubbleCancelsTheOldOnesAutoHide() async throws {
        let sleeper = ManualSleeper()
        let service = makeService(captureEngine: MockMeetingAudioCaptureEngine())
        service.sleep = sleeper.sleep

        await service.startRecording()
        await sleeper.waitForRequests(1)
        service.handleCaptureInterruption(.microphone, "Microphone stopped after an audio device change: gone")
        sleeper.releaseAll()
        await Task.yield()
        XCTAssertEqual(service.bubble?.kind, .interruption, "the 5 s timer of the start bubble must not hide the warning")
        XCTAssertNil(service.bubbleHideTask, "an interruption stays until dismissed")
        await service.stopRecording(transcribe: false)
    }

    func testSavingStateBetweenStopAndMix() async throws {
        let captureEngine = MockMeetingAudioCaptureEngine()
        captureEngine.stopDelayNanoseconds = 50_000_000
        let service = makeService(captureEngine: captureEngine)
        await service.startRecording()

        let stop = Task { await service.stopRecording() }
        while captureEngine.stopCallCount == 0 {
            await Task.yield()
        }
        XCTAssertTrue(service.isSaving)
        XCTAssertFalse(service.isRecording)
        XCTAssertEqual(service.bubble, .saving)
        XCTAssertEqual(service.busyMenuLabel, MeetingBubble.savingMenuLabel)

        // The hotkey during saving neither starts a recording nor drops the saving bubble
        await service.toggleRecording()
        XCTAssertEqual(captureEngine.startCallCount, 1)
        XCTAssertEqual(service.bubble, .saving)
        await stop.value
        XCTAssertNil(service.busyMenuLabel)
    }

    func testTranscribingShowsBusyMenuLabel() async throws {
        var transcription = MockMeetingTranscriptionService()
        transcription.delayNanoseconds = 100_000_000
        let service = makeService(captureEngine: MockMeetingAudioCaptureEngine(), transcription: transcription)
        await service.startRecording()
        let stop = Task { await service.stopRecording() }
        while !service.isTranscribing {
            await Task.yield()
        }
        XCTAssertEqual(service.busyMenuLabel, MeetingBubble.transcribingMenuLabel)
        XCTAssertEqual(service.bubble, .transcribing)
        await stop.value
    }

    func testInterruptionsPickTheirTextAndAreAcceptedWhileStopping() async throws {
        let captureEngine = MockMeetingAudioCaptureEngine()
        let service = makeService(captureEngine: captureEngine)
        await service.startRecording()

        service.handleCaptureInterruption(.microphone, "Microphone stopped after an audio device change: unplugged")
        XCTAssertEqual(service.bubble?.text, MeetingBubble.micLostSystemContinuesText)
        XCTAssertEqual(service.bubble?.actions, [.dismiss])
        XCTAssertTrue(service.statusMessage.contains("unplugged"))
        service.handleCaptureInterruption(.systemAudio, "System audio capture stopped: gone")
        XCTAssertEqual(service.bubble?.text, MeetingBubble.systemLostNothingLeftText, "the mic already dropped")

        // Reported while finalizing: no bubble over "Saving…", but the warning reaches the result
        captureEngine.stopDelayNanoseconds = 50_000_000
        let stop = Task { await service.stopRecording(transcribe: false) }
        while captureEngine.stopCallCount == 0 {
            await Task.yield()
        }
        service.handleCaptureInterruption(.storage, "Could not write meeting audio: disk full")
        XCTAssertEqual(service.bubble, .saving)
        await stop.value
        XCTAssertEqual(service.lastCompletedResult?.warning, "Could not write meeting audio: disk full")

        // Idle: ignored
        service.handleCaptureInterruption(.microphone, "late")
        XCTAssertFalse(service.statusMessage.contains("late"))

        let micOnly = makeService(captureEngine: MockMeetingAudioCaptureEngine())
        micOnly.settingsStore.setCaptureSystemAudio(false)
        await micOnly.startRecording()
        micOnly.handleCaptureInterruption(.microphone, "gone")
        XCTAssertEqual(micOnly.bubble?.text, MeetingBubble.micLostNothingLeftText)
        micOnly.handleCaptureInterruption(.storage, "disk")
        XCTAssertEqual(micOnly.bubble?.text, MeetingBubble.storageFailedText)
        await micOnly.stopRecording(transcribe: false)
        micOnly.settingsStore.setCaptureSystemAudio(true)
    }

    // MARK: - Delegate wiring (D5)

    func testMenuBarRecIndicatorFollowsRecording() async throws {
        let service = makeService(captureEngine: MockMeetingAudioCaptureEngine())
        let delegate = BitzAppDelegate(meetingSettings: service.settingsStore, meetingRecorder: service, userDefaults: defaults)
        XCTAssertFalse(delegate.isRecordingIndicatorVisible)

        await service.startRecording()
        XCTAssertTrue(delegate.isRecordingIndicatorVisible)
        service.dismissBubble()
        XCTAssertTrue(delegate.isRecordingIndicatorVisible, "REC stays after the start bubble hides")

        await service.stopRecording(transcribe: false)
        XCTAssertFalse(delegate.isRecordingIndicatorVisible)
    }

    func testPersonalityPausesWhileRecordingOrAMeetingBubbleShows() async throws {
        let personalitySettings = PersonalitySettingsStore(userDefaults: defaults)
        personalitySettings.setEnabled(true)
        let generator = StubCommentaryGenerator(stubbedResult: .success("Meow during your meeting"))
        let personality = PersonalityService(primaryGenerator: generator, fallbackGenerator: generator, settingsStore: personalitySettings)
        let service = makeService(captureEngine: MockMeetingAudioCaptureEngine())
        let delegate = BitzAppDelegate(
            personalitySettings: personalitySettings,
            personalityService: personality,
            meetingSettings: service.settingsStore,
            meetingRecorder: service,
            userDefaults: defaults
        )
        // Let the launch-time tick from enabling personality finish first
        for _ in 0..<40 where delegate.engine.idleCommentaryText == nil {
            try await Task.sleep(nanoseconds: 25_000_000)
        }
        XCTAssertNotNil(delegate.engine.idleCommentaryText)
        generator.lastGeneratedContext = nil

        await service.startRecording()
        service.dismissBubble() // the start bubble is gone; the recording still pauses commentary
        delegate.triggerPersonalityTick(bypassRateLimit: true)
        XCTAssertNil(delegate.engine.idleCommentaryText, "the old line is cleared for the recording")
        await service.stopRecording(transcribe: false)
        XCTAssertEqual(service.bubble?.kind, .completion)
        delegate.triggerPersonalityTick(bypassRateLimit: true)
        for _ in 0..<4 { await Task.yield() }
        XCTAssertNil(generator.lastGeneratedContext, "no commentary is generated while recording or under a meeting bubble")
        XCTAssertNil(delegate.engine.idleCommentaryText)

        // Control: once the bubble is dismissed, the same tick produces commentary again
        service.dismissBubble()
        delegate.triggerPersonalityTick(bypassRateLimit: true)
        for _ in 0..<40 where delegate.engine.idleCommentaryText == nil {
            try await Task.sleep(nanoseconds: 25_000_000)
        }
        XCTAssertNotNil(generator.lastGeneratedContext)
        XCTAssertEqual(delegate.engine.idleCommentaryText, "Meow during your meeting")
    }

    func testBubblePriorityLadder() {
        let ladder: [MeetingBubble.Priority] = [.thermal, .failure, .interruption, .recording, .progress, .completion, .personality]
        XCTAssertEqual(ladder, ladder.sorted(by: >))
        let result = MeetingRecordingResult(
            sessionID: "s", sessionDirectoryURL: tempDir, audioFileURL: tempDir, metadataFileURL: tempDir, durationSeconds: 1
        )
        XCTAssertEqual(MeetingBubble.failure(MeetingBubble.needsPermissionText).priority, .failure)
        XCTAssertEqual(MeetingBubble.interruption(.microphone, remaining: [.systemAudio]).priority, .interruption)
        XCTAssertEqual(MeetingBubble.recording.priority, .recording)
        XCTAssertEqual(MeetingBubble.saving.priority, .progress)
        XCTAssertEqual(MeetingBubble.transcribing.priority, .progress)
        XCTAssertEqual(MeetingBubble.completion(for: result).priority, .completion)
        // Only bubbles with buttons take clicks
        XCTAssertFalse(MeetingBubble.recording.isInteractive)
        XCTAssertFalse(MeetingBubble.saving.isInteractive)
        XCTAssertTrue(MeetingBubble.failure("x").isInteractive)
        XCTAssertTrue(MeetingBubble.completion(for: result).isInteractive)
    }

    func testFailedStartRemovesEmptySessionFolder() async throws {
        let captureEngine = MockMeetingAudioCaptureEngine()
        captureEngine.shouldThrowOnStart = MeetingRecorderError.captureStartFailed("boom")
        let service = makeService(captureEngine: captureEngine)

        await service.startRecording()

        let contents = try FileManager.default.contentsOfDirectory(atPath: tempDir.path)
        XCTAssertTrue(contents.isEmpty, "Failed start must not leave an empty session folder: \(contents)")
    }

    func testSessionFolderCollisionGetsSuffixAndKeepsFirstRecording() async throws {
        let clock = Date(timeIntervalSince1970: 1_762_340_000)
        let captureEngine = MockMeetingAudioCaptureEngine()
        let service = makeService(captureEngine: captureEngine, nowProvider: { clock })

        await service.startRecording()
        await service.stopRecording(transcribe: false)
        let first = try XCTUnwrap(service.lastCompletedResult)
        let firstAudio = try Data(contentsOf: first.audioFileURL)
        let firstMetadata = try Data(contentsOf: first.metadataFileURL)

        // Same second, same folder name: the second recording must not reuse or clear the first folder
        await service.startRecording()
        await service.stopRecording(transcribe: false)
        let second = try XCTUnwrap(service.lastCompletedResult)

        let baseName = MeetingFormatting.sessionFolderName(for: clock)
        XCTAssertEqual(first.sessionDirectoryURL.lastPathComponent, baseName)
        XCTAssertEqual(second.sessionDirectoryURL.lastPathComponent, "\(baseName)-2")
        XCTAssertEqual(second.sessionID, "\(baseName)-2")
        XCTAssertEqual(try Data(contentsOf: first.audioFileURL), firstAudio)
        XCTAssertEqual(try Data(contentsOf: first.metadataFileURL), firstMetadata)
        XCTAssertTrue(FileManager.default.fileExists(atPath: second.audioFileURL.path))
    }

    func testTranscriptionAndCaptureFailuresAreSurfaced() async throws {
        let captureEngine = MockMeetingAudioCaptureEngine()
        var transcription = MockMeetingTranscriptionService()
        transcription.error = MeetingTranscriptionError.timedOut(60)
        let service = makeService(captureEngine: captureEngine, transcription: transcription)

        await service.startRecording()
        service.handleCaptureInterruption(.systemAudio, "System audio capture stopped: test")
        XCTAssertTrue(service.statusMessage.contains("System audio capture stopped"))
        XCTAssertEqual(service.bubble?.text, MeetingBubble.systemLostMicContinuesText)
        await service.stopRecording()

        let result = try XCTUnwrap(service.lastCompletedResult)
        let bubble = try XCTUnwrap(service.bubble)
        XCTAssertEqual(bubble.text, MeetingBubble.transcriptFailedText, "one short clause, no stacked prefixes")
        XCTAssertEqual(bubble.detail, "Speech transcription timed out after 60 s. System audio capture stopped: test")
        XCTAssertEqual(bubble.actions, [.transcribeAgain, .openInFinder, .dismiss])
        XCTAssertEqual(MeetingBubble.completion(for: result), bubble)
        XCTAssertTrue(service.statusMessage.contains("timed out"))
    }

    func testQuitDuringTranscriptionMarksMetadataInterrupted() async throws {
        let captureEngine = MockMeetingAudioCaptureEngine()
        var transcription = MockMeetingTranscriptionService()
        transcription.delayNanoseconds = 200_000_000
        let service = makeService(captureEngine: captureEngine, transcription: transcription)
        await service.startRecording()

        let stop = Task { await service.stopRecording() }
        while !service.isTranscribing {
            await Task.yield()
        }
        service.markTranscriptionInterrupted()

        let metadataURL = try XCTUnwrap(captureEngine.lastSessionDirectoryURL)
            .appendingPathComponent("metadata.json")
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let meta = try decoder.decode(MeetingRecordingMetadata.self, from: Data(contentsOf: metadataURL))
        XCTAssertEqual(meta.transcriptStatus, "interrupted")
        await stop.value
    }

    // MARK: - Skipped transcription and Transcribe Again (D4, D6)

    func testSkippedTranscriptSaysWhy() async throws {
        let turnedOff = makeService(captureEngine: MockMeetingAudioCaptureEngine())
        turnedOff.settingsStore.setAutoTranscribeOnStop(false)
        await turnedOff.startRecording()
        await turnedOff.stopRecording()
        let offResult = try XCTUnwrap(turnedOff.lastCompletedResult)
        XCTAssertEqual(offResult.transcriptSkipReason, .transcriptionTurnedOff)
        XCTAssertEqual(turnedOff.bubble?.text, MeetingBubble.transcriptSkippedText)
        XCTAssertEqual(turnedOff.bubble?.detail, "Transcription is turned off.")
        XCTAssertEqual(try decodeMetadata(offResult.metadataFileURL).transcriptStatus, "skipped")

        let notAllowed = makeService(captureEngine: MockMeetingAudioCaptureEngine(), speechRecognition: .denied)
        notAllowed.settingsStore.setMeetingsRootDirectoryURL(tempDir.appendingPathComponent("denied", isDirectory: true))
        notAllowed.settingsStore.setAutoTranscribeOnStop(true) // same defaults suite as the first service
        await notAllowed.startRecording()
        await notAllowed.stopRecording()
        XCTAssertEqual(notAllowed.lastCompletedResult?.transcriptSkipReason, .speechRecognitionNotAllowed)
        XCTAssertEqual(notAllowed.bubble?.text, MeetingBubble.transcriptSkippedText)
        XCTAssertEqual(notAllowed.bubble?.detail, "Speech Recognition is not allowed — Settings → Audio.")
        XCTAssertTrue(notAllowed.statusMessage.contains("Speech Recognition is not allowed"))
    }

    func testTranscribeAgainRewritesTranscriptUpdatesMetadataAndReexports() async throws {
        final class URLLog: @unchecked Sendable { var urls: [URL] = [] }
        let log = URLLog()
        var transcription = MockMeetingTranscriptionService()
        transcription.onTranscribe = { log.urls.append($0) }
        let service = makeService(captureEngine: MockMeetingAudioCaptureEngine(), transcription: transcription)
        service.settingsStore.setMeetingsRootDirectoryURL(tempDir.appendingPathComponent("Meetings", isDirectory: true))
        service.settingsStore.setAutoTranscribeOnStop(false)
        await service.startRecording()
        await service.stopRecording()
        let first = try XCTUnwrap(service.lastCompletedResult)
        XCTAssertNil(first.transcriptTextURL)
        XCTAssertTrue(log.urls.isEmpty)
        XCTAssertTrue(service.canTranscribeAgain)

        let staleTxt = first.sessionDirectoryURL.appendingPathComponent("transcript.txt")
        try "stale".write(to: staleTxt, atomically: true, encoding: .utf8)
        let exportDir = tempDir.appendingPathComponent("Export", isDirectory: true)
        service.settingsStore.setTranscriptExportDirectoryURL(exportDir)
        service.settingsStore.setTranscriptionLocaleIdentifier("nl-BE")

        await service.transcribeAgain()

        let again = try XCTUnwrap(service.lastCompletedResult)
        XCTAssertEqual(log.urls.map(\.lastPathComponent), ["audio.m4a"])
        XCTAssertEqual(again.sessionDirectoryURL, first.sessionDirectoryURL)
        XCTAssertNil(again.transcriptSkipReason)
        XCTAssertNil(again.warning)
        XCTAssertEqual(again.transcriptTextURL, staleTxt)
        XCTAssertTrue(try String(contentsOf: staleTxt, encoding: .utf8).contains("[00:00] Hello team."))
        XCTAssertFalse(service.isTranscribing)
        XCTAssertEqual(service.bubble?.text, MeetingBubble.savedAndTranscribedText)

        let meta = try decodeMetadata(again.metadataFileURL)
        XCTAssertEqual(meta.transcriptStatus, "completed")
        XCTAssertEqual(meta.transcriptLocale, "nl-BE")
        let exported = try XCTUnwrap(meta.transcriptExportPath)
        XCTAssertEqual(try String(contentsOfFile: exported, encoding: .utf8), try String(contentsOf: staleTxt, encoding: .utf8))
        XCTAssertEqual(meta.durationSeconds, first.durationSeconds, accuracy: 0.01, "recording metadata is kept")
    }

    func testTranscribeAgainIsRefusedWhileRecording() async throws {
        final class URLLog: @unchecked Sendable { var urls: [URL] = [] }
        let log = URLLog()
        var transcription = MockMeetingTranscriptionService()
        transcription.onTranscribe = { log.urls.append($0) }
        let service = makeService(captureEngine: MockMeetingAudioCaptureEngine(), transcription: transcription)
        await service.startRecording()
        await service.stopRecording()
        XCTAssertEqual(log.urls.count, 1)

        await service.startRecording()
        XCTAssertTrue(service.isRecording)
        XCTAssertFalse(service.canTranscribeAgain)
        await service.transcribeAgain()
        XCTAssertEqual(log.urls.count, 1, "no transcription while recording")
        XCTAssertTrue(service.isRecording)
        guard case .recording = service.state else { return XCTFail("still recording") }
        await service.stopRecording()
    }

    func testTranscribeAgainAsksOnlyForSpeechWhenNotYetAsked() async throws {
        final class RequestLog: @unchecked Sendable { var requests: [[Bool]] = [] }
        let log = RequestLog()
        var checker = MockMeetingPermissionChecker(
            state: MeetingPermissionState(microphone: .authorized, screenAudio: .authorized, speechRecognition: .notDetermined)
        )
        checker.stateAfterRequest = MeetingPermissionState(microphone: .authorized, screenAudio: .authorized, speechRecognition: .authorized)
        checker.onRequest = { log.requests.append([$0, $1, $2]) }
        let service = makeService(captureEngine: MockMeetingAudioCaptureEngine(), permissionChecker: checker)
        service.settingsStore.setAutoTranscribeOnStop(false)
        await service.startRecording()
        await service.stopRecording()
        XCTAssertEqual(log.requests, [[true, true, false]], "auto-transcribe off: the start does not ask for Speech")

        await service.transcribeAgain()
        XCTAssertEqual(log.requests.last, [false, false, true], "Transcribe Again asks for Speech only")
        let again = try XCTUnwrap(service.lastCompletedResult)
        XCTAssertNotNil(again.transcriptTextURL)
        XCTAssertNil(again.transcriptSkipReason)

        // Settings' "Check / Request Permissions" includes Speech even with auto-transcribe off
        await service.requestPermissions(includeSpeech: true)
        XCTAssertEqual(log.requests.last, [true, true, true])
    }

    func testFailedTranscribeAgainKeepsThePreviousTranscript() async throws {
        final class Flag: @unchecked Sendable { var on = false }
        let fail = Flag()
        var transcription = MockMeetingTranscriptionService()
        transcription.error = NSError(domain: "test", code: 1, userInfo: [NSLocalizedDescriptionKey: "Recognizer crashed"])
        transcription.failsNow = { fail.on }
        let service = makeService(captureEngine: MockMeetingAudioCaptureEngine(), transcription: transcription)
        service.settingsStore.setMeetingsRootDirectoryURL(tempDir.appendingPathComponent("Meetings", isDirectory: true))
        service.settingsStore.setTranscriptExportDirectoryURL(tempDir.appendingPathComponent("Export", isDirectory: true))
        await service.startRecording()
        await service.stopRecording()
        let first = try XCTUnwrap(service.lastCompletedResult)
        let txtURL = try XCTUnwrap(first.transcriptTextURL)
        let transcriptBefore = try Data(contentsOf: txtURL)
        let metadataBefore = try Data(contentsOf: first.metadataFileURL)
        XCTAssertNotNil(try decodeMetadata(first.metadataFileURL).transcriptExportPath)

        fail.on = true
        await service.transcribeAgain()

        let again = try XCTUnwrap(service.lastCompletedResult)
        XCTAssertEqual(again.warning, "Transcribe Again failed — previous transcript kept: Recognizer crashed")
        XCTAssertEqual(again.transcriptTextURL, txtURL)
        XCTAssertEqual(try Data(contentsOf: txtURL), transcriptBefore)
        XCTAssertEqual(try Data(contentsOf: first.metadataFileURL), metadataBefore, "status, locale and export path stay")
        XCTAssertFalse(service.isTranscribing)
    }

    func testReexportReplacesItsOwnCopyButNeverAnotherFile() async throws {
        let service = makeService(captureEngine: MockMeetingAudioCaptureEngine())
        service.settingsStore.setMeetingsRootDirectoryURL(tempDir.appendingPathComponent("Meetings", isDirectory: true))
        let exportDir = tempDir.appendingPathComponent("Export", isDirectory: true)
        service.settingsStore.setTranscriptExportDirectoryURL(exportDir)
        await service.startRecording()
        await service.stopRecording()
        let first = try XCTUnwrap(service.lastCompletedResult)
        let txtURL = try XCTUnwrap(first.transcriptTextURL)
        let exported = URL(fileURLWithPath: try XCTUnwrap(decodeMetadata(first.metadataFileURL).transcriptExportPath))
        let name = exported.lastPathComponent

        // Same folder, previous export still there: overwritten in place, no "(2)" copy
        try "old run".write(to: exported, atomically: true, encoding: .utf8)
        await service.transcribeAgain()
        XCTAssertNil(service.lastCompletedResult?.warning)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: exportDir.path), [name])
        XCTAssertEqual(try Data(contentsOf: exported), try Data(contentsOf: txtURL))
        XCTAssertEqual(try decodeMetadata(first.metadataFileURL).transcriptExportPath, exported.path)

        // Export folder changed and holds an unrelated file of the same name: suffix, nothing overwritten
        let newDir = tempDir.appendingPathComponent("Other Export", isDirectory: true)
        try FileManager.default.createDirectory(at: newDir, withIntermediateDirectories: true)
        try "keep me".write(to: newDir.appendingPathComponent(name), atomically: true, encoding: .utf8)
        service.settingsStore.setTranscriptExportDirectoryURL(newDir)
        await service.transcribeAgain()
        XCTAssertEqual(try String(contentsOf: newDir.appendingPathComponent(name), encoding: .utf8), "keep me")
        let copy = try XCTUnwrap(decodeMetadata(first.metadataFileURL).transcriptExportPath)
        XCTAssertEqual(URL(fileURLWithPath: copy).deletingLastPathComponent().standardizedFileURL.path, newDir.standardizedFileURL.path)
        XCTAssertTrue(copy.hasSuffix("transcript (2).txt"))
        XCTAssertEqual(try Data(contentsOf: exported), try Data(contentsOf: txtURL), "the old folder's copy is left alone")
    }

    // MARK: - Transcription language setting

    func testTranscriptionLocaleSettingPersists() {
        let store = MeetingSettingsStore(userDefaults: defaults)
        XCTAssertNil(store.transcriptionLocaleIdentifier, "Default is Automatic")

        store.setTranscriptionLocaleIdentifier("nl-BE")
        XCTAssertEqual(MeetingSettingsStore(userDefaults: defaults).transcriptionLocaleIdentifier, "nl-BE")

        store.setTranscriptionLocaleIdentifier(nil)
        XCTAssertNil(MeetingSettingsStore(userDefaults: defaults).transcriptionLocaleIdentifier)
    }

    // MARK: - Transcript export folder

    func testTranscriptExportFolderSettingPersists() {
        let store = MeetingSettingsStore(userDefaults: defaults)
        XCTAssertNil(store.transcriptExportDirectoryURL, "Export is off by default")

        let exportDir = tempDir.appendingPathComponent("Inbox", isDirectory: true)
        store.setTranscriptExportDirectoryURL(exportDir)
        XCTAssertEqual(MeetingSettingsStore(userDefaults: defaults).transcriptExportDirectoryURL?.path, exportDir.path)

        store.setTranscriptExportDirectoryURL(nil)
        XCTAssertNil(MeetingSettingsStore(userDefaults: defaults).transcriptExportDirectoryURL)
    }

    func testTranscriptIsCopiedToExportFolderWithoutOverwriting() async throws {
        let clock = Date(timeIntervalSince1970: 1_762_340_000)
        let service = makeService(captureEngine: MockMeetingAudioCaptureEngine(), nowProvider: { clock })
        let exportDir = tempDir.appendingPathComponent("Notes Inbox", isDirectory: true) // created on demand
        service.settingsStore.setMeetingsRootDirectoryURL(tempDir.appendingPathComponent("Meetings", isDirectory: true))
        service.settingsStore.setTranscriptExportDirectoryURL(exportDir)

        let sessionID = MeetingFormatting.sessionFolderName(for: clock)
        try FileManager.default.createDirectory(at: exportDir, withIntermediateDirectories: true)
        let existing = exportDir.appendingPathComponent("\(sessionID) transcript.txt")
        try "keep me".write(to: existing, atomically: true, encoding: .utf8)

        await service.startRecording()
        await service.stopRecording()

        let result = try XCTUnwrap(service.lastCompletedResult)
        XCTAssertNil(result.warning)
        XCTAssertEqual(try String(contentsOf: existing, encoding: .utf8), "keep me", "An existing export must never be overwritten")

        let copy = exportDir.appendingPathComponent("\(sessionID) transcript (2).txt")
        let original = try XCTUnwrap(result.transcriptTextURL)
        XCTAssertEqual(try String(contentsOf: copy, encoding: .utf8), try String(contentsOf: original, encoding: .utf8))
        XCTAssertEqual(
            try FileManager.default.contentsOfDirectory(atPath: exportDir.path).sorted(),
            ["\(sessionID) transcript (2).txt", "\(sessionID) transcript.txt"],
            "Only transcript.txt is exported"
        )

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let meta = try decoder.decode(MeetingRecordingMetadata.self, from: Data(contentsOf: result.metadataFileURL))
        XCTAssertEqual(meta.transcriptExportPath, copy.path)
        let copyPermissions = try FileManager.default.attributesOfItem(atPath: copy.path)[.posixPermissions] as? NSNumber
        XCTAssertEqual(copyPermissions?.intValue, 0o600)
    }

    func testTranscriptExportFailureWarnsButCompletesRecording() async throws {
        let service = makeService(captureEngine: MockMeetingAudioCaptureEngine())
        service.settingsStore.setMeetingsRootDirectoryURL(tempDir.appendingPathComponent("Meetings", isDirectory: true))
        let notAFolder = tempDir.appendingPathComponent("export-is-a-file")
        try "x".write(to: notAFolder, atomically: true, encoding: .utf8)
        service.settingsStore.setTranscriptExportDirectoryURL(notAFolder)

        await service.startRecording()
        await service.stopRecording()

        let result = try XCTUnwrap(service.lastCompletedResult)
        XCTAssertNotNil(result.transcriptTextURL, "The transcript itself is still saved")
        XCTAssertTrue(result.warning?.contains("copy to export folder failed") ?? false)
        XCTAssertTrue(service.statusMessage.contains("copy to export folder failed"))
        XCTAssertEqual(MeetingBubble.completion(for: result).text, MeetingBubble.savedWithWarningText)

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let meta = try decoder.decode(MeetingRecordingMetadata.self, from: Data(contentsOf: result.metadataFileURL))
        XCTAssertEqual(meta.transcriptStatus, "completed")
        XCTAssertNil(meta.transcriptExportPath)
    }

    func testSyncWarningFlagsCloudSyncedFolders() {
        let home = URL(fileURLWithPath: "/Users/tester", isDirectory: true)
        func warning(_ relative: String) -> String? {
            MeetingSettingsStore.syncWarning(for: home.appendingPathComponent(relative), home: home)
        }
        XCTAssertEqual(warning("Documents/Bitz/Meetings"), "macOS may sync this folder to iCloud (Desktop & Documents).")
        XCTAssertEqual(warning("Desktop"), "macOS may sync this folder to iCloud (Desktop & Documents).")
        XCTAssertEqual(warning("Library/Mobile Documents/com~apple~CloudDocs/Notes"), "This folder is synced to a cloud service.")
        XCTAssertEqual(warning("Library/CloudStorage/OneDrive-Contoso/Meetings"), "This folder is synced to a cloud service.")
        XCTAssertNil(warning("Library/Application Support/Bitz/Meetings"))
        XCTAssertNil(warning("DocumentsArchive"), "Only the folder itself and its children count")
    }

    // MARK: - Stop-time mix, quit budget, launch recovery

    func testQuitWithExhaustedBudgetKeepsTracksUnmixedForRecovery() async throws {
        let service = makeService(captureEngine: MockMeetingAudioCaptureEngine())
        await service.startRecording()

        await service.finalizeForTermination(mixBudget: .zero)

        let result = try XCTUnwrap(service.lastCompletedResult)
        let sessionDir = result.sessionDirectoryURL
        XCTAssertEqual(MeetingTrackMixer.audioFileNames(in: sessionDir), ["mic.caf"])
        XCTAssertEqual(result.audioFileURL.lastPathComponent, "mic.caf")
        XCTAssertTrue(result.warning?.contains("mixed at next launch") ?? false)
        var meta = try decodeMetadata(result.metadataFileURL)
        XCTAssertEqual(meta.audioStatus, "unmixed")
        XCTAssertEqual(meta.audioFileNames, ["mic.caf"])
        XCTAssertEqual(meta.transcriptStatus, "skipped")

        // Next launch mixes what the quit left behind
        await service.recoverUnmixedSessions()
        meta = try decodeMetadata(result.metadataFileURL)
        XCTAssertEqual(meta.audioStatus, "mixed")
        XCTAssertEqual(meta.audioFileNames, ["audio.m4a"])
        XCTAssertEqual(meta.recovered, true)
        XCTAssertEqual(meta.sessionID, result.sessionID, "existing metadata is kept, not rebuilt")
        XCTAssertEqual(meta.transcriptStatus, "skipped", "recovery never transcribes")
    }

    func testQuitWithinBudgetMixesBeforeExit() async throws {
        let service = makeService(captureEngine: MockMeetingAudioCaptureEngine())
        await service.startRecording()

        await service.finalizeForTermination()

        let result = try XCTUnwrap(service.lastCompletedResult)
        XCTAssertEqual(MeetingTrackMixer.audioFileNames(in: result.sessionDirectoryURL), ["audio.m4a"])
        XCTAssertEqual(result.audioFileURL.lastPathComponent, "audio.m4a")
        XCTAssertNil(result.warning)
        let meta = try decodeMetadata(result.metadataFileURL)
        XCTAssertEqual(meta.audioStatus, "mixed")
        XCTAssertEqual(meta.audioFileNames, ["audio.m4a"])
        XCTAssertNil(meta.recovered)
    }

    func testEmptyRecordingIsMarkedEmptyAndNotRetriedByRecovery() async throws {
        let captureEngine = MockMeetingAudioCaptureEngine()
        captureEngine.trackFrameCount = 0
        let service = makeService(captureEngine: captureEngine)
        await service.startRecording()
        await service.stopRecording(transcribe: false)

        let result = try XCTUnwrap(service.lastCompletedResult)
        let sessionDir = result.sessionDirectoryURL
        XCTAssertEqual(try decodeMetadata(result.metadataFileURL).audioStatus, "empty")
        XCTAssertFalse(MeetingTrackMixer.needsMix(sessionDir))
        let metadataBefore = try Data(contentsOf: result.metadataFileURL)

        await service.recoverUnmixedSessions()

        XCTAssertEqual(try Data(contentsOf: result.metadataFileURL), metadataBefore, "an empty session is skipped, not rewritten")
        XCTAssertEqual(MeetingTrackMixer.audioFileNames(in: sessionDir), ["mic.caf"])
    }

    func testFailedMixTranscribesTheKeptTrack() async throws {
        for track in [MeetingTrackWriter.micFileName, MeetingTrackWriter.systemFileName] {
            let captureEngine = MockMeetingAudioCaptureEngine()
            captureEngine.trackFileName = track
            captureEngine.blocksMixOutput = true
            final class URLLog: @unchecked Sendable { var urls: [URL] = [] }
            let log = URLLog()
            var transcription = MockMeetingTranscriptionService()
            transcription.onTranscribe = { log.urls.append($0) }
            let service = makeService(captureEngine: captureEngine, transcription: transcription)
            service.settingsStore.setMeetingsRootDirectoryURL(tempDir.appendingPathComponent(track, isDirectory: true))

            await service.startRecording()
            await service.stopRecording()

            let result = try XCTUnwrap(service.lastCompletedResult)
            XCTAssertEqual(log.urls.map(\.lastPathComponent), [track], "a failed mix falls back to the kept track")
            XCTAssertEqual(result.audioFileURL.lastPathComponent, track)
            XCTAssertNotNil(result.transcriptTextURL)
            XCTAssertTrue(result.warning?.contains("mixing them into audio.m4a failed") ?? false)
            let meta = try decodeMetadata(result.metadataFileURL)
            XCTAssertEqual(meta.audioStatus, "unmixed")
            XCTAssertEqual(meta.audioFileNames, [track], "the folder at audio.m4a is not audio")
        }
    }

    func testStartIsRefusedWhenTheRecordingsDriveIsNearlyFull() async throws {
        let captureEngine = MockMeetingAudioCaptureEngine()
        let service = makeService(captureEngine: captureEngine, freeBytes: MeetingRecorderService.minimumFreeBytesToRecord - 1)

        await service.startRecording()

        XCTAssertFalse(service.isRecording)
        XCTAssertEqual(captureEngine.startCallCount, 0)
        guard case .failed(let message) = service.state else { return XCTFail("expected a failure, got \(service.state)") }
        XCTAssertTrue(message.contains("free disk space"), message)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: tempDir.path), [])

        // Unknown free space does not block recording
        let unknown = makeService(captureEngine: captureEngine, freeBytes: nil)
        await unknown.startRecording()
        XCTAssertTrue(unknown.isRecording)
        await unknown.stopRecording(transcribe: false)
    }

    func testDefaultFreeSpaceProviderReadsTheNearestExistingFolder() {
        let notYetCreated = tempDir.appendingPathComponent("Meetings/Nested", isDirectory: true)
        XCTAssertGreaterThan(MeetingRecorderService.availableBytes(at: notYetCreated) ?? 0, 0)
    }

    private func writeTrack(_ url: URL, frames: AVAudioFrameCount = 9_600) throws {
        let writer = try MeetingTrackWriter(fileURL: url, sessionStartHostSeconds: 0)
        writer.append(try XCTUnwrap(MockMeetingAudioCaptureEngine.makeSineWaveBuffer(frequency: 440, frameCount: frames)), hostSeconds: nil)
        writer.close()
    }

    func testLaunchRecoveryMixesOrphanedSessionsAndLeavesCompleteOnesAlone() async throws {
        let service = makeService(captureEngine: MockMeetingAudioCaptureEngine())
        let fm = FileManager.default

        // Crash mid-recording: tracks, no metadata, and a partial mix from a quit that was cut short
        let orphan = tempDir.appendingPathComponent("2026-11-05_09-00-00", isDirectory: true)
        try fm.createDirectory(at: orphan, withIntermediateDirectories: false)
        try writeTrack(orphan.appendingPathComponent(MeetingTrackWriter.micFileName))
        try writeTrack(orphan.appendingPathComponent(MeetingTrackWriter.systemFileName), frames: 14_400)
        try Data("partial".utf8).write(to: orphan.appendingPathComponent("audio.mixing.m4a"))

        // Finished earlier: audio.m4a and metadata, no tracks
        let complete = tempDir.appendingPathComponent("2026-11-05_08-00-00", isDirectory: true)
        try fm.createDirectory(at: complete, withIntermediateDirectories: false)
        try Data("finished audio".utf8).write(to: complete.appendingPathComponent("audio.m4a"))
        try Data("{}".utf8).write(to: complete.appendingPathComponent("metadata.json"))
        let completeBefore = try fm.contentsOfDirectory(atPath: complete.path).sorted()

        await service.recoverUnmixedSessions()

        XCTAssertEqual(try fm.contentsOfDirectory(atPath: orphan.path).sorted(), ["audio.m4a", "metadata.json"])
        let mixed = try AVAudioFile(forReading: orphan.appendingPathComponent("audio.m4a"))
        XCTAssertEqual(Double(mixed.length), 14_400, accuracy: Double(MeetingTrackMixer.chunkFrames))
        let meta = try decodeMetadata(orphan.appendingPathComponent("metadata.json"))
        XCTAssertEqual(meta.recovered, true)
        XCTAssertEqual(meta.audioStatus, "mixed")
        XCTAssertEqual(meta.sessionID, "2026-11-05_09-00-00")
        XCTAssertEqual(meta.durationSeconds, 0.3, accuracy: 0.001, "derived from the longest track")
        XCTAssertTrue(meta.captureMicrophone && meta.captureSystemAudio)
        XCTAssertEqual(meta.transcriptStatus, "skipped")

        XCTAssertEqual(try fm.contentsOfDirectory(atPath: complete.path).sorted(), completeBefore)
        XCTAssertEqual(try String(contentsOf: complete.appendingPathComponent("audio.m4a"), encoding: .utf8), "finished audio")
    }

    private func makeSession(_ name: String) throws -> URL {
        let url = tempDir.appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
        return url
    }

    private func writeMetadataJSON(_ json: String, in sessionDir: URL) throws -> URL {
        let url = sessionDir.appendingPathComponent("metadata.json")
        try Data(json.utf8).write(to: url)
        return url
    }

    func testRecoveryNeverReplacesAVerifiedMixWithALeftoverTrack() async throws {
        let service = makeService(captureEngine: MockMeetingAudioCaptureEngine())
        let session = try makeSession("2026-11-05_10-00-00")
        let mic = session.appendingPathComponent(MeetingTrackWriter.micFileName)
        let system = session.appendingPathComponent(MeetingTrackWriter.systemFileName)
        try writeTrack(mic, frames: 144_000)
        try writeTrack(system, frames: 48_000)
        XCTAssertTrue(MeetingTrackMixer.mixSession(in: session).mixed)
        let audioURL = session.appendingPathComponent("audio.m4a")
        let mixedBefore = try Data(contentsOf: audioURL)
        XCTAssertEqual(try AVAudioFile(forReading: audioURL).length, 144_000)
        // Killed after deleting mic.caf, before system.caf: only the shorter track is left over
        try writeTrack(system, frames: 48_000)

        XCTAssertFalse(MeetingTrackMixer.needsMix(session))
        await service.recoverUnmixedSessions()

        XCTAssertEqual(try Data(contentsOf: audioURL), mixedBefore, "the verified two-track mix is kept")
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: session.path).sorted(), ["audio.m4a"], "the covered leftover is deleted")

        // Even when asked directly, the mixer refuses to replace a readable audio.m4a
        try writeTrack(system, frames: 48_000)
        let direct = MeetingTrackMixer.mixSession(in: session)
        XCTAssertFalse(direct.mixed)
        XCTAssertEqual(try Data(contentsOf: audioURL), mixedBefore)
        XCTAssertTrue(FileManager.default.fileExists(atPath: system.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: session.appendingPathComponent("audio.mixing.m4a").path))
    }

    func testMixedSessionWithAnUnreadableTrackStaysMixedAcrossLaunches() async throws {
        let service = makeService(captureEngine: MockMeetingAudioCaptureEngine())
        let session = try makeSession("2026-11-05_11-00-00")
        try writeTrack(session.appendingPathComponent(MeetingTrackWriter.micFileName))
        try Data("not audio".utf8).write(to: session.appendingPathComponent(MeetingTrackWriter.systemFileName))
        XCTAssertTrue(MeetingTrackMixer.mixSession(in: session).mixed)
        XCTAssertEqual(MeetingTrackMixer.audioStatus(in: session), "mixed")
        let metadataURL = try writeMetadataJSON("""
            {"sessionID":"2026-11-05_11-00-00","startedAt":"2026-11-05T11:00:00Z","endedAt":"2026-11-05T11:00:01Z",
             "durationSeconds":1,"captureMicrophone":true,"captureSystemAudio":true,"detectedAppNames":[],
             "audioFileNames":["audio.m4a","system.caf"],"audioStatus":"mixed","transcriptStatus":"completed"}
            """, in: session)
        let metadataBefore = try Data(contentsOf: metadataURL)

        await service.recoverUnmixedSessions()
        await service.recoverUnmixedSessions()

        XCTAssertEqual(try Data(contentsOf: metadataURL), metadataBefore)
        XCTAssertEqual(MeetingTrackMixer.audioFileNames(in: session), ["audio.m4a", "system.caf"], "the unreadable track is kept")
    }

    func testRecoveryOnlyTouchesBitzSessionFolders() async throws {
        let service = makeService(captureEngine: MockMeetingAudioCaptureEngine())
        let fm = FileManager.default
        let foreign = try makeSession("Podcast drafts")
        try writeTrack(foreign.appendingPathComponent(MeetingTrackWriter.micFileName))
        // A symlink named like a session, pointing at a folder outside the recordings root
        let outside = tempDir.appendingPathComponent(".outside", isDirectory: true)
        try fm.createDirectory(at: outside, withIntermediateDirectories: false)
        try writeTrack(outside.appendingPathComponent(MeetingTrackWriter.micFileName))
        try fm.createSymbolicLink(at: tempDir.appendingPathComponent("2026-11-05_12-00-00"), withDestinationURL: outside)
        let suffixed = try makeSession("2026-11-05_12-00-00-2")
        try writeTrack(suffixed.appendingPathComponent(MeetingTrackWriter.micFileName))

        await service.recoverUnmixedSessions()

        XCTAssertEqual(try fm.contentsOfDirectory(atPath: foreign.path), ["mic.caf"])
        XCTAssertEqual(try fm.contentsOfDirectory(atPath: outside.path), ["mic.caf"])
        XCTAssertEqual(try fm.contentsOfDirectory(atPath: suffixed.path).sorted(), ["audio.m4a", "metadata.json"], "a -N session is still recovered")
    }

    func testOlderMetadataDecodesAndRecoveryMergesIntoIt() async throws {
        let service = makeService(captureEngine: MockMeetingAudioCaptureEngine())
        // Written before the per-source tracks: one audioFileName, no audioStatus
        let legacy = """
            {"sessionID":"2026-11-04_09-00-00","startedAt":"2026-11-04T09:00:00Z","endedAt":"2026-11-04T09:30:00Z",
             "durationSeconds":1800,"captureMicrophone":true,"captureSystemAudio":false,"detectedAppNames":["zoom.us"],
             "audioFileName":"audio.m4a","transcriptStatus":"completed","transcriptLocale":"nl-BE"}
            """
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let decoded = try decoder.decode(MeetingRecordingMetadata.self, from: Data(legacy.utf8))
        XCTAssertEqual(decoded.audioFileNames, ["audio.m4a"])
        XCTAssertEqual(decoded.audioStatus, "mixed")
        XCTAssertNil(decoded.recovered)

        // Recovery keeps what older metadata holds and only updates the audio fields
        let session = try makeSession("2026-11-04_09-00-00")
        try writeTrack(session.appendingPathComponent(MeetingTrackWriter.micFileName))
        let metadataURL = try writeMetadataJSON(legacy, in: session)
        // Metadata that does not decode at all is never replaced
        let unreadable = try makeSession("2026-11-04_10-00-00")
        try writeTrack(unreadable.appendingPathComponent(MeetingTrackWriter.micFileName))
        let unreadableMetadataURL = try writeMetadataJSON("{ not json", in: unreadable)

        await service.recoverUnmixedSessions()

        let merged = try decodeMetadata(metadataURL)
        XCTAssertEqual(merged.detectedAppNames, ["zoom.us"])
        XCTAssertEqual(merged.transcriptStatus, "completed")
        XCTAssertEqual(merged.transcriptLocale, "nl-BE")
        XCTAssertEqual(merged.durationSeconds, 1800)
        XCTAssertEqual(merged.audioStatus, "mixed")
        XCTAssertEqual(merged.recovered, true)
        XCTAssertEqual(try String(contentsOf: unreadableMetadataURL, encoding: .utf8), "{ not json")
        XCTAssertEqual(MeetingTrackMixer.audioFileNames(in: unreadable), ["audio.m4a"], "the audio is still mixed")
    }

    func testLaunchRecoveryNeverRunsDuringARecording() async throws {
        let service = makeService(captureEngine: MockMeetingAudioCaptureEngine())
        let orphan = tempDir.appendingPathComponent("2026-11-05_09-00-00", isDirectory: true)
        try FileManager.default.createDirectory(at: orphan, withIntermediateDirectories: false)
        try writeTrack(orphan.appendingPathComponent(MeetingTrackWriter.micFileName))

        await service.startRecording()
        let active = try XCTUnwrap(service.state.recordingSessionDirectory(in: tempDir))
        await service.recoverUnmixedSessions()

        XCTAssertEqual(MeetingTrackMixer.audioFileNames(in: orphan), ["mic.caf"])
        XCTAssertEqual(MeetingTrackMixer.audioFileNames(in: active), ["mic.caf"], "the live session is never touched")
        await service.stopRecording(transcribe: false)
    }
}

/// Stands in for `Task.sleep` in bubble auto-hide: records each requested delay and returns only when released.
final class ManualSleeper: @unchecked Sendable {
    private let lock = NSLock()
    private var waiting: [CheckedContinuation<Void, Never>] = []
    private var durations: [Duration] = []

    var requested: [Duration] { lock.withLock { durations } }

    var sleep: @Sendable (Duration) async -> Void {
        { [self] duration in
            await withCheckedContinuation { continuation in
                lock.withLock {
                    durations.append(duration)
                    waiting.append(continuation)
                }
            }
        }
    }

    func releaseAll() {
        let released = lock.withLock { () -> [CheckedContinuation<Void, Never>] in
            defer { waiting.removeAll() }
            return waiting
        }
        released.forEach { $0.resume() }
    }

    /// Yields until `count` delays were requested (the hide task runs on the main actor after the caller yields).
    func waitForRequests(_ count: Int) async {
        while requested.count < count {
            await Task.yield()
        }
    }
}

private extension MeetingRecorderState {
    func recordingSessionDirectory(in root: URL) -> URL? {
        guard case .recording(let sessionID, _, _) = self else { return nil }
        return root.appendingPathComponent(sessionID, isDirectory: true)
    }
}
