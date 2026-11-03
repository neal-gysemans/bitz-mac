# Tasks: On-Device AI Personality

**Spec**: [spec.md](spec.md) | **Plan**: [plan.md](plan.md)

## Work Package WP01: Core Contracts, Stub & Settings Store

**Goal**: Define the contracts everything else builds on.
**Prompt**: `/tasks/WP01-core-contracts.md`
**Requirement Refs**: FR-001, FR-002, FR-003, C-001, C-004
**Dependencies**: none

### Included Subtasks
- T001: Add `PersonalityPreset` (snarky/supportive/cute, each with system prompt + tone guide), `PersonalityContext` (wellness state/points, work minutes, temp, CPU load, frontmost app, agent status, optional git commit count) and `PersonalityError`.
- T002: Add `CommentaryGenerating` protocol (`generate(context:preset:) async throws -> String`, `unload()`), `GitActivityProviding` protocol with a no-op default, and a `StubCommentaryGenerator` for tests.
- T003: Add `PersonalitySettingsStore` (enabled=false, preset, min interval minutes, daily cap, watched repos, daily counter) on `UserDefaults`.
- T004: Tests with isolated `UserDefaults(suiteName:)` and cleanup: defaults off, persistence round-trip, preset prompts are distinct.

---

## Work Package WP02: Gate, Rate Limiter & Sanitizer

**Goal**: Pure, injectable, fully unit-tested guard rails.
**Prompt**: `/tasks/WP02-guard-rails.md`
**Requirement Refs**: FR-007, FR-008, FR-010, NFR-004
**Dependencies**: WP01

### Included Subtasks
- T005: `PersonalityGate` with injectable `PowerStateProviding` (battery %, Low Power Mode, `ProcessInfo.thermalState`); skip on low battery, LPM, serious/critical.
- T006: `PersonalityRateLimiter` with injectable clock: min gap and daily cap with day rollover.
- T007: `CommentarySanitizer`: single line, ~80-char cap, strip URLs, reject output echoing the window title or empty output.
- T008: Tests covering every gate combination, gap/cap/rollover edge cases and sanitizer cases.

---

## Work Package WP03: Templated Backend & PersonalityService

**Goal**: Orchestrate gate, limiter, generation, timeout, sanitizing and fallback.
**Prompt**: `/tasks/WP03-personality-service.md`
**Requirement Refs**: FR-004, FR-006, FR-009, NFR-003, NFR-005, NFR-004
**Dependencies**: WP01, WP02

### Included Subtasks
- T009: `TemplatedCommentaryGenerator`: per-preset template pools filled from `PersonalityContext`, no repeats within the last K lines.
- T010: `PersonalityService` (`@MainActor ObservableObject`): `tick(context:isBubbleIdle:)` runs gate, limiter, generate with ~2 s timeout, sanitize and publish `aiCommentary`; falls back to templated on error, unavailability or timeout. Does nothing when disabled.
- T011: Optional `rephrase(warning:)` that keeps the warning meaning and falls back to the static text on any failure.
- T012: Tests with the stub: disabled no-op, success, error fallback, timeout fallback, rate limit honored, preset changes prompt, no network types used.

---

## Work Package WP04: Foundation Models Backend

**Goal**: Real on-device backend with lazy load and unload.
**Prompt**: `/tasks/WP04-foundation-models-backend.md`
**Requirement Refs**: FR-002, FR-011, FR-013, C-001, NFR-002
**Dependencies**: WP01

### Included Subtasks
- T013: First verify the `FoundationModels` API against the installed Xcode SDK (macOS 26.6.2 host); record findings in `research/foundation-models.md`.
- T014: Implement `FoundationModelsCommentaryGenerator` inside `#if canImport(FoundationModels)` + `#available(macOS 26, *)`: check `SystemLanguageModel.default.availability`, create the session lazily with preset instructions, throw `PersonalityError.unavailable` otherwise.
- T015: Release the session after an idle timeout and on memory-pressure notifications (`unload()`).
- T016: Tests that compile and pass on all supported OS versions: availability mapping and unload behavior via a seam; no live model required.

---

## Work Package WP05: Engine & App Wiring

**Goal**: Show AI lines without touching warning priority.
**Prompt**: `/tasks/WP05-engine-wiring.md`
**Requirement Refs**: FR-004, FR-005, C-002, C-003, NFR-001
**Dependencies**: WP03

### Included Subtasks
- [x] T017: Add an injectable idle-commentary input to `WellnessPointEngine`; `currentBubbleText` becomes `activeSpeechBubbleText ?? idleCommentary ?? transientBubbleText`. Off means identical output.
- [x] T018: `BitzApp` owns `PersonalityService`, builds `PersonalityContext` from the engine, `ActivityMonitorService` and `AgentMonitorService`, and calls `tick` from the existing telemetry tick (no new timers).
- [x] T019: Agent popups and critical warnings keep priority; optional rephrase wiring with static text set first.
- [x] T020: Tests: existing engine tests unchanged and green; warnings always shown in all gating and failure combinations; idle line only when no other bubble.

---

## Work Package WP06: Settings Tab

**Goal**: User-facing controls.
**Prompt**: `/tasks/WP06-settings-tab.md`
**Requirement Refs**: FR-001, FR-007, FR-009, C-003
**Dependencies**: WP01, WP07

### Included Subtasks
- [x] T021: `PersonalitySettingsTabView`: enable toggle (off by default), preset picker, interval and daily cap, availability note (Foundation Models status), and the watched-repo picker from WP07.
- [x] T022: Register the tab in `SettingsRootView`; bindings persist through `PersonalitySettingsStore`.
- [x] T023: Tests for two-way binding persistence; confirm the window still detaches on close.

---

## Work Package WP07: Opt-in Git Activity Signal

**Goal**: Local, opt-in commit counts.
**Prompt**: `/tasks/WP07-git-activity.md`
**Requirement Refs**: FR-012
**Dependencies**: WP01

### Included Subtasks
- [x] T024: `GitActivityProvider` conforming to `GitActivityProviding`: `git log --since` per chosen repo, off-main, TTL-cached, injectable process runner.
- [x] T025: `GitReposPickerView` (folder picker list) embedded by the Settings tab.
- [x] T026: Tests: no repos means no process spawned; counts aggregate; cache TTL honored.

---

## Work Package WP08: Verification & PR Notes

**Goal**: Prove the budgets and document the decision.
**Prompt**: `/tasks/WP08-verification.md`
**Requirement Refs**: NFR-001, NFR-002, NFR-003, NFR-004, FR-013
**Dependencies**: WP04, WP05, WP06, WP07

### Included Subtasks
- [x] T027: Run full `xcrun swift test` with zero failures.
- [x] T028: Package release and verify idle CPU < 2% and RAM < 70 MB with Settings closed (commands in AGENTS.md section 2.8), feature on, model unloaded.
- [x] T029: Assert no network use from the feature (code inspection plus a test that the service has no URLSession dependency); optionally confirm with `nettop`.
- [x] T030: Write `docs/PERSONALITY_BACKEND_DECISION.md` (Foundation Models vs MLX vs llama.cpp vs Ollama) and update `docs/ARCHITECTURE.md`; prepare PR with `Closes #20` and `refs #20`.

---
