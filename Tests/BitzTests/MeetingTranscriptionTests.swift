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
        // Re-delivered utterance whose start shifted a little later
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
}
