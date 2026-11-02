# Bitz the Cyber Cat (`bitz-mac`)

<p align="center">
  <img src="docs/bitz-states-preview.png" alt="Bitz the Cyber Cat — Live SwiftUI Desktop Overlay States" width="920" />
</p>

<p align="center">
  <img src="https://img.shields.io/badge/Platform-macOS%2014.0%2B-00F0FF?style=flat-square&logo=apple" alt="macOS 14.0+" />
  <img src="https://img.shields.io/badge/SwiftUI-Vector%20Animation-FF007F?style=flat-square&logo=swift" alt="SwiftUI Vector Animation" />
  <img src="https://img.shields.io/badge/Hardware-Apple%20Silicon%20IOHID%20%2B%20Mach-FFB000?style=flat-square" alt="Apple Silicon Telemetry" />
  <img src="https://img.shields.io/badge/Privacy-Zero%20Keylogging-34C759?style=flat-square" alt="Privacy First" />
</p>

**Bitz the Cyber Cat** is a native, lightweight macOS cyberpunk desktop companion built with **Swift**, **SwiftUI**, and **AppKit**. Bitz sits quietly in the bottom-right corner of your screen inside a 100% click-through floating overlay (`NSPanel`), rendered with a procedural 60 FPS SwiftUI vector rig (`TimelineView`) that reacts in real time to your **coding focus**, **offline breaks**, and **live Apple Silicon hardware sensors** (CPU die temperature in `°C` and Mach kernel CPU load `%`).

---

## 🚀 Quick Install

### Install via Homebrew (Recommended)

Install Bitz with a single command via [Homebrew](https://brew.sh):

```bash
brew install --cask akramks/tap/bitz
```

Or tap and install:

```bash
brew tap akramks/tap
brew install --cask bitz
```

To update Bitz in the future:
```bash
brew upgrade --cask bitz
```

### Direct Download (.DMG)

1. Download the latest `Bitz.dmg` from the [GitHub Releases](https://github.com/AkramKs/bitz-mac/releases/latest) page.
2. Open `Bitz.dmg` and drag `Bitz.app` into your **Applications** folder.
3. Launch `Bitz.app` from `/Applications` or Spotlight (`Cmd + Space`).

> **Note on macOS Gatekeeper**: Because Bitz is distributed outside the Mac App Store and built open-source without an Apple Developer ID certificate, macOS may show a prompt on first open. Simply right-click (or Control-click) `Bitz.app` in `/Applications` and select **Open**, or run:
> ```bash
> xattr -cr /Applications/Bitz.app
> ```

---

## ✨ Key Features

- **100% Click-Through Desktop Overlay (`MascotOverlayPanel`)**
  - Renders inside a borderless, non-activating floating `NSPanel` (`ignoresMouseEvents = true`, `.canJoinAllSpaces`, `.fullScreenAuxiliary`, `.stationary`).
  - Never steals keyboard focus, never intercepts mouse clicks over your IDE or browser, and **never alters your macOS desktop wallpaper**.
- **See-Through Hologram Opacity (`AvatarOpacityStore`)**
  - Adjustable transparency presets (`Solid 100%`, `Translucent 80%`, `Hologram 60%`, `Ghost 40%`, `Stealth 25%`) and `±10%` steps so text and code behind Bitz are always readable.
- **4-Corner Desktop Positioning (`ScreenCornerAnchor`)**
  - Anchor Bitz to `Bottom-Right (Default)`, `Bottom-Left`, `Top-Right`, or `Top-Left` directly from the Menu Bar.
- **Manual Avatar Resizing (`AvatarScaleStore`)**
  - Scale Bitz from `50%` to `175%` (`Small 60%`, `Medium 80%`, `Default 100%`, `Large 125%`, `XL 150%`) with automatic bottom/right corner re-anchoring.
- **Expressive Procedural Animations (`MascotOverlayView`)**
  - Cyberpunk cat silhouette with moving paws/trot cycle, natural eye-blink intervals, glowing LED visor, and ambient particles (neon sparks in Super Charged, binary bits in Balanced, drifting ZZZs in Charging, and ear steam puffs in Overheat).
- **Real Apple Silicon Hardware Telemetry (`AppleSiliconHardwareSensors`)**
  - **Live Die Temperature (`°C`)**: Queries Apple Silicon `IOHIDEventSystemClient` on-die thermal sensors (`PrimaryUsagePage: 0xFF00`, `PrimaryUsage: 5`) without requiring `sudo` or root privileges.
  - **Live CPU Load (`%`)**: Samples Darwin Mach kernel `host_statistics(HOST_CPU_LOAD_INFO)` delta ticks (`user`, `system`, `nice`, `idle`).
  - **Live HUD Pill**: Displays real-time hardware stats directly beneath Bitz (`e.g., 51.8°C • 14% CPU • 50 PTS`).
- **Privacy-First Focus, Safari & Break Tracking (`ActivityMonitorService`)**
  - Uses standard macOS `NSWorkspace.shared.frontmostApplication` and `CGEventSource.secondsSinceLastEventType`.
  - Zero Accessibility permissions (`AXIsProcessTrusted`) and zero keystroke/mouse logging.
  - Inspects active tabs across Firefox, Chrome, Brave, Edge, Arc, Opera, Vivaldi, and Safari.
  - 1-click Menu Bar controls to mark any custom app or domain as **Always Productive** or **Distraction**.
- **Session Persistence & macOS Sleep/Wake Break Crediting**
  - Focus points, work streaks, and custom rules automatically persist in `UserDefaults`.
  - Automatically listens to macOS sleep, display sleep, and screen lock/unlock events, restoring energy after offline breaks.
- **Launch at Login (`SMAppService`)**
  - Toggle native macOS auto-start at login directly from the Menu Bar.
- **Menu Bar Control Center (`MenuBarExtra`)**
  - Click the `cat.fill` icon in the macOS Menu Bar to inspect live sensors, pet Bitz (`<3  <3`), change size/opacity/corner, or test states.
- **AI Coding Agent Detection & Speech-Bubble Popups (`AgentMonitorService`)**
  - Automatically notices running AI coding agents (**Claude Code**, **Gemini**, **Antigravity**, **Codex / ChatGPT**, **Cursor**, **Windsurf**, **Copilot**, **Aider**, **Goose**, **OpenCode**, **Amp**, **Cline**) via privacy-first process polling and lightweight drop-box event hooks.
  - Pops up high-contrast speech bubbles when an agent finishes (**`"Claude is done!"`**) or needs your approval (**`"Claude needs approval!"`**).
  - 1-click Claude Code hook installer directly in the Menu Bar (`~/.claude/settings.json`) with safe automated backup.
  - Extensible to custom agent processes with per-agent notification toggles in the Menu Bar.

---

## ⚡ Emotions & Wellness Points (`PTS`)

Bitz's mood is driven by **Wellness Points (`PTS`)** on a scale from **`0.0` to `100.0`** (starting at `50.0 PTS`), sampled every **5 seconds** with timer coalescing (`< 1%` CPU overhead):

### How `PTS` & Continuous Work Streak Change
| Activity | Condition | Effect |
| :--- | :--- | :--- |
| **Productive Coding & Office Work** | Active app is a Developer IDE/Terminal (`Antigravity IDE`, `Xcode`, `VS Code`, `Cursor`, `Windsurf`, `Zed`, `Terminal`, `iTerm2`, `Warp`, `Ghostty`, `JetBrains`, `Docker`, `Postman`, `TablePlus`), Office Suite (`Word`, `Excel`, `PowerPoint`, `Outlook`, `OneNote`, `Pages`, `Numbers`, `Keynote`, `Notes`, `Calendar`, `Mail`), or Collaboration/Design tool (`Teams`, `Slack`, `Zoom`, `Notion`, `Obsidian`, `Linear`, `Figma`, `Miro`, `Canva`) | **`+0.5 PTS`** / tick (increases continuous work streak) |
| **Too Much YouTube / Netflix / Browsing** | Active app is a browser, video player, or distraction (`Firefox`, `Safari`, `Chrome`, `WhatsApp`, `Discord`, etc.) | **`-1.5 PTS`** / tick — drains below `40 PTS` into **`.dopamineSad`** (`T  T`) |
| **Working Too Long Without a Break** | Continuous productive work `>= 45 min` (`Overworked`) or `>= 90 min` (`Burnout`) without stepping away | Triggers **`.overworked`** (`-  -`) -> **`.burnout`** (`X  X`) with break reminders |
| **Idle / Away from Keyboard (`>= 60s`)** | No keyboard or mouse input for `>= 60s` | Enters **`.charging`** (`⚡ Z Z`), recharging **`+0.5 PTS`** per tick & clearing work fatigue |
| **Offline Break Return (`> 2 min`)** | Returning after stepping away from the Mac | **`+5.0 PTS` per minute** restored and resets continuous work streak to `0m` |
| **Thermal / CPU Spike Override** | Apple Silicon CPU die temperature **`> 80.0 °C`**, CPU load **`> 85%`**, or `.serious`/`.critical` thermal pressure | Immediate override to **`.overheating`** (`>  <`) with an actionable cool-down alert above Bitz |

### Bitz's Behavioral States (`BitzState`)
| State | Trigger Condition | Visor Color | Visual & Speech Bubble Behavior |
| :--- | :--- | :--- | :--- |
| **Super Charged** (`.superCharged`) | `80.0 – 100.0 PTS` (`< 45m` work streak) | **Neon Magenta (`#FF007F`)** | Happy `^  ^` LED visor, fast `2.0x` breathing & tail wag |
| **Balanced** (`.balanced`) | `40.0 – 79.9 PTS` (`< 45m` work streak) | **Electric Cyan (`#00F0FF`)** | Calm glowing cyan eyes, steady `1.0x` breathing & tail sway |
| **Sad / Dopamine Overload** (`.dopamineSad`) | `< 40.0 PTS` (Watching YouTube/Netflix/browsing too long) | **Dopamine Violet (`#9D4EDD`)** | Sad crying `T  T` eyes, drooping ears, **`"DOPAMINE OVERLOAD — BACK TO FOCUS?"`** |
| **Overworked** (`.overworked`) | `>= 45 min` non-stop work without a break | **Warning Amber (`#FFB000`)** | Tired `-  -` squint, drooping ears, **`"WORKING NON-STOP — TAKE A QUICK BREAK ☕"`** |
| **Burnout** (`.burnout`) | `>= 90 min` non-stop work without a break | **Warning Amber (`#FFB000`)** | Exhausted `X  X` loaf (`0.0x` motion), **`"BURNOUT! STEP AWAY FOR 5 MIN TO RECHARGE 💤"`** |
| **Charging** (`.charging`) | `>= 60s` without touching keyboard or mouse | **Cyber Green (`#00FF88`)** | Cozy loaf with **`⚡ Z Z`** visor, **`"CHARGING ENERGY... ⚡"`** |
| **Overheating** (`.overheating`) | **`> 80.0 °C`** die temp or **`> 85%`** CPU load | **Critical Red (`#FF1E1E`)** | Glitching `>  <` visor + actionable alert: **`"🔥 85°C (92% CPU) — CLOSE HEAVY TABS OR BUILDS TO COOL DOWN!"`** |

> **Petting Bitz**: Clicking **"Pet Bitz (`<3`)"** in the Menu Bar fires the `triggerPet` state machine trigger and lights up Bitz's visor with glowing neon magenta hearts (`<3  <3`).

---

## 🏗️ Architecture & Project Layout

```text
bitz-mac/
├── Package.swift                              # SwiftPM manifest (BitzCore library, Bitz executable, BitzTests)
├── Resources/
│   └── AppIcon.icns                           # High-resolution macOS application icon bundle
├── Scripts/
│   └── package_and_run.sh                     # Builds, bundles, ad-hoc signs, and launches build/Bitz.app
├── src/
│   ├── App/
│   │   ├── BitzApp.swift                      # NSApplicationDelegate, MenuBarExtra UI, stores & position sync
│   │   └── Window/
│   │       └── MascotOverlayPanel.swift       # Click-through, non-activating floating NSPanel with corner math
│   ├── Executable/
│   │   └── main.swift                         # Native macOS app entry point (BitzApp.main())
│   ├── Models/
│   │   └── AgentModels.swift                  # AgentDefinition, AgentEvent, AgentEventKind & AgentPopupState
│   ├── Services/
│   │   ├── WellnessPointEngine.swift          # Reactive PTS state engine, work streak & break persistence
│   │   ├── ActivityMonitorService.swift       # Apple Silicon hardware sensors (IOHID + Mach) & telemetry
│   │   ├── AgentMonitorService.swift          # Central agent coordinator, popup states & catalog
│   │   ├── ProcessAgentAdapter.swift          # Polling running processes and bundle IDs
│   │   ├── DropboxAgentAdapter.swift          # Real-time JSON event drop-box directory watcher
│   │   ├── AntigravityTranscriptAdapter.swift  # Live Antigravity session transcript stream monitor
│   │   ├── LogWatcherAgentAdapter.swift       # Generic log file keyword monitor (approval / done)
│   │   └── AgentHookInstaller.swift           # Claude Code & CLI shell hook generator & backup manager
│   └── Views/
│       └── MascotOverlayView.swift            # Vector cat rig, LED visor, trot cycles & speech bubble popups
├── Tests/
│   └── BitzTests/                             # 66 deterministic XCTest unit tests
│       ├── WellnessPointEngineTests.swift
│       ├── ActivityMonitorServiceTests.swift
│       ├── MascotOverlayPanelTests.swift
│       ├── AgentMonitorServiceTests.swift
│       ├── ProcessAgentAdapterTests.swift
│       ├── DropboxAgentAdapterTests.swift
│       ├── AntigravityTranscriptAdapterTests.swift
│       ├── LogWatcherAgentAdapterTests.swift
│       └── AgentHookInstallerTests.swift
└── docs/
    ├── ARCHITECTURE.md                        # Layered system architecture & invariants
    ├── STATE_MACHINE.md                       # 7-state emotional machine & Rive contract
    ├── ACCEPTANCE_CRITERIA.md                 # Requirements traceability & test matrix
    └── agent-research.md                      # AI agent signaling research & adapter specifications
```

---

## 🤖 AI Coding Agent Detection & Hooks

Bitz features multi-channel signaling to monitor your AI coding companions without stealing focus or requiring Accessibility permissions:

### Supported Agents & Signal Channels
| Agent | Signal Channel | Supported Signals | Integration Details |
| :--- | :--- | :--- | :--- |
| **Claude Code** | Session log (`~/.claude/projects/<project>/<session>.jsonl`, read-only) + drop-box hooks | `.working`, `.done`, context gauge, loop & stall warnings (log); `.needsApproval` (hook) | Automatic via `ClaudeCodeTranscriptAdapter`; optional 1-click hooks via Menu Bar (`Stop` & `PermissionRequest`) |
| **Antigravity** | Live session transcript monitoring (`transcript.jsonl`) | `.working`, `.needsApproval`, `.done`, context gauge, loop & stall warnings | Automatic via `AntigravityTranscriptAdapter` monitoring `~/.gemini/antigravity/brain/` |
| **Codex CLI / ChatGPT** | Drop-box event script or `notify` config | `.started`, `.done` | Drop-box JSON files written to `Bitz/agent-events/` |
| **Cursor / Windsurf / Copilot** | Process & bundle ID detection | `.started`, `.working` (focus PTS boost) | Automatically detected as active productive developer apps |
| **Custom Agents** | User-defined processes & bundle IDs | `.started`, `.working`, `.done` | Configurable in Menu Bar or programmatically in `AgentMonitorService` |

### Drop-Box Event Format
Any third-party script or agent can trigger Bitz speech bubbles by dropping a `.json` file into:
`~/Library/Application Support/Bitz/agent-events/`

```json
{
  "id": "e461239c-703a-4ef4-8c88-e3251c86dbd1",
  "agentID": "claude",
  "agentName": "Claude",
  "kind": "done",
  "message": "Claude is done!",
  "timestamp": "2026-10-28T12:00:00Z"
}
```

`kind` is one of `started`, `working`, `needsApproval`, `done`, `almostDone`, `warning` or `usage`, with optional string/number `metadata` (full schema: [`docs/agent-dropbox-event.schema.json`](docs/agent-dropbox-event.schema.json)). Bitz has no built-in "almost done" detector; scripts send `almostDone` themselves. Examples:

```json
{ "agentID": "claude", "agentName": "Claude", "kind": "almostDone", "message": "✨ Claude is almost done!" }
{ "agentID": "claude", "agentName": "Claude", "kind": "warning", "message": "⚠️ Build failed", "metadata": { "reason": "reported" } }
{ "agentID": "codex", "agentName": "Codex", "kind": "usage", "metadata": { "contextTokens": 185000 } }
```

A warning stays until **GOT IT**, menu bar **Dismiss Agent Warning**, or the same agent's `done` / `needsApproval`; the visor turns amber meanwhile. Thresholds and toggles live in Settings → AI Agents → Agent Signals & Warnings.

---

## 🛠️ Build from Source & Local Development

### Requirements
- **macOS 14.0 (Sonoma)** or later (Apple Silicon recommended for on-die `IOHIDEventSystemClient` temperature sensors)
- **Xcode 15.4+** / Xcode Command Line Tools (`/usr/bin/swift`)

### 1. Build, Package & Launch `Bitz.app`
Run the included packaging script to compile the executable, bundle `build/Bitz.app` with its `LSUIElement` `Info.plist`, ad-hoc sign it, and launch it:

```bash
./Scripts/package_and_run.sh
```

Once launched:
1. Look at the **bottom-right corner** of your screen to see Bitz and the live hardware HUD pill (`°C • CPU % • PTS`).
2. Look at the **top-right macOS Menu Bar** and click the **cat icon (`Bitz`)** to view live telemetry or interact with Bitz.

### 2. Run the Unit Test Suite
```bash
/usr/bin/swift test
```

---

## 🔧 Customizing Productive Apps & Thresholds

You can customize which apps count as productive or adjust the idle and thermal thresholds in [`ActivityMonitorService.swift`](src/Services/ActivityMonitorService.swift):

```swift
let customMonitor = ActivityMonitorService(
    engine: engine,
    productiveBundleIDs: [
        "com.google.antigravity-ide",
        "com.apple.dt.Xcode",
        "com.microsoft.VSCode",
        "com.apple.Terminal",
        "com.figma.Desktop" // Add any custom creative/dev bundle IDs
    ],
    idleBreakThresholdSeconds: 60.0,            // Enter break mode after 60s of no input
    overheatingTemperatureThresholdCelsius: 80.0 // Trigger SYSTEM HOT! above 80°C
)
```

---

## 🤝 Contributing

We welcome community contributions! To keep `main` stable and secure, we enforce a strict **Ticket First + Pull Request** workflow:

1. **Direct pushes to `main` are disabled.**
2. **Every Pull Request must be linked to an approved issue ticket** (`Closes #<id>` or `Fixes #<id>`).
3. Automated CI checks (`Verify Linked Issue / Ticket` and `Swift CI Build & Test`) must pass before merging.
4. All PRs require review and approval from a maintainer.

For full guidelines and instructions, please read [CONTRIBUTING.md](CONTRIBUTING.md).

---

## 📄 License & Ownership Policy

Copyright © 2026 **Akram Kasimi**. All rights reserved.

**Bitz the Cyber Cat** is released under a **Source-Available & Personal Hobbyist License** (see [LICENSE](LICENSE)):

- **✅ Personal & Hobbyist Use**: You are free to download, run, study, and tinker with Bitz locally for your own personal use, learning, and hobbyist projects.
- **🚫 No Commercial Copies or Resale**: You may **not** copy, clone, redistribute, white-label, re-license, or sell Bitz (or derivative products based on it). Commercial rights and future monetized features are strictly and exclusively reserved by the author.
- **🐾 Trademark & Brand Assets**: The "Bitz" mascot design, character artwork, and brand identity remain the exclusive intellectual property of **Akram Kasimi**.
