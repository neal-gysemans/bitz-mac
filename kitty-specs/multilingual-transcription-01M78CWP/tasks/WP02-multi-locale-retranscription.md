---
work_package_id: WP02
title: Multi-Locale Re-transcription Engine
dependencies:
- WP01
requirement_refs:
- FR-004
planning_base_branch: feat/issue-148-multilingual-transcription
merge_target_branch: feat/issue-148-multilingual-transcription
branch_strategy: Planning artifacts for this mission were generated on feat/issue-148-multilingual-transcription. During /spec-kitty.implement this WP may branch from a dependency-specific base, but completed changes must merge back into feat/issue-148-multilingual-transcription unless the human explicitly redirects the landing branch.
subtasks:
- T005
- T006
- T007
- T008
phase: Phase 2 - Re-transcription
agent: Antigravity
history:
- timestamp: '2026-11-12T00:00:00Z'
  agent: system
  action: Prompt generated via plan
authoritative_surface: src/Services/MeetingRecorder/
create_intent: []
execution_mode: code_change
owned_files:
- src/Services/MeetingRecorder/MeetingRecorderService.swift
- Tests/BitzTests/MeetingRecorderServiceTests.swift
tags: []
tracker_refs: []
---

# Work Package Prompt: WP02 – Multi-Locale Re-transcription Engine

## Objectives
Extend `MeetingRecorderService.transcribeAgain(localeIdentifier:)` to accept an explicit target locale, re-transcribe session audio with that locale, and update session metadata.

## Files to Create / Modify
- `src/Services/MeetingRecorder/MeetingRecorderService.swift`
- `Tests/BitzTests/MeetingRecorderServiceTests.swift`
