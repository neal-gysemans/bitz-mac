---
work_package_id: WP01
title: Licensing Models & Keychain Storage Isolation
dependencies: []
requirement_refs:
- FR-001
- FR-004
- FR-007
- NFR-003
- NFR-004
- C-001
- C-002
- C-003
planning_base_branch: feat/issue-117-bitz-pro-licensing
merge_target_branch: feat/issue-117-bitz-pro-licensing
branch_strategy: Planning artifacts for this mission were generated on feat/issue-117-bitz-pro-licensing. During /spec-kitty.implement this WP may branch from a dependency-specific base, but completed changes must merge back into feat/issue-117-bitz-pro-licensing unless the human explicitly redirects the landing branch.
base_branch: kitty/mission-bitz-pro-licensing-01M6JYJJ
base_commit: 9e4df6da3255e8f94465d8e6f5e7000103f9875b
created_at: '2026-11-04T10:12:16.632675+00:00'
subtasks:
- T001
- T002
- T003
phase: Phase 1 - Models & Storage
history: []
authoritative_surface: src/Models/
create_intent:
- src/Models/LicensingModels.swift
- src/Services/Licensing/LicenseStorageProtocol.swift
- src/Services/Licensing/KeychainLicenseStorage.swift
execution_mode: code_change
owned_files:
- src/Models/LicensingModels.swift
- src/Services/Licensing/LicenseStorageProtocol.swift
- src/Services/Licensing/KeychainLicenseStorage.swift
tags: []
task_type: implement
tracker_refs: []
---

# Work Package Prompt: WP01 – Licensing Models & Keychain Storage Isolation

## Objectives & Success Criteria
Satisfies: FR-001, FR-004, FR-007, NFR-003, NFR-004, C-001, C-002, C-003 (see spec.md).
Define `BitzTier`, `BitzFeature`, `LicensePayload`, `LicensingError`, `LicenseStorageProtocol`, and `KeychainLicenseStorage`.

## Subtasks
- **T001**: Create `src/Models/LicensingModels.swift` with `BitzTier` (`.free`, `.pro`), `BitzFeature` enum, `LicensePayload` (Decodable struct with `tier`, `license_id`, `issued_at`, `expires_at`), and `LicensingError` enum.
- **T002**: Create `src/Services/Licensing/LicenseStorageProtocol.swift` defining `loadLicenseToken() -> String?`, `saveLicenseToken(_ token: String) throws`, and `deleteLicenseToken() throws`.
- **T003**: Create `src/Services/Licensing/KeychainLicenseStorage.swift` implementing `LicenseStorageProtocol` using Apple `Security` framework (`kSecClassGenericPassword`).
