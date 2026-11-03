import Foundation

#if canImport(FoundationModels)
import FoundationModels
#endif

/// Real on-device language model backend powered by Apple Foundation Models (macOS 26+).
///
/// Operates with zero network calls, utilizing the system-managed on-device foundation model.
/// Lazily loads the session upon first request and automatically releases it on memory pressure or idle timeout.
public actor FoundationModelsCommentaryGenerator: CommentaryGenerating {
    private var cachedPreset: PersonalityPreset?
    #if canImport(FoundationModels)
    private var activeSession: Any?
    #endif

    private let availabilityOverride: (@Sendable () -> Bool)?
    private let customResponder: (@Sendable (String, PersonalityPreset) async throws -> String)?

    public init(
        availabilityOverride: (@Sendable () -> Bool)? = nil,
        customResponder: (@Sendable (String, PersonalityPreset) async throws -> String)? = nil
    ) {
        self.availabilityOverride = availabilityOverride
        self.customResponder = customResponder
    }

    public var isAvailable: Bool {
        if let override = availabilityOverride {
            return override()
        }
        #if canImport(FoundationModels)
        if #available(macOS 26.0, *) {
            return SystemLanguageModel.default.isAvailable
        }
        #endif
        return false
    }

    public func generate(context: PersonalityContext, preset: PersonalityPreset) async throws -> String {
        guard isAvailable else {
            throw PersonalityError.modelUnavailable("Apple Intelligence on-device model is not ready or unavailable")
        }

        if let responder = customResponder {
            return try await responder(buildPrompt(from: context), preset)
        }

        #if canImport(FoundationModels)
        if #available(macOS 26.0, *) {
            let session = resolveSession(for: preset)
            let prompt = buildPrompt(from: context)
            do {
                let response = try await session.respond(to: prompt)
                return response.content
            } catch {
                throw PersonalityError.generationFailed(error.localizedDescription)
            }
        }
        #endif

        throw PersonalityError.modelUnavailable("Foundation Models requires macOS 26+")
    }

    public func rephrase(warning: String, context: PersonalityContext, preset: PersonalityPreset) async throws -> String {
        guard isAvailable else { return warning }

        if let responder = customResponder {
            do {
                return try await responder("Rephrase: \(warning)", preset)
            } catch {
                return warning
            }
        }

        #if canImport(FoundationModels)
        if #available(macOS 26.0, *) {
            let session = resolveSession(for: preset)
            let prompt = "Rephrase this warning message into exactly one sentence in your characteristic voice, keeping the core alert intact: \"\(warning)\""
            do {
                let response = try await session.respond(to: prompt)
                return response.content
            } catch {
                return warning
            }
        }
        #endif

        return warning
    }

    public func unload() async {
        cachedPreset = nil
        #if canImport(FoundationModels)
        activeSession = nil
        #endif
    }

    #if canImport(FoundationModels)
    @available(macOS 26.0, *)
    private func resolveSession(for preset: PersonalityPreset) -> LanguageModelSession {
        if let existing = activeSession as? LanguageModelSession, cachedPreset == preset {
            return existing
        }
        let session = LanguageModelSession(model: .default, instructions: preset.systemPrompt)
        activeSession = session
        cachedPreset = preset
        return session
    }
    #endif

    private func buildPrompt(from context: PersonalityContext) -> String {
        var lines: [String] = []
        lines.append("Wellness state: \(context.wellnessState.rawValue)")
        lines.append("Points: \(Int(context.currentPoints))/100")
        lines.append("Continuous work minutes: \(Int(context.continuousWorkMinutes))m")
        if let temp = context.temperatureCelsius {
            lines.append("CPU temp: \(Int(temp))°C")
        }
        if let cpu = context.cpuLoadPercentage {
            lines.append("CPU load: \(Int(cpu))%")
        }
        if let app = context.frontmostAppName {
            lines.append("Frontmost app: \(app)")
        }
        if let commits = context.recentCommitCount {
            lines.append("Recent git commits: \(commits)")
        }
        if let agent = context.activeAgentNames.first {
            lines.append("Active AI agent: \(agent)")
        }
        return "Given this Mac desktop state, produce exactly one short, contextual speech-bubble comment (under 80 chars):\n" + lines.joined(separator: "\n")
    }
}
