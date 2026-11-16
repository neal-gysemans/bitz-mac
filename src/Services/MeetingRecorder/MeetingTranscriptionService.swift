#if canImport(AppKit)
import AppKit
#endif
@preconcurrency import AVFoundation
import Foundation
import Speech

// MARK: - On-Device Model Status

public enum OnDeviceModelStatus: String, Equatable, Sendable {
    case ready
    case needsDownload
    case unsupported
}

// MARK: - Meeting Transcription Errors

public enum MeetingTranscriptionError: Error, LocalizedError, Equatable, Sendable {
    case recognizerUnavailable(String)
    case onDeviceRecognitionUnsupported(String)
    case missingOnDeviceAsset(locale: String, languageDisplayName: String)
    case recognitionFailed(String)
    case timedOut(TimeInterval)

    public var errorDescription: String? {
        switch self {
        case .recognizerUnavailable(let locale):
            return "Speech recognizer is unavailable for locale '\(locale)'."
        case .onDeviceRecognitionUnsupported(let locale):
            return "On-device speech recognition is not supported for locale '\(locale)'."
        case .missingOnDeviceAsset(let locale, let languageDisplayName):
            return "On-device speech model for '\(languageDisplayName)' (\(locale)) is not downloaded in macOS. Please download it in System Settings → Keyboard → Dictation."
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

    /// Transcribes both local microphone (`mic.caf`) and system output (`system.caf`) tracks with speaker attribution (#202).
    func transcribeDualTrack(
        micURL: URL?,
        systemURL: URL?,
        fallbackURL: URL,
        sessionID: String,
        locale: Locale?
    ) async throws -> MeetingTranscript
}

extension MeetingTranscriptionProviding {
    public func transcribeDualTrack(
        micURL: URL?,
        systemURL: URL?,
        fallbackURL: URL,
        sessionID: String,
        locale: Locale?
    ) async throws -> MeetingTranscript {
        try await transcribe(audioFileURL: fallbackURL, sessionID: sessionID, locale: locale)
    }
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

    /// Probed on macOS 26: missing Assistant/Dictation asset errors (e.g. "No Assistant asset for language nl-NL").
    public static func isMissingAssetError(_ error: Error) -> Bool {
        if let transcriptionError = error as? MeetingTranscriptionError,
           case .missingOnDeviceAsset = transcriptionError {
            return true
        }
        let nsError = error as NSError
        let desc = nsError.localizedDescription.lowercased()
        if nsError.domain == "kAFAssistantErrorDomain" {
            if desc.contains("asset") || desc.contains("download") || desc.contains("not found") || desc.contains("not installed") || nsError.code == 1700 || nsError.code == 1107 {
                return true
            }
        }
        if desc.contains("no assistant asset") || (desc.contains("asset") && (desc.contains("language") || desc.contains("not downloaded") || desc.contains("missing"))) {
            return true
        }
        return false
    }

    private static func isLocaleSupported(_ locale: Locale, in supportedLocales: Set<Locale>) -> Bool {
        let targetID = locale.identifier(.bcp47)
        let targetLang = locale.language.languageCode?.identifier
        return supportedLocales.contains {
            $0.identifier(.bcp47) == targetID || (targetLang != nil && $0.language.languageCode?.identifier == targetLang)
        }
    }

    /// Probes whether the on-device asset for a locale is downloaded, needs downloading, or is unsupported.
    public static func checkOnDeviceAssetStatus(
        for locale: Locale,
        supportedLocales: Set<Locale> = SFSpeechRecognizer.supportedLocales(),
        supportsOnDevice: (Locale) -> Bool = { SFSpeechRecognizer(locale: $0)?.supportsOnDeviceRecognition ?? false },
        isAvailable: (Locale) -> Bool = { SFSpeechRecognizer(locale: $0)?.isAvailable ?? false }
    ) -> OnDeviceModelStatus {
        guard isLocaleSupported(locale, in: supportedLocales) else { return .unsupported }
        guard supportsOnDevice(locale) && isAvailable(locale) else { return .needsDownload }
        return .ready
    }

#if canImport(AppKit)
    @MainActor
    @discardableResult
    public static func openDictationSettings(
        openURL: (URL) -> Bool = { NSWorkspace.shared.open($0) }
    ) -> Bool {
        invalidateCachedLocaleOptions()
        let dictationURLs = [
            URL(string: "x-apple.systempreferences:com.apple.Keyboard-Settings.extension?Dictation"),
            URL(string: "x-apple.systempreferences:com.apple.preference.keyboard?Dictation"),
            URL(string: "x-apple.systempreferences:com.apple.Keyboard-Settings.extension"),
            URL(string: "x-apple.systempreferences:com.apple.preference.keyboard")
        ].compactMap { $0 }
        return dictationURLs.contains(where: openURL)
    }
#endif

    /// Pure handling of one recognition callback (or the timeout, passed as `MeetingTranscriptionError.timedOut`):
    /// adds the result's utterance to `utterances`, then decides whether the task continues or finishes, and how.
    static func recognitionStep(
        result: (segments: [MeetingTranscriptSegment], text: String, isFinal: Bool)?,
        error: Error?,
        utterances: UtteranceAccumulator,
        resolvedLocaleID: String? = nil
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
        // Check for missing on-device speech asset
        if isMissingAssetError(error) {
            let localeID = resolvedLocaleID ?? "current"
            let displayName = Locale.current.localizedString(forIdentifier: localeID) ?? localeID
            let missingError = MeetingTranscriptionError.missingOnDeviceAsset(locale: localeID, languageDisplayName: displayName)
            return utterances.isEmpty
                ? .finishFailure(missingError)
                : .finishPartial(warning: "Transcript may be incomplete: \(missingError.localizedDescription)")
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

    private static func isRecognizerReady(for locale: Locale) -> Bool {
        guard let recognizer = SFSpeechRecognizer(locale: locale) else { return false }
        return recognizer.supportsOnDeviceRecognition && recognizer.isAvailable
    }

    /// First locale with an on-device model: the requested (or current) locale, its same-language variants
    /// (en-US first for English), then for Automatic each preferred language and its variants.
    /// e.g. `en_BE` has no model and region-less fallback picks `en-GB` (also none), so this lands on `en-US`.
    static func resolveOnDeviceLocale(
        requested: Locale?,
        current: Locale = .current,
        preferredLanguages: [String] = Locale.preferredLanguages,
        supportedLocales: Set<Locale> = SFSpeechRecognizer.supportedLocales(),
        supportsOnDevice: (Locale) -> Bool = { isRecognizerReady(for: $0) }
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

        let supportedIDSet = Set(supportedIDs)
        var seen = Set<String>()
        var firstSupportedCandidate: Locale?
        for id in candidates where seen.insert(id).inserted {
            let locale = Locale(identifier: id)
            if firstSupportedCandidate == nil, supportedIDSet.contains(locale.identifier(.bcp47)) {
                firstSupportedCandidate = locale
            }
            if supportsOnDevice(locale) { return locale }
        }

        if let fallback = firstSupportedCandidate ?? (isLocaleSupported(base, in: supportedLocales) ? base : nil) {
            let displayName = Locale.current.localizedString(forIdentifier: fallback.identifier) ?? fallback.identifier
            throw MeetingTranscriptionError.missingOnDeviceAsset(locale: fallback.identifier, languageDisplayName: displayName)
        }
        throw MeetingTranscriptionError.onDeviceRecognitionUnsupported(base.identifier)
    }

    private static let cachedLocaleOptionsLock = NSLock()
    nonisolated(unsafe) private static var _cachedLocaleOptions: [(id: String, label: String)]?
    nonisolated(unsafe) private static var _cachedLocaleOptionsUpdatedAt: Date?
    nonisolated(unsafe) private static var _isRefreshingLocaleOptions = false

    /// Returns cached on-device transcription languages (ordered by user preference, then name),
    /// refreshing off-main if missing or older than 10 seconds without blocking `@MainActor`.
    public static func cachedOnDeviceLocaleOptions() -> [(id: String, label: String)] {
        let snapshot: (options: [(id: String, label: String)], needsBackgroundRefresh: Bool) = cachedLocaleOptionsLock.withLock {
            let stale = _cachedLocaleOptions == nil || (_cachedLocaleOptionsUpdatedAt.map { Date().timeIntervalSince($0) > 10 } ?? true)
            let shouldRefresh = stale && !_isRefreshingLocaleOptions
            if shouldRefresh { _isRefreshingLocaleOptions = true }
            return (_cachedLocaleOptions ?? [], shouldRefresh)
        }
        if snapshot.needsBackgroundRefresh {
            Task.detached(priority: .utility) {
                _ = onDeviceLocaleOptions()
            }
        }
        return snapshot.options
    }

    /// Clears the freshness timestamp so the next lookup refreshes asynchronously off-main without blocking `@MainActor`.
    public static func invalidateCachedLocaleOptions() {
        cachedLocaleOptionsLock.withLock {
            _cachedLocaleOptionsUpdatedAt = nil
        }
    }

    /// Locale identifiers enabled in macOS Dictation preferences.
    public static func dictationLocaleIdentifiers(
        prefs: [String: Any]? = UserDefaults.standard.persistentDomain(forName: "com.apple.speech.recognition.AppleSpeechRecognition.prefs")
    ) -> [String] {
        guard let dict = prefs?["VisibleNetworkSRLocaleIdentifiers"] as? [String: Any] else {
            return []
        }
        return dict.compactMap { key, value in
            (value as? NSNumber)?.boolValue == true ? Locale(identifier: key).identifier(.bcp47) : nil
        }.sorted()
    }

    static func candidateLocaleIdentifiers(
        dictationLocales: [String],
        supportedLocales: Set<Locale>,
        supportsOnDevice: (Locale) -> Bool
    ) -> [String] {
        let supportedIDs = Set(supportedLocales.map { $0.identifier(.bcp47) })
        let dictationMatches = dictationLocales
            .map { Locale(identifier: $0).identifier(.bcp47) }
            .filter { supportedIDs.contains($0) }
        if !dictationMatches.isEmpty {
            return dictationMatches
        }
        return supportedLocales
            .filter(supportsOnDevice)
            .map { $0.identifier(.bcp47) }
    }

    /// Transcription languages for the Settings picker: Dictation-enabled locales supported by Speech,
    /// falling back to installed on-device locales when Dictation preferences are empty.
    public static func onDeviceLocaleOptions() -> [(id: String, label: String)] {
        let dictationLocales = dictationLocaleIdentifiers()
        let preferred = Locale.preferredLanguages + dictationLocales.filter { !Locale.preferredLanguages.contains($0) }
        let candidates = candidateLocaleIdentifiers(
            dictationLocales: dictationLocales,
            supportedLocales: SFSpeechRecognizer.supportedLocales(),
            supportsOnDevice: { SFSpeechRecognizer(locale: $0)?.supportsOnDeviceRecognition ?? false }
        )
        let options = orderedLocaleOptions(
            candidates,
            preferredLanguages: preferred,
            displayLocale: .current
        )
        cachedLocaleOptionsLock.withLock {
            _cachedLocaleOptions = options
            _cachedLocaleOptionsUpdatedAt = Date()
            _isRefreshingLocaleOptions = false
        }
        return options
    }

    /// Downloads and installs the on-device speech model for `locale` if missing (macOS 26+ `AssetInventory`),
    /// returning `true` when `SFSpeechRecognizer` reports on-device support and availability afterward.
    @discardableResult
    public static func ensureOnDeviceAssetInstalled(for locale: Locale) async -> Bool {
        if isRecognizerReady(for: locale) {
            return true
        }
        if #available(macOS 26.0, *) {
            let installLocale = await DictationTranscriber.supportedLocale(equivalentTo: locale) ?? locale
            if isRecognizerReady(for: installLocale) {
                return true
            }
            let targetID = installLocale.identifier(.bcp47)
            let reserved = await AssetInventory.reservedLocales
            if !reserved.contains(where: { $0.identifier(.bcp47) == targetID }) {
                if reserved.count >= AssetInventory.maximumReservedLocales {
                    for oldLocale in reserved where oldLocale.identifier(.bcp47) != targetID {
                        _ = await AssetInventory.release(reservedLocale: oldLocale)
                        break
                    }
                }
                _ = try? await AssetInventory.reserve(locale: installLocale)
            }
            let module = DictationTranscriber(locale: installLocale, preset: .progressiveLongDictation)
            if let request = try? await AssetInventory.assetInstallationRequest(supporting: [module]) {
                try? await request.downloadAndInstall()
            }
            invalidateCachedLocaleOptions()
            return isRecognizerReady(for: locale) || isRecognizerReady(for: installLocale)
        }
        return isRecognizerReady(for: locale)
    }

    /// Picker entries after "Automatic": the user's preferred languages first (in their order, preferred variants in the
    /// user's order before their siblings), then the rest by name. One entry per language (and script): the user's exact preferred
    /// variants, else the language's default region (en → en-US), else the first. The region is shown only when that
    /// leaves more than one entry for a language, e.g. English (United States) / English (United Kingdom) but plain "French".
    static func orderedLocaleOptions(
        _ identifiers: [String],
        preferredLanguages: [String],
        displayLocale: Locale
    ) -> [(id: String, label: String)] {
        func normalized(_ id: String) -> String { id.replacingOccurrences(of: "_", with: "-") }
        func language(_ id: String) -> String { Locale(identifier: id).language.languageCode?.identifier ?? id }
        // Traditional and Simplified Chinese stay separate entries, and so does zh-HK (Cantonese, not Mandarin)
        func languageAndScript(_ id: String) -> String {
            if id == "zh-HK" { return id }
            let full = Locale.Language(identifier: Locale.Language(identifier: id).maximalIdentifier)
            return [full.languageCode?.identifier ?? id, full.script?.identifier].compactMap { $0 }.joined(separator: "-")
        }
        let preferredOrder = preferredLanguages.map(normalized)
        let preferredIDs = Set(preferredOrder)
        let ids = Dictionary(grouping: Set(identifiers.map(normalized)).sorted(), by: languageAndScript)
            .flatMap { key, variants -> [String] in
                let preferred = variants.filter(preferredIDs.contains)
                if !preferred.isEmpty { return preferred }
                let defaultRegion = Locale.Language(identifier: Locale.Language(identifier: key).maximalIdentifier).region?.identifier
                return [variants.first { Locale(identifier: $0).region?.identifier == defaultRegion } ?? variants[0]]
            }
        let localesPerLanguage = Dictionary(grouping: ids, by: language).mapValues(\.count)
        let preferredLanguageCodes = preferredLanguages.map(language)
        func label(_ id: String) -> String {
            localesPerLanguage[language(id), default: 0] > 1
                ? displayLocale.localizedString(forIdentifier: id) ?? id
                : displayLocale.localizedString(forLanguageCode: language(id)) ?? id
        }
        func rank(_ id: String) -> (Int, Int) {
            (preferredLanguageCodes.firstIndex(of: language(id)) ?? .max, preferredOrder.firstIndex(of: id) ?? .max)
        }
        return ids.map { (id: $0, label: label($0)) }.sorted { a, b in
            let (rankA, rankB) = (rank(a.id), rank(b.id))
            return rankA != rankB ? rankA < rankB : a.label.localizedStandardCompare(b.label) == .orderedAscending
        }
    }

    /// Maximum duration (in seconds) of a single audio window passed to `SFSpeechURLRecognitionRequest`.
    /// On-device `SFSpeechRecognitionTask` has a daemon session quota around 5 minutes; keeping each window
    /// at 180s (3 minutes) guarantees the engine never terminates early or hits daemon session timeouts (#200).
    public static let maxWindowDuration: TimeInterval = 180.0

    /// Slices an audio file into a temporary 16-bit PCM CAF file from `startSeconds` with duration `durationSeconds`,
    /// optionally scaling samples by `boostGain` with hard clipping at `[-1.0, 1.0]` (#202).
    public static func sliceAudio(
        from sourceURL: URL,
        startSeconds: TimeInterval,
        durationSeconds: TimeInterval,
        boostGain: Float = 1.0
    ) throws -> URL {
        let sourceFile = try AVAudioFile(forReading: sourceURL)
        let sampleRate = sourceFile.fileFormat.sampleRate
        let totalFrames = sourceFile.length
        let startFrame = AVAudioFramePosition(max(0, startSeconds * sampleRate))
        guard startFrame < totalFrames else {
            throw MeetingTranscriptionError.recognitionFailed("Slice start beyond end of audio")
        }
        let availableFrames = totalFrames - startFrame
        let targetFrames = AVAudioFramePosition(durationSeconds * sampleRate)
        let frameCount = AVAudioFrameCount(min(availableFrames, targetFrames))
        guard frameCount > 0 else {
            throw MeetingTranscriptionError.recognitionFailed("Empty slice requested")
        }

        sourceFile.framePosition = startFrame
        guard let buffer = AVAudioPCMBuffer(pcmFormat: sourceFile.processingFormat, frameCapacity: frameCount) else {
            throw MeetingTranscriptionError.recognitionFailed("Failed to allocate PCM buffer for audio slice")
        }
        try sourceFile.read(into: buffer, frameCount: frameCount)

        if boostGain != 1.0, let channels = buffer.floatChannelData {
            let count = Int(buffer.frameLength)
            for ch in 0..<Int(buffer.format.channelCount) {
                let ptr = channels[ch]
                for i in 0..<count {
                    ptr[i] = max(-1.0, min(1.0, ptr[i] * boostGain))
                }
            }
        }

        let tempURL = FileManager.default.temporaryDirectory.appendingPathComponent("bitz_slice_\(UUID().uuidString).caf")
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: sampleRate,
            AVNumberOfChannelsKey: Int(sourceFile.processingFormat.channelCount),
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false
        ]
        let tempFile = try AVAudioFile(forWriting: tempURL, settings: settings, commonFormat: .pcmFormatFloat32, interleaved: false)
        try tempFile.write(from: buffer)
        return tempURL
    }

    /// Transcribes a single audio window file (either the original file or a temporary slice) and accumulates its utterances.
    private func transcribeWindow(
        audioFileURL: URL,
        recognizer: SFSpeechRecognizer,
        timeOffset: TimeInterval,
        audioDuration: TimeInterval,
        utterances: UtteranceAccumulator,
        resolvedLocaleID: String,
        speaker: String? = nil
    ) async throws {
        let timeout = Self.recognitionTimeout(forAudioDuration: audioDuration)
        let state = WindowContinuationGate()
        let request = Self.makeRecognitionRequest(audioFileURL: audioFileURL)

        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                state.install(continuation)
                @Sendable func finish(_ step: RecognitionStep) {
                    switch step {
                    case .accumulate:
                        return
                    case .finishSuccess, .finishPartial:
                        state.finish(.success(()))
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
                                    startTime: timeOffset + seg.timestamp,
                                    endTime: timeOffset + seg.timestamp + seg.duration,
                                    confidence: seg.confidence,
                                    speaker: speaker
                                )
                            },
                            text: result.bestTranscription.formattedString,
                            isFinal: result.isFinal
                        )
                    }
                    finish(Self.recognitionStep(result: utterance, error: error, utterances: utterances, resolvedLocaleID: resolvedLocaleID))
                }
                state.attach(task)
                DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + timeout) {
                    finish(Self.recognitionStep(result: nil, error: MeetingTranscriptionError.timedOut(timeout), utterances: utterances, resolvedLocaleID: resolvedLocaleID))
                }
            }
        } onCancel: {
            state.finish(.failure(CancellationError()))
        }
    }

    public func transcribe(
        audioFileURL: URL,
        sessionID: String,
        locale: Locale? = nil
    ) async throws -> MeetingTranscript {
        try await transcribe(
            audioFileURL: audioFileURL,
            sessionID: sessionID,
            locale: locale,
            speaker: nil,
            boostGain: 1.0
        )
    }

    public func transcribe(
        audioFileURL: URL,
        sessionID: String,
        locale: Locale? = nil,
        speaker: String? = nil,
        boostGain: Float = 1.0
    ) async throws -> MeetingTranscript {
        if let locale, !Self.isRecognizerReady(for: locale) {
            _ = await Self.ensureOnDeviceAssetInstalled(for: locale)
        }
        let chosenLocale: Locale
        do {
            chosenLocale = try Self.resolveOnDeviceLocale(requested: locale)
        } catch let MeetingTranscriptionError.missingOnDeviceAsset(missingLocaleID, _) {
            _ = await Self.ensureOnDeviceAssetInstalled(for: Locale(identifier: missingLocaleID))
            chosenLocale = try Self.resolveOnDeviceLocale(requested: locale)
        }
        guard let recognizer = SFSpeechRecognizer(locale: chosenLocale) else {
            throw MeetingTranscriptionError.recognizerUnavailable(chosenLocale.identifier)
        }
        guard recognizer.isAvailable else {
            if recognizer.supportsOnDeviceRecognition {
                let displayName = Locale.current.localizedString(forIdentifier: chosenLocale.identifier) ?? chosenLocale.identifier
                throw MeetingTranscriptionError.missingOnDeviceAsset(locale: chosenLocale.identifier, languageDisplayName: displayName)
            }
            throw MeetingTranscriptionError.recognizerUnavailable(chosenLocale.identifier)
        }

        let resolvedLocaleID = recognizer.locale.identifier
        let audioDuration = (try? AVAudioFile(forReading: audioFileURL))
            .map { Double($0.length) / max(1, $0.fileFormat.sampleRate) } ?? 0

        let utterances = UtteranceAccumulator()
        // The task is cancelled if its recognizer is deallocated, so keep it alive until all results arrive
        defer { withExtendedLifetime(recognizer) {} }

        var capturedWarning: String?

        if audioDuration <= Self.maxWindowDuration {
            // Short meeting: single-pass recognition. If boostGain is requested, generate a boosted slice.
            let targetURL: URL
            let isTempSlice: Bool
            if boostGain != 1.0, let sliceURL = try? Self.sliceAudio(from: audioFileURL, startSeconds: 0, durationSeconds: audioDuration, boostGain: boostGain) {
                targetURL = sliceURL
                isTempSlice = true
            } else {
                targetURL = audioFileURL
                isTempSlice = false
            }
            defer {
                if isTempSlice {
                    try? FileManager.default.removeItem(at: targetURL)
                }
            }

            do {
                try await transcribeWindow(
                    audioFileURL: targetURL,
                    recognizer: recognizer,
                    timeOffset: 0.0,
                    audioDuration: audioDuration,
                    utterances: utterances,
                    resolvedLocaleID: resolvedLocaleID,
                    speaker: speaker
                )
            } catch let error as MeetingTranscriptionError {
                guard !utterances.isEmpty else { throw error }
                capturedWarning = "Transcript may be incomplete: \(error.localizedDescription)"
            }
        } else {
            // Long meeting (> maxWindowDuration): slice into sequential time windows to prevent on-device daemon timeout (#200)
            var windowStart: Double = 0.0
            while windowStart < audioDuration {
                try Task.checkCancellation()
                let windowEnd = min(audioDuration, windowStart + Self.maxWindowDuration)
                let duration = windowEnd - windowStart

                guard let sliceURL = try? Self.sliceAudio(from: audioFileURL, startSeconds: windowStart, durationSeconds: duration, boostGain: boostGain) else {
                    break
                }
                defer { try? FileManager.default.removeItem(at: sliceURL) }

                do {
                    try await transcribeWindow(
                        audioFileURL: sliceURL,
                        recognizer: recognizer,
                        timeOffset: windowStart,
                        audioDuration: duration,
                        utterances: utterances,
                        resolvedLocaleID: resolvedLocaleID,
                        speaker: speaker
                    )
                } catch is CancellationError {
                    throw CancellationError()
                } catch {
                    if utterances.isEmpty && windowEnd >= audioDuration {
                        throw error
                    }
                    capturedWarning = "Transcript may be incomplete: \(error.localizedDescription)"
                }

                windowStart = windowEnd
            }
        }

        return utterances.transcript(sessionID: sessionID, localeIdentifier: resolvedLocaleID, warning: capturedWarning)
    }

    /// Transcribes both local microphone (`mic.caf`) and system output (`system.caf`) tracks sequentially with speaker attribution (#202).
    public func transcribeDualTrack(
        micURL: URL?,
        systemURL: URL?,
        fallbackURL: URL,
        sessionID: String,
        locale: Locale?
    ) async throws -> MeetingTranscript {
        let hasMic = micURL.map { FileManager.default.fileExists(atPath: $0.path) } ?? false
        let hasSystem = systemURL.map { FileManager.default.fileExists(atPath: $0.path) } ?? false

        // If neither track exists, fall back to fallbackURL (typically audio.m4a)
        guard hasMic || hasSystem else {
            return try await transcribe(audioFileURL: fallbackURL, sessionID: sessionID, locale: locale)
        }

        // If only one track exists, transcribe that single track
        if hasMic && !hasSystem, let micURL {
            return try await transcribe(audioFileURL: micURL, sessionID: sessionID, locale: locale, speaker: "You")
        }
        if hasSystem && !hasMic, let systemURL {
            return try await transcribe(audioFileURL: systemURL, sessionID: sessionID, locale: locale, speaker: "Participants", boostGain: 2.5)
        }

        // Both tracks exist: transcribe sequentially to avoid on-device Neural Engine contention (#202)
        guard let micURL, let systemURL else {
            return try await transcribe(audioFileURL: fallbackURL, sessionID: sessionID, locale: locale)
        }

        var micTranscript: MeetingTranscript?
        var systemTranscript: MeetingTranscript?
        var warnings: [String] = []

        do {
            micTranscript = try await transcribe(
                audioFileURL: micURL,
                sessionID: sessionID,
                locale: locale,
                speaker: "You"
            )
        } catch {
            warnings.append("Mic transcription note: \(error.localizedDescription)")
        }

        do {
            systemTranscript = try await transcribe(
                audioFileURL: systemURL,
                sessionID: sessionID,
                locale: locale,
                speaker: "Participants",
                boostGain: 2.5
            )
        } catch {
            warnings.append("Participants transcription note: \(error.localizedDescription)")
        }

        // If both failed, try fallbackURL
        if micTranscript == nil && systemTranscript == nil {
            return try await transcribe(audioFileURL: fallbackURL, sessionID: sessionID, locale: locale)
        }

        // Merge segments chronologically
        let micSegments = micTranscript?.segments ?? []
        let systemSegments = systemTranscript?.segments ?? []
        let allSegments = (micSegments + systemSegments).sorted { a, b in
            if a.startTime != b.startTime {
                return a.startTime < b.startTime
            }
            return a.endTime < b.endTime
        }

        let combinedFullText: String
        if !allSegments.isEmpty {
            combinedFullText = allSegments.map(\.text).joined(separator: " ")
        } else {
            combinedFullText = [micTranscript?.fullText, systemTranscript?.fullText]
                .compactMap { $0 }
                .filter { !$0.isEmpty }
                .joined(separator: " ")
        }

        let chosenLocaleID = micTranscript?.localeIdentifier ?? systemTranscript?.localeIdentifier ?? locale?.identifier ?? "en-US"
        let allWarnings = warnings + [micTranscript?.warning, systemTranscript?.warning].compactMap { $0 }
        let mergedWarning = allWarnings.isEmpty ? nil : allWarnings.joined(separator: " ")

        return MeetingTranscript(
            sessionID: sessionID,
            localeIdentifier: chosenLocaleID,
            generatedAt: Date(),
            fullText: combinedFullText,
            segments: allSegments,
            warning: mergedWarning
        )
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

/// Resumes a window transcription continuation exactly once across the result callback, timeout, and cancellation.
final class WindowContinuationGate: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Void, Error>?
    private var task: SFSpeechRecognitionTask?
    private var outcome: Result<Void, Error>?

    func install(_ continuation: CheckedContinuation<Void, Error>) {
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

    func finish(_ result: Result<Void, Error>) {
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
        task?.cancel()
        continuation?.resume(with: result)
    }
}

// MARK: - Transcript File Writer

public enum MeetingTranscriptWriter {
    /// Both files are written to `savingURL` names first and renamed only once both exist, so `.txt` and `.json`
    /// never describe different runs; a failed write changes nothing.
    public static func write(
        _ transcript: MeetingTranscript,
        to sessionDirectoryURL: URL
    ) throws -> (txtURL: URL, jsonURL: URL) {
        try FileManager.default.createDirectory(at: sessionDirectoryURL, withIntermediateDirectories: true)

        let txtURL = sessionDirectoryURL.appendingPathComponent("transcript.txt")
        let jsonURL = sessionDirectoryURL.appendingPathComponent("transcript.json")
        let pending = [txtURL, jsonURL].map(savingURL(for:))
        defer { pending.forEach { try? FileManager.default.removeItem(at: $0) } }

        try Data(transcript.formattedPlainText().utf8).write(to: pending[0])
        try MeetingFormatting.jsonEncoder().encode(transcript).write(to: pending[1])
        for (from, to) in zip(pending, [txtURL, jsonURL]) {
            guard rename(from.path, to.path) == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        }
        return (txtURL, jsonURL)
    }

    /// Hidden name a transcript file is written under before it replaces the real one.
    static func savingURL(for url: URL) -> URL {
        url.deletingLastPathComponent().appendingPathComponent(".\(url.lastPathComponent).saving")
    }
}
