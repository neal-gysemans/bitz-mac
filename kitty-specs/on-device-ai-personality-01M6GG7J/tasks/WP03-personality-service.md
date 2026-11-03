---
work_package_id: WP03
title: Templated Backend & PersonalityService
dependencies: ['WP01', 'WP02']
requirement_refs:
- FR-004
- FR-006
- FR-009
- NFR-003
- NFR-005
- NFR-004
planning_base_branch: feat/20-on-device-ai-personality
merge_target_branch: feat/20-on-device-ai-personality
branch_strategy: Planning artifacts for this mission were generated on feat/20-on-device-ai-personality. During /spec-kitty.implement this WP may branch from a dependency-specific base, but completed changes must merge back into feat/20-on-device-ai-personality unless the human explicitly redirects the landing branch.
subtasks:
- T009
- T010
- T011
- T012
phase: Phase 3 - Service
history: []
authoritative_surface: src/Services/
execution_mode: code_change
create_intent:
- src/Services/TemplatedCommentaryGenerator.swift
- src/Services/PersonalityService.swift
- Tests/BitzTests/PersonalityServiceTests.swift
owned_files:
- src/Services/TemplatedCommentaryGenerator.swift
- src/Services/PersonalityService.swift
- Tests/BitzTests/PersonalityServiceTests.swift
tags: []
task_type: implement
tracker_refs: []
---

# Work Package Prompt: WP03 – Templated Backend & PersonalityService

## Objectives & Success Criteria
Orchestrate gate, limiter, generation, timeout, sanitizing and fallback. Satisfies: FR-004, FR-006, FR-009, NFR-003, NFR-005, NFR-004 (see spec.md).

## Subtasks
- **T009**: `TemplatedCommentaryGenerator`: per-preset template pools filled from `PersonalityContext`, no repeats within the last K lines.
- **T010**: `PersonalityService` (`@MainActor ObservableObject`): `tick(context:isBubbleIdle:)` runs gate, limiter, generate with ~2 s timeout, sanitize and publish `aiCommentary`; falls back to templated on error, unavailability or timeout. Does nothing when disabled.
- **T011**: Optional `rephrase(warning:)` that keeps the warning meaning and falls back to the static text on any failure.
- **T012**: Tests with the stub: disabled no-op, success, error fallback, timeout fallback, rate limit honored, preset changes prompt, no network types used.

## Notes & Risks
Follow AGENTS.md invariants (Swift 6, no new dependencies, isolated UserDefaults in tests, Xcode toolchain). Run `xcrun swift test` before finishing.
