# Bitz Public Beta — Onboarding & Installation Guide

Welcome to the **Bitz the Cyber Cat** Public Beta! This guide walks you through installing, launching, and updating Bitz on **macOS 14 (Sonoma)**, **macOS 15 (Sequoia)**, and **macOS 26 (Tahoe)**.

---

## 🌟 Public Beta All-Access Status

- During the free Public Beta (**`BETA ALL-ACCESS`**), **all shipped Bitz Pro features are unlocked at no cost** out of the box—no account or license key is required.
- Unlocked Beta features include the **Mascot Roster** (Byte, Aero, Pixel), **Palette & Visor Studio**, **Multi-Agent Swarm**, **Local Meeting Assistant**, and **AI Personality**.
- You can confirm your active status anytime under **Menu Bar → Settings → Bitz Pro**.
- Official Apple Developer ID notarization and commercial Pro licensing (`BITZ1` keys) will roll out at our final commercial GA launch.

---

## 🛡️ Why macOS Shows a Gatekeeper Warning During Beta

When installing Bitz during the Public Beta, macOS may display a security warning such as:

- *"Apple could not verify 'Bitz.app' is free of malware that may harm your Mac or compromise your privacy."*
- *"Bitz cannot be opened because the developer cannot be verified."*
- *"Bitz is damaged and can't be opened. You should move it to the Trash."*

**Why this happens:**
Bitz is currently in **free Public Beta** and distributed outside the Mac App Store. Beta builds are **ad-hoc signed** (`codesign --sign -`) with macOS Hardened Runtime rather than a paid Apple Developer Program ID and notarization ticket (**Apple Developer ID notarization will follow at commercial launch**). When you download `Bitz.dmg` from the web, macOS attaches a `com.apple.quarantine` attribute to the app, causing Gatekeeper to block first launch.

> **Important:** The app is **not** damaged—do **not** click **Move to Trash**. Use either installation method below to launch cleanly.

---

## Method A (Recommended): Install via Homebrew Tap

Installing through [Homebrew](https://brew.sh) is the fastest way to install and update Bitz during Beta:

```bash
brew tap akramks/tap
brew install --cask bitz
```

*(Equivalent one-liner: `brew install --cask akramks/tap/bitz`)*

Once installed:
1. Launch **Bitz** from `/Applications` or Spotlight (`Cmd + Space`).
2. Look for Bitz in the **bottom-right corner** of your screen and the **cat icon** in your top-right macOS Menu Bar.

> **If macOS still prompts on first launch** after a Homebrew install, clear the quarantine flag in Terminal:
> ```bash
> xattr -cr /Applications/Bitz.app
> ```
> Or open **System Settings → Privacy & Security → Open Anyway**.

---

## Method B: Direct `.dmg` Download

### Step 1: Download & Copy to `/Applications`

1. Download the latest `Bitz.dmg` from [AkramKs/bitz-releases](https://github.com/AkramKs/bitz-releases/releases/latest) ([Direct `Bitz.dmg` download](https://github.com/AkramKs/bitz-releases/releases/latest/download/Bitz.dmg)).
2. Double-click `Bitz.dmg` to mount it.
3. Drag **`Bitz.app`** into the **`Applications`** folder shortcut inside the disk image.

> ⚠️ **Do not launch `Bitz.app` directly from inside the mounted `.dmg`.** Always copy it to `/Applications` first so Gatekeeper approval and updates work properly. (`FIRST TIME OPENING - READ ME.txt` is also included inside the `.dmg` for quick reference.)

### Step 2: Bypass Gatekeeper (Choose Option 1 or Option 2)

#### Option 1 — Terminal One-Liner (Fastest, works on macOS 14, 15, and 26)

1. Open **Terminal** (`Cmd + Space`, type `Terminal`, press `Return`).
2. Run:
   ```bash
   xattr -cr /Applications/Bitz.app
   ```
   *(`xattr -cr` recursively clears the `com.apple.quarantine` download attribute from `/Applications/Bitz.app`.)*
3. Launch **Bitz** from `/Applications` or Spotlight (`Cmd + Space`).

#### Option 2 — System Settings GUI (No Terminal required)

> **macOS 15 Sequoia & macOS 26 Note:** Apple **removed** the old **right-click (or Control-click) → Open** Gatekeeper bypass shortcut starting in **macOS 15 Sequoia**. On macOS 15+ (and macOS 14 Sonoma), use **System Settings → Privacy & Security → Open Anyway**:

1. Double-click **`Bitz.app`** in `/Applications` once to trigger the Gatekeeper prompt, then click **Done** (or **Cancel** — do **not** click *Move to Trash*).
2. Open **System Settings → Privacy & Security** and scroll down to the **Security** section.
3. Next to *"Bitz.app was blocked to protect your Mac"*, click **Open Anyway**.
4. Authenticate with Touch ID or your Mac password, then confirm **Open Anyway** / **Open**.

---

## 🔄 Updating Bitz During Beta & Permissions Tip

### How to Update

- **Homebrew:**
  ```bash
  brew upgrade --cask bitz
  ```
- **Direct `.dmg`:**
  1. Quit Bitz from the top-right Menu Bar cat icon.
  2. Download the latest `Bitz.dmg` from [AkramKs/bitz-releases](https://github.com/AkramKs/bitz-releases/releases/latest).
  3. Drag the new `Bitz.app` into `/Applications` and choose **Replace**.
  4. Re-run `xattr -cr /Applications/Bitz.app` (or click **Open Anyway** in **System Settings → Privacy & Security**) if macOS prompts again.

### Re-Toggling Meeting Recorder Permissions After Ad-Hoc Updates

Because Public Beta builds are ad-hoc signed (`codesign --sign -`), each updated build gets a new code signature (`cdhash`). macOS TCC (Transparency, Consent, and Control) binds privacy grants to that signature, so **after updating Bitz**, previously granted **Meeting Recorder** permissions—**Microphone**, **Screen & System Audio Recording**, and **Speech Recognition**—may stop working even if their switches still look enabled in System Settings.

**If Meeting Recorder stops capturing mic or system audio after an update:**
1. Open **System Settings → Privacy & Security**.
2. Under **Microphone**, **Screen & System Audio Recording**, and **Speech Recognition**, toggle **Bitz** **OFF** and then **ON** again, then quit and relaunch Bitz.
3. If toggling does not stick, reset Bitz's TCC entries in Terminal and re-grant permissions on your next recording:
   ```bash
   tccutil reset All com.bitz.cybercat
   ```
   *(Local source builds launched with `Scripts/package_and_run.sh` use `com.bitz.cybercat.dev` instead of `com.bitz.cybercat`.)*

> **Zero-Permission Core Companion:** Bitz's click-through desktop overlay, wellness `PTS` tracking, CPU/die temperature HUD, and AI agent transcript monitoring require **zero** Accessibility permissions and perform **zero** keystroke logging.

---

## ✅ Quick Post-Install Tips

- **Where to find Bitz:** Look in the **bottom-right corner** of your screen for Bitz + the telemetry pill (`°C • CPU % • PTS`), and click the **cat icon** in the top-right macOS Menu Bar for controls and **Settings**.
- **Move Bitz anywhere:** Hold **`⌥ Option`** while hovering over Bitz to drag and reposition freely (snaps magnetically to screen edges). Press **`⎋ Esc`** or release `Option` to return to 100% click-through mode.
- **Need help or found a bug?** Check the [Latest Releases](https://github.com/AkramKs/bitz-releases/releases) page for release notes and updates.
