---
work_package_id: WP04
title: Settings Model Status Badges & 1-Click Dictation Deep Link
dependencies:
- WP01
requirement_refs:
- FR-005
- FR-006
planning_base_branch: feat/issue-148-multilingual-transcription
merge_target_branch: feat/issue-148-multilingual-transcription
branch_strategy: Planning artifacts for this mission were generated on feat/issue-148-multilingual-transcription. During /spec-kitty.implement this WP may branch from a dependency-specific base, but completed changes must merge back into feat/issue-148-multilingual-transcription unless the human explicitly redirects the landing branch.
subtasks:
- T013
- T014
- T015
phase: Phase 4 - Settings UI
agent: Antigravity
history:
- timestamp: '2026-11-12T00:00:00Z'
  agent: system
  action: Prompt generated via plan
authoritative_surface: src/Views/Settings/
create_intent: []
execution_mode: code_change
owned_files:
- src/Views/Settings/AudioSettingsTabView.swift
- Tests/BitzTests/AudioSettingsViewsTests.swift
tags: []
tracker_refs: []
---

# Work Package Prompt: WP04 – Settings Model Status Badges & 1-Click Dictation Deep Link

## Objectives
Display model readiness status in Settings > Audio > Transcription, show missing model warnings, and provide the 1-click button opening macOS Dictation settings.

## Files to Create / Modify
- `src/Views/Settings/AudioSettingsTabView.swift`
- `Tests/BitzTests/AudioSettingsViewsTests.swift`
