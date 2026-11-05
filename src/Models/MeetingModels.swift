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

/// Metadata written to `metadata.json` inside each meeting recording directory (#43).
public struct MeetingRecordingMetadata: Codable, Equatable, Sendable {
    public let sessionID: String
    public let startedAt: Date
    public let endedAt: Date
    public let durationSeconds: TimeInterval
    public let captureMicrophone: Bool
    public let captureSystemAudio: Bool
    public let detectedAppNames: [String]
    /// Files the audio is in: `audio.m4a`, or `mic.caf` / `system.caf` while unmixed.
    public var audioFileNames: [String]
    /// "mixed" once `audio.m4a` is verified, "unmixed" while only the tracks exist (launch recovery mixes them).
    public var audioStatus: String
    /// True when launch recovery mixed the tracks after a crash or quit (absent otherwise).
    public var recovered: Bool?
    public var transcriptStatus: String
    /// Locale the on-device recognizer actually used (nil until a transcript is written).
    public var transcriptLocale: String?
    /// Where the transcript copy was exported (nil when export is off or failed).
    public var transcriptExportPath: String?

    public init(
        sessionID: String,
        startedAt: Date,
        endedAt: Date,
        durationSeconds: TimeInterval,
        captureMicrophone: Bool,
        captureSystemAudio: Bool,
        detectedAppNames: [String],
        audioFileNames: [String] = ["audio.m4a"],
        audioStatus: String = "mixed",
        recovered: Bool? = nil,
        transcriptStatus: String = "pending",
        transcriptLocale: String? = nil,
        transcriptExportPath: String? = nil
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
        self.transcriptStatus = transcriptStatus
        self.transcriptLocale = transcriptLocale
        self.transcriptExportPath = transcriptExportPath
    }

    private enum LegacyCodingKeys: String, CodingKey {
        case audioFileName
    }

    /// Also reads metadata from before the per-source tracks: one `audioFileName` and no `audioStatus`.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        sessionID = try container.decode(String.self, forKey: .sessionID)
        startedAt = try container.decode(Date.self, forKey: .startedAt)
        endedAt = try container.decode(Date.self, forKey: .endedAt)
        durationSeconds = try container.decode(TimeInterval.self, forKey: .durationSeconds)
        captureMicrophone = try container.decode(Bool.self, forKey: .captureMicrophone)
        captureSystemAudio = try container.decode(Bool.self, forKey: .captureSystemAudio)
        detectedAppNames = try container.decode([String].self, forKey: .detectedAppNames)
        let legacyFileName = try decoder.container(keyedBy: LegacyCodingKeys.self).decodeIfPresent(String.self, forKey: .audioFileName)
        audioFileNames = try container.decodeIfPresent([String].self, forKey: .audioFileNames)
            ?? legacyFileName.map { [$0] }
            ?? [MeetingTrackMixer.audioFileName]
        // Older recordings were encoded straight to audio.m4a
        audioStatus = try container.decodeIfPresent(String.self, forKey: .audioStatus)
            ?? (audioFileNames.contains(MeetingTrackMixer.audioFileName) ? "mixed" : "unmixed")
        recovered = try container.decodeIfPresent(Bool.self, forKey: .recovered)
        transcriptStatus = try container.decode(String.self, forKey: .transcriptStatus)
        transcriptLocale = try container.decodeIfPresent(String.self, forKey: .transcriptLocale)
        transcriptExportPath = try container.decodeIfPresent(String.self, forKey: .transcriptExportPath)
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

/// Summary of a completed meeting recording & transcription session (#43).
public struct MeetingRecordingResult: Equatable, Sendable {
    public let sessionID: String
    public let sessionDirectoryURL: URL
    public let audioFileURL: URL
    public let metadataFileURL: URL
    public let transcriptTextURL: URL?
    public let transcriptJSONURL: URL?
    public let durationSeconds: TimeInterval
    /// Capture interruption or transcription failure the user must see (nil when everything succeeded).
    public let warning: String?

    public init(
        sessionID: String,
        sessionDirectoryURL: URL,
        audioFileURL: URL,
        metadataFileURL: URL,
        transcriptTextURL: URL? = nil,
        transcriptJSONURL: URL? = nil,
        durationSeconds: TimeInterval,
        warning: String? = nil
    ) {
        self.sessionID = sessionID
        self.sessionDirectoryURL = sessionDirectoryURL
        self.audioFileURL = audioFileURL
        self.metadataFileURL = metadataFileURL
        self.transcriptTextURL = transcriptTextURL
        self.transcriptJSONURL = transcriptJSONURL
        self.durationSeconds = durationSeconds
        self.warning = warning
    }

    public var bubbleHeadline: String {
        if let warning {
            return "⚠️ Meeting audio saved. \(warning)"
        }
        return transcriptTextURL != nil ? "✨ Meeting saved & transcribed!" : "✨ Meeting audio saved!"
    }
}

/// Lifecycle state of the Meeting Audio Recorder & Transcription pipeline (#43).
public enum MeetingRecorderState: Equatable, Sendable {
    case idle
    case recording(sessionID: String, startedAt: Date, elapsedSeconds: Int)
    case transcribing(sessionID: String, sessionDirectoryURL: URL)
    case completed(MeetingRecordingResult)
    case failed(String)
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

/// Formatting helpers shared by the recorder, transcript writer and speech bubble (#43).
public enum MeetingFormatting {
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

    /// Generates a deterministic session folder name `YYYY-MM-DD_HH-mm-ss` in UTC/local calendar.
    public static func sessionFolderName(for date: Date, timeZone: TimeZone = .current) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = timeZone
        formatter.dateFormat = "yyyy-MM-dd_HH-mm-ss"
        return formatter.string(from: date)
    }
}
