@testable import BitzCore
import Foundation
import WhisperKit
import XCTest

final class WhisperKitTranscriptionTests: XCTestCase {
    @MainActor
    func testMeetingSettingsStorePersistsEngineAndWhisperVariant() {
        let suite = "WhisperKitTranscriptionTests.settings.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }

        let store = MeetingSettingsStore(userDefaults: defaults)
        XCTAssertEqual(store.transcriptionEngine, .whisperAI)
        XCTAssertEqual(store.whisperModelVariant, .largeV3Turbo)

        store.setTranscriptionEngine(.appleDictation)
        store.setWhisperModelVariant(.compact)

        let reloaded = MeetingSettingsStore(userDefaults: defaults)
        XCTAssertEqual(reloaded.transcriptionEngine, .appleDictation)
        XCTAssertEqual(reloaded.whisperModelVariant, .compact)
    }

    @MainActor
    func testModelManagerDownloadIntegrityCheckAndDelete() async throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("WhisperKitModelManagerTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let manager = WhisperKitModelManager(modelsRootURL: tempDir) { variant, rootURL, onProgress in
            let folder = rootURL
                .appendingPathComponent("models/argmaxinc/whisperkit-coreml/\(variant.rawValue)", isDirectory: true)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            for component in ["AudioEncoder.mlmodelc", "TextDecoder.mlmodelc", "MelSpectrogram.mlmodelc"] {
                let compDir = folder.appendingPathComponent(component, isDirectory: true)
                try FileManager.default.createDirectory(at: compDir, withIntermediateDirectories: true)
                try Data("weights".utf8).write(to: compDir.appendingPathComponent("coremldata.bin"))
            }
            try Data("{}".utf8).write(to: folder.appendingPathComponent("config.json"))
            onProgress(0.5)
            onProgress(1.0)
            return folder
        }

        XCTAssertEqual(manager.state(for: .compact), .notDownloaded)
        let downloaded = try await manager.ensureModelDownloaded(.compact)
        XCTAssertTrue(WhisperKitModelManager.isModelValid(at: downloaded))
        XCTAssertTrue(manager.state(for: .compact).isDownloaded)

        try manager.deleteModel(.compact)
        XCTAssertEqual(manager.state(for: .compact), .notDownloaded)
        XCTAssertFalse(WhisperKitModelManager.isModelValid(at: downloaded))
    }

    @MainActor
    func testModelManagerRejectsCorruptBundleAndCleansUp() async throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("WhisperKitModelManagerCorrupt-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let manager = WhisperKitModelManager(modelsRootURL: tempDir) { variant, rootURL, _ in
            let folder = rootURL
                .appendingPathComponent("models/argmaxinc/whisperkit-coreml/\(variant.rawValue)", isDirectory: true)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            // Missing required .mlmodelc directories
            return folder
        }

        do {
            _ = try await manager.ensureModelDownloaded(.compact)
            XCTFail("Expected invalidModelBundle error")
        } catch let error as WhisperModelManagerError {
            XCTAssertEqual(error, .invalidModelBundle(WhisperModelVariant.compact.rawValue))
        }
        let expectedFolder = manager.modelFolderURL(for: .compact)
        XCTAssertFalse(FileManager.default.fileExists(atPath: expectedFolder.path), "Invalid bundle should be removed")
        if case .failed = manager.state(for: .compact) {
            // expected
        } else {
            XCTFail("Expected failed state")
        }
    }

    @MainActor
    func testModelManagerHandlesURLErrorCancellationWithoutErrorState() async throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("WhisperKitModelManagerCancel-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let manager = WhisperKitModelManager(modelsRootURL: tempDir) { _, _, _ in
            throw URLError(.cancelled)
        }

        do {
            _ = try await manager.ensureModelDownloaded(.compact)
            XCTFail("Expected downloadCancelled error")
        } catch let error as WhisperModelManagerError {
            XCTAssertEqual(error, .downloadCancelled)
        }
        XCTAssertEqual(manager.state(for: .compact), .notDownloaded)
    }

    func testConvertResultsSanitizesNonFiniteNumbersForJSONEncoding() throws {
        let seg = TranscriptionSegment(
            start: .nan,
            end: .infinity,
            text: "Hello world",
            avgLogprob: .nan,
            noSpeechProb: 0.1
        )
        let result = TranscriptionResult(
            text: "Hello world",
            segments: [seg],
            language: "en",
            timings: TranscriptionTimings()
        )
        let converted = WhisperKitTranscriptionService.convertResults([result], speaker: nil)
        XCTAssertEqual(converted.count, 1)
        XCTAssertEqual(converted[0].startTime, 0.0)
        XCTAssertEqual(converted[0].endTime, 0.0)
        XCTAssertEqual(converted[0].confidence, 0.0)
        _ = try JSONEncoder().encode(converted)
    }

    func testDualTrackChronologicalMergeAndSpeakerPlainTextFormatting() {
        let mic = [
            MeetingTranscriptSegment(text: "Hey team, can you hear me?", startTime: 0.5, endTime: 2.1, confidence: 0.95, speaker: "You"),
            MeetingTranscriptSegment(text: "Sounds good, let's ship it.", startTime: 6.0, endTime: 8.2, confidence: 0.92, speaker: "You")
        ]
        let system = [
            MeetingTranscriptSegment(text: "Yes, loud and clear!", startTime: 2.3, endTime: 4.0, confidence: 0.96, speaker: "Participants"),
            MeetingTranscriptSegment(text: "PR is ready for review.", startTime: 4.1, endTime: 5.9, confidence: 0.91, speaker: "Participants")
        ]

        let merged = WhisperKitTranscriptionService.mergeDualTrackSegments(micSegments: mic, systemSegments: system)
        XCTAssertEqual(merged.map(\.speaker), ["You", "Participants", "Participants", "You"])

        let transcript = MeetingTranscript(
            sessionID: "meeting-204",
            localeIdentifier: "en-US",
            fullText: WhisperKitTranscriptionService.buildFullText(from: merged),
            segments: merged
        )
        let plain = transcript.formattedPlainText()
        XCTAssertTrue(plain.contains("[00:00] You: Hey team, can you hear me?"))
        XCTAssertTrue(plain.contains("[00:02] Participants: Yes, loud and clear!"))
        XCTAssertTrue(plain.contains("[00:04] Participants: PR is ready for review."))
        XCTAssertTrue(plain.contains("[00:06] You: Sounds good, let's ship it."))
    }

    func testSilenceGatingAndGainNormalization() {
        let silent = [Float](repeating: 0.00001, count: 16_000)
        XCTAssertEqual(WhisperKitTranscriptionService.normalizeAndGateSamples(silent), [])

        let quietSpeech = [Float](repeating: 0.05, count: 16_000)
        let normalized = WhisperKitTranscriptionService.normalizeAndGateSamples(quietSpeech)
        XCTAssertEqual(normalized.count, 16_000)
        XCTAssertGreaterThan(normalized[0], 0.5)
        XCTAssertLessThanOrEqual(normalized[0], 1.0)
    }

    func testHallucinationFiltering() {
        XCTAssertTrue(WhisperKitTranscriptionService.isLikelyHallucination("[BLANK_AUDIO]", noSpeechProb: 0.1, avgLogprob: -0.2))
        XCTAssertTrue(WhisperKitTranscriptionService.isLikelyHallucination("(silence)", noSpeechProb: 0.1, avgLogprob: -0.2))
        XCTAssertTrue(WhisperKitTranscriptionService.isLikelyHallucination("uh", noSpeechProb: 0.9, avgLogprob: -1.5))
        XCTAssertTrue(WhisperKitTranscriptionService.isLikelyHallucination("TV Gelderland 2021", noSpeechProb: 0.1, avgLogprob: -0.2))
        XCTAssertFalse(WhisperKitTranscriptionService.isLikelyHallucination("Let's review the pull request.", noSpeechProb: 0.05, avgLogprob: -0.2))
    }

    func testSegmentDeduplicationAndSpeechEnergyGate() {
        let segments = [
            MeetingTranscriptSegment(text: "Oké, dat kan niet werken. Maar hoort je jezelf dubbel?", startTime: 33.0, endTime: 37.0, confidence: 0.5, speaker: "Participants"),
            MeetingTranscriptSegment(text: "Oké, dat kan niet werken.", startTime: 37.7, endTime: 39.9, confidence: 0.5, speaker: "Participants"),
            MeetingTranscriptSegment(text: "Oké, dat kan niet werken. Maar hoort je jezelf dubbel?", startTime: 39.9, endTime: 51.8, confidence: 0.5, speaker: "Participants"),
            MeetingTranscriptSegment(text: "Ik hoor je.", startTime: 58.0, endTime: 61.0, confidence: 0.6, speaker: "Participants")
        ]
        let deduped = WhisperKitTranscriptionService.deduplicateSegments(segments)
        XCTAssertEqual(deduped.count, 2)
        XCTAssertEqual(deduped.map(\.text), [
            "Oké, dat kan niet werken. Maar hoort je jezelf dubbel?",
            "Ik hoor je."
        ])

        // 2 seconds of silence at 16 kHz
        let silentSamples = [Float](repeating: 0.0001, count: 32_000)
        XCTAssertFalse(WhisperKitTranscriptionService.segmentHasSpeechEnergy(samples: silentSamples, startTime: 0.5, endTime: 1.5))
        let speechSamples = [Float](repeating: 0.05, count: 32_000)
        XCTAssertTrue(WhisperKitTranscriptionService.segmentHasSpeechEnergy(samples: speechSamples, startTime: 0.5, endTime: 1.5))
    }

    func testTranscriptionRouterDispatchesByEngine() async throws {
        struct StubDualProvider: MeetingDualTrackTranscriptionProviding {
            let label: String
            func transcribe(audioFileURL: URL, sessionID: String, locale: Locale?) async throws -> MeetingTranscript {
                MeetingTranscript(sessionID: sessionID, localeIdentifier: "en-US", fullText: label, segments: [])
            }
            func transcribeTracks(
                micURL: URL?,
                systemURL: URL?,
                fallbackAudioURL: URL,
                sessionID: String,
                locale: Locale?,
                onStatusUpdate: (@MainActor @Sendable (String) -> Void)?
            ) async throws -> MeetingTranscript {
                MeetingTranscript(sessionID: sessionID, localeIdentifier: "en-US", fullText: "\(label)-dual", segments: [])
            }
        }

        struct StubAppleProvider: MeetingTranscriptionProviding {
            func transcribe(audioFileURL: URL, sessionID: String, locale: Locale?) async throws -> MeetingTranscript {
                MeetingTranscript(sessionID: sessionID, localeIdentifier: "en-US", fullText: "apple", segments: [])
            }
        }

        let currentEngine = LockedBox<MeetingTranscriptionEngine>(.whisperAI)
        let router = MeetingTranscriptionRouter(
            engineProvider: { currentEngine.value },
            whisperService: StubDualProvider(label: "whisper"),
            appleService: StubAppleProvider()
        )
        let dummyURL = URL(fileURLWithPath: "/tmp/nonexistent.m4a")

        let whisperResult = try await router.transcribeTracks(
            micURL: nil,
            systemURL: nil,
            fallbackAudioURL: dummyURL,
            sessionID: "s1",
            locale: nil,
            onStatusUpdate: nil
        )
        XCTAssertEqual(whisperResult.fullText, "whisper-dual")

        currentEngine.value = .appleDictation
        let appleResult = try await router.transcribeTracks(
            micURL: nil,
            systemURL: nil,
            fallbackAudioURL: dummyURL,
            sessionID: "s1",
            locale: nil,
            onStatusUpdate: nil
        )
        XCTAssertEqual(appleResult.fullText, "apple")
    }

    /// Real-world end-to-end WhisperKit accuracy benchmark (>= 90% word accuracy).
    /// Run explicitly via: `BITZ_RUN_WHISPER_BENCHMARK=1 xcrun swift test --filter testRealWorldAudioAccuracyBenchmark`
    @MainActor
    func testRealWorldAudioAccuracyBenchmark() async throws {
        guard ProcessInfo.processInfo.environment["BITZ_RUN_WHISPER_BENCHMARK"] == "1" else {
            throw XCTSkip("Set BITZ_RUN_WHISPER_BENCHMARK=1 to run live WhisperKit model download & accuracy benchmark.")
        }

        let jfkURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent(".build/checkouts/WhisperKit/Tests/WhisperKitTests/Resources/jfk.wav")
        XCTAssertTrue(FileManager.default.fileExists(atPath: jfkURL.path), "Missing jfk.wav at \(jfkURL.path)")

        let tedURL = jfkURL.deletingLastPathComponent().appendingPathComponent("ted_60.m4a")
        XCTAssertTrue(FileManager.default.fileExists(atPath: tedURL.path), "Missing ted_60.m4a at \(tedURL.path)")

        let modelManager = WhisperKitModelManager()
        let service = WhisperKitTranscriptionService(
            modelManager: modelManager,
            variantProvider: { .compact }
        )

        let jfkTranscript = try await service.transcribe(
            audioFileURL: jfkURL,
            sessionID: "benchmark-jfk",
            locale: Locale(identifier: "en-US")
        )
        let jfkReference = "And so my fellow Americans ask not what your country can do for you ask what you can do for your country"
        let jfkAccuracy = Self.wordAccuracy(reference: jfkReference, hypothesis: jfkTranscript.fullText)
        print("BENCHMARK JFK -> Accuracy: \(String(format: "%.2f%%", jfkAccuracy * 100)) | Text: \(jfkTranscript.fullText)")
        XCTAssertGreaterThanOrEqual(jfkAccuracy, 0.90, "JFK word accuracy must be >= 90%, got \(jfkAccuracy)")

        let tedTranscript = try await service.transcribe(
            audioFileURL: tedURL,
            sessionID: "benchmark-ted",
            locale: Locale(identifier: "en-US")
        )
        let tedReference = "So in college I was a government major which means I had to write a lot of papers Now when a normal student writes a paper they might spread the work out a little like this So you know you get started maybe a little slowly but you get enough done in the first week that with some heavier days later on everything gets done and things stay civil And I would want to do that like that That would be the plan I would have it all ready to go But then actually the paper would come along And then I would kind of do this And that would happen every single paper But then came my 90 page senior thesis a paper you're supposed to spend a year on I knew for a paper like that my normal workflow was not an option It was way too big a project So I planned things out and I decided I kind of had to go something like this This is how the year would go So I'd start off light and I'd bump it up"
        let tedAccuracy = Self.wordAccuracy(reference: tedReference, hypothesis: tedTranscript.fullText)
        print("BENCHMARK TED -> Accuracy: \(String(format: "%.2f%%", tedAccuracy * 100)) | Words: \(tedTranscript.wordCount) | Segments: \(tedTranscript.segments.count)")
        XCTAssertGreaterThanOrEqual(tedAccuracy, 0.90, "TED 60s word accuracy must be >= 90%, got \(tedAccuracy)")
    }

    static func wordAccuracy(reference: String, hypothesis: String) -> Double {
        func normalize(_ text: String) -> [String] {
            text.lowercased()
                .components(separatedBy: CharacterSet.alphanumerics.inverted)
                .filter { !$0.isEmpty }
        }
        let ref = normalize(reference)
        let hyp = normalize(hypothesis)
        guard !ref.isEmpty else { return hyp.isEmpty ? 1.0 : 0.0 }

        var dp = Array(repeating: Array(repeating: 0, count: hyp.count + 1), count: ref.count + 1)
        for i in 0...ref.count { dp[i][0] = i }
        for j in 0...hyp.count { dp[0][j] = j }
        for i in 1...ref.count {
            for j in 1...hyp.count {
                if ref[i - 1] == hyp[j - 1] {
                    dp[i][j] = dp[i - 1][j - 1]
                } else {
                    dp[i][j] = 1 + min(dp[i - 1][j], dp[i][j - 1], dp[i - 1][j - 1])
                }
            }
        }
        let wer = Double(dp[ref.count][hyp.count]) / Double(ref.count)
        return max(0.0, 1.0 - wer)
    }
}

private final class LockedBox<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var _value: T
    init(_ value: T) { self._value = value }
    var value: T {
        get { lock.lock(); defer { lock.unlock() }; return _value }
        set { lock.lock(); defer { lock.unlock() }; _value = newValue }
    }
}
