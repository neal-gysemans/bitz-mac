---
work_package_id: WP04
title: Foundation Models Backend
dependencies: [WP01]
requirement_refs:
- FR-002
- FR-011
- FR-013
- C-001
- NFR-002
planning_base_branch: feat/20-on-device-ai-personality
merge_target_branch: feat/20-on-device-ai-personality
branch_strategy: Planning artifacts for this mission were generated on feat/20-on-device-ai-personality. During /spec-kitty.implement this WP may branch from a dependency-specific base, but completed changes must merge back into feat/20-on-device-ai-personality unless the human explicitly redirects the landing branch.
base_branch: kitty/mission-on-device-ai-personality-01M6GG7J
base_commit: d926684a9055f00c1959320e70b4990188fc43ed
created_at: '2026-11-03T11:19:16.428168+00:00'
subtasks:
- T013
- T014
- T015
- T016
phase: Phase 3 - Backend
history: []
authoritative_surface: src/Services/
create_intent:
- src/Services/FoundationModelsCommentaryGenerator.swift
- Tests/BitzTests/FoundationModelsAvailabilityTests.swift
execution_mode: code_change
owned_files:
- src/Services/FoundationModelsCommentaryGenerator.swift
- Tests/BitzTests/FoundationModelsAvailabilityTests.swift
tags: []
task_type: implement
tracker_refs: []
---

# Work Package Prompt: WP04 – Foundation Models Backend

## Objectives & Success Criteria
Real on-device backend with lazy load and unload. Satisfies: FR-002, FR-011, FR-013, C-001, NFR-002 (see spec.md).

## Subtasks
- **T013**: First verify the `FoundationModels` API against the installed Xcode SDK (macOS 26.6.2 host); record findings in `research/foundation-models.md`.
- **T014**: Implement `FoundationModelsCommentaryGenerator` inside `#if canImport(FoundationModels)` + `#available(macOS 26, *)`: check `SystemLanguageModel.default.availability`, create the session lazily with preset instructions, throw `PersonalityError.unavailable` otherwise.
- **T015**: Release the session after an idle timeout and on memory-pressure notifications (`unload()`).
- **T016**: Tests that compile and pass on all supported OS versions: availability mapping and unload behavior via a seam; no live model required.

## Notes & Risks
Follow AGENTS.md invariants (Swift 6, no new dependencies, isolated UserDefaults in tests, Xcode toolchain). Run `xcrun swift test` before finishing.
