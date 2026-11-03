import Foundation

/// `@MainActor` coordinator for Bitz's on-device AI personality.
///
/// Orchestrates:
/// 1. Gating checks (Low Power Mode, low battery, thermal stress).
/// 2. Rate limiting (minimum intervals and daily quota).
/// 3. Asynchronous generation with a hard 2.0s latency bound.
/// 4. Automatic fallback to templated generation when an LLM fails or times out.
/// 5. Output sanitization ensuring single-line formatting under 80 characters.
@MainActor
public final class PersonalityService: ObservableObject {
    public static let generationTimeoutSeconds: TimeInterval = 2.0

    @Published public private(set) var activeCommentary: String? = nil
    @Published public private(set) var isGenerating: Bool = false
    @Published public private(set) var lastError: PersonalityError? = nil

    public var primaryGenerator: CommentaryGenerating
    public var fallbackGenerator: CommentaryGenerating
    public var gate: PersonalityGate
    public var rateLimiter: PersonalityRateLimiter
    public var sanitizer: CommentarySanitizer
    public var powerStateProvider: PowerStateProviding
    public let settingsStore: PersonalitySettingsStore
    public var clock: () -> Date

    public init(
        primaryGenerator: CommentaryGenerating? = nil,
        fallbackGenerator: CommentaryGenerating = TemplatedCommentaryGenerator(),
        gate: PersonalityGate = PersonalityGate(),
        rateLimiter: PersonalityRateLimiter = PersonalityRateLimiter(),
        sanitizer: CommentarySanitizer = CommentarySanitizer(),
        powerStateProvider: PowerStateProviding = SystemPowerStateProvider(),
        settingsStore: PersonalitySettingsStore,
        clock: @escaping () -> Date = Date.init
    ) {
        let fallback = fallbackGenerator
        self.primaryGenerator = primaryGenerator ?? fallback
        self.fallbackGenerator = fallback
        self.gate = gate
        self.rateLimiter = rateLimiter
        self.sanitizer = sanitizer
        self.powerStateProvider = powerStateProvider
        self.settingsStore = settingsStore
        self.clock = clock
    }

    /// Primary periodic tick called from Bitz's telemetry polling loop.
    ///
    /// When `isBubbleIdle` is `false`, Bitz is actively presenting an agent popup,
    /// a critical warning, or a transient notification; personality commentary
    /// strictly defers to avoid visual clutter or priority inversion.
    public func tick(context: PersonalityContext, isBubbleIdle: Bool, bypassRateLimit: Bool = false) async {
        // FR-001: Opt-in requirement; strictly no-op when disabled
        guard settingsStore.isEnabled else { return }

        // FR-004: Only display commentary when no other bubble is showing
        guard isBubbleIdle else { return }

        // Prevent overlapping generation passes
        guard !isGenerating else { return }

        let now = clock()

        // FR-008: Hardware power and thermal gate
        let gateDecision = gate.evaluate(powerState: powerStateProvider, context: context)
        guard gateDecision.isAllowed else {
            lastError = gateDecision.error
            return
        }

        // FR-007: Rate limiting (cooldown interval and daily cap)
        guard settingsStore.canGenerateCommentToday(for: now) else { return }
        if !bypassRateLimit {
            let rateDecision = rateLimiter.evaluate(
                now: now,
                minIntervalMinutes: settingsStore.minIntervalMinutes,
                dailyCap: settingsStore.dailyCap
            )
            guard rateDecision.isAllowed else { return }
        }

        isGenerating = true
        defer { isGenerating = false }

        let preset = settingsStore.preset

        // Attempt generation with strict 2.0s timeout and automatic fallback (FR-006, NFR-005)
        let rawResult: Result<String, Error> = await generateWithFallback(context: context, preset: preset)

        switch rawResult {
        case .success(let rawText):
            let sanitizeResult = sanitizer.sanitize(rawText, context: context)
            switch sanitizeResult {
            case .success(let cleanText):
                self.activeCommentary = cleanText
                self.rateLimiter.recordGeneration(now: now)
                self.settingsStore.recordCommentGenerated(on: now)
                self.lastError = nil
            case .failure(let error):
                self.lastError = error
            }

        case .failure(let error):
            if let personalityError = error as? PersonalityError {
                self.lastError = personalityError
            } else {
                self.lastError = .generationFailed(error.localizedDescription)
            }
        }
    }

    /// Rephrases a deterministic critical warning (thermal, burnout, overworked) in the active preset voice.
    /// Falls back to the verbatim static warning if disabled, gated, timed out, or encountering any error.
    public func rephraseWarning(_ warning: String, context: PersonalityContext) async -> String {
        guard settingsStore.isEnabled else { return warning }

        let gateDecision = gate.evaluate(powerState: powerStateProvider, context: context)
        guard gateDecision.isAllowed else { return warning }

        let preset = settingsStore.preset
        let generator = self.primaryGenerator

        do {
            let candidate = try await executeWithTimeout(seconds: Self.generationTimeoutSeconds) {
                try await generator.rephrase(warning: warning, context: context, preset: preset)
            }
            if case .success(let sanitized) = sanitizer.sanitize(candidate, context: context) {
                return sanitized
            }
        } catch {
            // Fail open: always preserve the static warning
        }

        return warning
    }

    /// Clears any active AI commentary bubble.
    public func clearCommentary() {
        activeCommentary = nil
    }

    /// Unloads backend LLM sessions and releases memory.
    public func unloadBackend() async {
        await primaryGenerator.unload()
        await fallbackGenerator.unload()
    }

    // MARK: - Private Helpers

    private func generateWithFallback(context: PersonalityContext, preset: PersonalityPreset) async -> Result<String, Error> {
        let primary = self.primaryGenerator
        let fallback = self.fallbackGenerator

        do {
            let primaryResult = try await executeWithTimeout(seconds: Self.generationTimeoutSeconds) {
                try await primary.generate(context: context, preset: preset)
            }
            return .success(primaryResult)
        } catch {
            // Fall back to templated generator
            do {
                let fallbackResult = try await executeWithTimeout(seconds: Self.generationTimeoutSeconds) {
                    try await fallback.generate(context: context, preset: preset)
                }
                return .success(fallbackResult)
            } catch let fallbackError {
                return .failure(fallbackError)
            }
        }
    }

    private func executeWithTimeout<T: Sendable>(seconds: TimeInterval, operation: @escaping @Sendable () async throws -> T) async throws -> T {
        try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask {
                try await operation()
            }
            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
                throw PersonalityError.timedOut
            }
            guard let firstResult = try await group.next() else {
                throw PersonalityError.timedOut
            }
            group.cancelAll()
            return firstResult
        }
    }
}
