---
work_package_id: WP02
title: Automated Cross-Repo CI/CD Release Pipeline
dependencies:
- WP01
requirement_refs:
- FR-001
- FR-002
- FR-003
- NFR-002
- NFR-003
- C-001
- C-002
planning_base_branch: feat/issue-105-private-repo-release-pipeline
merge_target_branch: feat/issue-105-private-repo-release-pipeline
branch_strategy: Planning artifacts for this mission were generated on feat/issue-105-private-repo-release-pipeline. During /spec-kitty.implement this WP may branch from a dependency-specific base, but completed changes must merge back into feat/issue-105-private-repo-release-pipeline unless the human explicitly redirects the landing branch.
subtasks:
- T004
- T005
- T006
- T007
- T008
phase: Phase 2 - CI/CD Pipeline
history: []
authoritative_surface: .github/workflows/
create_intent:
- .github/workflows/release.yml
execution_mode: code_change
owned_files:
- .github/workflows/release.yml
tags: []
task_type: implement
tracker_refs: []
---

# Work Package Prompt: WP02 – Automated Cross-Repo CI/CD Release Pipeline

## Objectives & Success Criteria
Satisfies: FR-001, FR-002, FR-003, NFR-002, NFR-003, C-001, C-002 (see spec.md).
Create a complete GitHub Actions release pipeline for building `Bitz.dmg`, publishing to `AkramKs/bitz-releases`, and bumping `AkramKs/homebrew-tap/Casks/bitz.rb`.

## Subtasks
- **T004**: Create `.github/workflows/release.yml` with triggers on tag push (`v*.*.*`) and manual `workflow_dispatch`.
- **T005**: Configure macOS 14 (Apple Silicon) runner with Xcode 16 and test validation step (`swift test`).
- **T006**: Add release DMG packaging step using `Scripts/create_dmg.sh` and compute SHA256 checksum.
- **T007**: Add step to create release and upload `Bitz.dmg` to `AkramKs/bitz-releases` using `gh release create` authenticated with `secrets.RELEASE_DISTRIBUTION_TOKEN`.
- **T008**: Add step to checkout `AkramKs/homebrew-tap`, update `Casks/bitz.rb` (version, sha256, download URL pointing to `bitz-releases`), and push commit.

## Notes & Risks
Requires `RELEASE_DISTRIBUTION_TOKEN` secret with write permissions to `bitz-releases` and `homebrew-tap`.
