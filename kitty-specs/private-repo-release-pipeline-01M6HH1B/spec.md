# Mission Specification: Private Repository Transition with Public Release Pipeline & Homebrew Support

**Mission Branch**: `feat/issue-105-private-repo-release-pipeline`  
**Created**: 2026-11-03  
**Status**: In Progress  
**Input**: User request: "plan is to get a private repo while brew install works with the auto cicd pipeline for building the release and pasting it there" (Tracks GitHub issue #105, refs #105, Closes #105)

## User Scenarios & Testing *(mandatory)*

### User Story 1 - Public Homebrew Installation via Tap (Priority: P1)

A macOS user installs Bitz via Homebrew by running `brew install --cask akramks/tap/bitz`. Even though the core source repository `bitz-mac` is private, the command succeeds seamlessly because the binary release artifact is fetched from a dedicated public distribution sink (`AkramKs/bitz-releases`).

**Why this priority**: Core user acquisition and distribution channel. Must remain completely unblocked and zero-auth for end users.

**Independent Test**: Run `brew install --cask akramks/tap/bitz` on an unauthenticated macOS machine; verify the latest signed `Bitz.dmg` downloads and installs cleanly to `/Applications`.

**Acceptance Scenarios**:

1. **Given** `AkramKs/bitz-mac` is private and `AkramKs/bitz-releases` is public, **When** a user runs `brew install --cask akramks/tap/bitz`, **Then** Homebrew resolves the Cask URL to `AkramKs/bitz-releases/releases/download/v{version}/Bitz.dmg` and downloads the asset with HTTP 200 without requiring a GitHub token.
2. **Given** an existing installation of Bitz, **When** a user runs `brew upgrade --cask bitz`, **Then** Homebrew checks the Cask version against `bitz-releases` and upgrades cleanly.

---

### User Story 2 - Automated GitHub Actions Release Pipeline (Priority: P1)

When a developer or maintainer pushes a release tag (e.g., `v1.3.1`) or triggers manual release dispatch in `AkramKs/bitz-mac`, an automated GitHub Actions CI/CD workflow builds the release app, packages the disk image (`Bitz.dmg`), computes its SHA256 checksum, publishes the release to `AkramKs/bitz-releases`, and updates `Casks/bitz.rb` in `AkramKs/homebrew-tap`.

**Why this priority**: Eliminates error-prone manual releases and guarantees atomic synchronization between private build outputs and public distribution channels.

**Independent Test**: Trigger a tag push or `workflow_dispatch` on the release workflow; verify that a release is published on `AkramKs/bitz-releases` with `Bitz.dmg`, and a commit updating the Cask SHA256/version is pushed to `AkramKs/homebrew-tap`.

**Acceptance Scenarios**:

1. **Given** a git tag `v*.*.*` pushed to `AkramKs/bitz-mac`, **When** `.github/workflows/release.yml` executes on `macos-14`, **Then** it compiles the application, runs `Scripts/create_dmg.sh`, and validates `build/Bitz.dmg` exists.
2. **Given** a generated `build/Bitz.dmg`, **When** the workflow publishes the release, **Then** it creates a release on `AkramKs/bitz-releases` with matching tag, release notes, and uploaded DMG asset.
3. **Given** the published release asset, **When** the workflow updates Homebrew, **Then** it updates `version` and `sha256` in `AkramKs/homebrew-tap/Casks/bitz.rb` and points the URL to `bitz-releases`.

---

### User Story 3 - In-App Update Checks from Public Release Sink (Priority: P1)

When a user runs Bitz, the in-app `AppUpdateService` polls for the latest available release without failing or throwing authentication errors.

**Why this priority**: Existing and new desktop users rely on in-app update banners and speech bubble alerts for seamless upgrades without terminal interaction.

**Independent Test**: Run Bitz in release mode, trigger an update check; verify HTTP query targets `https://api.github.com/repos/AkramKs/bitz-releases/releases/latest` and returns valid release metadata.

**Acceptance Scenarios**:

1. **Given** Bitz is launched on a user's Mac, **When** `AppUpdateService` performs its periodic or manual check, **Then** it queries `AkramKs/bitz-releases` and parses `GitHubReleaseDTO` successfully.
2. **Given** a newer version is present in `bitz-releases`, **When** the user clicks "Download Update" or "GOT IT", **Then** the browser opens the public download or release notes page on `bitz-releases`.

---

### User Story 4 - Public Documentation & Direct Downloads (Priority: P2)

README and documentation reference the public release repository for direct `.dmg` downloads, issue discussions, and Homebrew tap instructions without leaking private repository structure.

**Why this priority**: Ensures public users have working download links, issue reporting channels, and security instructions.

**Independent Test**: Audit all download links in `README.md` and docs to ensure none point to release downloads of the private repository.

**Acceptance Scenarios**:

1. **Given** the project `README.md`, **When** a user clicks "Direct Download (.DMG)", **Then** the URL links to `https://github.com/AkramKs/bitz-releases/releases/latest/download/Bitz.dmg`.

---

### Edge Cases

- What happens if the distribution token expires or lacks write permission to `bitz-releases` or `homebrew-tap`?
  - The CI workflow fails fast with a clear diagnostic error message before modifying the Cask.
- What happens if a tag is retried or re-pushed?
  - The release step uses release overwrite / idempotency so existing assets can be updated or cleanly replaced without crashing.
- What happens if `AppUpdateService` encounters network timeout or GitHub API rate limiting?
  - Existing silent fallback logic in `AppUpdateService` retains the current status message and prevents UI crashes or annoying modal errors.

## Requirements *(mandatory)*

### Functional Requirements

| ID | Title | User Story | Priority | Status |
|----|-------|------------|----------|--------|
| FR-001 | Public Distribution Sink | As a user, I want public access to `.dmg` releases so that I can download and install Bitz without authentication. | High | Open |
| FR-002 | Automated Release CI/CD | As a developer, I want pushing a tag to automatically compile, package, and publish releases to `bitz-releases` and update `homebrew-tap`. | High | Open |
| FR-003 | Homebrew Cask Target | As a user, I want `brew install --cask akramks/tap/bitz` to fetch from `bitz-releases` so that installation succeeds. | High | Open |
| FR-004 | In-App Update Service Adaptation | As a user, I want in-app update checks to query `bitz-releases` so that updates are detected while source remains private. | High | Open |
| FR-005 | Updated Documentation & Links | As a user, I want documentation download links to point to the public distribution repository. | Medium | Open |

### Non-Functional Requirements

| ID | Title | Requirement | Category | Priority | Status |
|----|-------|-------------|----------|----------|--------|
| NFR-001 | Zero Auth for End Users | `brew install` and in-app update checks must require 0 tokens, logins, or configurations from users. | Usability | High | Open |
| NFR-002 | Security & Privacy | Core source code in `bitz-mac` must remain 100% private; release secrets must use GitHub Actions encrypted secrets. | Security | High | Open |
| NFR-003 | Deterministic Packaging | Packaging must strictly use `Scripts/create_dmg.sh` to produce identical UDZO compressed disk images. | Reliability | High | Open |
| NFR-004 | Zero Idle Overhead | Updating `AppUpdateService` repository string must not impact runtime CPU (< 2%) or memory (< 70 MB). | Performance | High | Open |

### Constraints

| ID | Title | Constraint | Category | Priority | Status |
|----|-------|------------|----------|----------|--------|
| C-001 | macOS Architecture | Builds must run on macOS 14 (Sonoma) Apple Silicon runner with Xcode 16. | Technical | High | Open |
| C-002 | GitHub Token Scopes | Distribution PAT must have `repo` write scope to `AkramKs/bitz-releases` and `AkramKs/homebrew-tap`. | Security | High | Open |
| C-003 | Zero External SwiftPM Dependencies | The Swift codebase must continue using zero third-party SwiftPM dependencies. | Architectural | High | Open |

## Success Criteria *(mandatory)*

### Measurable Outcomes

- **SC-001**: `brew install --cask akramks/tap/bitz` completes with exit code 0 on an unauthenticated machine.
- **SC-002**: Automated release CI/CD workflow builds `Bitz.dmg`, computes SHA256, publishes release to `bitz-releases`, and updates `homebrew-tap` Cask in under 10 minutes.
- **SC-003**: `AppUpdateService` tests pass with 100% success rate against `AkramKs/bitz-releases`.
- **SC-004**: `bitz-mac` repository can be set to Private with zero degradation to existing end-user installation workflows.
