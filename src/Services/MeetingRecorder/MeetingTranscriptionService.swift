@preconcurrency import AVFoundation
import Foundation
import Speech

// MARK: - Meeting Transcription Errors

public enum MeetingTranscriptionError: Error, LocalizedError, Equatable, Sendable {
    case recognizerUnavailable(String)
    case onDeviceRecognitionUnsupported(String)
    case recognitionFailed(String)
    case timedOut(TimeInterval)

    public var errorDescription: String? {
        switch self {
        case .recognizerUnavailable(let locale):
            return "Speech recognizer is unavailable for locale '\(locale)'."
        case .onDeviceRecognitionUnsupported(let locale):
            return "On-device speech recognition is not supported for locale '\(locale)'."
        case .recognitionFailed(let reason):
            return "Speech transcription failed: \(reason)"
        case .timedOut(let seconds):
            return "Speech transcription timed out after \(Int(seconds)) s."
        }
    }
}

// MARK: - Meeting Transcription Protocol

public protocol MeetingTranscriptionProviding: Sendable {
    /// `locale == nil` is Automatic: current locale, then the user's preferred languages.
    func transcribe(
        audioFileURL: URL,
        sessionID: String,
        locale: Locale?
    ) async throws -> MeetingTranscript
}

// MARK: - Native Apple Speech.framework On-Device Transcription Service

/// Performs offline, on-device speech recognition using Apple's `SFSpeechRecognizer` (#43).
public struct SpeechFrameworkTranscriptionService: MeetingTranscriptionProviding {
    public init() {}

    /// Configures a URL recognition request for offline on-device transcription.
    public static func makeRecognitionRequest(audioFileURL: URL) -> SFSpeechURLRecognitionRequest {
        let request = SFSpeechURLRecognitionRequest(url: audioFileURL)
        request.requiresOnDeviceRecognition = true
        request.shouldReportPartialResults = false
        return request
    }

    /// What the recognition task does after one callback.
    enum RecognitionStep: Equatable {
        case accumulate
        case finishSuccess
        case finishPartial(warning: String)
        case finishFailure(MeetingTranscriptionError)
    }

    /// Probed on macOS 26 (en-US, on-device): a silent or noise-only file fails with `kAFAssistantErrorDomain` 1110.
    static func isNoSpeechError(_ error: Error) -> Bool {
        let nsError = error as NSError
        return nsError.domain == "kAFAssistantErrorDomain" && nsError.code == 1110
    }

    /// Pure handling of one recognition callback (or the timeout, passed as `MeetingTranscriptionError.timedOut`):
    /// adds the result's utterance to `utterances`, then decides whether the task continues or finishes, and how.
    static func recognitionStep(
        result: (segments: [MeetingTranscriptSegment], text: String, isFinal: Bool)?,
        error: Error?,
        utterances: UtteranceAccumulator
    ) -> RecognitionStep {
        if let result {
            utterances.add(segments: result.segments, formattedString: result.text)
        }
        guard let error else {
            return result?.isFinal == true ? .finishSuccess : .accumulate
        }
        // An empty or silent recording is an empty transcript, not a failure
        if isNoSpeechError(error) {
            return .finishSuccess
        }
        // Keep what was recognized before the failure or timeout instead of losing the whole meeting
        if let timedOut = error as? MeetingTranscriptionError, case .timedOut = timedOut {
            return utterances.isEmpty ? .finishFailure(timedOut) : .finishPartial(warning: "Transcript may be incomplete: transcription timed out")
        }
        return utterances.isEmpty
            ? .finishFailure(.recognitionFailed(error.localizedDescription))
            : .finishPartial(warning: "Transcript may be incomplete: \(error.localizedDescription)")
    }

    /// Generous bound so a stalled recognizer can never leave `isTranscribing` stuck (estimate: on-device runs faster than real time).
    static func recognitionTimeout(forAudioDuration seconds: TimeInterval) -> TimeInterval {
        max(60, seconds * 2 + 60)
    }

    /// First locale with an on-device model: the requested (or current) locale, its same-language variants
    /// (en-US first for English), then for Automatic each preferred language and its variants.
    /// e.g. `en_BE` has no model and region-less fallback picks `en-GB` (also none), so this lands on `en-US`.
    static func resolveOnDeviceLocale(
        requested: Locale?,
        current: Locale = .current,
        preferredLanguages: [String] = Locale.preferredLanguages,
        supportedLocales: Set<Locale> = SFSpeechRecognizer.supportedLocales(),
        supportsOnDevice: (Locale) -> Bool = { SFSpeechRecognizer(locale: $0)?.supportsOnDeviceRecognition ?? false }
    ) throws -> Locale {
        let base = requested ?? current
        let supportedIDs = supportedLocales.map { $0.identifier(.bcp47) }.sorted()

        func withVariants(_ locale: Locale) -> [String] {
            guard let language = locale.language.languageCode?.identifier else { return [locale.identifier(.bcp47)] }
            let variants = supportedIDs.filter { Locale(identifier: $0).language.languageCode?.identifier == language }
            return [locale.identifier(.bcp47)] + (language == "en" ? ["en-US"] : []) + variants
        }

        var candidates = withVariants(base)
        if requested == nil {
            candidates += preferredLanguages.flatMap { withVariants(Locale(identifier: $0)) }
        }

        var seen = Set<String>()
        for id in candidates where seen.insert(id).inserted {
            let locale = Locale(identifier: id)
            if supportsOnDevice(locale) { return locale }
        }
        throw MeetingTranscriptionError.onDeviceRecognitionUnsupported(base.identifier)
    }

    /// On-device transcription languages for the Settings picker, sorted by display name.
    public static func onDeviceLocaleOptions() -> [(id: String, label: String)] {
        SFSpeechRecognizer.supportedLocales()
            .filter { SFSpeechRecognizer(locale: $0)?.supportsOnDeviceRecognition ?? false }
            .map { (id: $0.identifier, label: Locale.current.localizedString(forIdentifier: $0.identifier) ?? $0.identifier) }
            .sorted { $0.label.localizedStandardCompare($1.label) == .orderedAscending }
    }

    public func transcribe(
        audioFileURL: URL,
        sessionID: String,
        locale: Locale? = nil
    ) async throws -> MeetingTranscript {
        let chosenLocale = try Self.resolveOnDeviceLocale(requested: locale)
        guard let recognizer = SFSpeechRecognizer(locale: chosenLocale), recognizer.isAvailable else {
            throw MeetingTranscriptionError.recognizerUnavailable(chosenLocale.identifier)
        }

        let resolvedLocaleID = recognizer.locale.identifier
        let request = Self.makeRecognitionRequest(audioFileURL: audioFileURL)

        let audioDuration = (try? AVAudioFile(forReading: audioFileURL))
            .map { Double($0.length) / max(1, $0.fileFormat.sampleRate) } ?? 0
        let timeout = Self.recognitionTimeout(forAudioDuration: audioDuration)
        let state = ContinuationGate()
        let utterances = UtteranceAccumulator()
        // The task is cancelled if its recognizer is deallocated, so keep it alive until the result arrives
        defer { withExtendedLifetime(recognizer) {} }

        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                state.install(continuation)
                @Sendable func finish(_ step: RecognitionStep) {
                    switch step {
                    case .accumulate:
                        return
                    case .finishSuccess:
                        state.finish(.success(utterances.transcript(sessionID: sessionID, localeIdentifier: resolvedLocaleID)))
                    case .finishPartial(let warning):
                        state.finish(.success(utterances.transcript(sessionID: sessionID, localeIdentifier: resolvedLocaleID, warning: warning)))
                    case .finishFailure(let error):
                        state.finish(.failure(error))
                    }
                }
                let task = recognizer.recognitionTask(with: request) { result, error in
                    let utterance = result.map { result in
                        (
                            segments: result.bestTranscription.segments.map { seg in
                                MeetingTranscriptSegment(
                                    text: seg.substring,
                                    startTime: seg.timestamp,
                                    endTime: seg.timestamp + seg.duration,
                                    confidence: seg.confidence
                                )
                            },
                            text: result.bestTranscription.formattedString,
                            isFinal: result.isFinal
                        )
                    }
                    finish(Self.recognitionStep(result: utterance, error: error, utterances: utterances))
                }
                state.attach(task)
                DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + timeout) {
                    finish(Self.recognitionStep(result: nil, error: MeetingTranscriptionError.timedOut(timeout), utterances: utterances))
                }
            }
        } onCancel: {
            state.finish(.failure(CancellationError()))
        }
    }
}

/// Collects every recognized utterance. Even with `shouldReportPartialResults = false`, URL recognition delivers one
/// result per pause-separated utterance and only the last is `isFinal`, holding just the last utterance.
/// Locked: callbacks arrive on `SFSpeechRecognizer.queue`, but the timeout reads it from another queue.
final class UtteranceAccumulator: @unchecked Sendable {
    private let lock = NSLock()
    private var utterances: [TimeInterval: (segments: [MeetingTranscriptSegment], text: String)] = [:]

    var isEmpty: Bool { lock.withLock { utterances.isEmpty } }

    /// Keyed by the first segment's start time (absolute within the file). A result replaces every utterance that starts
    /// within its span, so a re-delivered utterance (even with a shifted start) or a cumulative result never duplicates text.
    /// A file ending in silence gets an empty final result (one `""` segment at 0.0); its span would erase the first utterance.
    func add(segments: [MeetingTranscriptSegment], formattedString: String) {
        let segments = segments.filter { !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        guard let start = segments.first?.startTime else { return }
        let span = start...max(start, segments.map(\.endTime).max() ?? start)
        lock.withLock {
            utterances = utterances.filter { !span.contains($0.key) }
            utterances[start] = (segments, formattedString)
        }
    }

    func transcript(sessionID: String, localeIdentifier: String, warning: String? = nil) -> MeetingTranscript {
        let ordered = lock.withLock { utterances.keys.sorted().compactMap { utterances[$0] } }
        return MeetingTranscript(
            sessionID: sessionID,
            localeIdentifier: localeIdentifier,
            generatedAt: Date(),
            fullText: ordered.map(\.text).joined(separator: " "),
            segments: ordered.flatMap(\.segments),
            warning: warning
        )
    }
}

/// Resumes the transcription continuation exactly once across the result callback, timeout, and cancellation.
final class ContinuationGate: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<MeetingTranscript, Error>?
    private var task: SFSpeechRecognitionTask?
    private var outcome: Result<MeetingTranscript, Error>?

    /// Stores the continuation, or resumes it at once when cancellation already finished the gate.
    func install(_ continuation: CheckedContinuation<MeetingTranscript, Error>) {
        lock.lock()
        if let outcome {
            lock.unlock()
            continuation.resume(with: outcome)
            return
        }
        self.continuation = continuation
        lock.unlock()
    }

    func attach(_ task: SFSpeechRecognitionTask) {
        lock.lock()
        let isFinished = outcome != nil
        if !isFinished { self.task = task }
        lock.unlock()
        if isFinished { task.cancel() }
    }

    func finish(_ result: Result<MeetingTranscript, Error>) {
        lock.lock()
        guard outcome == nil else {
            lock.unlock()
            return
        }
        outcome = result
        let continuation = self.continuation
        let task = self.task
        self.continuation = nil
        self.task = nil
        lock.unlock()
        // A timeout can finish with a partial transcript (success) while the task still runs, so always cancel it
        task?.cancel()
        continuation?.resume(with: result)
    }
}

// MARK: - Transcript File Writer

public enum MeetingTranscriptWriter {
    public static func write(
        _ transcript: MeetingTranscript,
        to sessionDirectoryURL: URL
    ) throws -> (txtURL: URL, jsonURL: URL) {
        try FileManager.default.createDirectory(at: sessionDirectoryURL, withIntermediateDirectories: true)

        let txtURL = sessionDirectoryURL.appendingPathComponent("transcript.txt")
        let jsonURL = sessionDirectoryURL.appendingPathComponent("transcript.json")

        let plainText = transcript.formattedPlainText()
        try plainText.write(to: txtURL, atomically: true, encoding: .utf8)

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let jsonData = try encoder.encode(transcript)
        try jsonData.write(to: jsonURL, options: .atomic)

        return (txtURL, jsonURL)
    }
}
