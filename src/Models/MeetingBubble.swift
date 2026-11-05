import Foundation

/// Which capture path broke mid-recording (#43 D5); picks the interruption bubble's text.
public enum MeetingCaptureSource: Sendable, Equatable {
    case microphone
    case systemAudio
    /// A track could not be written (full disk, removed volume); both sources may still be live.
    case storage
}

/// The one meeting recorder bubble (#43 D5). `SpeechBubbleView`, `SpeechBubbleContent.current`, the bubble panel's
/// click-through and the personality idle check all read it; every meeting recorder text lives here as a constant.
public struct MeetingBubble: Equatable, Sendable {
    public enum Kind: Equatable, Sendable {
        case recording, interruption, saving, transcribing, completion, failure
    }

    public enum Action: Hashable, Sendable {
        case transcribeAgain, openInFinder, openSettings, dismiss

        public var title: String {
            switch self {
            case .transcribeAgain: return "TRANSCRIBE AGAIN"
            case .openInFinder: return "OPEN IN FINDER"
            case .openSettings: return "OPEN SETTINGS"
            case .dismiss: return "DISMISS"
            }
        }

        public var accessibilityLabel: String {
            switch self {
            case .transcribeAgain: return "Transcribe Recording Again"
            case .openInFinder: return "Open Meeting in Finder"
            case .openSettings: return "Open Audio Settings"
            case .dismiss: return "Dismiss Meeting Notice"
            }
        }
    }

    public let kind: Kind
    /// Headline: one short clause, never truncated.
    public let text: String
    /// Optional cause (error text, skipped reason); the full text is also in `statusMessage`.
    public let detail: String?
    public let actions: [Action]

    public init(kind: Kind, text: String, detail: String? = nil, actions: [Action] = []) {
        self.kind = kind
        self.text = text
        self.detail = detail
        self.actions = actions
    }

    /// Only a bubble with buttons makes the bubble panel take clicks (AGENTS.md §4.1).
    public var isInteractive: Bool { !actions.isEmpty }

    // MARK: - Texts

    public static let recordingText = "🔴 Recording meeting"
    public static let savingText = "💾 Saving meeting…"
    public static let transcribingText = "✨ Meeting saved! Transcribing…"

    public static let micLostSystemContinuesText = "⚠️ Mic disconnected — still recording system audio"
    public static let systemLostMicContinuesText = "⚠️ System audio stopped — still recording your mic"
    public static let micLostNothingLeftText = "⚠️ Mic disconnected — nothing is being recorded"
    public static let systemLostNothingLeftText = "⚠️ System audio stopped — nothing is being recorded"
    public static let storageFailedText = "⚠️ Can't write audio — check free disk space"

    public static let savedAndTranscribedText = "✨ Meeting saved & transcribed!"
    public static let audioSavedText = "✨ Meeting audio saved!"
    public static let savedWithWarningText = "⚠️ Meeting saved with a warning"
    public static let transcriptFailedText = "⚠️ Audio saved — transcript failed"
    public static let transcriptSkippedText = "⚠️ Audio saved — transcript skipped"

    public static let speechNotAllowedReason = "Speech Recognition is not allowed — Settings → Audio."
    public static let transcriptionOffReason = "Transcription is turned off."
    public static let previousTranscriptKeptWarning = "Transcribe Again failed — previous transcript kept"
    public static let noSpeechKeptWarning = "Transcribe Again found no speech — previous transcript kept"
    public static let stoppedEarlyKeptWarning = "Transcribe Again stopped early — previous complete transcript kept"
    public static let noMoreTextKeptWarning = "Transcribe Again found no more text — previous transcript kept"
    public static let micOnlyWarning = "Transcribed from the microphone track only — the meeting audio wasn't mixed yet."
    public static let transcriptNotSavedError = "Transcript recognized but could not be saved"
    public static let metadataUnreadableError = "metadata.json could not be read."

    public static let needsPermissionText = "⚠️ Recording needs permission"
    public static let noSourceText = "⚠️ Turn on Microphone or System Audio"
    public static let lowDiskText = "⚠️ Not enough disk space to record"
    public static let couldNotStartText = "⚠️ Recording couldn't start"

    public static let stillSavingText = "⏳ Still saving the last meeting — try again in a moment"
    public static let stillTranscribingText = "⏳ Still transcribing the last meeting — try again in a moment"

    public static let savingMenuLabel = "Saving…"
    public static let transcribingMenuLabel = "Transcribing…"

    // MARK: - Bubbles

    public static let recording = MeetingBubble(kind: .recording, text: recordingText)
    public static let saving = MeetingBubble(kind: .saving, text: savingText)
    public static let transcribing = MeetingBubble(kind: .transcribing, text: transcribingText)
    /// A start refused while the last meeting is busy; same look as the busy bubble it briefly covers.
    public static let stillSaving = MeetingBubble(kind: .saving, text: stillSavingText)
    public static let stillTranscribing = MeetingBubble(kind: .transcribing, text: stillTranscribingText)

    /// `remaining`: sources still recording after `source` dropped.
    public static func interruption(_ source: MeetingCaptureSource, remaining: Set<MeetingCaptureSource>) -> MeetingBubble {
        let text: String
        switch source {
        case .microphone:
            text = remaining.contains(.systemAudio) ? micLostSystemContinuesText : micLostNothingLeftText
        case .systemAudio:
            text = remaining.contains(.microphone) ? systemLostMicContinuesText : systemLostNothingLeftText
        case .storage:
            text = storageFailedText
        }
        return MeetingBubble(kind: .interruption, text: text, actions: [.dismiss])
    }

    public static func failure(_ text: String, detail: String? = nil) -> MeetingBubble {
        MeetingBubble(kind: .failure, text: text, detail: detail, actions: [.openSettings, .dismiss])
    }

    public static func completion(for result: MeetingRecordingResult) -> MeetingBubble {
        let text: String
        if result.transcriptError != nil {
            text = transcriptFailedText
        } else if result.transcriptSkipReason != nil {
            text = transcriptSkippedText
        } else if result.warning != nil {
            text = savedWithWarningText
        } else {
            text = result.transcriptTextURL != nil ? savedAndTranscribedText : audioSavedText
        }
        let causes = [result.transcriptError, result.transcriptSkipReason?.text, result.warning].compactMap { $0 }
        let actions: [Action] = result.transcriptTextURL == nil
            ? [.transcribeAgain, .openInFinder, .dismiss]
            : [.openInFinder, .dismiss]
        return MeetingBubble(
            kind: .completion,
            text: text,
            detail: causes.isEmpty ? nil : causes.joined(separator: " "),
            actions: actions
        )
    }
}
