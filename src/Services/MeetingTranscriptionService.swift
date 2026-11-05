import Foundation
import Speech

// MARK: - Meeting Transcription Errors

public enum MeetingTranscriptionError: Error, LocalizedError, Equatable, Sendable {
    case recognizerUnavailable(String)
    case onDeviceRecognitionUnsupported(String)
    case recognitionFailed(String)

    public var errorDescription: String? {
        switch self {
        case .recognizerUnavailable(let locale):
            return "Speech recognizer is unavailable for locale '\(locale)'."
        case .onDeviceRecognitionUnsupported(let locale):
            return "On-device speech recognition is not supported for locale '\(locale)'."
        case .recognitionFailed(let reason):
            return "Speech transcription failed: \(reason)"
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

        return try await withCheckedThrowingContinuation { continuation in
            let state = ContinuationGate()
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
                        state.resumeOnce(with: .success(emptyTranscript), continuation: continuation)
                    } else {
                        state.resumeOnce(
                            with: .failure(MeetingTranscriptionError.recognitionFailed(nsError.localizedDescription)),
                            continuation: continuation
                        )
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
                state.resumeOnce(with: .success(transcript), continuation: continuation)
            }
            _ = task
        }
    }
}

private final class ContinuationGate: @unchecked Sendable {
    private let lock = NSLock()
    private var hasResumed = false

    func resumeOnce(
        with result: Result<MeetingTranscript, Error>,
        continuation: CheckedContinuation<MeetingTranscript, Error>
    ) {
        lock.lock()
        defer { lock.unlock() }
        guard !hasResumed else { return }
        hasResumed = true
        continuation.resume(with: result)
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
