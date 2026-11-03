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

## 🚀 One-Time Setup Instructions

Follow these steps once to configure the automated release pipeline:

### Step 1: Create the Public Distribution Sink Repository
Create an empty public repository under your GitHub account:
- **Repository Name**: `bitz-releases`
- **Owner**: `AkramKs`
- **Visibility**: **Public** (Do NOT make this private; release assets must be downloadable without auth)
- **Description**: `Public distribution repository for Bitz the Cyber Cat macOS releases and DMGs`

Via GitHub CLI:
```bash
gh repo create AkramKs/bitz-releases --public --description "Public distribution repository for Bitz the Cyber Cat macOS releases and DMGs"
```

### Step 2: Create a GitHub Personal Access Token (PAT)
The CI/CD pipeline running in the private `bitz-mac` repository needs permission to:
1. Create releases and upload `.dmg` assets in `AkramKs/bitz-releases`.
2. Push commits to `AkramKs/homebrew-tap` to update `Casks/bitz.rb`.

1. Go to **GitHub Settings** -> **Developer Settings** -> **Personal Access Tokens** -> **Tokens (classic)** (or Fine-grained tokens with access to `bitz-releases` and `homebrew-tap`).
2. Generate a token with:
   - Name: `Bitz Release Distribution Token`
   - Scope: `repo` (Full control of private and public repositories)
3. Copy the generated token string (starts with `ghp_...`).

### Step 3: Add the Token Secret to `bitz-mac`
1. Go to `AkramKs/bitz-mac` on GitHub.
2. Navigate to **Settings** -> **Secrets and variables** -> **Actions**.
3. Click **New repository secret**:
   - **Name**: `RELEASE_DISTRIBUTION_TOKEN`
   - **Secret**: *Paste your PAT from Step 2*
4. Click **Add secret**.

### Step 4: Toggle `bitz-mac` to Private
1. In `AkramKs/bitz-mac`, go to **Settings** -> **General** (scroll to the bottom **Danger Zone**).
2. Click **Change repository visibility** -> **Make private**.
3. Confirm the change.

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
