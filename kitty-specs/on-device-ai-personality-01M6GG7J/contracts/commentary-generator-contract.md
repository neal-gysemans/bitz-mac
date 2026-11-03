# Contract: On-Device AI Personality Generator (`CommentaryGenerating`)

**Mission**: `on-device-ai-personality-01M6GG7J`  
**Components**: `src/Services/CommentaryGenerating.swift`, `src/Services/FoundationModelsCommentaryGenerator.swift`, `src/Services/TemplatedCommentaryGenerator.swift`

---

## 1. Backend Protocol Specification

Any personality commentary engine MUST conform to the `CommentaryGenerating` protocol:

```swift
public protocol CommentaryGenerating: Sendable {
    var backendIdentifier: String { get }
    var isAvailable: Bool { get }
    func generateCommentary(context: PersonalityContext, preset: PersonalityPreset) async throws -> String
    func unloadBackend() async
}
```

### Invariants

1. **Deterministic Fallback**:
   When running on macOS < 26, or when Apple Intelligence / Foundation Models are unavailable, disabled, or encounter errors, `TemplatedCommentaryGenerator` MUST serve as the instant zero-dependency fallback.
2. **Execution Timeout**:
   `PersonalityService` bounds any commentary generation call with a strict timeout (2.0s). If generation exceeds 2.0s, the call is aborted and a static fallback line is used.
3. **Lazy Session Management & Lifecycle**:
   Backend models MUST NOT be loaded into memory until first requested.
   On application termination (`applicationWillTerminate`), memory pressure warnings, or after an idle period, `unloadBackend()` MUST be invoked to guarantee app resident RAM remains < 70 MB.
4. **Zero Outbound Network Traffic**:
   Neither `FoundationModelsCommentaryGenerator` nor `TemplatedCommentaryGenerator` nor any associated signal providers shall execute outbound HTTP/HTTPS or network calls.
