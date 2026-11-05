import Foundation

// MARK: - Meeting Settings Store

/// Persists user preferences for the Local Meeting Recorder & On-Device Transcription (#43).
@MainActor
public final class MeetingSettingsStore: ObservableObject {
    nonisolated public static let keyPrefix = "bitz.meeting."
    public static let captureMicrophoneKey = keyPrefix + "captureMicrophone"
    public static let captureSystemAudioKey = keyPrefix + "captureSystemAudio"
    public static let autoTranscribeKey = keyPrefix + "autoTranscribe"
    public static let copyTranscriptPathKey = keyPrefix + "copyTranscriptPath"
    public static let meetingsDirectoryPathKey = keyPrefix + "directoryPath"
    public static let transcriptionLocaleKey = keyPrefix + "transcriptionLocale"
    public static let transcriptExportDirectoryPathKey = keyPrefix + "transcriptExportDirectoryPath"
    public static let recordingHotkeyKey = keyPrefix + "recordingHotkey"
    public static let consentAcknowledgedKey = keyPrefix + "consentAcknowledged"
    public static let retentionDaysKey = keyPrefix + "retentionDays"
    /// "Delete recordings after" choices in days; nil (Off) is the default.
    public static let retentionDayOptions = [30, 90]

    /// Keys written by earlier builds of this branch, mapped to their `bitz.meeting.` replacements.
    static let legacyKeys: [String: String] = [
        "Bitz.MeetingRecorder.CaptureMicrophone": captureMicrophoneKey,
        "Bitz.MeetingRecorder.CaptureSystemAudio": captureSystemAudioKey,
        "Bitz.MeetingRecorder.AutoTranscribe": autoTranscribeKey,
        "Bitz.MeetingRecorder.CopyTranscriptPath": copyTranscriptPathKey,
        "Bitz.MeetingRecorder.DirectoryPath": meetingsDirectoryPathKey,
        "Bitz.MeetingRecorder.TranscriptionLocale": transcriptionLocaleKey,
        "Bitz.MeetingRecorder.TranscriptExportDirectoryPath": transcriptExportDirectoryPathKey,
        "Bitz.MeetingRecorder.RecordingHotkey": recordingHotkeyKey,
        "Bitz.MeetingRecorder.ScreenCaptureRequested": SystemMeetingPermissionChecker.screenCaptureRequestedKey
    ]

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
    /// The first-recording notice was answered with Continue (D7).
    @Published public private(set) var consentAcknowledged: Bool
    /// Days after which finished recordings are deleted; nil = Off.
    @Published public private(set) var retentionDays: Int?

    /// Shared with `SystemMeetingPermissionChecker`, so its flag lives (and migrates) in the same domain.
    let userDefaults: UserDefaults

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
        if isInsideGitWorkTree(url) {
            return "This folder is inside a git repository, so transcripts could be committed and pushed."
        }
        if isInside("Documents") || isInside("Desktop") {
            return "macOS may sync this folder to iCloud (Desktop & Documents)."
        }
        return nil
    }

    /// True when `url` or one of its parents (at most `maxDepth` levels up) holds `.git`, a folder or a worktree's file.
    nonisolated static func isInsideGitWorkTree(_ url: URL, maxDepth: Int = 64) -> Bool {
        var folder = url.standardizedFileURL
        for _ in 0..<maxDepth {
            if FileManager.default.fileExists(atPath: folder.appendingPathComponent(".git").path) { return true }
            let parent = folder.deletingLastPathComponent()
            if parent.path == folder.path { return false }
            folder = parent
        }
        return false
    }

    public init(userDefaults: UserDefaults = .standard) {
        self.userDefaults = userDefaults
        Self.migrateLegacyKeys(in: userDefaults)

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
        self.consentAcknowledged = userDefaults.bool(forKey: Self.consentAcknowledgedKey)
        let savedRetention = userDefaults.integer(forKey: Self.retentionDaysKey)
        self.retentionDays = Self.retentionDayOptions.contains(savedRetention) ? savedRetention : nil
    }

    /// Copies each legacy value whose new key is still absent, then removes the legacy key, so it only ever acts once.
    static func migrateLegacyKeys(in userDefaults: UserDefaults) {
        for (oldKey, newKey) in legacyKeys {
            guard let value = userDefaults.object(forKey: oldKey) else { continue }
            if userDefaults.object(forKey: newKey) == nil {
                userDefaults.set(value, forKey: newKey)
            }
            userDefaults.removeObject(forKey: oldKey)
        }
    }

    public func setConsentAcknowledged(_ acknowledged: Bool) {
        consentAcknowledged = acknowledged
        userDefaults.set(acknowledged, forKey: Self.consentAcknowledgedKey)
    }

    public func setRetentionDays(_ days: Int?) {
        retentionDays = days
        userDefaults.set(days, forKey: Self.retentionDaysKey)
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
