# Mission Specification: On-Device AI Personality

**Mission Branch**: `feat/20-on-device-ai-personality`  
**Created**: 2026-11-03  
**Status**: Draft  
**Input**: GitHub issue #20 — "On-Device AI Personality for Bitz"

## Summary

Add an opt-in, fully on-device personality that writes short speech-bubble comments from live context (wellness state, work streak, CPU temp/load, frontmost app, agent status, optional git activity). It supplements the existing static lines and never replaces critical warnings. Primary backend: Apple Foundation Models (macOS 26+). Fallback: templated lines filled with live data. No network, no new SwiftPM dependencies.

## User Scenarios & Testing *(mandatory)*

### User Story 1 - Context-aware comments (Priority: P1)

With the feature enabled, Bitz occasionally says a short line that reflects what the user is doing.

**Why this priority**: Core value of the feature.

**Independent Test**: Enable the feature with a stub generator; with `activeSpeechBubbleText == nil` and a populated context, a single-line comment appears in the bubble.

**Acceptance Scenarios**:

1. **Given** the feature is on and no bubble is active, **When** the rate limiter allows, **Then** one sanitized line (≤ ~80 chars) is shown.
2. **Given** the feature is off (default), **When** Bitz runs, **Then** behavior is identical to today.
3. **Given** an agent popup is showing, **When** a comment is due, **Then** it does not interrupt the popup.

---

### User Story 2 - Safe fallback and critical warnings (Priority: P1)

Deterministic warnings always appear; AI failures degrade silently to static lines.

**Independent Test**: Stub generator throws / times out (> ~2 s) / is unavailable; static lines are used. Thermal, burnout and overworked warnings always display, static or as an AI rephrase that preserves the message.

**Acceptance Scenarios**:

1. **Given** model unavailable, error or timeout, **When** a comment is due, **Then** the existing static string (or templated line) is used.
2. **Given** a critical warning state, **When** evaluating, **Then** the warning is shown regardless of AI state.

---

### User Story 3 - Resource-aware and rate-limited (Priority: P1)

Generation never worsens the thermal/battery situation Bitz reports.

**Independent Test**: Unit tests for the rate limiter (min gap, daily cap) and gating (low battery, Low Power Mode, `thermalState >= .serious`).

**Acceptance Scenarios**:

1. **Given** a line was shown less than N minutes ago or the daily cap is reached, **Then** no generation occurs.
2. **Given** low battery, Low Power Mode, or serious/critical thermal state, **Then** generation is skipped.

---

### User Story 4 - Settings and personality presets (Priority: P2)

Users enable the feature and choose Snarky / Supportive / Cute, plus interval and daily cap, in Settings.

**Independent Test**: Toggle and preset changes persist in isolated `UserDefaults` and change the system prompt/tone guide.

**Acceptance Scenarios**:

1. **Given** Settings is open, **When** the user selects a preset, **Then** subsequent generations use that preset's prompt.

---

### User Story 5 - Git activity signal (Priority: P3, opt-in)

Users choose watched repos; recent commit count (via local `git log --since`) feeds the context.

**Independent Test**: With a temp repo and stub runner, commit count is included in `PersonalityContext`; with no repos selected, no git process runs.

**Acceptance Scenarios**:

1. **Given** no repos selected, **Then** no git commands execute.

---

### Edge Cases

- macOS < 26, Intel Mac, or Apple Intelligence disabled/model not ready → templated fallback.
- Model output multi-line, too long, containing URLs, or echoing window titles → sanitized or discarded.
- Memory pressure or idle timeout → backend session released.
- Settings closed → no extra CPU/RAM from the feature UI.

## Requirements *(mandatory)*

### Functional Requirements

| ID | Title | User Story | Priority | Status |
|----|-------|------------|----------|--------|
| FR-001 | Opt-in toggle | As a user, I want AI personality off by default and switchable in Settings so that nothing changes unless I choose. | High | Open |
| FR-002 | CommentaryGenerating protocol | As a developer, I want a swappable backend protocol with a Foundation Models backend, templated backend and test stub. | High | Open |
| FR-003 | PersonalityContext | As a developer, I want a snapshot of wellness state/points, work streak, temp/load, frontmost app, agent status and optional git activity. | High | Open |
| FR-004 | Idle-only display | As a user, I want comments only when no other bubble is active, never interrupting agent popups. | High | Open |
| FR-005 | Critical warnings preserved | As a user, I want thermal/burnout/overworked/dopamine warnings always shown, static or rephrased with the same meaning. | High | Open |
| FR-006 | Fallback | As a user, I want static lines on unavailable model, error, or ~2 s timeout. | High | Open |
| FR-007 | Rate limiting | As a user, I want ≤ 1 line per N minutes (configurable) and a daily cap. | High | Open |
| FR-008 | Resource gating | As a user, I want generation skipped on low battery, Low Power Mode, or serious/critical thermal state. | High | Open |
| FR-009 | Presets | As a user, I want Snarky / Supportive / Cute presets that change tone. | Medium | Open |
| FR-010 | Output sanitization | As a user, I want single-line, length-capped output with no raw URLs or window titles. | High | Open |
| FR-011 | Lazy load/unload | As a user, I want the model loaded on first use and released after idle timeout or memory pressure. | High | Open |
| FR-012 | Git activity (opt-in) | As a user, I want to pick repos whose recent commit count informs comments. | Low | Open |
| FR-013 | Backend decision doc | As a maintainer, I want the Foundation Models vs MLX vs llama.cpp tradeoff documented in the PR. | Medium | Open |

### Non-Functional Requirements

| ID | Title | Requirement | Category | Priority | Status |
|----|-------|-------------|----------|----------|--------|
| NFR-001 | Idle CPU | Desktop idle CPU stays < 2% with feature on and Settings closed. | Performance | High | Open |
| NFR-002 | Idle RAM | Total app RAM < 70 MB when backend unloaded; feature overhead ≈ 0 when unloaded. | Performance | High | Open |
| NFR-003 | Privacy | Zero network requests from the feature; verified by test/inspection. | Security | High | Open |
| NFR-004 | Determinism | All logic testable with stub generator; full `xcrun swift test` passes. | Reliability | High | Open |
| NFR-005 | Latency bound | Generation abandoned after ~2 s; UI never blocks the main thread. | Reliability | High | Open |

### Constraints

| ID | Title | Constraint | Category | Priority | Status |
|----|-------|------------|----------|----------|--------|
| C-001 | No new dependencies | Zero external SwiftPM dependencies; package stays macOS 14+ with `#available(macOS 26, *)` gating. | Technical | High | Open |
| C-002 | Panel invariants | Click-through, no focus stealing and no off-window drawing per AGENTS.md remain intact. | Technical | High | Open |
| C-003 | Engine isolation | Polling observers stay in leaf views; settings window detaches on close. | Technical | High | Open |
| C-004 | Test isolation | Stores/services tests use isolated `UserDefaults(suiteName:)` with cleanup. | Technical | Medium | Open |

### Key Entities

- **PersonalityContext**: immutable snapshot of signals used to prompt the generator.
- **CommentaryGenerating**: backend protocol (`generate(context, preset) async throws -> String`).
- **PersonalityService**: `ObservableObject` orchestrating gating, rate limit, timeout, sanitizing and fallback.
- **PersonalityPreset**: Snarky / Supportive / Cute with prompt and tone guide.
- **PersonalitySettingsStore**: persisted toggle, preset, interval, daily cap, watched repos.

## Success Criteria *(mandatory)*

### Measurable Outcomes

- **SC-001**: With the feature off, bubble behavior is byte-identical to the current build (existing tests unchanged and green).
- **SC-002**: With the feature on, idle CPU < 2% and no network connections from the process attributable to the feature.
- **SC-003**: 100% of critical warnings are displayed in unit tests across all gating/failure combinations.
- **SC-004**: Rate limiter never emits more than the configured lines per interval/day in tests.
- **SC-005**: Switching presets produces distinct system prompts verified by test.
