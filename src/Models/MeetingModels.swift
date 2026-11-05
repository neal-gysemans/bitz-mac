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
    public let audioFileName: String
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
        audioFileName: String = "audio.m4a",
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
        self.audioFileName = audioFileName
        self.transcriptStatus = transcriptStatus
        self.transcriptLocale = transcriptLocale
        self.transcriptExportPath = transcriptExportPath
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
                    let stamp = MeetingSettingsStore.formatDuration(Int(currentStart.rounded(.down)))
                    lines.append("[\(stamp)] \(currentPhraseWords.joined(separator: " "))")
                    currentPhraseWords.removeAll(keepingCapacity: true)
                }
            }
            if !currentPhraseWords.isEmpty {
                let stamp = MeetingSettingsStore.formatDuration(Int(currentStart.rounded(.down)))
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

// MARK: - Meeting Settings Store

/// Persists user preferences for the Local Meeting Recorder & On-Device Transcription (#43).
@MainActor
public final class MeetingSettingsStore: ObservableObject {
    public static let captureMicrophoneKey = "Bitz.MeetingRecorder.CaptureMicrophone"
    public static let captureSystemAudioKey = "Bitz.MeetingRecorder.CaptureSystemAudio"
    public static let autoTranscribeKey = "Bitz.MeetingRecorder.AutoTranscribe"
    public static let copyTranscriptPathKey = "Bitz.MeetingRecorder.CopyTranscriptPath"
    public static let meetingsDirectoryPathKey = "Bitz.MeetingRecorder.DirectoryPath"
    public static let transcriptionLocaleKey = "Bitz.MeetingRecorder.TranscriptionLocale"
    public static let transcriptExportDirectoryPathKey = "Bitz.MeetingRecorder.TranscriptExportDirectoryPath"

    @Published public private(set) var captureMicrophone: Bool
    @Published public private(set) var captureSystemAudio: Bool
    @Published public private(set) var autoTranscribeOnStop: Bool
    @Published public private(set) var copyTranscriptPathToClipboard: Bool
    @Published public private(set) var meetingsRootDirectoryURL: URL
    /// nil = Automatic; otherwise a locale identifier such as `nl-BE`.
    @Published public private(set) var transcriptionLocaleIdentifier: String?
    /// Optional folder that also receives a copy of each `transcript.txt` (nil = off).
    @Published public private(set) var transcriptExportDirectoryURL: URL?

    private let userDefaults: UserDefaults

    /// Application Support, not `~/Documents`: Documents is commonly synced (iCloud, OneDrive) and Spotlight-indexed,
    /// so confidential meetings could leave the Mac before the user ever opens Settings.
    nonisolated public static var defaultMeetingsDirectoryURL: URL {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support", isDirectory: true)
        return appSupport
            .appendingPathComponent("Bitz", isDirectory: true)
            .appendingPathComponent("Meetings", isDirectory: true)
    }

    public var isUsingDefaultMeetingsDirectory: Bool {
        meetingsRootDirectoryURL.standardizedFileURL.path == Self.defaultMeetingsDirectoryURL.standardizedFileURL.path
    }

    /// Warning when `url` is likely synced off the Mac, nil otherwise.
    nonisolated public static func syncWarning(
        for url: URL,
        home: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> String? {
        let path = url.standardizedFileURL.path
        func isInside(_ relative: String) -> Bool {
            let base = home.appendingPathComponent(relative).standardizedFileURL.path
            return path == base || path.hasPrefix(base + "/")
        }
        if isInside("Library/Mobile Documents") || isInside("Library/CloudStorage") {
            return "This folder is synced to a cloud service."
        }
        if isInside("Documents") || isInside("Desktop") {
            return "macOS may sync this folder to iCloud (Desktop & Documents)."
        }
        return nil
    }

    public init(userDefaults: UserDefaults = .standard) {
        self.userDefaults = userDefaults

        if userDefaults.object(forKey: Self.captureMicrophoneKey) != nil {
            self.captureMicrophone = userDefaults.bool(forKey: Self.captureMicrophoneKey)
        } else {
            self.captureMicrophone = true
        }

        if userDefaults.object(forKey: Self.captureSystemAudioKey) != nil {
            self.captureSystemAudio = userDefaults.bool(forKey: Self.captureSystemAudioKey)
        } else {
            self.captureSystemAudio = true
        }

        if userDefaults.object(forKey: Self.autoTranscribeKey) != nil {
            self.autoTranscribeOnStop = userDefaults.bool(forKey: Self.autoTranscribeKey)
        } else {
            self.autoTranscribeOnStop = true
        }

        if userDefaults.object(forKey: Self.copyTranscriptPathKey) != nil {
            self.copyTranscriptPathToClipboard = userDefaults.bool(forKey: Self.copyTranscriptPathKey)
        } else {
            self.copyTranscriptPathToClipboard = false
        }

        if let savedPath = userDefaults.string(forKey: Self.meetingsDirectoryPathKey),
           !savedPath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            let expanded = (savedPath as NSString).expandingTildeInPath
            self.meetingsRootDirectoryURL = URL(fileURLWithPath: expanded, isDirectory: true)
        } else {
            self.meetingsRootDirectoryURL = Self.defaultMeetingsDirectoryURL
        }

        self.transcriptionLocaleIdentifier = userDefaults.string(forKey: Self.transcriptionLocaleKey)

        if let savedExportPath = userDefaults.string(forKey: Self.transcriptExportDirectoryPathKey),
           !savedExportPath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            let expanded = (savedExportPath as NSString).expandingTildeInPath
            self.transcriptExportDirectoryURL = URL(fileURLWithPath: expanded, isDirectory: true)
        } else {
            self.transcriptExportDirectoryURL = nil
        }
    }

    public func setCaptureMicrophone(_ enabled: Bool) {
        captureMicrophone = enabled
        userDefaults.set(enabled, forKey: Self.captureMicrophoneKey)
    }

    public func setCaptureSystemAudio(_ enabled: Bool) {
        captureSystemAudio = enabled
        userDefaults.set(enabled, forKey: Self.captureSystemAudioKey)
    }

    public func setAutoTranscribeOnStop(_ enabled: Bool) {
        autoTranscribeOnStop = enabled
        userDefaults.set(enabled, forKey: Self.autoTranscribeKey)
    }

    public func setCopyTranscriptPathToClipboard(_ enabled: Bool) {
        copyTranscriptPathToClipboard = enabled
        userDefaults.set(enabled, forKey: Self.copyTranscriptPathKey)
    }

    /// nil resets to the default folder. Existing recordings are never moved.
    public func setMeetingsRootDirectoryURL(_ url: URL?) {
        meetingsRootDirectoryURL = url ?? Self.defaultMeetingsDirectoryURL
        userDefaults.set(url?.path, forKey: Self.meetingsDirectoryPathKey)
    }

    public func setTranscriptExportDirectoryURL(_ url: URL?) {
        transcriptExportDirectoryURL = url
        userDefaults.set(url?.path, forKey: Self.transcriptExportDirectoryPathKey)
    }

    public func setTranscriptionLocaleIdentifier(_ identifier: String?) {
        transcriptionLocaleIdentifier = identifier
        userDefaults.set(identifier, forKey: Self.transcriptionLocaleKey)
    }

    /// Formats elapsed seconds as `MM:SS` (or `HH:MM:SS` when >= 1 hour).
    nonisolated public static func formatDuration(_ totalSeconds: Int) -> String {
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
    nonisolated public static func sessionFolderName(for date: Date, timeZone: TimeZone = .current) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = timeZone
        formatter.dateFormat = "yyyy-MM-dd_HH-mm-ss"
        return formatter.string(from: date)
    }
}
