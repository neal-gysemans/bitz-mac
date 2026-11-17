---
work_package_id: WP01
title: WhisperKit ASR Engine, Model Manager, Dual-Track Diarization & UI
dependencies: []
requirement_refs:
- FR-001
- FR-002
- FR-003
- FR-004
- FR-005
- FR-006
planning_base_branch: feat/whisperkit-asr-204
merge_target_branch: feat/whisperkit-asr-204
branch_strategy: Planning artifacts for this mission were generated on feat/whisperkit-asr-204. During /spec-kitty.implement this WP may branch from a dependency-specific base, but completed changes must merge back into feat/whisperkit-asr-204 unless the human explicitly redirects the landing branch.
subtasks: []
history: []
authoritative_surface: src/
create_intent: []
execution_mode: code_change
lane: planned
owned_files:
- src/**
tags: []
tracker_refs: []
---

# WP01: WhisperKit ASR Engine, Model Manager, Dual-Track Diarization & UI

Implement the full on-device WhisperKit ASR integration for Bitz Meeting Recorder (#204), including:
1. `WhisperKit` SwiftPM dependency in `Package.swift`.
2. `MeetingTranscriptionEngine` & `WhisperModelVariant` in `MeetingSettingsStore`.
3. `speaker: String?` on `MeetingTranscriptSegment` and speaker-tagged plain text formatting.
4. `WhisperKitModelManager` for on-demand download, progress, integrity verification, and cache management.
5. `WhisperKitTranscriptionService` & `MeetingTranscriptionRouter` with gain normalization, silence gating, hallucination filtering, dual-track chronological merge (`"You"` vs `"Participants"`), and `unloadModels()` cleanup.
6. `MeetingRecorderService` dual-track flow and `AudioSettingsTabView` / `BitzApp` UI wiring.
7. Unit tests + real-world audio accuracy benchmark (>= 90% word accuracy).
