import Foundation

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
    public static let recordingHotkeyKey = "Bitz.MeetingRecorder.RecordingHotkey"

    @Published public private(set) var captureMicrophone: Bool
    @Published public private(set) var captureSystemAudio: Bool
    @Published public private(set) var autoTranscribeOnStop: Bool
    @Published public private(set) var copyTranscriptPathToClipboard: Bool
    @Published public private(set) var meetingsRootDirectoryURL: URL
    /// nil = Automatic; otherwise a locale identifier such as `nl-BE`.
    @Published public private(set) var transcriptionLocaleIdentifier: String?
    /// Optional folder that also receives a copy of each `transcript.txt` (nil = off).
    @Published public private(set) var transcriptExportDirectoryURL: URL?
    @Published public private(set) var recordingHotkey: MeetingRecordingHotkey

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

        self.recordingHotkey = userDefaults.string(forKey: Self.recordingHotkeyKey)
            .flatMap(MeetingRecordingHotkey.init(rawValue:)) ?? .controlOptionCommandR
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

    public func setRecordingHotkey(_ hotkey: MeetingRecordingHotkey) {
        recordingHotkey = hotkey
        userDefaults.set(hotkey.rawValue, forKey: Self.recordingHotkeyKey)
    }

    public func setTranscriptExportDirectoryURL(_ url: URL?) {
        transcriptExportDirectoryURL = url
        userDefaults.set(url?.path, forKey: Self.transcriptExportDirectoryPathKey)
    }

    public func setTranscriptionLocaleIdentifier(_ identifier: String?) {
        transcriptionLocaleIdentifier = identifier
        userDefaults.set(identifier, forKey: Self.transcriptionLocaleKey)
    }
}
