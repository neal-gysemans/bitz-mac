# Bitz Distribution & Private Repository Release Architecture

This document describes the distribution architecture used to keep the core Bitz codebase (`AkramKs/bitz-mac`) **private** while allowing public end-users to install and update Bitz freely via **Homebrew** (`brew install --cask akramks/tap/bitz`) and direct `.dmg` downloads without requiring GitHub authentication.

---

## 🏛️ Architecture Overview

```
┌───────────────────────────────────────────────┐
│           AkramKs/bitz-mac (PRIVATE)          │
│  - Proprietary source code                    │
│  - SwiftUI & CoreAnimation mascot engine      │
│  - CI/CD workflow (.github/workflows/release) │
└───────────────────────┬───────────────────────┘
                        │ Tag push (v*.*.*) or workflow_dispatch
                        │ Builds & packages Bitz.dmg
                        │ Signs & computes SHA256
                        ▼
┌───────────────────────────────────────────────┐
│         AkramKs/bitz-releases (PUBLIC)        │ ◄───────────────────┐
│  - Public distribution sink                   │                     │
│  - Hosts compiled Bitz.dmg release assets     │                     │
│  - Unauthenticated JSON endpoint for:         │                     │
│    AppUpdateService.swift                     │                     │
└───────────────────────┬───────────────────────┘                     │
                        │                                             │
                        │ Updates Casks/bitz.rb                       │
                        ▼                                             │
┌───────────────────────────────────────────────┐                     │
│          akramks/homebrew-tap (PUBLIC)        │                     │
│  - Official Homebrew Tap                      │                     │
│  - Cask URL points to bitz-releases ──────────┴─────────────────────┘
│  - `brew install --cask akramks/tap/bitz`
└───────────────────────────────────────────────┘
```

---

## 🚀 Configured Architecture Status

The automated release and distribution pipeline is fully configured and active:

- **Public Distribution Sink**: [`AkramKs/bitz-releases`](https://github.com/AkramKs/bitz-releases) (Public)
  - Hosts published `.dmg` binaries and release notes.
  - Public JSON API for unauthenticated in-app update checks via `AppUpdateService.swift`.
- **Private Source Repository**: [`AkramKs/bitz-mac`](https://github.com/AkramKs/bitz-mac) (Private)
  - Houses the proprietary Swift/SwiftUI mascot engine.
  - Contains repository secret `RELEASE_DISTRIBUTION_TOKEN` for pushing releases and cask updates.
- **Homebrew Tap**: [`AkramKs/homebrew-tap`](https://github.com/AkramKs/homebrew-tap) (Public)
  - `Casks/bitz.rb` points to release assets in `bitz-releases`.
  - Automatically bumped on every release.

---

## 📦 How to Trigger a Release

Whenever you are ready to publish a new version of Bitz:

### Option A: Tag Push (Recommended)
```bash
# Ensure local main is clean and up to date
git checkout main
git pull origin main

# Create and push a semver tag
git tag v1.3.1
git push origin v1.3.1
```

### Option B: Manual GitHub Actions Dispatch
1. Go to `AkramKs/bitz-mac` -> **Actions** -> **Release & Distribute**.
2. Click **Run workflow**.
3. Enter the tag name (e.g., `v1.3.1`) and confirm.

---

## ⚡ What the Automated Pipeline Does

1. **Builds & Tests**: Checks out source code on macOS 14 (Sonoma Apple Silicon) and runs `swift test`.
2. **Packages DMG**: Runs `Scripts/create_dmg.sh` to produce a compressed `build/Bitz.dmg`.
3. **Calculates Checksum**: Computes `sha256` of `Bitz.dmg`.
4. **Publishes to `bitz-releases`**: Automatically creates the GitHub Release `vX.Y.Z` with release notes and attaches `Bitz.dmg`.
5. **Updates Homebrew Tap**: Clones `AkramKs/homebrew-tap`, updates `Casks/bitz.rb` with the new version and checksum, and pushes the commit directly to `main`.
6. **In-App Updater Ready**: `AppUpdateService.swift` immediately discovers the new release on the next periodic check.
