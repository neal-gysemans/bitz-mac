# Implementation Plan: On-Device AI Personality

**Branch**: `feat/20-on-device-ai-personality` | **Date**: 2026-11-03 | **Spec**: [spec.md](spec.md)
**Input**: GitHub issue #20

## Summary

Add an opt-in `PersonalityService` that produces short, context-aware speech-bubble lines through a swappable `CommentaryGenerating` backend. The primary backend is Apple Foundation Models (macOS 26+, gated by `#available`, loaded lazily). A templated backend that uses live context is the fallback. All gating, rate limiting, timeout and sanitizing live in the service, so they are testable with a stub. Critical warnings in `WellnessPointEngine.evaluateState()` stay deterministic. AI text only fills idle moments, or rephrases a warning while keeping its meaning.

## Technical Context

**Language/Version**: Swift 6.0 (`swift-tools-version: 6.0`), strict concurrency
**Primary Dependencies**: AppKit, SwiftUI, Foundation; `FoundationModels` weak-linked, used only inside `#if canImport(FoundationModels)` + `#available(macOS 26, *)`. No new SwiftPM deps.
**Storage**: `UserDefaults` via `PersonalitySettingsStore` (toggle, preset, interval, daily cap, watched repos, daily counter)
**Testing**: XCTest, `@testable import BitzCore`; stub generator; isolated `UserDefaults(suiteName:)`
**Target Platform**: macOS 14+ (arm64 primary); Foundation Models path macOS 26+ with Apple Intelligence
**Project Type**: single SwiftPM package (`BitzCore` / `Bitz` / `BitzTests`)
**Performance Goals**: idle CPU < 2%; no per-frame work; zero main-thread blocking
**Constraints**: RAM < 70 MB with the model unloaded; generation timeout ~2 s; 0 network calls
**Scale/Scope**: about 1 line per N minutes (default 10), daily cap (default 20)

## Charter Check

Gates come from AGENTS.md:
- No `TimelineView` or repeatForever animation. Pass: the feature is text-only.
- Polling observers stay in leaf views. Pass: the service pushes a single string through the engine.
- Settings window is detached on close. Pass: a new tab inside the existing window.
- Click-through and no focus stealing are untouched. Pass: no panel changes.
- Zero external dependencies. Pass.
- Live CPU verification is required for changes in `src/Views/` and `src/Services/`. Planned in the final work package.

## Design

### Components (all in `src/`)

| File | Role |
|------|------|
| `Models/PersonalityModels.swift` | `PersonalityPreset`, `PersonalityContext`, `PersonalityError` |
| `Services/CommentaryGenerating.swift` | Protocol: `func generate(context:preset:) async throws -> String`, `func unload()` |
| `Services/FoundationModelsCommentaryGenerator.swift` | Real backend. Checks `SystemLanguageModel.default.availability`, keeps a `LanguageModelSession`, preset-specific instructions, releases it on idle or memory pressure |
| `Services/TemplatedCommentaryGenerator.swift` | Fallback. Template pools filled with context values, with no repeats in the last K lines |
| `Services/PersonalityGate.swift` | Pure functions: battery, Low Power Mode, `thermalState`; injectable `PowerStateProviding` |
| `Services/PersonalityRateLimiter.swift` | Min gap and daily cap, injectable clock |
| `Services/CommentarySanitizer.swift` | Single line, ~80-char cap, strips URLs, rejects window-title echoes |
| `Services/PersonalityService.swift` | `@MainActor ObservableObject`. Orchestrates gate → limiter → generate with a 2 s timeout → sanitize → publish `aiCommentary`, or fall back |
| `Services/GitActivityProvider.swift` | Opt-in. Runs `git log --since` off-main, per chosen repo, with a cached TTL |
| `Models/PersonalitySettingsStore.swift` | Persisted settings |
| `Views/Settings/PersonalitySettingsTabView.swift` | Toggle, preset, interval, daily cap, repo picker, availability note |

### Integration

- `WellnessPointEngine`: adds an injectable `idleCommentary` input. The `currentBubbleText` computed property (line ~423) is `activeSpeechBubbleText ?? idleCommentary ?? transientBubbleText`. The priority order of warnings is unchanged, and the toggle off yields identical output.
- Critical rephrase: `PersonalityService.rephrase(warning:)` is optional. A failure shows the static text. The static text is always set first and replaced only on success.
- `BitzApp` owns the service, wires the context builder from `WellnessPointEngine`, `ActivityMonitorService` (frontmost app) and `AgentMonitorService`, and calls `tick()` on the existing 5 s coalesced telemetry tick. No new timers.
- Agent popups (`.agentPopup` in `SpeechBubbleContent`) keep higher priority.

### Backend decision (for the PR)

| Option | Verdict |
|--------|---------|
| Foundation Models | **Chosen.** No download, OS-managed memory, no dependency |
| MLX | Deferred. Adds a dependency and a model download of about 0.5–1 GB |
| llama.cpp | Rejected for v1. C++ interop, a dependency and a download |
| Templated lines | Always-on fallback |
| Ollama | Rejected. External daemon, heavy |

## Project Structure

```
kitty-specs/on-device-ai-personality-01M6GG7J/{spec.md, plan.md, tasks/}
src/Models/{PersonalityModels,PersonalitySettingsStore}.swift
src/Services/{CommentaryGenerating,FoundationModelsCommentaryGenerator,TemplatedCommentaryGenerator,
              PersonalityGate,PersonalityRateLimiter,CommentarySanitizer,PersonalityService,GitActivityProvider}.swift
src/Views/Settings/PersonalitySettingsTabView.swift
Tests/BitzTests/Personality*Tests.swift
```

**Structure Decision**: extend the existing `BitzCore` target. No new targets.

## Implementation Concern Map

- **IC-01 Core contracts**: models, protocol, stub, settings store.
- **IC-02 Guard rails**: gate, rate limiter, sanitizer, timeout and fallback in the service.
- **IC-03 Backends**: templated generator, then the Foundation Models generator with lazy load, idle unload and memory-pressure unload.
- **IC-04 Engine and UI wiring**: `WellnessPointEngine` idle slot, `BitzApp` wiring, context builder, critical rephrase.
- **IC-05 Settings tab**: `PersonalitySettingsTabView` registered in `SettingsRootView`.
- **IC-06 Git activity** (P3): provider, repo picker, context field.
- **IC-07 Verification**: network-free assertion test, full `xcrun swift test`, release CPU/RAM check, PR backend doc.

## Risks

- The Foundation Models API surface is unverified here. IC-03 starts by checking the SDK in the installed Xcode (this Mac runs macOS 26.6.2).
- `swift test` on the Xcode toolchain must compile with the macOS 14 deployment target and the `#available` gate.
- Model output can ignore length limits. The sanitizer truncates, and rejects lines it can't repair.

## Complexity Tracking

No charter violations.
