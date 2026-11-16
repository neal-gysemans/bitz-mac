import Foundation
import Speech
import XCTest
@testable import BitzCore

// MARK: - On-device transcription

@MainActor
final class MeetingTranscriptionTests: XCTestCase {
    func testSpeechFrameworkRequestRequiresOnDeviceRecognition() {
        let dummyURL = FileManager.default.temporaryDirectory.appendingPathComponent("audio.m4a")
        let request = SpeechFrameworkTranscriptionService.makeRecognitionRequest(audioFileURL: dummyURL)
        XCTAssertTrue(request.requiresOnDeviceRecognition, "Must enforce 100% offline on-device recognition")
        XCTAssertFalse(request.shouldReportPartialResults)
    }

    func testTranscriptionGateResumesOnceEvenWhenCancelledBeforeStart() async {
        let gate = ContinuationGate()
        gate.finish(.failure(CancellationError()))
        gate.finish(.failure(MeetingTranscriptionError.timedOut(1)))
        do {
            _ = try await withCheckedThrowingContinuation { gate.install($0) }
            XCTFail("Expected cancellation")
        } catch {
            XCTAssertTrue(error is CancellationError)
        }
        XCTAssertEqual(SpeechFrameworkTranscriptionService.recognitionTimeout(forAudioDuration: 0), 60)
        XCTAssertEqual(SpeechFrameworkTranscriptionService.recognitionTimeout(forAudioDuration: 600), 1_260)
    }

    // MARK: - Transcription language (on-device locale resolution)

    private func resolve(
        _ requested: String?,
        current: String = "en_BE",
        preferred: [String] = ["en-BE", "nl-BE"],
        onDevice: Set<String>
    ) throws -> String {
        let supported: Set<Locale> = Set(["en-US", "en-GB", "en-AU", "nl-NL", "nl-BE"].map(Locale.init(identifier:)))
        return try SpeechFrameworkTranscriptionService.resolveOnDeviceLocale(
            requested: requested.map(Locale.init(identifier:)),
            current: Locale(identifier: current),
            preferredLanguages: preferred,
            supportedLocales: supported,
            supportsOnDevice: { onDevice.contains($0.identifier(.bcp47)) }
        ).identifier(.bcp47)
    }

    func testTranscriptionLocaleFallsBackToOnDeviceVariant() throws {
        XCTAssertEqual(try resolve("en-GB", onDevice: ["en-US", "nl-BE"]), "en-US")
        XCTAssertEqual(try resolve("nl-BE", onDevice: ["en-US", "nl-BE"]), "nl-BE")
        XCTAssertEqual(try resolve(nil, onDevice: ["en-AU", "nl-BE"]), "en-AU", "Automatic keeps the user's language (English)")
        XCTAssertEqual(try resolve(nil, onDevice: ["en-AU", "en-US", "nl-BE"]), "en-US", "en-US is tried first among English variants")
        XCTAssertEqual(try resolve(nil, current: "fr_BE", onDevice: ["nl-BE"]), "nl-BE", "Automatic then tries preferred languages")
        XCTAssertThrowsError(try resolve("en-GB", onDevice: []))

        do {
            _ = try resolve("nl-NL", onDevice: [])
            XCTFail("Should throw missingOnDeviceAsset")
        } catch let MeetingTranscriptionError.missingOnDeviceAsset(locale, _) {
            XCTAssertEqual(locale, "nl-NL")
        } catch {
            XCTFail("Unexpected error: \(error)")
        }

        do {
            _ = try resolve(nil, current: "en_BE", onDevice: [])
            XCTFail("Should throw missingOnDeviceAsset for en_BE with first supported candidate")
        } catch let MeetingTranscriptionError.missingOnDeviceAsset(locale, _) {
            XCTAssertEqual(locale, "en-US")
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    // MARK: - Utterance accumulation (one recognition result per utterance)

    private func segments(_ words: String, from start: TimeInterval) -> [MeetingTranscriptSegment] {
        words.split(separator: " ").enumerated().map { index, word in
            let t = start + Double(index) * 0.4
            return MeetingTranscriptSegment(text: String(word), startTime: t, endTime: t + 0.35, confidence: 0.9)
        }
    }

    func testUtteranceAccumulatorKeepsEveryUtteranceInOrder() {
        // Mirrors the live probe: three pause-separated results, only the last one final
        let first = "First sentence about the project budget"
        let second = "Second sentence about the timeline of the next steps"
        let third = "Third sentence OK I am going to stop recording now"
        let accumulator = UtteranceAccumulator()
        accumulator.add(segments: segments(first, from: 0.0), formattedString: first)
        accumulator.add(segments: segments(second, from: 6.45), formattedString: second)
        accumulator.add(segments: segments(third, from: 13.77), formattedString: third)

        let transcript = accumulator.transcript(sessionID: "s", localeIdentifier: "en-US")
        XCTAssertEqual(transcript.fullText, "\(first) \(second) \(third)")
        XCTAssertEqual(transcript.segments.count, 6 + 9 + 10)
        XCTAssertEqual(transcript.segments.first?.text, "First")
        XCTAssertEqual(transcript.segments.last?.text, "now")
        XCTAssertEqual(transcript.segments.map(\.startTime), transcript.segments.map(\.startTime).sorted())
        XCTAssertNil(transcript.warning)

        let plain = transcript.formattedPlainText()
        XCTAssertTrue(plain.contains("budget") && plain.contains("timeline") && plain.contains("recording now"))
    }

    func testUtteranceAccumulatorReplacesRedeliveredUtterance() {
        let accumulator = UtteranceAccumulator()
        accumulator.add(segments: segments("Hello team", from: 2.0), formattedString: "Hello team")
        accumulator.add(segments: segments("Bye", from: 9.0), formattedString: "Bye")
        accumulator.add(segments: segments("Hello team, welcome", from: 2.0), formattedString: "Hello team, welcome")
        accumulator.add(segments: [], formattedString: "")

        let transcript = accumulator.transcript(sessionID: "s", localeIdentifier: "en-US", warning: "partial")
        XCTAssertEqual(transcript.fullText, "Hello team, welcome Bye")
        XCTAssertEqual(transcript.segments.count, 4)
        XCTAssertEqual(transcript.warning, "partial")
    }

    func testUtteranceAccumulatorDropsOverlappedUtterances() {
        // Re-delivered utterance whose start shifted a little earlier
        let shifted = UtteranceAccumulator()
        shifted.add(segments: segments("Hello team", from: 2.0), formattedString: "Hello team")
        shifted.add(segments: segments("Hello team today", from: 1.9), formattedString: "Hello team today")
        XCTAssertEqual(shifted.transcript(sessionID: "s", localeIdentifier: "en-US").fullText, "Hello team today")

        // One cumulative result spanning several earlier utterances replaces them all, later ones stay
        let cumulative = UtteranceAccumulator()
        cumulative.add(segments: segments("One two", from: 0.0), formattedString: "One two")
        cumulative.add(segments: segments("Three four", from: 3.0), formattedString: "Three four")
        cumulative.add(segments: segments("Later", from: 20.0), formattedString: "Later")
        let span = segments("One two", from: 0.0) + segments("three four", from: 3.0)
        cumulative.add(segments: span, formattedString: "One two three four")
        let transcript = cumulative.transcript(sessionID: "s", localeIdentifier: "en-US")
        XCTAssertEqual(transcript.fullText, "One two three four Later")
        XCTAssertEqual(transcript.segments.count, 5)
    }

    func testEmptyFinalResultKeepsTheFirstUtterance() {
        // Probed shape (macOS 26): a file ending in silence gets a final result with one empty segment at 0.0
        let seg = { (text: String, start: Double, end: Double) in
            MeetingTranscriptSegment(text: text, startTime: start, endTime: end, confidence: 0.9)
        }
        let results: [(segments: [MeetingTranscriptSegment], text: String, isFinal: Bool)] = [
            ([seg("Good", 0.0, 0.5), seg("numbers", 3.0, 3.57)], "Good morning numbers", false),
            ([seg("The", 6.0, 6.5), seg("year", 8.5, 9.0)], "The second year", false),
            ([seg("", 0.0, 0.0)], "", true),
        ]
        let utterances = UtteranceAccumulator()
        let steps = results.map {
            SpeechFrameworkTranscriptionService.recognitionStep(result: $0, error: nil, utterances: utterances)
        }
        XCTAssertEqual(steps, [.accumulate, .accumulate, .finishSuccess], "the empty final result still finishes")
        let transcript = utterances.transcript(sessionID: "s", localeIdentifier: "en-US")
        XCTAssertEqual(transcript.fullText, "Good morning numbers The second year")
        XCTAssertEqual(transcript.segments.map(\.text), ["Good", "numbers", "The", "year"])
    }

    // MARK: - Recognition callback handling

    private typealias Step = SpeechFrameworkTranscriptionService.RecognitionStep

    private func step(
        words: String? = nil,
        isFinal: Bool = false,
        error: Error? = nil,
        priorUtterance: Bool = false
    ) -> (step: Step, transcript: MeetingTranscript) {
        let utterances = UtteranceAccumulator()
        if priorUtterance {
            utterances.add(segments: segments("Earlier words", from: 0.0), formattedString: "Earlier words")
        }
        let result = words.map { (segments: segments($0, from: 10.0), text: $0, isFinal: isFinal) }
        let step = SpeechFrameworkTranscriptionService.recognitionStep(result: result, error: error, utterances: utterances)
        return (step, utterances.transcript(sessionID: "s", localeIdentifier: "en-US"))
    }

    func testRecognitionCallbackTable() {
        let noSpeech = NSError(domain: "kAFAssistantErrorDomain", code: 1110, userInfo: [NSLocalizedDescriptionKey: "Anything"])
        let otherError = NSError(domain: "kAFAssistantErrorDomain", code: 1101, userInfo: [NSLocalizedDescriptionKey: "Model crashed"])
        // Detected by domain and code, never by the English message
        let noSpeechText = NSError(domain: "SomeOtherDomain", code: 1110, userInfo: [NSLocalizedDescriptionKey: "No speech detected"])

        let silent = step(error: noSpeech)
        XCTAssertEqual(silent.step, .finishSuccess)
        XCTAssertEqual(silent.transcript.fullText, "")

        let partial = step(error: otherError, priorUtterance: true)
        XCTAssertEqual(partial.step, .finishPartial(warning: "Transcript may be incomplete: Model crashed"))
        XCTAssertEqual(partial.transcript.fullText, "Earlier words")

        XCTAssertEqual(step(error: otherError).step, .finishFailure(.recognitionFailed("Model crashed")))
        XCTAssertEqual(step(error: noSpeechText).step, .finishFailure(.recognitionFailed("No speech detected")))

        // Precedence: an error delivered with a result still counts that result, and is not a full success
        let errorWithResult = step(words: "Last words", error: otherError)
        XCTAssertEqual(errorWithResult.step, .finishPartial(warning: "Transcript may be incomplete: Model crashed"))
        XCTAssertEqual(errorWithResult.transcript.fullText, "Last words")

        let final = step(words: "Last words", isFinal: true, priorUtterance: true)
        XCTAssertEqual(final.step, .finishSuccess)
        XCTAssertEqual(final.transcript.fullText, "Earlier words Last words")

        let interim = step(words: "Middle words")
        XCTAssertEqual(interim.step, .accumulate)
        XCTAssertEqual(interim.transcript.fullText, "Middle words")
    }

    func testTimeoutKeepsPartialTranscript() {
        let timeout = MeetingTranscriptionError.timedOut(60)
        XCTAssertEqual(
            step(error: timeout, priorUtterance: true).step,
            .finishPartial(warning: "Transcript may be incomplete: transcription timed out")
        )
        XCTAssertEqual(step(error: timeout).step, .finishFailure(timeout))
    }

    // MARK: - On-Device Asset Status & Error Classification (#148)

    func testCheckOnDeviceAssetStatus() {
        let fake = Locale(identifier: "xx-YY")
        let unsupported = SpeechFrameworkTranscriptionService.checkOnDeviceAssetStatus(
            for: fake,
            supportedLocales: [],
            supportsOnDevice: { _ in false },
            isAvailable: { _ in false }
        )
        XCTAssertEqual(unsupported, .unsupported)

        let dutch = Locale(identifier: "nl-NL")
        let needsDownload = SpeechFrameworkTranscriptionService.checkOnDeviceAssetStatus(
            for: dutch,
            supportedLocales: [dutch],
            supportsOnDevice: { _ in false },
            isAvailable: { _ in false }
        )
        XCTAssertEqual(needsDownload, .needsDownload)

        let ready = SpeechFrameworkTranscriptionService.checkOnDeviceAssetStatus(
            for: dutch,
            supportedLocales: [dutch],
            supportsOnDevice: { _ in true },
            isAvailable: { _ in true }
        )
        XCTAssertEqual(ready, .ready)
    }

    func testIsMissingAssetErrorClassification() {
        let assistantError = NSError(domain: "kAFAssistantErrorDomain", code: 1700, userInfo: [NSLocalizedDescriptionKey: "No Assistant asset for language nl-NL"])
        XCTAssertTrue(SpeechFrameworkTranscriptionService.isMissingAssetError(assistantError))

        let code1107Error = NSError(domain: "kAFAssistantErrorDomain", code: 1107, userInfo: [NSLocalizedDescriptionKey: "Asset missing"])
        XCTAssertTrue(SpeechFrameworkTranscriptionService.isMissingAssetError(code1107Error))

        let textError = NSError(domain: "SpeechError", code: 1, userInfo: [NSLocalizedDescriptionKey: "No Assistant asset for language nl-NL"])
        XCTAssertTrue(SpeechFrameworkTranscriptionService.isMissingAssetError(textError))

        let unrelatedError = NSError(domain: "Network", code: -1009, userInfo: [NSLocalizedDescriptionKey: "The Internet connection appears to be offline."])
        XCTAssertFalse(SpeechFrameworkTranscriptionService.isMissingAssetError(unrelatedError))

        let enumError = MeetingTranscriptionError.missingOnDeviceAsset(locale: "nl-NL", languageDisplayName: "Dutch")
        XCTAssertTrue(SpeechFrameworkTranscriptionService.isMissingAssetError(enumError))
        XCTAssertTrue(enumError.localizedDescription.contains("Dutch"))
        XCTAssertTrue(enumError.localizedDescription.contains("nl-NL"))
        XCTAssertTrue(enumError.localizedDescription.contains("Dictation"))
    }

    func testMissingAssetErrorYieldsMissingOnDeviceAssetStep() {
        let assetError = NSError(domain: "kAFAssistantErrorDomain", code: 1700, userInfo: [NSLocalizedDescriptionKey: "No Assistant asset for language nl-NL"])
        let utterances = UtteranceAccumulator()
        let step = SpeechFrameworkTranscriptionService.recognitionStep(
            result: nil,
            error: assetError,
            utterances: utterances,
            resolvedLocaleID: "nl-NL"
        )
        let expectedError = MeetingTranscriptionError.missingOnDeviceAsset(
            locale: "nl-NL",
            languageDisplayName: Locale.current.localizedString(forIdentifier: "nl-NL") ?? "nl-NL"
        )
        XCTAssertEqual(step, .finishFailure(expectedError))
    }

    func testInvalidateCachedLocaleOptions() {
        _ = SpeechFrameworkTranscriptionService.onDeviceLocaleOptions()
        let options1 = SpeechFrameworkTranscriptionService.cachedOnDeviceLocaleOptions()
        XCTAssertFalse(options1.isEmpty)

        // Invalidating resets freshness without dropping cached options for @MainActor callers
        SpeechFrameworkTranscriptionService.invalidateCachedLocaleOptions()
        let options2 = SpeechFrameworkTranscriptionService.cachedOnDeviceLocaleOptions()
        XCTAssertEqual(options1.count, options2.count)
    }

    func testDictationLocaleIdentifiersFiltersDisabledAndSorts() {
        let prefs: [String: Any] = [
            "VisibleNetworkSRLocaleIdentifiers": [
                "nl_BE": 1,
                "fr_FR": 0,
                "de_DE": true,
                "zh_Hans_CN": 1,
                "zh_Hant_TW": 1,
                "zh_Hant_HK": 1
            ]
        ]
        XCTAssertEqual(
            SpeechFrameworkTranscriptionService.dictationLocaleIdentifiers(prefs: prefs),
            ["de-DE", "nl-BE", "zh-CN", "zh-HK", "zh-TW"]
        )
        XCTAssertEqual(SpeechFrameworkTranscriptionService.dictationLocaleIdentifiers(prefs: nil), [])
    }

    func testCandidateLocaleIdentifiersFiltersToDictationWithOnDeviceFallback() {
        let supported: Set<Locale> = Set(["en-US", "nl-BE", "fr-FR", "zh-CN", "zh-TW", "zh-HK"].map(Locale.init(identifier:)))
        let filtered = SpeechFrameworkTranscriptionService.candidateLocaleIdentifiers(
            dictationLocales: ["nl_BE", "zh_Hans_CN", "zh_Hant_TW", "zh_Hant_HK", "xx-YY"],
            supportedLocales: supported,
            supportsOnDevice: { $0.identifier == "en-US" }
        )
        XCTAssertEqual(filtered, ["nl-BE", "zh-CN", "zh-TW", "zh-HK"])

        let fallback = SpeechFrameworkTranscriptionService.candidateLocaleIdentifiers(
            dictationLocales: [],
            supportedLocales: supported,
            supportsOnDevice: { $0.identifier == "en-US" }
        )
        XCTAssertEqual(fallback, ["en-US"])
    }

    // MARK: - Long-Audio Windowing & Audio Slicing (#200)

    func testMaxWindowDurationConstant() {
        XCTAssertEqual(SpeechFrameworkTranscriptionService.maxWindowDuration, 180.0)
    }

    func testWindowContinuationGateResumesOnce() async {
        let gate = WindowContinuationGate()
        gate.finish(.success(()))
        gate.finish(.failure(MeetingTranscriptionError.timedOut(1)))
        do {
            try await withCheckedThrowingContinuation { gate.install($0) }
        } catch {
            XCTFail("Should not have thrown after success")
        }
    }

    func testWindowContinuationGateHandlesCancellation() async {
        let gate = WindowContinuationGate()
        gate.finish(.failure(CancellationError()))
        do {
            try await withCheckedThrowingContinuation { gate.install($0) }
            XCTFail("Expected CancellationError")
        } catch {
            XCTAssertTrue(error is CancellationError)
        }
    }

    func testSliceAudioCreatesValidPCMFile() throws {
        // Create a 5-second 48kHz stereo test CAF file
        let sampleRate: Double = 48_000
        let format = MeetingTrackWriter.canonicalPCMFormat
        let tempDir = FileManager.default.temporaryDirectory
        let sourceURL = tempDir.appendingPathComponent("test_slice_src_\(UUID().uuidString).caf")
        defer { try? FileManager.default.removeItem(at: sourceURL) }

        let frameCount: AVAudioFrameCount = 48_000 * 5 // 5 seconds
        let sourceFile = try AVAudioFile(
            forWriting: sourceURL,
            settings: [
                AVFormatIDKey: kAudioFormatLinearPCM,
                AVSampleRateKey: sampleRate,
                AVNumberOfChannelsKey: 2,
                AVLinearPCMBitDepthKey: 16,
                AVLinearPCMIsFloatKey: false,
                AVLinearPCMIsBigEndianKey: false,
                AVLinearPCMIsNonInterleaved: false
            ],
            commonFormat: .pcmFormatFloat32,
            interleaved: false
        )
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount)!
        buffer.frameLength = frameCount
        try sourceFile.write(from: buffer)

        // Slice 2 seconds starting at second 1.0
        let sliceURL = try SpeechFrameworkTranscriptionService.sliceAudio(
            from: sourceURL,
            startSeconds: 1.0,
            durationSeconds: 2.0
        )
        defer { try? FileManager.default.removeItem(at: sliceURL) }

        XCTAssertTrue(FileManager.default.fileExists(atPath: sliceURL.path))
        let slicedFile = try AVAudioFile(forReading: sliceURL)
        XCTAssertEqual(slicedFile.fileFormat.sampleRate, sampleRate)
        XCTAssertEqual(slicedFile.fileFormat.channelCount, 2)
        // 2 seconds * 48000 = 96000 frames
        XCTAssertEqual(slicedFile.length, 96_000)

        // Slicing beyond end of file must throw
        XCTAssertThrowsError(
            try SpeechFrameworkTranscriptionService.sliceAudio(
                from: sourceURL,
                startSeconds: 10.0,
                durationSeconds: 1.0
            )
        )
    }

    func testMultiWindowOffsetAccumulation() {
        let accumulator = UtteranceAccumulator()

        // Window 0 (0s - 180s)
        let win0Segments = [
            MeetingTranscriptSegment(text: "Hello", startTime: 10.0, endTime: 10.5, confidence: 0.9),
            MeetingTranscriptSegment(text: "world", startTime: 10.6, endTime: 11.0, confidence: 0.9)
        ]
        accumulator.add(segments: win0Segments, formattedString: "Hello world")

        // Window 1 (180s - 360s, offset = 180s)
        let win1Segments = [
            MeetingTranscriptSegment(text: "Second", startTime: 185.0, endTime: 185.5, confidence: 0.9),
            MeetingTranscriptSegment(text: "window", startTime: 185.6, endTime: 186.0, confidence: 0.9)
        ]
        accumulator.add(segments: win1Segments, formattedString: "Second window")

        let transcript = accumulator.transcript(sessionID: "test", localeIdentifier: "nl-BE")
        XCTAssertEqual(transcript.fullText, "Hello world Second window")
        XCTAssertEqual(transcript.segments.count, 4)
        XCTAssertEqual(transcript.segments[0].startTime, 10.0)
        XCTAssertEqual(transcript.segments[2].startTime, 185.0)
    }

    // MARK: - Dual-Track Speaker Attribution & Gain Boost (#202)

    func testMeetingTranscriptSegmentSpeakerAttributionAndEncoding() throws {
        let segYou = MeetingTranscriptSegment(text: "Hello", startTime: 1.0, endTime: 1.5, confidence: 0.95, speaker: "You")
        let segPart = MeetingTranscriptSegment(text: "Hi", startTime: 2.0, endTime: 2.4, confidence: 0.92, speaker: "Participants")
        let segLegacy = MeetingTranscriptSegment(text: "Legacy", startTime: 3.0, endTime: 3.5, confidence: 0.90)

        XCTAssertEqual(segYou.speaker, "You")
        XCTAssertEqual(segPart.speaker, "Participants")
        XCTAssertNil(segLegacy.speaker)

        // Test round-trip encoding/decoding
        let encoder = JSONEncoder()
        let decoder = JSONDecoder()

        let dataYou = try encoder.encode(segYou)
        let decodedYou = try decoder.decode(MeetingTranscriptSegment.self, from: dataYou)
        XCTAssertEqual(decodedYou.speaker, "You")
        XCTAssertEqual(decodedYou.text, "Hello")

        // Test backwards compatibility: JSON without "speaker" key decodes as nil
        let jsonWithoutSpeaker = """
        {"text":"Old","start_time":0.5,"end_time":1.0,"confidence":0.88}
        """.data(using: .utf8)!
        let decodedLegacy = try decoder.decode(MeetingTranscriptSegment.self, from: jsonWithoutSpeaker)
        XCTAssertNil(decodedLegacy.speaker)
        XCTAssertEqual(decodedLegacy.text, "Old")
    }

    func testMeetingTranscriptFormattedPlainTextSpeakerTurns() {
        let segments = [
            MeetingTranscriptSegment(text: "Hello", startTime: 1.0, endTime: 1.4, confidence: 0.9, speaker: "You"),
            MeetingTranscriptSegment(text: "everyone.", startTime: 1.5, endTime: 2.0, confidence: 0.9, speaker: "You"),
            MeetingTranscriptSegment(text: "Good", startTime: 3.0, endTime: 3.3, confidence: 0.9, speaker: "Participants"),
            MeetingTranscriptSegment(text: "morning!", startTime: 3.4, endTime: 3.8, confidence: 0.9, speaker: "Participants"),
            MeetingTranscriptSegment(text: "Can", startTime: 5.0, endTime: 5.3, confidence: 0.9, speaker: "You"),
            MeetingTranscriptSegment(text: "you", startTime: 5.4, endTime: 5.6, confidence: 0.9, speaker: "You"),
            MeetingTranscriptSegment(text: "hear", startTime: 5.7, endTime: 5.9, confidence: 0.9, speaker: "You"),
            MeetingTranscriptSegment(text: "me?", startTime: 6.0, endTime: 6.3, confidence: 0.9, speaker: "You"),
            MeetingTranscriptSegment(text: "Yes", startTime: 7.0, endTime: 7.2, confidence: 0.9, speaker: "Participants"),
            MeetingTranscriptSegment(text: "clearly.", startTime: 7.3, endTime: 7.6, confidence: 0.9, speaker: "Participants")
        ]

        let transcript = MeetingTranscript(
            sessionID: "test_session",
            localeIdentifier: "en-US",
            generatedAt: Date(),
            fullText: "Hello everyone. Good morning! Can you hear me? Yes clearly.",
            segments: segments
        )

        let plainText = transcript.formattedPlainText()
        let expectedLines = [
            "# Bitz Meeting Transcript (test_session)",
            "Locale: en-US",
            "",
            "[00:01] You: Hello everyone.",
            "[00:03] Participants: Good morning!",
            "[00:05] You: Can you hear me?",
            "[00:07] Participants: Yes clearly.",
            ""
        ]
        XCTAssertEqual(plainText, expectedLines.joined(separator: "\n"))
    }

    func testSliceAudioBoostGainScalingAndClipping() throws {
        let sampleRate: Double = 48_000
        let format = MeetingTrackWriter.canonicalPCMFormat
        let tempDir = FileManager.default.temporaryDirectory
        let sourceURL = tempDir.appendingPathComponent("test_boost_src_\(UUID().uuidString).caf")
        defer { try? FileManager.default.removeItem(at: sourceURL) }

        let frameCount: AVAudioFrameCount = 48_000 // 1 second
        let sourceFile = try AVAudioFile(
            forWriting: sourceURL,
            settings: [
                AVFormatIDKey: kAudioFormatLinearPCM,
                AVSampleRateKey: sampleRate,
                AVNumberOfChannelsKey: 2,
                AVLinearPCMBitDepthKey: 16,
                AVLinearPCMIsFloatKey: false,
                AVLinearPCMIsBigEndianKey: false,
                AVLinearPCMIsNonInterleaved: false
            ],
            commonFormat: .pcmFormatFloat32,
            interleaved: false
        )
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount)!
        buffer.frameLength = frameCount
        // Populate channel 0 with 0.20 and channel 1 with 0.70
        let ch0 = buffer.floatChannelData![0]
        let ch1 = buffer.floatChannelData![1]
        for i in 0..<Int(frameCount) {
            ch0[i] = 0.20
            ch1[i] = 0.70
        }
        try sourceFile.write(from: buffer)

        // Slice with boostGain: 2.5. 0.20 * 2.5 = 0.50. 0.70 * 2.5 = 1.75 -> clipped to 1.0
        let sliceURL = try SpeechFrameworkTranscriptionService.sliceAudio(
            from: sourceURL,
            startSeconds: 0.0,
            durationSeconds: 0.5,
            boostGain: 2.5
        )
        defer { try? FileManager.default.removeItem(at: sliceURL) }

        let slicedFile = try AVAudioFile(forReading: sliceURL)
        let readBuffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(slicedFile.length))!
        try slicedFile.read(into: readBuffer)

        let readCh0 = readBuffer.floatChannelData![0]
        let readCh1 = readBuffer.floatChannelData![1]
        XCTAssertEqual(readCh0[100], 0.50, accuracy: 0.02)
        XCTAssertEqual(readCh1[100], 1.00, accuracy: 0.02)
    }

    func testTranscribeDualTrackMergesAndSortsChronologically() async throws {
        struct DualMockService: MeetingTranscriptionProviding {
            func transcribe(
                audioFileURL: URL,
                sessionID: String,
                locale: Locale?
            ) async throws -> MeetingTranscript {
                MeetingTranscript(
                    sessionID: sessionID,
                    localeIdentifier: locale?.identifier ?? "en-US",
                    generatedAt: Date(),
                    fullText: "Fallback audio",
                    segments: []
                )
            }

            func transcribeDualTrack(
                micURL: URL?,
                systemURL: URL?,
                fallbackURL: URL,
                sessionID: String,
                locale: Locale?
            ) async throws -> MeetingTranscript {
                let micSegments = [
                    MeetingTranscriptSegment(text: "Hello", startTime: 1.0, endTime: 1.5, confidence: 0.9, speaker: "You"),
                    MeetingTranscriptSegment(text: "there", startTime: 1.6, endTime: 2.0, confidence: 0.9, speaker: "You")
                ]
                let systemSegments = [
                    MeetingTranscriptSegment(text: "Hi", startTime: 2.5, endTime: 2.8, confidence: 0.9, speaker: "Participants"),
                    MeetingTranscriptSegment(text: "Bitz", startTime: 2.9, endTime: 3.2, confidence: 0.9, speaker: "Participants")
                ]
                let merged = (micSegments + systemSegments).sorted { $0.startTime < $1.startTime }
                return MeetingTranscript(
                    sessionID: sessionID,
                    localeIdentifier: "en-US",
                    generatedAt: Date(),
                    fullText: merged.map(\.text).joined(separator: " "),
                    segments: merged
                )
            }
        }

        let service = DualMockService()
        let result = try await service.transcribeDualTrack(
            micURL: URL(fileURLWithPath: "/tmp/mic.caf"),
            systemURL: URL(fileURLWithPath: "/tmp/system.caf"),
            fallbackURL: URL(fileURLWithPath: "/tmp/audio.m4a"),
            sessionID: "sess_dual",
            locale: Locale(identifier: "en-US")
        )

        XCTAssertEqual(result.segments.count, 4)
        XCTAssertEqual(result.segments[0].speaker, "You")
        XCTAssertEqual(result.segments[1].speaker, "You")
        XCTAssertEqual(result.segments[2].speaker, "Participants")
        XCTAssertEqual(result.segments[3].speaker, "Participants")
        XCTAssertEqual(result.fullText, "Hello there Hi Bitz")
    }
}
