---
work_package_id: WP05
title: Verification, CPU Invariants & Packaging
dependencies:
- WP01
- WP02
- WP03
- WP04
requirement_refs:
- NFR-001
- NFR-002
- NFR-005
- C-004
planning_base_branch: feat/issue-150-archetype-sound-design
merge_target_branch: feat/issue-150-archetype-sound-design
branch_strategy: Planning artifacts for this mission were generated on feat/issue-150-archetype-sound-design. During /spec-kitty.implement this WP may branch from a dependency-specific base, but completed changes must merge back into feat/issue-150-archetype-sound-design unless the human explicitly redirects the landing branch.
subtasks:
- T019
- T020
- T021
- T022
phase: Phase 5 - Verification
history:
- timestamp: '2026-11-12T00:00:00Z'
  agent: system
  action: Prompt generated via plan
authoritative_surface: src/
create_intent: []
execution_mode: code_change
owned_files:
- src/**
tags: []
tracker_refs: []
---

# Work Package Prompt: WP05 – Verification, CPU Invariants & Packaging

## Objectives
Execute full test suite (`xcrun swift test`), build and run release package (`./Scripts/package_and_run.sh release`), verify idle CPU `< 2%` with Settings closed via `top`, and perform listening check.

## Files to Create / Modify
- Test suite execution
- Release packaging verification
