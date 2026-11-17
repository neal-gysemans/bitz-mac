@preconcurrency import AVFoundation
import Foundation
import WhisperKit

/// Optional capability for transcription providers that support dual-track speaker diarization (#204).
public protocol MeetingDualTrackTranscriptionProviding: MeetingTranscriptionProviding {
    func transcribeTracks(
        micURL: URL?,
        systemURL: URL?,
        fallbackAudioURL: URL,
        sessionID: String,
        locale: Locale?,
        onStatusUpdate: (@MainActor @Sendable (String) -> Void)?
    ) async throws -> MeetingTranscript
}

/// On-device WhisperKit ASR transcription service with gain normalization, hallucination filtering,
/// and dual-track speaker diarization ("You" vs "Participants") (#204).
public final class WhisperKitTranscriptionService: MeetingDualTrackTranscriptionProviding, @unchecked Sendable {
    public static let micSpeakerLabel = "You"
    public static let systemSpeakerLabel = "Participants"

    private let modelManager: WhisperKitModelManager
    private let variantProvider: @MainActor @Sendable () -> WhisperModelVariant

    public init(
        modelManager: WhisperKitModelManager,
        variantProvider: @escaping @MainActor @Sendable () -> WhisperModelVariant = { .largeV3Turbo }
    ) {
        self.modelManager = modelManager
        self.variantProvider = variantProvider
    }

    public func transcribe(
        audioFileURL: URL,
        sessionID: String,
        locale: Locale?
    ) async throws -> MeetingTranscript {
        try await transcribeTracks(
            micURL: nil,
            systemURL: nil,
            fallbackAudioURL: audioFileURL,
            sessionID: sessionID,
            locale: locale,
            onStatusUpdate: nil
        )
    }

    public func transcribeTracks(
        micURL: URL?,
        systemURL: URL?,
        fallbackAudioURL: URL,
        sessionID: String,
        locale: Locale?,
        onStatusUpdate: (@MainActor @Sendable (String) -> Void)? = nil
    ) async throws -> MeetingTranscript {
        let variant = await variantProvider()

        await notify(onStatusUpdate, "Checking Whisper AI model (\(variant.approximateSizeLabel))...")
        let modelFolder = try await modelManager.ensureModelDownloaded(variant) { progress in
            let percent = Int((progress * 100).rounded())
            onStatusUpdate?("Downloading Whisper AI model (\(percent)%)...")
        }

        await notify(onStatusUpdate, "Loading Whisper AI model on-device...")
        let config = WhisperKitConfig(
            model: variant.rawValue,
            downloadBase: modelManager.modelsRootURL,
            modelFolder: modelFolder.path,
            verbose: false,
            logLevel: .none,
            prewarm: false,
            load: true,
            download: false
        )
        let pipe = try await WhisperKit(config)

        do {
            await notify(onStatusUpdate, "Transcribing audio on-device with Whisper AI...")

            let decodeOptions = Self.makeDecodingOptions(locale: locale)
            let hasMic = micURL.map { FileManager.default.fileExists(atPath: $0.path) } ?? false
            let hasSystem = systemURL.map { FileManager.default.fileExists(atPath: $0.path) } ?? false

            let transcript: MeetingTranscript
            if hasMic || hasSystem {
                let isDualTrack = hasMic && hasSystem
                var micSegments: [MeetingTranscriptSegment] = []
                var systemSegments: [MeetingTranscriptSegment] = []
                var detectedLanguage: String?

                if let micURL, hasMic {
                    let (segments, lang) = try await transcribeSingleTrack(
                        pipe: pipe,
                        audioURL: micURL,
                        speaker: isDualTrack ? Self.micSpeakerLabel : nil,
                        decodeOptions: decodeOptions
                    )
                    micSegments = segments
                    detectedLanguage = detectedLanguage ?? lang
                }

                if let systemURL, hasSystem {
                    let (segments, lang) = try await transcribeSingleTrack(
                        pipe: pipe,
                        audioURL: systemURL,
                        speaker: isDualTrack ? Self.systemSpeakerLabel : nil,
                        decodeOptions: decodeOptions
                    )
                    systemSegments = segments
                    detectedLanguage = detectedLanguage ?? lang
                }

                let merged = Self.mergeDualTrackSegments(micSegments: micSegments, systemSegments: systemSegments)
                let resolvedLocale = Self.resolvedLocaleIdentifier(requested: locale, detectedLanguage: detectedLanguage)
                let fullText = Self.buildFullText(from: merged)
                transcript = MeetingTranscript(
                    sessionID: sessionID,
                    localeIdentifier: resolvedLocale,
                    fullText: fullText,
                    segments: merged
                )
            } else {
                let (segments, lang) = try await transcribeSingleTrack(
                    pipe: pipe,
                    audioURL: fallbackAudioURL,
                    speaker: nil,
                    decodeOptions: decodeOptions
                )
                let resolvedLocale = Self.resolvedLocaleIdentifier(requested: locale, detectedLanguage: lang)
                let fullText = Self.buildFullText(from: segments)
                transcript = MeetingTranscript(
                    sessionID: sessionID,
                    localeIdentifier: resolvedLocale,
                    fullText: fullText,
                    segments: segments
                )
            }

            await pipe.unloadModels()
            return transcript
        } catch {
            await pipe.unloadModels()
            throw error
        }
    }

    private func notify(
        _ callback: (@MainActor @Sendable (String) -> Void)?,
        _ message: String
    ) async {
        guard let callback else { return }
        await MainActor.run {
            callback(message)
        }
    }

    private func transcribeSingleTrack(
        pipe: WhisperKit,
        audioURL: URL,
        speaker: String?,
        decodeOptions: DecodingOptions
    ) async throws -> (segments: [MeetingTranscriptSegment], detectedLanguage: String?) {
        let samples = try Self.loadAndNormalize16kMonoSamples(from: audioURL)
        guard !samples.isEmpty else {
            return ([], nil)
        }

        let results = try await pipe.transcribe(audioArray: samples, decodeOptions: decodeOptions)
        let detectedLanguage = results.first(where: { !$0.language.isEmpty })?.language
        let segments = Self.convertResults(results, speaker: speaker, samples: samples)
        return (segments, detectedLanguage)
    }

    // MARK: - Pure Helpers (Testable)

    static func makeDecodingOptions(locale: Locale?) -> DecodingOptions {
        let languageCode = whisperLanguageCode(for: locale)
        return DecodingOptions(
            verbose: false,
            task: .transcribe,
            language: languageCode,
            temperature: 0.0,
            temperatureIncrementOnFallback: 0.2,
            temperatureFallbackCount: 3,
            sampleLength: 224,
            usePrefillPrompt: true,
            detectLanguage: languageCode == nil,
            skipSpecialTokens: true,
            withoutTimestamps: false,
            wordTimestamps: false,
            suppressBlank: true,
            compressionRatioThreshold: 2.0,
            logProbThreshold: -1.0,
            noSpeechThreshold: 0.55,
            chunkingStrategy: .vad
        )
    }

    static func whisperLanguageCode(for locale: Locale?) -> String? {
        guard let locale else { return nil }
        if let code = locale.language.languageCode?.identifier, !code.isEmpty {
            return code.lowercased()
        }
        let raw = locale.identifier(.bcp47).split(separator: "-").first.map(String.init)
        return raw?.lowercased()
    }

    static func resolvedLocaleIdentifier(requested: Locale?, detectedLanguage: String?) -> String {
        if let requested {
            return requested.identifier(.bcp47)
        }
        if let detectedLanguage, !detectedLanguage.isEmpty {
            return detectedLanguage
        }
        return Locale.current.identifier(.bcp47)
    }

    static func convertResults(
        _ results: [TranscriptionResult],
        speaker: String?,
        samples: [Float]? = nil
    ) -> [MeetingTranscriptSegment] {
        var output: [MeetingTranscriptSegment] = []
        for result in results {
            for seg in result.segments {
                let cleaned = cleanSegmentText(seg.text)
                guard !cleaned.isEmpty else { continue }
                guard !isLikelyHallucination(cleaned, noSpeechProb: seg.noSpeechProb, avgLogprob: seg.avgLogprob) else {
                    continue
                }
                let start = seg.start.isFinite ? max(0, TimeInterval(seg.start)) : 0.0
                let end = seg.end.isFinite ? max(start, TimeInterval(seg.end)) : start
                if let samples, !segmentHasSpeechEnergy(samples: samples, startTime: start, endTime: end) {
                    continue
                }
                let rawConfidence = exp(seg.avgLogprob)
                let confidence: Float = rawConfidence.isFinite ? min(max(rawConfidence, 0.0), 1.0) : 0.0
                output.append(MeetingTranscriptSegment(
                    text: cleaned,
                    startTime: start,
                    endTime: end,
                    confidence: confidence,
                    speaker: speaker
                ))
            }
        }
        return deduplicateSegments(output)
    }

    static func cleanSegmentText(_ raw: String) -> String {
        raw.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static let subtitleHallucinationMarkers = [
        "tv gelderland", "ondertitels", "ondertiteling", "amara.org",
        "bedankt voor het kijken", "subtitles by", "thanks for watching"
    ]

    static func isLikelyHallucination(_ text: String, noSpeechProb: Float, avgLogprob: Float) -> Bool {
        let lower = text.lowercased()
        if lower == "[blank_audio]" || lower == "(silence)" || lower == "[silence]" || lower == "(music)" || lower == "[music]" {
            return true
        }
        if lower.hasPrefix("[") && lower.hasSuffix("]") && lower.count <= 24 {
            return true
        }
        if subtitleHallucinationMarkers.contains(where: { lower.contains($0) }) {
            return true
        }
        if noSpeechProb > 0.55 && avgLogprob < -1.0 {
            return true
        }
        return false
    }

    /// Drops segments whose underlying 16 kHz audio window is below the speech energy floor.
    static func segmentHasSpeechEnergy(
        samples: [Float],
        startTime: TimeInterval,
        endTime: TimeInterval,
        sampleRate: Double = 16_000,
        minRMS: Float = 0.001
    ) -> Bool {
        guard !samples.isEmpty, endTime > startTime else { return true }
        let startIdx = max(0, min(samples.count - 1, Int((startTime * sampleRate).rounded(.down))))
        let endIdx = max(startIdx + 1, min(samples.count, Int((endTime * sampleRate).rounded(.up))))
        let count = endIdx - startIdx
        guard count > 0 else { return true }
        var sumSquares: Double = 0
        for i in startIdx..<endIdx {
            let s = samples[i]
            sumSquares += Double(s * s)
        }
        return Float(sqrt(sumSquares / Double(count))) >= minRMS
    }

    /// Collapses consecutive repeated or prefix-echoed segments from the same speaker within 15 seconds.
    static func deduplicateSegments(_ segments: [MeetingTranscriptSegment]) -> [MeetingTranscriptSegment] {
        func normalizedKey(_ text: String) -> String {
            text.lowercased()
                .components(separatedBy: CharacterSet.alphanumerics.inverted)
                .filter { !$0.isEmpty }
                .joined(separator: " ")
        }

        var result: [MeetingTranscriptSegment] = []
        for seg in segments {
            let key = normalizedKey(seg.text)
            if let last = result.last,
               last.speaker == seg.speaker,
               seg.startTime - last.endTime <= 15.0,
               !key.isEmpty {
                let lastKey = normalizedKey(last.text)
                if key == lastKey || (key.count >= 12 && lastKey.contains(key)) {
                    continue
                }
                if lastKey.count >= 12 && key.contains(lastKey) {
                    result[result.count - 1] = seg
                    continue
                }
            }
            result.append(seg)
        }
        return result
    }

    static func mergeDualTrackSegments(
        micSegments: [MeetingTranscriptSegment],
        systemSegments: [MeetingTranscriptSegment]
    ) -> [MeetingTranscriptSegment] {
        (micSegments + systemSegments).sorted { lhs, rhs in
            if lhs.startTime != rhs.startTime {
                return lhs.startTime < rhs.startTime
            }
            if lhs.endTime != rhs.endTime {
                return lhs.endTime < rhs.endTime
            }
            return (lhs.speaker ?? "") < (rhs.speaker ?? "")
        }
    }

    static func buildFullText(from segments: [MeetingTranscriptSegment]) -> String {
        segments.map(\.text).joined(separator: " ")
    }

    /// Loads an audio file via WhisperKit's `AudioProcessor` (16 kHz mono Float32),
    /// gates out pure silence, and normalizes quiet tracks so WhisperKit receives clean speech levels.
    static func loadAndNormalize16kMonoSamples(from url: URL) throws -> [Float] {
        let samples = try AudioProcessor.loadAudioAsFloatArray(fromPath: url.path)
        return normalizeAndGateSamples(samples)
    }

    /// Returns `[]` for silent tracks; otherwise normalizes quiet tracks using windowed RMS (so isolated clicks
    /// do not suppress speech gain), gates silent frames, and soft-limits peaks into `[-1.0, 1.0]`.
    static func normalizeAndGateSamples(_ samples: [Float]) -> [Float] {
        guard !samples.isEmpty else { return [] }
        var peak: Float = 0
        var sumSquares: Double = 0
        for sample in samples {
            let absVal = abs(sample)
            if absVal > peak { peak = absVal }
            sumSquares += Double(sample * sample)
        }
        let rms = sqrt(sumSquares / Double(samples.count))
        guard peak >= 0.0005 && rms >= 0.0001 else {
            return []
        }

        // Compute 99th-percentile 100ms window RMS (at 16 kHz = 1600 samples) to ignore isolated clicks/pops
        let windowSize = 1_600
        var windowRMSValues: [Float] = []
        windowRMSValues.reserveCapacity(max(1, samples.count / windowSize))
        var idx = 0
        while idx < samples.count {
            let end = min(samples.count, idx + windowSize)
            var winSum: Double = 0
            for j in idx..<end {
                let s = samples[j]
                winSum += Double(s * s)
            }
            windowRMSValues.append(Float(sqrt(winSum / Double(end - idx))))
            idx = end
        }
        windowRMSValues.sort()
        let p99Index = min(windowRMSValues.count - 1, Int(Double(windowRMSValues.count - 1) * 0.99))
        let refLevel = max(windowRMSValues[p99Index], Float(rms))

        // Target ~0.7 for clean levels (or up to 12x gain for quiet tracks), with soft limiting above 0.85
        let gain: Float = refLevel < 0.35 ? min(Float(0.7) / max(refLevel, 0.0001), Float(12.0)) : 1.0
        guard gain != 1.0 || peak > 0.85 else { return samples }

        return samples.map { sample in
            let scaled = sample * gain
            if abs(scaled) > 0.85 {
                let sign: Float = scaled < 0 ? -1.0 : 1.0
                return sign * (0.85 + 0.15 * tanh((abs(scaled) - 0.85) / 0.15))
            }
            return scaled
        }
    }
}
