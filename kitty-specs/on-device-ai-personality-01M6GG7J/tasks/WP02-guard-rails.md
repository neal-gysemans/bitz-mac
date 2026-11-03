---
work_package_id: WP02
title: Gate, Rate Limiter & Sanitizer
dependencies: [WP01]
requirement_refs:
- FR-007
- FR-008
- FR-010
- NFR-004
planning_base_branch: feat/20-on-device-ai-personality
merge_target_branch: feat/20-on-device-ai-personality
branch_strategy: Planning artifacts for this mission were generated on feat/20-on-device-ai-personality. During /spec-kitty.implement this WP may branch from a dependency-specific base, but completed changes must merge back into feat/20-on-device-ai-personality unless the human explicitly redirects the landing branch.
base_branch: kitty/mission-on-device-ai-personality-01M6GG7J
base_commit: 0c81da1f97065dcf7250f58962653e23ffe0e332
created_at: '2026-11-03T11:08:06.546481+00:00'
subtasks:
- T005
- T006
- T007
- T008
phase: Phase 2 - Guard Rails
history: []
authoritative_surface: src/Services/
create_intent:
- src/Services/PersonalityGate.swift
- src/Services/PersonalityRateLimiter.swift
- src/Services/CommentarySanitizer.swift
- Tests/BitzTests/PersonalityGuardRailTests.swift
execution_mode: code_change
owned_files:
- src/Services/PersonalityGate.swift
- src/Services/PersonalityRateLimiter.swift
- src/Services/CommentarySanitizer.swift
- Tests/BitzTests/PersonalityGuardRailTests.swift
tags: []
task_type: implement
tracker_refs: []
---

# Work Package Prompt: WP02 – Gate, Rate Limiter & Sanitizer

## Objectives & Success Criteria
Pure, injectable, fully unit-tested guard rails. Satisfies: FR-007, FR-008, FR-010, NFR-004 (see spec.md).

## Subtasks
- **T005**: `PersonalityGate` with injectable `PowerStateProviding` (battery %, Low Power Mode, `ProcessInfo.thermalState`); skip on low battery, LPM, serious/critical.
- **T006**: `PersonalityRateLimiter` with injectable clock: min gap and daily cap with day rollover.
- **T007**: `CommentarySanitizer`: single line, ~80-char cap, strip URLs, reject output echoing the window title or empty output.
- **T008**: Tests covering every gate combination, gap/cap/rollover edge cases and sanitizer cases.

## Notes & Risks
Follow AGENTS.md invariants (Swift 6, no new dependencies, isolated UserDefaults in tests, Xcode toolchain). Run `xcrun swift test` before finishing.
