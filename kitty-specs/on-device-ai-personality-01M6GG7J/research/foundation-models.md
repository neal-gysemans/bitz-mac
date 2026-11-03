# FoundationModels SDK Research & Verification

**Host OS**: macOS 26.6.2 (Darwin 25.3.0)  
**Xcode SDK**: MacOSX27.2.sdk  
**Framework**: `/Applications/Xcode.app/Contents/Developer/Platforms/MacOSX.platform/Developer/SDKs/MacOSX.sdk/System/Library/Frameworks/FoundationModels.framework`

## Verified Public API Symbols

### Availability Checking
- `SystemLanguageModel.default.isAvailable: Bool`
- `SystemLanguageModel.default.availability: SystemLanguageModel.Availability`
  - `.available`
  - `.unavailable(SystemLanguageModel.Availability.UnavailableReason)`

### Session Management & Generation
- `LanguageModelSession`
  - `init(model: SystemLanguageModel = .default, instructions: String? = nil)`
  - `respond(to: String) async throws -> Response<String>`
- `Response<String>`
  - `.content: String`
  - `.transcriptEntries`

### Platform Gating & Weak Linking
- Required compile guards:
  ```swift
  #if canImport(FoundationModels)
  import FoundationModels
  #endif
  ```
- Required runtime availability:
  ```swift
  @available(macOS 26.0, *)
  ```
- Graceful fallback: when unavailable or running on macOS 14–25, throws `PersonalityError.modelUnavailable(...)`, allowing `PersonalityService` to seamlessly fall back to `TemplatedCommentaryGenerator`.
