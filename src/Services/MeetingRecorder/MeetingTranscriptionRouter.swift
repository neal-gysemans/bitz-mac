import Foundation

/// Routes meeting transcription requests to either WhisperKit AI or Apple Dictation based on settings (#204).
public final class MeetingTranscriptionRouter: MeetingDualTrackTranscriptionProviding, @unchecked Sendable {
    private let engineProvider: @MainActor @Sendable () -> MeetingTranscriptionEngine
    private let whisperService: any MeetingDualTrackTranscriptionProviding
    private let appleService: any MeetingTranscriptionProviding

    public init(
        engineProvider: @escaping @MainActor @Sendable () -> MeetingTranscriptionEngine,
        whisperService: any MeetingDualTrackTranscriptionProviding,
        appleService: any MeetingTranscriptionProviding = SpeechFrameworkTranscriptionService()
    ) {
        self.engineProvider = engineProvider
        self.whisperService = whisperService
        self.appleService = appleService
    }

    public func transcribe(
        audioFileURL: URL,
        sessionID: String,
        locale: Locale?
    ) async throws -> MeetingTranscript {
        let engine = await engineProvider()
        switch engine {
        case .whisperAI:
            return try await whisperService.transcribe(audioFileURL: audioFileURL, sessionID: sessionID, locale: locale)
        case .appleDictation:
            return try await appleService.transcribe(audioFileURL: audioFileURL, sessionID: sessionID, locale: locale)
        }
    }

    public func transcribeTracks(
        micURL: URL?,
        systemURL: URL?,
        fallbackAudioURL: URL,
        sessionID: String,
        locale: Locale?,
        onStatusUpdate: (@MainActor @Sendable (String) -> Void)?
    ) async throws -> MeetingTranscript {
        let engine = await engineProvider()
        switch engine {
        case .whisperAI:
            return try await whisperService.transcribeTracks(
                micURL: micURL,
                systemURL: systemURL,
                fallbackAudioURL: fallbackAudioURL,
                sessionID: sessionID,
                locale: locale,
                onStatusUpdate: onStatusUpdate
            )
        case .appleDictation:
            return try await appleService.transcribe(
                audioFileURL: fallbackAudioURL,
                sessionID: sessionID,
                locale: locale
            )
        }
    }
}
