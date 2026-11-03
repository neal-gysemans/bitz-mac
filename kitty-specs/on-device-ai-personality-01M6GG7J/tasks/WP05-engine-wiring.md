---
work_package_id: WP05
title: Engine & App Wiring
dependencies: ['WP03']
requirement_refs:
- FR-004
- FR-005
- C-002
- C-003
- NFR-001
planning_base_branch: feat/20-on-device-ai-personality
merge_target_branch: feat/20-on-device-ai-personality
branch_strategy: Planning artifacts for this mission were generated on feat/20-on-device-ai-personality. During /spec-kitty.implement this WP may branch from a dependency-specific base, but completed changes must merge back into feat/20-on-device-ai-personality unless the human explicitly redirects the landing branch.
subtasks:
- T017
- T018
- T019
- T020
phase: Phase 4 - Integration
history: []
authoritative_surface: src/
execution_mode: code_change
create_intent:
- Tests/BitzTests/PersonalityIntegrationTests.swift
owned_files:
- src/Services/WellnessPointEngine.swift
- src/App/BitzApp.swift
- Tests/BitzTests/PersonalityIntegrationTests.swift
tags: []
task_type: implement
tracker_refs: []
---

# Work Package Prompt: WP05 – Engine & App Wiring

## Objectives & Success Criteria
Show AI lines without touching warning priority. Satisfies: FR-004, FR-005, C-002, C-003, NFR-001 (see spec.md).

## Subtasks
- **T017**: Add an injectable idle-commentary input to `WellnessPointEngine`; `currentBubbleText` becomes `activeSpeechBubbleText ?? idleCommentary ?? transientBubbleText`. Off means identical output.
- **T018**: `BitzApp` owns `PersonalityService`, builds `PersonalityContext` from the engine, `ActivityMonitorService` and `AgentMonitorService`, and calls `tick` from the existing telemetry tick (no new timers).
- **T019**: Agent popups and critical warnings keep priority; optional rephrase wiring with static text set first.
- **T020**: Tests: existing engine tests unchanged and green; warnings always shown in all gating and failure combinations; idle line only when no other bubble.

## Notes & Risks
Follow AGENTS.md invariants (Swift 6, no new dependencies, isolated UserDefaults in tests, Xcode toolchain). Run `xcrun swift test` before finishing.
