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
    var onCaptureInterrupted: (@Sendable (String) -> Void)?

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

        // Write a real mic track, so the stop-time mix produces a valid audio.m4a
        let writer = try MeetingTrackWriter(
            fileURL: sessionDirectoryURL.appendingPathComponent(MeetingTrackWriter.micFileName),
            sessionStartHostSeconds: 0
        )
        if let buffer = Self.makeSineWaveBuffer(frequency: 440.0, frameCount: 4_800) {
            writer.append(buffer, hostSeconds: nil)
        }
        writer.close()
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

    func transcribe(
        audioFileURL: URL,
        sessionID: String,
        locale: Locale?
    ) async throws -> MeetingTranscript {
        if delayNanoseconds > 0 {
            try? await Task.sleep(nanoseconds: delayNanoseconds)
        }
        if let error { throw error }
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

        // Meeting data is owner-only: 0700 session dir, 0600 files (atomic rewrites included)
        func posixMode(_ url: URL) throws -> Int {
            try XCTUnwrap(FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? NSNumber).intValue
        }
        XCTAssertEqual(try posixMode(result.sessionDirectoryURL), 0o700)
        for file in [result.audioFileURL, result.metadataFileURL, txtURL, jsonURL] {
            XCTAssertEqual(try posixMode(file), 0o600, file.lastPathComponent)
        }
        XCTAssertEqual(decodedMeta.transcriptLocale, "en-US", "metadata.json records the locale actually used")
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

    // MARK: - Recording lifecycle and failure handling

    private func makeService(
        captureEngine: MockMeetingAudioCaptureEngine,
        transcription: MockMeetingTranscriptionService = MockMeetingTranscriptionService(),
        microphone: MeetingPermissionState.Status = .authorized,
        nowProvider: @escaping () -> Date = { Date() }
    ) -> MeetingRecorderService {
        let settings = MeetingSettingsStore(userDefaults: defaults)
        settings.setMeetingsRootDirectoryURL(tempDir)
        return MeetingRecorderService(
            settingsStore: settings,
            captureEngine: captureEngine,
            transcriptionService: transcription,
            permissionChecker: MockMeetingPermissionChecker(
                state: MeetingPermissionState(microphone: microphone, screenAudio: .authorized, speechRecognition: .authorized)
            ),
            nowProvider: nowProvider,
            onRevealURL: { _ in }
        )
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

    func testFailureBubbleAutoDismisses() async throws {
        let captureEngine = MockMeetingAudioCaptureEngine()
        let service = makeService(captureEngine: captureEngine, microphone: .denied)
        service.failureBubbleDurationNanoseconds = 20_000_000

        await service.startRecording()
        XCTAssertNotNil(service.activeSpeechBubbleText)

        try await Task.sleep(nanoseconds: 200_000_000)
        XCTAssertNil(service.activeSpeechBubbleText)
        XCTAssertEqual(service.state, .idle)
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
        service.handleCaptureInterruption("System audio capture stopped: test")
        XCTAssertTrue(service.statusMessage.contains("System audio capture stopped"))
        await service.stopRecording()

        let result = try XCTUnwrap(service.lastCompletedResult)
        let bubble = try XCTUnwrap(service.activeSpeechBubbleText)
        XCTAssertTrue(bubble.hasPrefix("⚠️"))
        XCTAssertTrue(bubble.contains("System audio capture stopped"))
        XCTAssertTrue(bubble.contains("timed out"))
        XCTAssertEqual(result.bubbleHeadline, bubble)
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
        XCTAssertTrue(result.bubbleHeadline.hasPrefix("⚠️"))

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
}
