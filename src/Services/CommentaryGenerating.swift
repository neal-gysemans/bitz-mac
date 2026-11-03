import Foundation

/// Protocol abstraction for commentary generators (on-device Foundation Models, templated fallback, test stub).
public protocol CommentaryGenerating: Sendable {
    /// Generates a single line of speech-bubble commentary given the live context and chosen preset.
    func generate(context: PersonalityContext, preset: PersonalityPreset) async throws -> String

    /// Optional rephrasing of a deterministic critical warning (thermal, burnout, overworked).
    /// If unimplemented or if it fails, the caller falls back to the original static warning text.
    func rephrase(warning: String, context: PersonalityContext, preset: PersonalityPreset) async throws -> String

    /// Unloads any cached language model session, context memory, or buffers.
    func unload() async
}

public extension CommentaryGenerating {
    func rephrase(warning: String, context: PersonalityContext, preset: PersonalityPreset) async throws -> String {
        // Default implementation returns the unchanged static warning text
        warning
    }

    func unload() async {}
}

/// Protocol for querying local git commit activity.
public protocol GitActivityProviding: Sendable {
    /// Returns the number of commits made across watched repository paths within the given time window.
    func recentCommitCount(sinceMinutes: Int) async -> Int?
}

/// No-op git activity provider used when git tracking is disabled or in testing.
public struct NoOpGitActivityProvider: GitActivityProviding {
    public init() {}
    public func recentCommitCount(sinceMinutes: Int) async -> Int? { nil }
}

/// Deterministic test stub commentary generator.
public final class StubCommentaryGenerator: CommentaryGenerating, @unchecked Sendable {
    public var stubbedResult: Result<String, Error>
    public var lastGeneratedContext: PersonalityContext?
    public var lastGeneratedPreset: PersonalityPreset?
    public var unloadCallCount: Int = 0
    public var delayNanoseconds: UInt64 = 0

    public init(stubbedResult: Result<String, Error> = .success("Bitz says meow.")) {
        self.stubbedResult = stubbedResult
    }

    public func generate(context: PersonalityContext, preset: PersonalityPreset) async throws -> String {
        lastGeneratedContext = context
        lastGeneratedPreset = preset
        if delayNanoseconds > 0 {
            try await Task.sleep(nanoseconds: delayNanoseconds)
        }
        return try stubbedResult.get()
    }

    public func unload() async {
        unloadCallCount += 1
    }
}
