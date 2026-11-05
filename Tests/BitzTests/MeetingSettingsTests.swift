import XCTest
@testable import BitzCore

/// #43 D7: settings keys and migration, the first-recording notice, retention, and the language picker order.
@MainActor
final class MeetingSettingsTests: XCTestCase {
    private var suiteName: String!
    private var defaults: UserDefaults!
    private var tempDir: URL!

    override func setUp() async throws {
        suiteName = "MeetingSettingsTests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)!
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("bitz-meeting-settings-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        defaults.removePersistentDomain(forName: suiteName)
        try? FileManager.default.removeItem(at: tempDir)
    }

    // MARK: - Keys and migration

    func testMigrationCopiesLegacyKeysOnceRemovesThemAndNeverOverwritesNewKeys() {
        defaults.set(false, forKey: "Bitz.MeetingRecorder.CaptureMicrophone")
        defaults.set("/tmp/old-meetings", forKey: "Bitz.MeetingRecorder.DirectoryPath")
        defaults.set(true, forKey: "Bitz.MeetingRecorder.ScreenCaptureRequested")
        // Already written under the new key: the legacy value must not win
        defaults.set("controlShiftR", forKey: "Bitz.MeetingRecorder.RecordingHotkey")
        defaults.set(MeetingRecordingHotkey.off.rawValue, forKey: MeetingSettingsStore.recordingHotkeyKey)

        let store = MeetingSettingsStore(userDefaults: defaults)

        XCTAssertFalse(store.captureMicrophone)
        XCTAssertEqual(store.meetingsRootDirectoryURL.path, "/tmp/old-meetings")
        XCTAssertEqual(store.recordingHotkey, .off)
        XCTAssertEqual(defaults.object(forKey: "bitz.meeting.captureMicrophone") as? Bool, false)
        XCTAssertEqual(defaults.bool(forKey: SystemMeetingPermissionChecker.screenCaptureRequestedKey), true)
        for oldKey in MeetingSettingsStore.legacyKeys.keys {
            XCTAssertNil(defaults.object(forKey: oldKey), "\(oldKey) should be removed")
        }

        // A second launch finds nothing to migrate and keeps the user's later changes
        store.setCaptureMicrophone(true)
        XCTAssertTrue(MeetingSettingsStore(userDefaults: defaults).captureMicrophone)
    }

    func testEveryMeetingKeyUsesThePrefix() {
        let keys = [
            MeetingSettingsStore.captureMicrophoneKey, MeetingSettingsStore.captureSystemAudioKey,
            MeetingSettingsStore.autoTranscribeKey, MeetingSettingsStore.copyTranscriptPathKey,
            MeetingSettingsStore.meetingsDirectoryPathKey, MeetingSettingsStore.transcriptionLocaleKey,
            MeetingSettingsStore.transcriptExportDirectoryPathKey, MeetingSettingsStore.recordingHotkeyKey,
            MeetingSettingsStore.consentAcknowledgedKey, MeetingSettingsStore.retentionDaysKey,
            SystemMeetingPermissionChecker.screenCaptureRequestedKey
        ]
        XCTAssertTrue(keys.allSatisfy { $0.hasPrefix("bitz.meeting.") })
        XCTAssertEqual(MeetingSettingsStore.consentAcknowledgedKey, "bitz.meeting.consentAcknowledged")
        XCTAssertEqual(Set(MeetingSettingsStore.legacyKeys.values).count, MeetingSettingsStore.legacyKeys.count)
    }

    // MARK: - First-recording notice

    func testConsentNoticeGatesTheFirstStartBeforeAnyPermissionPrompt() async throws {
        final class Log: @unchecked Sendable { var steps: [String] = []; var answer = false }
        let log = Log()
        let captureEngine = MockMeetingAudioCaptureEngine()
        let service = makeService(captureEngine: captureEngine, onPermissionRequest: { log.steps.append("permissions") })
        service.consentPresenter = { folder in
            XCTAssertEqual(folder, self.tempDir)
            log.steps.append("notice")
            return log.answer
        }

        // Cancel aborts: nothing recorded, nothing asked, nothing stored
        await service.startRecording()
        XCTAssertFalse(service.isRecording)
        XCTAssertEqual(captureEngine.startCallCount, 0)
        XCTAssertEqual(log.steps, ["notice"])
        XCTAssertFalse(service.settingsStore.consentAcknowledged)
        XCTAssertFalse(MeetingSettingsStore(userDefaults: defaults).consentAcknowledged)

        // Continue starts the recording, and the notice comes before the permission prompt
        log.answer = true
        await service.startRecording()
        XCTAssertTrue(service.isRecording)
        XCTAssertEqual(log.steps, ["notice", "notice", "permissions"])
        XCTAssertTrue(MeetingSettingsStore(userDefaults: defaults).consentAcknowledged)
        await service.stopRecording(transcribe: false)

        // Never shown again once acknowledged
        await service.startRecording()
        XCTAssertTrue(service.isRecording)
        XCTAssertEqual(log.steps.filter { $0 == "notice" }.count, 2)
        await service.stopRecording(transcribe: false)
    }

    func testConsentNoticeTextCoversCaptureScopeStorageAndParticipants() {
        let message = MeetingConsentNotice.message(recordingsFolder: tempDir)
        XCTAssertTrue(message.contains("microphone"))
        XCTAssertTrue(message.contains("Screen & System Audio Recording"))
        XCTAssertTrue(message.contains("only uses the audio"))
        XCTAssertTrue(message.contains(tempDir.lastPathComponent))
        XCTAssertTrue(message.contains("on this Mac"))
        XCTAssertTrue(message.contains("Let other participants know before you record."))
    }

    // MARK: - Retention

    func testRetentionDeletesOnlyOldBitzSessionsWithValidMetadata() async throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let old = now.addingTimeInterval(-40 * 86_400)
        let expired = try makeSession("2026-01-01_10-00-00", startedAt: old)
        let young = try makeSession("2026-01-02_10-00-00", startedAt: now.addingTimeInterval(-10 * 86_400))
        let notASession = try makeSession("Project notes", startedAt: old)
        let noMetadata = try makeSession("2026-01-03_10-00-00", startedAt: nil)
        let badMetadata = try makeSession("2026-01-04_10-00-00", startedAt: nil)
        try Data("not json".utf8).write(to: badMetadata.appendingPathComponent("metadata.json"))
        // A symlink named like a session, pointing at an old session outside the root
        let outside = FileManager.default.temporaryDirectory.appendingPathComponent("bitz-outside-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: outside) }
        let target = try makeSession("2026-01-05_10-00-00", startedAt: old, in: outside)
        let link = tempDir.appendingPathComponent("2026-01-06_10-00-00")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)

        let service = makeService(captureEngine: MockMeetingAudioCaptureEngine(), now: { now })

        // Off (default) deletes nothing
        await service.applyRetention()
        XCTAssertTrue(exists(expired))

        service.settingsStore.setRetentionDays(30)
        await service.applyRetention()

        XCTAssertFalse(exists(expired))
        for survivor in [young, notASession, noMetadata, badMetadata, link, target] {
            XCTAssertTrue(exists(survivor), "\(survivor.lastPathComponent) should survive")
        }
    }

    func testRetentionNeverRunsDuringARecordingAndRunsAfterIt() async throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let expired = try makeSession("2026-01-01_10-00-00", startedAt: now.addingTimeInterval(-100 * 86_400))
        let service = makeService(captureEngine: MockMeetingAudioCaptureEngine(), now: { now })
        service.settingsStore.setRetentionDays(90)
        service.settingsStore.setAutoTranscribeOnStop(false)
        service.settingsStore.setConsentAcknowledged(true)

        await service.startRecording()
        XCTAssertTrue(service.isRecording)
        await service.applyRetention()
        XCTAssertTrue(exists(expired), "nothing is deleted while recording")

        await service.stopRecording()
        XCTAssertFalse(exists(expired), "retention runs after each finished recording")
        let session = try XCTUnwrap(service.lastCompletedResult?.sessionDirectoryURL)
        XCTAssertTrue(exists(session), "the session just recorded is kept")
    }

    func testExpiredSessionsFilterUsesMetadataStartDate() throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let justOld = try makeSession("2026-01-01_10-00-00", startedAt: now.addingTimeInterval(-30 * 86_400 - 1))
        _ = try makeSession("2026-01-01_10-00-01", startedAt: now.addingTimeInterval(-30 * 86_400 + 60))

        XCTAssertEqual(
            MeetingRecorderService.expiredSessions(in: tempDir, olderThanDays: 30, now: now).map(\.lastPathComponent),
            [justOld.lastPathComponent]
        )
    }

    // MARK: - Language picker

    func testLanguageOptionsPutPreferredLanguagesFirstAndShowRegionOnlyToDisambiguate() {
        let options = SpeechFrameworkTranscriptionService.orderedLocaleOptions(
            ["fr-FR", "en-GB", "de-DE", "nl-NL", "en-US", "nl-BE", "en_US"],
            preferredLanguages: ["nl-BE", "en-US"],
            displayLocale: Locale(identifier: "en_US")
        )

        XCTAssertEqual(options.map(\.id), ["nl-BE", "nl-NL", "en-US", "en-GB", "fr-FR", "de-DE"])
        let labels = Dictionary(uniqueKeysWithValues: options.map { ($0.id, $0.label) })
        XCTAssertEqual(labels["fr-FR"], "French")
        XCTAssertEqual(labels["de-DE"], "German")
        XCTAssertEqual(labels["en-US"], "English (United States)")
        XCTAssertEqual(labels["en-GB"], "English (United Kingdom)")
        XCTAssertEqual(labels["nl-BE"], "Dutch (Belgium)")
    }

    // MARK: - Helpers

    private func makeService(
        captureEngine: MockMeetingAudioCaptureEngine,
        now: @escaping () -> Date = { Date() },
        onPermissionRequest: (@Sendable () -> Void)? = nil
    ) -> MeetingRecorderService {
        let settings = MeetingSettingsStore(userDefaults: defaults)
        settings.setMeetingsRootDirectoryURL(tempDir)
        return MeetingRecorderService(
            settingsStore: settings,
            captureEngine: captureEngine,
            transcriptionService: MockMeetingTranscriptionService(),
            permissionChecker: MockMeetingPermissionChecker(
                state: MeetingPermissionState(microphone: .authorized, screenAudio: .authorized, speechRecognition: .authorized),
                onRequest: { _, _, _ in onPermissionRequest?() }
            ),
            nowProvider: now,
            freeBytesProvider: { _ in .max },
            onRevealURL: { _ in }
        )
    }

    /// A folder with a valid `metadata.json` starting at `startedAt`, or no metadata when nil.
    private func makeSession(_ name: String, startedAt: Date?, in root: URL? = nil) throws -> URL {
        let folder = (root ?? tempDir).appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        if let startedAt {
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            let metadata = MeetingRecordingMetadata(
                sessionID: name, startedAt: startedAt, endedAt: startedAt.addingTimeInterval(60), durationSeconds: 60,
                captureMicrophone: true, captureSystemAudio: true, detectedAppNames: []
            )
            try encoder.encode(metadata).write(to: folder.appendingPathComponent("metadata.json"))
        }
        return folder
    }

    private func exists(_ url: URL) -> Bool {
        (try? url.checkResourceIsReachable()) == true || (try? FileManager.default.destinationOfSymbolicLink(atPath: url.path)) != nil
    }
}
