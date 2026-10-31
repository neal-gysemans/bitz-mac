---
work_package_id: WP01
title: Audio Models, Settings Store & Protocol Architecture
dependencies: []
requirement_refs:
- FR-001
- NFR-003
- C-001
planning_base_branch: feat/issue-21-cyber-audio
merge_target_branch: feat/issue-21-cyber-audio
branch_strategy: Planning artifacts for this mission were generated on feat/issue-21-cyber-audio. During /spec-kitty.implement this WP may branch from a dependency-specific base, but completed changes must merge back into feat/issue-21-cyber-audio unless the human explicitly redirects the landing branch.
subtasks:
- T001
- T002
- T003
- T004
phase: Phase 1 - Architecture
history: []
authoritative_surface: src/Models/
create_intent:
- src/Models/CyberAudioModels.swift
- src/Models/CyberAudioSettingsStore.swift
- src/Services/CyberAudioPlaying.swift
- Tests/BitzTests/CyberAudioSettingsStoreTests.swift
execution_mode: code_change
owned_files:
- src/Models/CyberAudioModels.swift
- src/Models/CyberAudioSettingsStore.swift
- src/Services/CyberAudioPlaying.swift
- Tests/BitzTests/CyberAudioSettingsStoreTests.swift
tags: []
task_type: implement
tracker_refs: []
---

# Work Package Prompt: WP01 – Audio Models, Settings Store & Protocol Architecture

## Objectives & Success Criteria
Satisfies: FR-001, NFR-003, C-001 (see spec.md).

## Subtasks
- **T001**: Implement `CyberSoundEvent` enum, sound event metadata, and suppression reasons in `src/Models/CyberAudioModels.swift`.
- **T002**: Implement `@MainActor public final class CyberAudioSettingsStore: ObservableObject` in `src/Models/CyberAudioSettingsStore.swift` with `UserDefaults` persistence, default-off setting, volume control, and per-event toggles.
- **T003**: Define `CyberAudioPlaying` protocol and `SpyCyberAudioPlayer` test double in `src/Services/CyberAudioPlaying.swift`.
- **T004**: Write comprehensive unit tests for `CyberAudioSettingsStore` persistence and domain isolation in `Tests/BitzTests/CyberAudioSettingsStoreTests.swift`.

## Notes & Risks
Default off (`isEnabled = false`) is required so existing users experience no unexpected sound. Tests must use isolated `UserDefaults(suiteName:)` domains with cleanup.
