import AppKit
import Foundation

// MARK: - Meeting Permission State

/// Permission status for the three native macOS capabilities used by the Meeting Recorder (#43).
public struct MeetingPermissionState: Equatable, Sendable {
    public enum Status: String, Codable, Sendable, Equatable {
        case notDetermined
        case denied
        case authorized

        public var displayLabel: String {
            switch self {
            case .authorized: return "Granted"
            case .denied: return "Denied"
            case .notDetermined: return "Not Requested"
            }
        }
    }

    public var microphone: Status
    public var screenAudio: Status
    public var speechRecognition: Status

    public init(
        microphone: Status = .notDetermined,
        screenAudio: Status = .notDetermined,
        speechRecognition: Status = .notDetermined
    ) {
        self.microphone = microphone
        self.screenAudio = screenAudio
        self.speechRecognition = speechRecognition
    }

    public func canRecord(captureMicrophone: Bool, captureSystemAudio: Bool) -> Bool {
        guard captureMicrophone || captureSystemAudio else { return false }
        let micOK = !captureMicrophone || microphone == .authorized
        let systemOK = !captureSystemAudio || screenAudio == .authorized
        return micOK && systemOK
    }

    public var canTranscribe: Bool {
        speechRecognition == .authorized
    }
}

// MARK: - Meeting Recording Metadata & Transcript Models

/// Metadata written to `metadata.json` inside each meeting recording directory (#43). Keys are snake_case like
/// `transcript.json`; files from earlier builds (camelCase keys, or one `audioFileName`) still decode, because
/// retention and launch recovery only touch sessions whose metadata decodes.
public struct MeetingRecordingMetadata: Codable, Equatable, Sendable {
    public enum TranscriptStatus: String, Codable, Sendable {
        case pending, skipped, completed, failed, interrupted
    }

    public enum AudioStatus: String, Codable, Sendable {
        /// `audio.m4a` is a verified mix.
        case mixed
        /// Only the tracks exist; launch recovery mixes them.
        case unmixed
        /// Every track holds no frames.
        case empty
    }

    public let sessionID: String
    public let startedAt: Date
    public let endedAt: Date
    public let durationSeconds: TimeInterval
    public let captureMicrophone: Bool
    public let captureSystemAudio: Bool
    /// Names of the running meeting apps, matched by bundle ID (browsers are never listed).
    public let detectedAppNames: [String]
    /// Files the audio is in: `audio.m4a`, or `mic.caf` / `system.caf` while unmixed.
    public var audioFileNames: [String]
    public var audioStatus: AudioStatus
    /// True when launch recovery mixed the tracks after a crash or quit (absent otherwise).
    public var recovered: Bool?
    /// Tracks that went into `audio.m4a`, recorded before it appears; only these are deleted as leftovers.
    public var mixedTracks: [String]?
    public var transcriptStatus: TranscriptStatus
    /// Locale the on-device recognizer actually used (nil until a transcript is written).
    public var transcriptLocale: String?
    /// File name of the transcript copy in the export folder (nil when export is off or failed). No path is stored.
    public var transcriptExportFileName: String?

    public init(
        sessionID: String,
        startedAt: Date,
        endedAt: Date,
        durationSeconds: TimeInterval,
        captureMicrophone: Bool,
        captureSystemAudio: Bool,
        detectedAppNames: [String],
        audioFileNames: [String] = ["audio.m4a"],
        audioStatus: AudioStatus = .mixed,
        recovered: Bool? = nil,
        mixedTracks: [String]? = nil,
        transcriptStatus: TranscriptStatus = .pending,
        transcriptLocale: String? = nil,
        transcriptExportFileName: String? = nil
    ) {
        self.sessionID = sessionID
        self.startedAt = startedAt
        self.endedAt = endedAt
        self.durationSeconds = durationSeconds
        self.captureMicrophone = captureMicrophone
        self.captureSystemAudio = captureSystemAudio
        self.detectedAppNames = detectedAppNames
        self.audioFileNames = audioFileNames
        self.audioStatus = audioStatus
        self.recovered = recovered
        self.mixedTracks = mixedTracks
        self.transcriptStatus = transcriptStatus
        self.transcriptLocale = transcriptLocale
        self.transcriptExportFileName = transcriptExportFileName
    }

    enum CodingKeys: String, CodingKey {
        case sessionID = "session_id"
        case startedAt = "started_at"
        case endedAt = "ended_at"
        case durationSeconds = "duration_seconds"
        case captureMicrophone = "capture_microphone"
        case captureSystemAudio = "capture_system_audio"
        case detectedAppNames = "detected_apps"
        case audioFileNames = "audio_files"
        case audioStatus = "audio_status"
        case recovered
        case mixedTracks = "mixed_tracks"
        case transcriptStatus = "transcript_status"
        case transcriptLocale = "transcript_locale"
        case transcriptExportFileName = "transcript_export_file_name"
    }

    /// Keys written by earlier builds of this branch.
    private enum LegacyCodingKeys: String, CodingKey {
        case sessionID, startedAt, endedAt, durationSeconds, captureMicrophone, captureSystemAudio, detectedAppNames
        case audioFileNames, audioFileName, audioStatus, transcriptStatus, transcriptLocale, transcriptExportPath
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let legacy = try decoder.container(keyedBy: LegacyCodingKeys.self)
        func optional<T: Decodable>(_ key: CodingKeys, _ legacyKey: LegacyCodingKeys) throws -> T? {
            try container.decodeIfPresent(T.self, forKey: key) ?? legacy.decodeIfPresent(T.self, forKey: legacyKey)
        }
        func required<T: Decodable>(_ key: CodingKeys, _ legacyKey: LegacyCodingKeys) throws -> T {
            // Neither key present: the snake_case decode throws keyNotFound
            try optional(key, legacyKey) ?? container.decode(T.self, forKey: key)
        }
        sessionID = try required(.sessionID, .sessionID)
        startedAt = try required(.startedAt, .startedAt)
        endedAt = try required(.endedAt, .endedAt)
        durationSeconds = try required(.durationSeconds, .durationSeconds)
        captureMicrophone = try required(.captureMicrophone, .captureMicrophone)
        captureSystemAudio = try required(.captureSystemAudio, .captureSystemAudio)
        detectedAppNames = try required(.detectedAppNames, .detectedAppNames)
        // Before the per-source tracks: one `audioFileName` and no `audioStatus`
        audioFileNames = try optional(.audioFileNames, .audioFileNames)
            ?? legacy.decodeIfPresent(String.self, forKey: .audioFileName).map { [$0] }
            ?? [MeetingTrackMixer.audioFileName]
        // Older recordings were encoded straight to audio.m4a
        audioStatus = try optional(.audioStatus, .audioStatus)
            ?? (audioFileNames.contains(MeetingTrackMixer.audioFileName) ? .mixed : .unmixed)
        recovered = try container.decodeIfPresent(Bool.self, forKey: .recovered)
        mixedTracks = try container.decodeIfPresent([String].self, forKey: .mixedTracks)
        transcriptStatus = try required(.transcriptStatus, .transcriptStatus)
        transcriptLocale = try optional(.transcriptLocale, .transcriptLocale)
        transcriptExportFileName = try container.decodeIfPresent(String.self, forKey: .transcriptExportFileName)
            ?? legacy.decodeIfPresent(String.self, forKey: .transcriptExportPath).map { ($0 as NSString).lastPathComponent }
    }
}

/// A single timestamped segment from on-device speech recognition (#43).
public struct MeetingTranscriptSegment: Codable, Equatable, Sendable {
    public let text: String
    public let startTime: TimeInterval
    public let endTime: TimeInterval
    public let confidence: Float

    enum CodingKeys: String, CodingKey {
        case text
        case startTime = "start_time"
        case endTime = "end_time"
        case confidence
    }

    public init(
        text: String,
        startTime: TimeInterval,
        endTime: TimeInterval,
        confidence: Float
    ) {
        self.text = text
        self.startTime = startTime
        self.endTime = endTime
        self.confidence = confidence
    }
}

/// Structured on-device transcript exported to `transcript.json` and formatted into `transcript.txt` (#43).
public struct MeetingTranscript: Codable, Equatable, Sendable {
    public let sessionID: String
    public let localeIdentifier: String
    public let generatedAt: Date
    public let fullText: String
    public let segments: [MeetingTranscriptSegment]
    /// Set when recognition stopped early and only part of the recording was transcribed.
    public let warning: String?

    enum CodingKeys: String, CodingKey {
        case sessionID = "session_id"
        case localeIdentifier = "locale"
        case generatedAt = "generated_at"
        case fullText = "full_text"
        case segments
        case warning
    }

    public init(
        sessionID: String,
        localeIdentifier: String,
        generatedAt: Date = Date(),
        fullText: String,
        segments: [MeetingTranscriptSegment],
        warning: String? = nil
    ) {
        self.sessionID = sessionID
        self.localeIdentifier = localeIdentifier
        self.generatedAt = generatedAt
        self.fullText = fullText
        self.segments = segments
        self.warning = warning
    }

    /// Formats a human-readable plain-text transcript with timestamped lines for `transcript.txt`.
    public func formattedPlainText() -> String {
        var lines: [String] = [
            "# Bitz Meeting Transcript (\(sessionID))",
            "Locale: \(localeIdentifier)",
            ""
        ]

        let trimmedFull = fullText.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmedFull.isEmpty && segments.isEmpty {
            lines.append("(No speech detected in recording.)")
            return lines.joined(separator: "\n") + "\n"
        }

        if !segments.isEmpty {
            // Group word-level segments into readable ~10-second or sentence-ending phrases
            var currentPhraseWords: [String] = []
            var currentStart: TimeInterval = segments[0].startTime
            for segment in segments {
                let word = segment.text.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !word.isEmpty else { continue }
                if currentPhraseWords.isEmpty {
                    currentStart = segment.startTime
                }
                currentPhraseWords.append(word)
                let elapsedInPhrase = segment.endTime - currentStart
                let endsSentence = word.hasSuffix(".") || word.hasSuffix("?") || word.hasSuffix("!")
                if endsSentence || elapsedInPhrase >= 10.0 || currentPhraseWords.count >= 18 {
                    let stamp = MeetingFormatting.formatDuration(Int(currentStart.rounded(.down)))
                    lines.append("[\(stamp)] \(currentPhraseWords.joined(separator: " "))")
                    currentPhraseWords.removeAll(keepingCapacity: true)
                }
            }
            if !currentPhraseWords.isEmpty {
                let stamp = MeetingFormatting.formatDuration(Int(currentStart.rounded(.down)))
                lines.append("[\(stamp)] \(currentPhraseWords.joined(separator: " "))")
            }
        } else {
            lines.append(trimmedFull)
        }

        return lines.joined(separator: "\n") + "\n"
    }
}

/// Why a recording has no transcript although transcription did not fail.
public enum MeetingTranscriptSkipReason: Equatable, Sendable {
    case speechRecognitionNotAllowed
    case transcriptionTurnedOff

    public var text: String {
        switch self {
        case .speechRecognitionNotAllowed: return MeetingBubble.speechNotAllowedReason
        case .transcriptionTurnedOff: return MeetingBubble.transcriptionOffReason
        }
    }
}

/// Summary of a completed meeting recording & transcription session (#43).
public struct MeetingRecordingResult: Equatable, Sendable {
    public let sessionID: String
    public let sessionDirectoryURL: URL
    public let audioFileURL: URL
    public let metadataFileURL: URL
    public let transcriptTextURL: URL?
    public let transcriptJSONURL: URL?
    public let durationSeconds: TimeInterval
    /// Capture interruption, mix, export or partial-transcript problem the user must see (nil when everything succeeded).
    public let warning: String?
    public let transcriptSkipReason: MeetingTranscriptSkipReason?
    /// Why transcription failed and no transcript exists (nil when it succeeded, was skipped or never ran).
    public let transcriptError: String?

    public init(
        sessionID: String,
        sessionDirectoryURL: URL,
        audioFileURL: URL,
        metadataFileURL: URL,
        transcriptTextURL: URL? = nil,
        transcriptJSONURL: URL? = nil,
        durationSeconds: TimeInterval,
        warning: String? = nil,
        transcriptSkipReason: MeetingTranscriptSkipReason? = nil,
        transcriptError: String? = nil
    ) {
        self.sessionID = sessionID
        self.sessionDirectoryURL = sessionDirectoryURL
        self.audioFileURL = audioFileURL
        self.metadataFileURL = metadataFileURL
        self.transcriptTextURL = transcriptTextURL
        self.transcriptJSONURL = transcriptJSONURL
        self.durationSeconds = durationSeconds
        self.warning = warning
        self.transcriptSkipReason = transcriptSkipReason
        self.transcriptError = transcriptError
    }
}

/// Lifecycle state of the Meeting Audio Recorder & Transcription pipeline (#43).
/// The session and result live on `MeetingRecorderService`; the failure text is its `statusMessage`.
public enum MeetingRecorderState: Equatable, Sendable {
    case idle
    case recording
    /// Between Stop and the end of the mix: capture is closed, `audio.m4a` is being written.
    case saving
    case transcribing
    case completed
    case failed
}

// MARK: - Meeting Recording Hotkey

/// Global start/stop chord. A global monitor can't swallow keystrokes, so ⌥⇧R also typed "‰" into the focused app;
/// the default is a non-typing chord, and Off disables it (#43).
public enum MeetingRecordingHotkey: String, CaseIterable, Identifiable, Sendable {
    case controlOptionCommandR
    case controlOptionR
    case controlShiftR
    case off

    public static let keyCode: UInt16 = 15
    public static let character = "r"

    public var id: String { rawValue }

    /// nil when Off.
    public var modifierFlags: NSEvent.ModifierFlags? {
        switch self {
        case .controlOptionCommandR: return [.control, .option, .command]
        case .controlOptionR: return [.control, .option]
        case .controlShiftR: return [.control, .shift]
        case .off: return nil
        }
    }

    public var displayString: String {
        switch self {
        case .controlOptionCommandR: return "⌃⌥⌘R"
        case .controlOptionR: return "⌃⌥R"
        case .controlShiftR: return "⌃⇧R"
        case .off: return "Off"
        }
    }

    /// Exact modifier match, so ⌃⌥⌘R does not also fire ⌃⌥R.
    public func matches(_ event: NSEvent) -> Bool {
        guard let required = modifierFlags else { return false }
        let pressed = event.modifierFlags.intersection([.control, .option, .command, .shift])
        let isR = event.keyCode == Self.keyCode || event.charactersIgnoringModifiers?.lowercased() == Self.character
        return pressed == required && isR
    }
}

// MARK: - Meeting Formatting

/// Formatting helpers shared by the recorder and transcript writer (#43).
public enum MeetingFormatting {
    /// `metadata.json` and `transcript.json`: pretty, sorted keys, ISO 8601 dates.
    public static func jsonEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }

    /// Formats elapsed seconds as `MM:SS` (or `HH:MM:SS` when >= 1 hour).
    public static func formatDuration(_ totalSeconds: Int) -> String {
        let clamped = max(0, totalSeconds)
        let hours = clamped / 3600
        let minutes = (clamped % 3600) / 60
        let seconds = clamped % 60
        if hours > 0 {
            return String(format: "%02d:%02d:%02d", hours, minutes, seconds)
        }
        return String(format: "%02d:%02d", minutes, seconds)
    }

    /// Generates a deterministic session folder name `YYYY-MM-DD_HH-mm-ss` in `timeZone` (local time by default).
    public static func sessionFolderName(for date: Date, timeZone: TimeZone = .current) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = timeZone
        formatter.dateFormat = "yyyy-MM-dd_HH-mm-ss"
        return formatter.string(from: date)
    }
}
