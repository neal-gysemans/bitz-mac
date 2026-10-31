---
work_package_id: WP05
title: Quality Verification, Invariants & Packaging
dependencies:
- WP01
- WP02
- WP03
- WP04
requirement_refs:
- C-001
- NFR-001
- NFR-002
- NFR-005
planning_base_branch: feat/issue-21-cyber-audio
merge_target_branch: feat/issue-21-cyber-audio
branch_strategy: Planning artifacts for this mission were generated on feat/issue-21-cyber-audio. During /spec-kitty.implement this WP may branch from a dependency-specific base, but completed changes must merge back into feat/issue-21-cyber-audio unless the human explicitly redirects the landing branch.
subtasks:
- T017
- T018
- T019
- T020
phase: Phase 5 - Verification
history: []
authoritative_surface: Tests/
create_intent: []
execution_mode: code_change
owned_files:
- Tests/BitzTests/MascotOverlayLayoutTests.swift
tags: []
task_type: verify
tracker_refs: []
---

# Work Package Prompt: WP05 – Quality Verification, Invariants & Packaging

## Objectives & Success Criteria
Satisfies: C-001, NFR-001, NFR-002, NFR-005, SC-002, SC-004, SC-005 (see spec.md).

## Subtasks
- **T017**: Run `xcrun swift test` and ensure all unit tests pass with zero failures.
- **T018**: Verify `MascotOverlayPanel.ignoresMouseEvents` invariant remains `true` and verify zero keyboard focus stealing.
- **T019**: Verify total sound asset bundle size is strictly < 300 KB and license provenance is complete.
- **T020**: Package and run with `./Scripts/package_and_run.sh release` to confirm live signing and AppKit execution.

## Notes & Risks
Zero regressions across all existing suites.
