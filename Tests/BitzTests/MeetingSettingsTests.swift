import AVFoundation
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
            SystemMeetingPermissionChecker.screenCaptureRequestedKey,
            SystemMeetingPermissionChecker.screenCaptureProbeGrantedKey
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
        try makeNewestSession(at: now)
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
        try makeNewestSession(at: now)
        let justOld = try makeSession("2026-01-01_10-00-00", startedAt: now.addingTimeInterval(-30 * 86_400 - 1))
        _ = try makeSession("2026-01-01_10-00-01", startedAt: now.addingTimeInterval(-30 * 86_400 + 60))

        XCTAssertEqual(
            MeetingRecorderService.expiredSessions(in: tempDir, olderThanDays: 30, now: now).map(\.lastPathComponent),
            [justOld.lastPathComponent]
        )
    }

    func testRetentionStillExpiresSessionsWithMetadataFromEarlierBuilds() throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        try makeNewestSession(at: now)
        let folder = tempDir.appendingPathComponent("2026-01-01_10-00-00", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
        // camelCase keys with a single audioFileName: the oldest schema this branch wrote
        try Data("""
            {"sessionID":"2026-01-01_10-00-00","startedAt":"2026-01-01T10:00:00Z","endedAt":"2026-01-01T10:30:00Z",
             "durationSeconds":1800,"captureMicrophone":true,"captureSystemAudio":false,"detectedAppNames":[],
             "audioFileName":"audio.m4a","transcriptStatus":"completed"}
            """.utf8).write(to: folder.appendingPathComponent("metadata.json"))
        try backdate(folder, to: now.addingTimeInterval(-60 * 86_400))

        XCTAssertEqual(MeetingRecorderService.expiredSessions(in: tempDir, olderThanDays: 30, now: now).map(\.lastPathComponent), [folder.lastPathComponent])
    }

    func testExpiredSessionsNeedTheFolderDateToAgreeWithMetadata() throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        // metadata says old, but the folder changed yesterday: a wrong startedAt alone never expires a session
        let session = try makeSession("2026-01-01_10-00-00", startedAt: now.addingTimeInterval(-40 * 86_400))
        try backdate(session, to: now.addingTimeInterval(-86_400))

        XCTAssertEqual(MeetingRecorderService.expiredSessions(in: tempDir, olderThanDays: 30, now: now), [])
    }

    /// A clock jumped a year ahead must not expire recordings that were within the limit of the newest one.
    func testAForwardClockJumpOnlyExpiresSessionsOlderThanTheNewestByTheLimit() throws {
        let newest = Date(timeIntervalSince1970: 1_800_000_000)
        try makeNewestSession(at: newest)
        let recent = try makeSession("2026-01-02_10-00-00", startedAt: newest.addingTimeInterval(-29 * 86_400))
        let old = try makeSession("2026-01-01_10-00-00", startedAt: newest.addingTimeInterval(-31 * 86_400))
        let jumped = newest.addingTimeInterval(365 * 86_400)

        XCTAssertEqual(
            MeetingRecorderService.expiredSessions(in: tempDir, olderThanDays: 30, now: jumped).map(\.lastPathComponent),
            [old.lastPathComponent],
            "\(recent.lastPathComponent) was within 30 days of the newest session"
        )
    }

    func testRetentionDeletesASymlinkInsideASessionButNeverItsTarget() async throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        try makeNewestSession(at: now)
        let old = now.addingTimeInterval(-40 * 86_400)
        let outside = FileManager.default.temporaryDirectory.appendingPathComponent("bitz-outside-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: outside) }
        try FileManager.default.createDirectory(at: outside.appendingPathComponent("sub"), withIntermediateDirectories: true)
        try Data("keep".utf8).write(to: outside.appendingPathComponent("keep.txt"))
        try Data("keep".utf8).write(to: outside.appendingPathComponent("sub/keep.txt"))
        let session = try makeSession("2026-01-01_10-00-00", startedAt: old)
        try FileManager.default.createSymbolicLink(at: session.appendingPathComponent("dirlink"), withDestinationURL: outside.appendingPathComponent("sub"))
        try FileManager.default.createSymbolicLink(at: session.appendingPathComponent("filelink"), withDestinationURL: outside.appendingPathComponent("keep.txt"))
        try backdate(session, to: old)

        let service = makeService(captureEngine: MockMeetingAudioCaptureEngine(), now: { now })
        service.settingsStore.setRetentionDays(30)
        await service.applyRetention()

        XCTAssertFalse(exists(session))
        XCTAssertTrue(FileManager.default.fileExists(atPath: outside.appendingPathComponent("keep.txt").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: outside.appendingPathComponent("sub/keep.txt").path))
    }

    func testRetentionRenamesASessionAwayBeforeDeletingAndSweepsWhatADeleteLeftBehind() async throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        try makeNewestSession(at: now)
        let old = now.addingTimeInterval(-40 * 86_400)
        let session = try makeSession("2026-01-01_10-00-00", startedAt: old)
        // A folder whose contents cannot be removed makes the delete stop halfway
        let locked = session.appendingPathComponent("locked", isDirectory: true)
        try FileManager.default.createDirectory(at: locked, withIntermediateDirectories: false)
        try Data("x".utf8).write(to: locked.appendingPathComponent("file"))
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: locked.path)
        try backdate(session, to: old)
        let leftover = tempDir.appendingPathComponent(".deleting-2026-01-01_10-00-00", isDirectory: true)
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: leftover.appendingPathComponent("locked").path)
        }

        let service = makeService(captureEngine: MockMeetingAudioCaptureEngine(), now: { now })
        service.settingsStore.setRetentionDays(30)
        await service.applyRetention()

        XCTAssertFalse(exists(session), "the session leaves the list in one rename")
        XCTAssertTrue(exists(leftover), "what could not be removed stays hidden under .deleting-")

        // The next run finishes it, even with retention Off; lookalikes and symlinks are left alone
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: leftover.appendingPathComponent("locked").path)
        let notOurs = tempDir.appendingPathComponent(".deleting-notes", isDirectory: true)
        try FileManager.default.createDirectory(at: notOurs, withIntermediateDirectories: false)
        let outside = try makeSession("2026-01-02_10-00-00", startedAt: nil, in: tempDir.appendingPathComponent("outside"))
        let link = tempDir.appendingPathComponent(".deleting-2026-01-02_10-00-00")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: outside)
        service.settingsStore.setRetentionDays(nil)
        await service.applyRetention()

        XCTAssertFalse(exists(leftover))
        for survivor in [notOurs, link, outside] {
            XCTAssertTrue(exists(survivor), "\(survivor.lastPathComponent) should survive")
        }
    }

    func testRetentionWaitsWhileTranscribing() async throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let expired = try makeSession("2026-01-01_10-00-00", startedAt: now.addingTimeInterval(-100 * 86_400))
        var transcription = MockMeetingTranscriptionService()
        transcription.delayNanoseconds = 300_000_000
        let service = makeService(captureEngine: MockMeetingAudioCaptureEngine(), transcription: transcription, now: { now })
        service.settingsStore.setRetentionDays(90)
        service.settingsStore.setAutoTranscribeOnStop(true)
        service.settingsStore.setConsentAcknowledged(true)
        await service.startRecording()

        let stop = Task { await service.stopRecording() }
        try await waitUntil { service.isTranscribing }
        await service.applyRetention()
        XCTAssertTrue(exists(expired), "nothing is deleted while transcribing")

        await stop.value
        XCTAssertFalse(exists(expired), "retention runs once the transcript is done")
    }

    func testRetentionWaitsWhileRecovering() async throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        try makeNewestSession(at: now)
        let expired = try makeSession("2026-01-01_10-00-00", startedAt: now.addingTimeInterval(-40 * 86_400))
        _ = try makeOrphanSession("2026-01-02_10-00-00")
        let service = makeService(captureEngine: MockMeetingAudioCaptureEngine(), now: { now })
        service.settingsStore.setRetentionDays(30)

        let recovery = Task { await service.recoverUnmixedSessions() }
        try await waitUntil { service.isRecovering }
        await service.applyRetention()
        XCTAssertTrue(exists(expired), "nothing is deleted while recovering")

        await recovery.value
        await service.applyRetention()
        XCTAssertFalse(exists(expired))
    }

    /// The orphan has no metadata, so retention alone skips it; only recovery first gives retention a start date to judge.
    func testLaunchRecoversBeforeApplyingRetention() async throws {
        let orphan = try makeOrphanSession("2026-01-01_10-00-00")
        let now = Date().addingTimeInterval(100 * 86_400)
        try makeNewestSession(at: now)
        let service = makeService(captureEngine: MockMeetingAudioCaptureEngine(), now: { now })
        service.settingsStore.setRetentionDays(30)

        await service.applyRetention()
        XCTAssertTrue(exists(orphan), "no metadata yet, so not a candidate")

        await service.runLaunchMaintenance()
        XCTAssertFalse(exists(orphan), "recovery wrote its metadata, then retention found it old")
    }

    // MARK: - Language picker

    func testLanguageOptionsPutPreferredLanguagesFirstWithOneEntryPerLanguage() {
        let options = SpeechFrameworkTranscriptionService.orderedLocaleOptions(
            ["fr-FR", "en-GB", "de-DE", "nl-NL", "en-US", "nl-BE", "en_US"],
            preferredLanguages: ["nl-BE", "en-US"],
            displayLocale: Locale(identifier: "en_US")
        )

        XCTAssertEqual(options.map(\.id), ["nl-BE", "en-US", "fr-FR", "de-DE"])
        XCTAssertEqual(options.map(\.label), ["Dutch", "English", "French", "German"])
    }

    /// The variants this Mac offers for a Belgian English/Dutch user: one English entry (the default region), no odd regions.
    func testLanguageOptionsPickTheDefaultRegionWhenNoPreferredVariantIsAvailable() {
        let options = SpeechFrameworkTranscriptionService.orderedLocaleOptions(
            Self.englishHeavyLocales,
            preferredLanguages: ["en-BE", "nl-BE"],
            displayLocale: Locale(identifier: "en_US")
        )

        XCTAssertEqual(options.map(\.id), ["en-US", "nl-BE"])
        XCTAssertEqual(options.map(\.label), ["English", "Dutch"])
    }

    /// Preferred variants keep the user's order (en-US before en-GB, though "United Kingdom" sorts first); zh-HK is
    /// Cantonese, so it keeps its own entry next to Traditional and Simplified Chinese.
    func testLanguageOptionsKeepEveryPreferredVariantAndSplitChineseByScript() {
        let options = SpeechFrameworkTranscriptionService.orderedLocaleOptions(
            Self.englishHeavyLocales + ["zh-CN", "zh-TW", "zh-HK"],
            preferredLanguages: ["en-US", "en-GB"],
            displayLocale: Locale(identifier: "en_US")
        )

        XCTAssertEqual(options.map(\.id), ["en-US", "en-GB", "zh-CN", "zh-HK", "zh-TW", "nl-BE"])
        let labels = Dictionary(uniqueKeysWithValues: options.map { ($0.id, $0.label) })
        XCTAssertEqual(labels["en-US"], "English (United States)")
        XCTAssertEqual(labels["en-GB"], "English (United Kingdom)")
        XCTAssertEqual(labels["zh-TW"], "Chinese (Taiwan)")
        XCTAssertEqual(labels["zh-HK"], "Chinese (Hong Kong)")
        XCTAssertEqual(labels["nl-BE"], "Dutch")
    }

    func testCantoneseStaysListedWhenTraditionalChineseIsPreferred() {
        let options = SpeechFrameworkTranscriptionService.orderedLocaleOptions(
            ["zh-CN", "zh-TW", "zh-HK", "fr-FR"],
            preferredLanguages: ["zh-TW", "fr-FR"],
            displayLocale: Locale(identifier: "en_US")
        )

        XCTAssertEqual(options.map(\.id), ["zh-TW", "zh-CN", "zh-HK", "fr-FR"])
    }

    func testASavedVariantMissingFromTheListStaysSelectable() {
        let loaded = SpeechFrameworkTranscriptionService.orderedLocaleOptions(
            Self.englishHeavyLocales,
            preferredLanguages: ["en-BE", "nl-BE"],
            displayLocale: Locale(identifier: "en_US")
        )

        XCTAssertEqual(AudioSettingsTabView.languageOptions(selected: "en-ID", loaded: loaded).map(\.id), ["en-ID", "en-US", "nl-BE"])
        XCTAssertEqual(AudioSettingsTabView.languageOptions(selected: "nl-BE", loaded: loaded).map(\.id), ["en-US", "nl-BE"])
        XCTAssertEqual(AudioSettingsTabView.languageOptions(selected: nil, loaded: loaded).map(\.id), ["en-US", "nl-BE"])
        XCTAssertEqual(AudioSettingsTabView.languageOptions(selected: "en-ID", loaded: []).map(\.id), ["en-ID"], "valid while loading")
    }

    private static let englishHeavyLocales = ["en-ID", "en-PH", "en-SA", "en-AE", "en-GB", "en-US", "nl-BE"]

    // MARK: - Helpers

    private func makeService(
        captureEngine: MockMeetingAudioCaptureEngine,
        transcription: MockMeetingTranscriptionService = MockMeetingTranscriptionService(),
        now: @escaping () -> Date = { Date() },
        onPermissionRequest: (@Sendable () -> Void)? = nil
    ) -> MeetingRecorderService {
        let settings = MeetingSettingsStore(userDefaults: defaults)
        settings.setMeetingsRootDirectoryURL(tempDir)
        return MeetingRecorderService(
            settingsStore: settings,
            captureEngine: captureEngine,
            transcriptionService: transcription,
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
            try backdate(folder, to: startedAt)
        }
        return folder
    }

    /// Sets the folder's modification date, which retention also requires to be past the limit.
    private func backdate(_ folder: URL, to date: Date) throws {
        try FileManager.default.setAttributes([.modificationDate: date], ofItemAtPath: folder.path)
    }

    /// The newest recording, made at `now`. Retention measures from the newest session, so without one nothing older expires.
    @discardableResult
    private func makeNewestSession(at now: Date) throws -> URL {
        try makeSession("2027-01-15_08-00-00", startedAt: now)
    }

    /// A session a crash left as a track and no metadata, so launch recovery mixes it and writes its metadata.
    private func makeOrphanSession(_ name: String) throws -> URL {
        let folder = tempDir.appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
        let writer = try MeetingTrackWriter(
            fileURL: folder.appendingPathComponent(MeetingTrackWriter.micFileName), sessionStartHostSeconds: 0
        )
        writer.append(try XCTUnwrap(MockMeetingAudioCaptureEngine.makeSineWaveBuffer(frequency: 440, frameCount: 9_600)), hostSeconds: nil)
        writer.close()
        return folder
    }

    /// Yields first so a task just started on the main actor runs to its first suspension, then polls.
    private func waitUntil(_ condition: () -> Bool) async throws {
        await Task.yield()
        for _ in 0..<2_000 where !condition() {
            try await Task.sleep(nanoseconds: 1_000_000)
        }
        XCTAssertTrue(condition())
    }

    private func exists(_ url: URL) -> Bool {
        (try? url.checkResourceIsReachable()) == true || (try? FileManager.default.destinationOfSymbolicLink(atPath: url.path)) != nil
    }
}
