# Implementation Plan: Private Repository Transition with Public Release Pipeline & Homebrew Support

**Branch**: `feat/issue-105-private-repo-release-pipeline` | **Date**: 2026-11-03 | **Spec**: [spec.md](spec.md)
**Input**: Feature specification from `/kitty-specs/private-repo-release-pipeline-01M6HH1B/spec.md` (Tracks GitHub issue #105, refs #105, Closes #105)

## Summary

Decouple proprietary source code from public binary distribution. Transition `AkramKs/bitz-mac` into a private repository while establishing an automated GitHub Actions CI/CD release pipeline that builds `Bitz.dmg`, publishes it to a dedicated public distribution sink (`AkramKs/bitz-releases`), updates `Casks/bitz.rb` in `AkramKs/homebrew-tap`, and updates `AppUpdateService.swift` so in-app update checks and `brew install --cask bitz` operate without authentication.

## Technical Context

**Language/Version**: Swift 6.0 (swift-tools-version 6.0), Bash, GitHub Actions YAML  
**Primary Dependencies**: AppKit, SwiftUI, GitHub REST API, Homebrew Cask; zero third-party SwiftPM dependencies  
**Storage**: GitHub Releases (`AkramKs/bitz-releases`), Homebrew Git Tap (`AkramKs/homebrew-tap`), `UserDefaults` for update check timestamps  
**Testing**: XCTest in `Tests/BitzTests/AppUpdateServiceTests.swift` (100% deterministic unit tests for release endpoint resolution & DTO parsing)  
**Target Platform**: macOS 14.0+ (Sonoma), Apple Silicon  
**Project Type**: Single Swift package (`BitzCore` library + `Bitz` executable) + GitHub Actions CI/CD workflows  
**Performance Goals**: Release build and DMG packaging completes in < 5 minutes in CI; in-app update check takes < 500 ms; 0% idle CPU overhead  
**Constraints**: Zero user authentication for `brew install` (`C-001`); source repo strictly private (`NFR-002`); zero external SwiftPM dependencies (`C-003`)  
**Scale/Scope**: 1 CI/CD release workflow (`.github/workflows/release.yml`), `src/Services/AppUpdateService.swift` endpoint configuration, `Tests/BitzTests/AppUpdateServiceTests.swift`, Homebrew tap Cask schema, and migration documentation  

## Charter Check

- **Click-Through Guarantee**: PASS. No overlay panel code modified; mouse event ignoring behavior preserved.
- **Zero Keyboard Focus Stealing**: PASS. No window focusing behavior modified.
- **Privacy & Source Code Invariants**: PASS. Proprietary source code is isolated inside the private repository; only compiled, signed DMG binaries and public release notes are published to the public sink.
- **Performance Invariants**: PASS. Update service changes modify only static URL string construction with 0% impact on idle CPU (< 2%) or memory (< 70 MB).

## Design Decisions

1. **Dedicated Public Distribution Sink (`AkramKs/bitz-releases`)**:
   - Rather than storing binaries in the tap repository (which bloats git history) or requiring complex S3/CDN setups, we use a public GitHub repository dedicated solely to Releases.
   - GitHub Releases on a public repo provide globally distributed, free CDN hosting for `.dmg` files.
   - Public users can directly download the `.dmg` via browser or `curl` with zero authentication.

2. **Automated Cross-Repository CI/CD Pipeline (`.github/workflows/release.yml`)**:
   - Triggers on tag push (`v*.*.*`) or manual `workflow_dispatch`.
   - Steps:
     1. Checks out `bitz-mac` source.
     2. Sets up Xcode 16 / Swift 6 toolchain on `macos-14`.
     3. Runs `swift test` to verify build and test invariants.
     4. Executes `Scripts/create_dmg.sh` to produce `build/Bitz.dmg`.
     5. Calculates SHA256 checksum: `shasum -a 256 build/Bitz.dmg`.
     6. Publishes Release with DMG to `AkramKs/bitz-releases` using `gh release create`.
     7. Clones `AkramKs/homebrew-tap`, updates `Casks/bitz.rb` with the new version, SHA256, and release URL, and commits/pushes the change.
   - Authentication: Uses a repository secret `RELEASE_DISTRIBUTION_TOKEN` (a fine-grained or classic GitHub Personal Access Token with write access to `bitz-releases` and `homebrew-tap`).

3. **In-App Update Adapter (`AppUpdateService.swift`)**:
   - Change default repository in `GitHubUpdateService` from `"AkramKs/bitz-mac"` to `"AkramKs/bitz-releases"`.
   - Update `AppUpdateServiceTests` to assert the new public endpoint.
   - Allows users to check for updates, view update banners in the mascot speech bubble, and jump to the public download page seamlessly.

4. **Homebrew Tap Alignment (`AkramKs/homebrew-tap/Casks/bitz.rb`)**:
   - Cask URL structure updated:
     `url "https://github.com/AkramKs/bitz-releases/releases/download/v#{version}/Bitz.dmg"`
   - `homepage` remains pointing to product page/releases.

## Project Structure

### Documentation & Spec
```
kitty-specs/private-repo-release-pipeline-01M6HH1B/
├── spec.md
├── plan.md
└── tasks.md
```

### Affected Source Code
```
.github/workflows/
├── ci.yml                 # Existing Swift CI
├── pr-ticket-check.yml    # Existing PR ticket enforcement
└── release.yml            # NEW: Automated release packaging & cross-repo publishing

src/Services/
└── AppUpdateService.swift # Updated: default repository set to AkramKs/bitz-releases

Tests/BitzTests/
└── AppUpdateServiceTests.swift # Updated: verify bitz-releases endpoint

README.md                  # Updated: download links to bitz-releases
docs/DISTRIBUTION.md       # NEW: Guide for private repo release workflow & token setup
```
