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
    func transcribe(
        audioFileURL: URL,
        sessionID: String,
        locale: Locale
    ) async throws -> MeetingTranscript
}

// MARK: - Native Apple Speech.framework On-Device Transcription Service

/// Performs 100% offline, on-device speech recognition using Apple's `SFSpeechRecognizer` (#43).
public struct SpeechFrameworkTranscriptionService: MeetingTranscriptionProviding {
    public let enforceOnDeviceRecognition: Bool

    public init(enforceOnDeviceRecognition: Bool = true) {
        self.enforceOnDeviceRecognition = enforceOnDeviceRecognition
    }

    /// Configures a URL recognition request for offline on-device transcription.
    public static func makeRecognitionRequest(
        audioFileURL: URL,
        enforceOnDevice: Bool = true
    ) -> SFSpeechURLRecognitionRequest {
        let request = SFSpeechURLRecognitionRequest(url: audioFileURL)
        request.requiresOnDeviceRecognition = enforceOnDevice
        request.shouldReportPartialResults = false
        return request
    }

    /// Generous bound so a stalled recognizer can never leave `isTranscribing` stuck (estimate: on-device runs faster than real time).
    static func recognitionTimeout(forAudioDuration seconds: TimeInterval) -> TimeInterval {
        max(60, seconds * 2 + 60)
    }

    public func transcribe(
        audioFileURL: URL,
        sessionID: String,
        locale: Locale = .current
    ) async throws -> MeetingTranscript {
        let resolvedRecognizer = SFSpeechRecognizer(locale: locale)
            ?? SFSpeechRecognizer(locale: Locale(identifier: "en-US"))

        guard let recognizer = resolvedRecognizer, recognizer.isAvailable else {
            throw MeetingTranscriptionError.recognizerUnavailable(locale.identifier)
        }

        let resolvedLocaleID = recognizer.locale.identifier
        if enforceOnDeviceRecognition && !recognizer.supportsOnDeviceRecognition {
            throw MeetingTranscriptionError.onDeviceRecognitionUnsupported(resolvedLocaleID)
        }

        let request = Self.makeRecognitionRequest(
            audioFileURL: audioFileURL,
            enforceOnDevice: enforceOnDeviceRecognition
        )

        let audioDuration = (try? AVAudioFile(forReading: audioFileURL))
            .map { Double($0.length) / max(1, $0.fileFormat.sampleRate) } ?? 0
        let timeout = Self.recognitionTimeout(forAudioDuration: audioDuration)
        let state = ContinuationGate()
        // The task is cancelled if its recognizer is deallocated, so keep it alive until the result arrives
        defer { withExtendedLifetime(recognizer) {} }

        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                state.install(continuation)
                let task = recognizer.recognitionTask(with: request) { result, error in
                    if let error {
                        // An empty/silent audio file can report "No speech detected"; treat that as an empty transcript
                        let nsError = error as NSError
                        let lowerDesc = nsError.localizedDescription.lowercased()
                        if lowerDesc.contains("no speech") || lowerDesc.contains("retry") && result != nil {
                            let emptyTranscript = MeetingTranscript(
                                sessionID: sessionID,
                                localeIdentifier: resolvedLocaleID,
                                generatedAt: Date(),
                                fullText: "",
                                segments: []
                            )
                            state.finish(.success(emptyTranscript))
                        } else {
                            state.finish(.failure(MeetingTranscriptionError.recognitionFailed(nsError.localizedDescription)))
                        }
                        return
                    }

                    guard let result, result.isFinal else { return }

                    let segments = result.bestTranscription.segments.map { seg in
                        MeetingTranscriptSegment(
                            text: seg.substring,
                            startTime: seg.timestamp,
                            endTime: seg.timestamp + seg.duration,
                            confidence: seg.confidence
                        )
                    }

                    let transcript = MeetingTranscript(
                        sessionID: sessionID,
                        localeIdentifier: resolvedLocaleID,
                        generatedAt: Date(),
                        fullText: result.bestTranscription.formattedString,
                        segments: segments
                    )
                    state.finish(.success(transcript))
                }
                state.attach(task)
                DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + timeout) {
                    state.finish(.failure(MeetingTranscriptionError.timedOut(timeout)))
                }
            }
        } onCancel: {
            state.finish(.failure(CancellationError()))
        }
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
        if case .failure = result { task?.cancel() }
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
