---
work_package_id: WP03
title: Menu Bar Quick Language Switcher & Re-transcribe As Submenus
dependencies:
- WP01
- WP02
requirement_refs:
- FR-001
- FR-002
- FR-003
planning_base_branch: feat/issue-148-multilingual-transcription
merge_target_branch: feat/issue-148-multilingual-transcription
branch_strategy: Planning artifacts for this mission were generated on feat/issue-148-multilingual-transcription. During /spec-kitty.implement this WP may branch from a dependency-specific base, but completed changes must merge back into feat/issue-148-multilingual-transcription unless the human explicitly redirects the landing branch.
subtasks:
- T009
- T010
- T011
- T012
phase: Phase 3 - Menu Bar UI
agent: Antigravity
history:
- timestamp: '2026-11-12T00:00:00Z'
  agent: system
  action: Prompt generated via plan
authoritative_surface: src/App/
create_intent: []
execution_mode: code_change
owned_files:
- src/App/BitzApp.swift
- Tests/BitzTests/MenuBarContentViewTests.swift
tags: []
tracker_refs: []
---

# Work Package Prompt: WP03 – Menu Bar Quick Language Switcher & Re-transcribe As Submenus

## Objectives
Add `Meeting Language ▸` and `Transcribe Last Recording Again As ▸` submenus directly in `BitzMenuBarContentView`.

## Files to Create / Modify
- `src/App/BitzApp.swift`
- `Tests/BitzTests/MenuBarContentViewTests.swift`
