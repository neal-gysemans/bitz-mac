# Tasks: Private Repository Transition with Public Release Pipeline & Homebrew Support

**Spec**: [spec.md](spec.md) | **Plan**: [plan.md](plan.md)

## Work Package WP01: In-App Update Service Adaptation

**Goal**: Configure `AppUpdateService` to query the public `AkramKs/bitz-releases` sink so existing desktop installations detect updates without requiring GitHub authentication.
**Requirement Refs**: FR-004, NFR-001, NFR-004
**Dependencies**: none

### Included Subtasks
- T001: Update default repository constant in `GitHubUpdateService` (`src/Services/AppUpdateService.swift`) to `"AkramKs/bitz-releases"`.
- T002: Update existing unit tests in `Tests/BitzTests/AppUpdateServiceTests.swift` to assert default repository is `"AkramKs/bitz-releases"`.
- T003: Run deterministic test suite (`xcrun swift test`) to verify all update parsing and comparison tests pass.

---

## Work Package WP02: Automated Cross-Repo CI/CD Release Pipeline

**Goal**: Create a GitHub Actions release workflow that builds `Bitz.dmg`, computes SHA256, publishes release artifacts to `AkramKs/bitz-releases`, and updates `AkramKs/homebrew-tap`.
**Requirement Refs**: FR-001, FR-002, FR-003, NFR-002, NFR-003, C-001, C-002
**Dependencies**: WP01

### Included Subtasks
- T004: Create `.github/workflows/release.yml` with triggers on tag push (`v*.*.*`) and manual `workflow_dispatch`.
- T005: Configure macOS 14 (Apple Silicon) runner with Xcode 16 and test validation step (`swift test`).
- T006: Add release DMG packaging step using `Scripts/create_dmg.sh` and compute SHA256 checksum.
- T007: Add step to create release and upload `Bitz.dmg` to `AkramKs/bitz-releases` using `gh release create` authenticated with `secrets.RELEASE_DISTRIBUTION_TOKEN`.
- T008: Add step to checkout `AkramKs/homebrew-tap`, update `Casks/bitz.rb` (version, sha256, download URL pointing to `bitz-releases`), and push commit.

---

## Work Package WP03: Documentation & Repository Transition Guide

**Goal**: Provide comprehensive setup documentation for the distribution token and update README links to the public sink.
**Requirement Refs**: FR-005, NFR-001, NFR-002
**Dependencies**: WP01, WP02

### Included Subtasks
- T009: Author `docs/DISTRIBUTION.md` outlining the architecture, step-by-step instructions for creating `AkramKs/bitz-releases`, configuring `RELEASE_DISTRIBUTION_TOKEN`, and switching `bitz-mac` to Private.
- T010: Update `README.md` direct download and release badge links to point to `AkramKs/bitz-releases`.
- T011: Run full verification suite (`xcrun swift test` and local release build packaging) to confirm zero performance or build regressions.
