# On-Device AI Personality Backend Evaluation & Decision Record

## 1. Context & Problem Statement

Ticket [#20](https://github.com/AkramKs/bitz-mac/issues/20) requests an opt-in, fully on-device AI personality for Bitz that writes short commentary lines (≤ 80 characters) based on live context (wellness points/state, continuous focus streak, CPU load/temperature, frontmost application, active AI coding agents, and optional git commit velocity).

Bitz sits on user desktops all day alongside resource-intensive IDEs (Xcode, Cursor, VS Code) and LLM agent processes. Consequently, any AI personality backend MUST strictly comply with Bitz's architectural performance invariants (`AGENTS.md` §2):
- **Idle CPU**: `< 2%` on Apple Silicon.
- **Memory Footprint**: `< 70 MB` RAM with model unloaded.
- **Privacy & Sandboxing**: Zero network egress (`0%` cloud telemetry or API calls).
- **Toolchain & Dependencies**: Zero external SwiftPM dependencies; clean Xcode toolchain build.
- **Warning Priority**: Deterministic critical warnings (thermal alerts, burnout, overworked) MUST always take priority over AI commentary.

---

## 2. Backend Evaluation Matrix

| Backend Candidate | Latency / Timeout | App Size Impact | Idle RAM | Offline & Private | External Dependencies / Daemons | Verdict |
| :--- | :--- | :--- | :--- | :--- | :--- | :--- |
| **Apple Foundation Models (`LanguageModelSession`)** | `< 2.0s` bound | `0 MB` (system framework) | `0 MB` (system managed) | `100%` On-Device | None (`#if canImport(FoundationModels)`) | **Selected (Primary LLM Backend)** |
| **Built-in Templated Generator** | `< 0.1ms` | `0 MB` (pure Swift actor) | `< 1 MB` | `100%` On-Device | None (zero dependencies) | **Selected (Universal Instant Fallback)** |
| **MLX Swift (`mlx-swift`)** | `0.5s–2.0s` | `+15 MB` binary + `2–4 GB` model weights | `> 1.5 GB` while active | `100%` On-Device | Heavy SwiftPM framework + HuggingFace weights | **Deferred (Future Optional Plugin)** |
| **llama.cpp / GGUF** | `0.8s–3.0s` | `+10 MB` binary + `1–3 GB` GGUF | `> 1.0 GB` | `100%` On-Device | C++ toolchain integration + bundled/downloaded weights | **Rejected (Violates 70 MB budget)** |
| **Ollama (HTTP Daemon)** | `0.5s–2.0s` | `0 MB` in app | `4–8 GB` daemon RAM | Localhost HTTP | Requires standalone background service running | **Rejected (Too heavyweight & fragile)** |

---

## 3. Decision Rationale

### Primary LLM Backend: Apple Foundation Models
- **Native OS Integration**: Apple Foundation Models provides system-level on-device language models running on the Apple Neural Engine (ANE) and GPU.
- **Zero Packaging Overhead**: No multi-gigabyte weights bundled with `Bitz.app` or downloaded on first run.
- **Dynamic Memory Management**: macOS handles model loading, caching, and eviction under memory pressure; Bitz releases its session on idle and termination via `unload()`.
- **Targeting**: Conditionally compiled with `#if canImport(FoundationModels)` and `@available(macOS 26.0, *)`, falling back transparently on macOS 14–25.

### Universal Fallback: Built-in Templated Generator
- **Instant Availability**: Ready immediately on all macOS 14+ systems without compilation flags, system model downloads, or warm-up latency.
- **Deterministic Reliability**: Categorized pools across all presets (`snarky`, `supportive`, `cute`) and states (`superCharged`, `balanced`, `dopamineSad`, `charging`, `overworked`, `burnout`, `overheating`).
- **Safety Seam**: Guarantees that if the LLM times out (`> 2.0s`), errors, or is gated by hardware/battery constraints, commentary still delivers smoothly without dropped frames.

### Why Ollama & llama.cpp Were Rejected
- Running Ollama requires the user to install a 4GB+ daemon that continuously consumes gigabytes of memory and battery, contradicting Bitz's lightweight pet philosophy.
- Bundling llama.cpp or MLX would require Bitz to download or ship 2–4 GB model files, violating the App Store / lightweight distribution invariants and pushing idle memory far past the 70 MB budget.

---

## 4. Architectural Safety Invariants

1. **Strict 2.0s Latency Bound**:
   - `PersonalityService.generateWithFallback(...)` enforces a hard `2.0s` timeout via `withThrowingTaskGroup`. If the primary generator exceeds 2.0s, the task is canceled and execution falls back to `TemplatedCommentaryGenerator`.
2. **Hardware & Thermal Gating**:
   - `PersonalityGate` blocks generation if:
     - Low Power Mode is active.
     - Battery level is `< 20%` on battery power.
     - `ProcessInfo.ThermalState` is `.serious` or `.critical`.
     - Wellness state is `.overheating`.
3. **Speech Bubble Priority & Synchronous Static Warnings**:
   - `SpeechBubbleView` hierarchy: `.agentPopup` > `.update` > `displayedSpeechBubbleText` (`.wellness`) > `.carousel`.
   - `WellnessPointEngine.displayedSpeechBubbleText`: `activeSpeechBubbleText ?? idleCommentaryText ?? transientBubbleText`.
   - When a warning triggers (e.g. `SYSTEM HOT! > <`), the static warning string is ALWAYS set synchronously first. Optional AI rephrasing runs asynchronously in the background and replaces the text only if the state hasn't changed.
4. **Single-Line Sanitization**:
   - `CommentarySanitizer` enforces a hard limit of `80` characters, strips line breaks, markdown, quotation marks, and URLs, and rejects commentary echoing the active application name.
