---
work_package_id: WP01
title: Speech Recognition Model Probing, Diagnostics & Deep Linking
dependencies: []
requirement_refs:
- FR-005
- FR-006
- FR-007
- C-001
planning_base_branch: feat/issue-148-multilingual-transcription
merge_target_branch: feat/issue-148-multilingual-transcription
branch_strategy: Planning artifacts for this mission were generated on feat/issue-148-multilingual-transcription. During /spec-kitty.implement this WP may branch from a dependency-specific base, but completed changes must merge back into feat/issue-148-multilingual-transcription unless the human explicitly redirects the landing branch.
subtasks:
- T001
- T002
- T003
- T004
phase: Phase 1 - Services & Probing
agent: Antigravity
history:
- timestamp: '2026-11-12T00:00:00Z'
  agent: system
  action: Prompt generated via plan
authoritative_surface: src/Services/MeetingRecorder/
create_intent: []
execution_mode: code_change
owned_files:
- src/Services/MeetingRecorder/MeetingTranscriptionService.swift
- src/Models/MeetingBubble.swift
- Tests/BitzTests/MeetingTranscriptionTests.swift
tags: []
tracker_refs: []
---

# Work Package Prompt: WP01 – Speech Recognition Model Probing, Diagnostics & Deep Linking

## Objectives
Implement on-device speech model readiness checking (`checkOnDeviceAssetStatus(for:)`), friendly error classification for missing Dictation models, and a utility to deep-link to macOS Keyboard/Dictation System Settings.

## Files to Create / Modify
- `src/Services/MeetingRecorder/MeetingTranscriptionService.swift`
- `src/Models/MeetingBubble.swift`
- `Tests/BitzTests/MeetingTranscriptionTests.swift`
