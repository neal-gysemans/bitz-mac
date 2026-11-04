---
work_package_id: WP02
title: Cryptographic Licensing Service & Test Suite
dependencies:
- WP01
requirement_refs:
- FR-002
- FR-003
- NFR-002
- NFR-004
- C-003
planning_base_branch: feat/issue-117-bitz-pro-licensing
merge_target_branch: feat/issue-117-bitz-pro-licensing
branch_strategy: Planning artifacts for this mission were generated on feat/issue-117-bitz-pro-licensing. During /spec-kitty.implement this WP may branch from a dependency-specific base, but completed changes must merge back into feat/issue-117-bitz-pro-licensing unless the human explicitly redirects the landing branch.
base_branch: kitty/mission-bitz-pro-licensing-01M6JYJJ
base_commit: 9e4df6da3255e8f94465d8e6f5e7000103f9875b
created_at: '2026-11-04T10:16:34.304259+00:00'
subtasks:
- T004
- T005
- T006
phase: Phase 2 - Domain Service & Tests
history: []
authoritative_surface: src/Services/Licensing/
create_intent:
- src/Services/Licensing/LicensingServiceProtocol.swift
- src/Services/Licensing/LicensingService.swift
- Tests/BitzTests/LicensingServiceTests.swift
execution_mode: code_change
owned_files:
- src/Services/Licensing/LicensingServiceProtocol.swift
- src/Services/Licensing/LicensingService.swift
- Tests/BitzTests/LicensingServiceTests.swift
tags: []
task_type: implement
tracker_refs: []
---

# Work Package Prompt: WP02 – Cryptographic Licensing Service & Test Suite

## Objectives & Success Criteria
Satisfies: FR-002, FR-003, NFR-002, NFR-004, C-003 (see spec.md).
Implement `LicensingServiceProtocol`, `LicensingService` with offline `CryptoKit` Ed25519 validation, and deterministic unit tests in `LicensingServiceTests.swift`.

## Subtasks
- **T004**: Create `src/Services/Licensing/LicensingServiceProtocol.swift` defining `@MainActor public protocol LicensingServiceProtocol`.
- **T005**: Implement `src/Services/Licensing/LicensingService.swift` with embedded public key, Base64URL token decoding, and `Curve25519.Signing.PublicKey` verification.
- **T006**: Create `Tests/BitzTests/LicensingServiceTests.swift` with `MockLicenseStorage` asserting valid activation, corrupt signature, expired key, malformed input, and deactivation. Run `xcrun swift test`.
