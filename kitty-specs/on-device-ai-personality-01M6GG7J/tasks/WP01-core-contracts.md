---
work_package_id: WP01
title: Core Contracts, Stub & Settings Store
dependencies: []
requirement_refs:
- FR-001
- FR-002
- FR-003
- C-001
- C-004
planning_base_branch: feat/20-on-device-ai-personality
merge_target_branch: feat/20-on-device-ai-personality
branch_strategy: Planning artifacts for this mission were generated on feat/20-on-device-ai-personality. During /spec-kitty.implement this WP may branch from a dependency-specific base, but completed changes must merge back into feat/20-on-device-ai-personality unless the human explicitly redirects the landing branch.
subtasks:
- T001
- T002
- T003
- T004
phase: Phase 1 - Foundation
history: []
authoritative_surface: src/Models/
execution_mode: code_change
create_intent:
- src/Models/PersonalityModels.swift
- src/Services/CommentaryGenerating.swift
- src/Models/PersonalitySettingsStore.swift
- Tests/BitzTests/PersonalityCoreTests.swift
owned_files:
- src/Models/PersonalityModels.swift
- src/Services/CommentaryGenerating.swift
- src/Models/PersonalitySettingsStore.swift
- Tests/BitzTests/PersonalityCoreTests.swift
tags: []
task_type: implement
tracker_refs: []
---

# Work Package Prompt: WP01 – Core Contracts, Stub & Settings Store

## Objectives & Success Criteria
Define the contracts everything else builds on. Satisfies: FR-001, FR-002, FR-003, C-001, C-004 (see spec.md).

## Subtasks
- **T001**: Add `PersonalityPreset` (snarky/supportive/cute, each with system prompt + tone guide), `PersonalityContext` (wellness state/points, work minutes, temp, CPU load, frontmost app, agent status, optional git commit count) and `PersonalityError`.
- **T002**: Add `CommentaryGenerating` protocol (`generate(context:preset:) async throws -> String`, `unload()`), `GitActivityProviding` protocol with a no-op default, and a `StubCommentaryGenerator` for tests.
- **T003**: Add `PersonalitySettingsStore` (enabled=false, preset, min interval minutes, daily cap, watched repos, daily counter) on `UserDefaults`.
- **T004**: Tests with isolated `UserDefaults(suiteName:)` and cleanup: defaults off, persistence round-trip, preset prompts are distinct.

## Notes & Risks
Follow AGENTS.md invariants (Swift 6, no new dependencies, isolated UserDefaults in tests, Xcode toolchain). Run `xcrun swift test` before finishing.
