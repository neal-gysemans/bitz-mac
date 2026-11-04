## Summary
Audit of the menu bar dropdown (`BitzMenuBarContentView`), the mascot right-click menu, and the Settings window (`SettingsRootView` + 6 tabs) on `main` @ `5289472` (post v1.3.0, includes #86–#90). Found **10 functional bugs**, **8 menu bar UX defects**, and **11 Settings UX / consistency issues**. This document is the implementation plan; GitHub issue #94 holds the same findings as the ticket of record.

The global-shortcut regression (#93) was split out and fixed separately and is not repeated here.

## Environment
- **Product**: bitz-mac (Bitz the Cyber Cat)
- **Version**: `main` @ `5289472`
- **OS**: macOS 14+ (Apple Silicon)
- **Method**: full code read of `src/App/BitzApp.swift` (menu bar + delegate), `src/Views/MascotOverlayView.swift` (context menu), `src/App/Settings/SettingsWindowManager.swift`, `src/Views/Settings/*.swift`. Release build launched locally; menu/visual rendering **not** captured (needs a manual pass, see Verification).

Confidence labels: **Confirmed** = proven by code path; **Likely** = strong code evidence, needs a visual check.

---

## Findings

### A. Functional bugs (wrong behavior or wrong data)

| ID | Finding | Evidence | Confidence |
|---|---|---|---|
| A1 | **Settings opened from the menu bar edits detached copies of the palette and interaction stores.** The menu bar builds its own `SettingsRootView` without `paletteStore`, `interactionSettings` and `inboxDirectoryURL`, so the defaults create new store instances. After the Settings window has been closed once (content is torn down, #70), reopening it from the menu bar means theme, colour, glow, hold-key, stroke-to-pet and file-drop changes never reach the live mascot until restart, and the live store can later overwrite them. No store observes `UserDefaults` changes. | `BitzApp.swift:905` (menu) vs `BitzApp.swift:378` (delegate); defaults in `SettingsRootView.init` | Confirmed |
| A2 | **"Check for Updates…" gives no feedback** when up to date or when the check fails. `AppUpdateStore.statusMessage` is set but never rendered anywhere (menu bar or Advanced tab). | `AppUpdateService.swift:268-298`; 0 references to `statusMessage` in views | Confirmed |
| A3 | **Telemetry → "Menu Bar Dropdown Stats" toggle does nothing.** `displayInMenuBarMenu` is persisted but no view reads it; the dropdown shows no stats. | `TelemetrySettingsTabView.swift:44`; only reference outside the store | Confirmed |
| A4 | **Telemetry → "Compact Menu Bar Title Item" likely never shows text.** `MenuBarExtra(_:systemImage:)` uses the title for accessibility only (icon-only label), and `BitzAppDelegate` is not an `ObservableObject`, so `@Published menuBarTitle` changes do not re-render the scene. | `BitzApp.swift:989`, `BitzApp.swift:9`, `BitzApp.swift:28` | Likely |
| A5 | **Behaviors → "Application Productivity Rules" classifies Bitz itself.** Opening Settings activates Bitz (`NSApp.activate`), so within one 5 s tick the sampled frontmost app is Bitz. "Classify Productive / Distraction" then writes a rule for Bitz, not for the app the user came from. Bitz is also scored as the active app while Settings is open. | `ActivityMonitorService.swift:1142-1153` (no own-bundle filter), `SettingsWindowManager.swift:44, 70` | Confirmed (code); verify live |
| A6 | **Point-rate label is wrong by ~12×.** Settings says "+0.5 PTS / min" / "-1.5 PTS / min"; the engine applies those deltas **per 5 s tick** (≈ +6 / −18 per minute at the default cadence). | `BehaviorSettingsTabView.swift:106`, `WellnessPointEngine.swift:158-159, 284-292` | Confirmed |
| A7 | **Display Routing picker goes blank for a specific display.** The picker has tags for Primary / Follow Active / All Screens but not `.specific`, which is set by the display list below it and by dragging Bitz to another screen. | `GeneralSettingsTabView.swift:265-273`, `DisplayPreferenceStore.swift:9` | Confirmed (code); verify visual |
| A8 | **Size and opacity preset pickers highlight the wrong preset.** After ⌘= (110 %) the segmented control highlights "100 %"; after ⌘] from 80 % (90 %) it highlights "80 %". The getter falls back to a default when the value is not a preset. | `GeneralSettingsTabView.swift:97, 151`; presets in `MascotOverlayPanel.swift:161, 275` (step 0.10) | Confirmed |
| A9 | **Settings window can be resized smaller than its content.** `window.minSize` = 640×520 (frame, incl. title bar) vs SwiftUI `.frame(minWidth: 660, minHeight: 560)`; with `sizingOptions = []` AppKit is never told the content minimum, so the footer and tab bar clip. | `SettingsWindowManager.swift:58`, `SettingsRootView.swift:105` | Confirmed (code); verify visual |
| A10 | **State names shown as raw enum values.** Menu: "State: superCharged"; Behaviors badge and General preview use `rawValue.capitalized` → "Supercharged", "Dopaminesad". The preview label also ignores an active colour preview (`previewSlot`) and shows the engine state instead of the previewed one. | `BitzApp.swift:932`, `BehaviorSettingsTabView.swift:353`, `GeneralSettingsTabView.swift:337, 367` | Confirmed |

### B. Menu bar dropdown UX

| ID | Finding | Evidence | Confidence |
|---|---|---|---|
| B1 | Shortcut shown twice: titles embed "(⌘=)", "(⌘[)", "[⎋ Esc / Right-Click]" **and** `.keyboardShortcut` renders the key-equivalent column. | `BitzApp.swift:852-877, 962` | Confirmed |
| B2 | "Lock Position" binds `⎋ Escape` as a menu key equivalent; Esc already closes the menu. Remove the shortcut. | `BitzApp.swift:962-967` | Confirmed |
| B3 | Visibility toggle label flips ("Mascot Visible on Screen" / "Mascot Hidden (Click to Show)") while also showing a checkmark. Use a fixed "Show Mascot". | `BitzApp.swift:959` | Confirmed |
| B4 | Volume (25/50/75/100 %) and Flow Shield streak (15/20/30/45 min) are plain buttons; the current value is only in a text row, never checkmarked. Use an inline `Picker` so the selected value is checked. | `BitzApp.swift:782-789, 831-838` | Confirmed |
| B5 | "Break Shield (Disable Focus)" appears twice when Flow Shield is active (top level and inside the Flow Shield submenu). | `BitzApp.swift:760, 771-779` | Confirmed |
| B6 | Header shows the same points twice ("(90 PTS)" and "Focus: 90.0 / 100"). | `BitzApp.swift:932-934` | Confirmed |
| B7 | Custom SwiftUI layout in menu style is flattened: the "Simulation Override Active" `HStack` with a Resume button, `.font`, `.foregroundStyle`, `.controlSize`, `.lineLimit`, `.padding` are ignored in a `.menu`-style `MenuBarExtra`. | `BitzApp.swift:937-951`; no `menuBarExtraStyle` in `src/` | Likely |
| B8 | The dropdown has grown back past the Settings spec goal (FR-002, NFR-003 "< 300 pt"): Theme (8 presets), Flow Shield (toggle + 4 thresholds), Sound (7 toggles + 4 volumes + test), Size & Opacity. These duplicate Settings tabs. | `kitty-specs/settings-window-01M63XMB/spec.md` FR-002 / NFR-003 | Confirmed |

### C. Settings window UX and consistency

| ID | Finding | Evidence |
|---|---|---|
| C1 | Duplicate controls: **Quit** twice (footer red prominent button next to "Close Settings" = misclick risk; Advanced tab), **Show Mascot** twice (footer, General), **override banner** in three places (menu, Behaviors, Advanced), **Pet Bitz** button in Behaviors. | `SettingsRootView.swift:113-130`, `AdvancedSettingsTabView.swift:175`, `GeneralSettingsTabView.swift:44` |
| C2 | Hidden zero-size `Button("")` shortcut listeners in the footer duplicate the app menu items and the local key monitor (three layers for ⌘-, ⌘=, ⌘[, ⌘], ⌘P). | `SettingsRootView.swift:133-147` |
| C3 | General tab is overloaded: preview, visibility, size, opacity, placement, theme with 9+ colour rows, interaction, display routing in one scroll. Split into **General** and **Appearance**. | `GeneralSettingsTabView.swift` (408 lines) |
| C4 | "Hold ⌥ anytime to freely drag Bitz" hint shows even when hold-to-interact is disabled. | `GeneralSettingsTabView.swift:206-212` |
| C5 | Flow Shield streak has a Stepper (5–120 min) **and** a Slider (5–90 min) for one value; above 90 the slider pins at 90. Keep one control. | `BehaviorSettingsTabView.swift:208-229` |
| C6 | Launch at Login swallows errors; the toggle silently flips back (e.g. when macOS requires approval for an ad-hoc signed build). Show status and an "Open Login Items" action (`SMAppService.openSystemSettingsLoginItems()`). | `AdvancedSettingsTabView.swift:131-145` |
| C7 | Claude Code hook card shows no installed / not-installed state; Install and Uninstall are always enabled; the result message is lost on tab switch. | `AgentsSettingsTabView.swift:157-204` |
| C8 | Keyboard Shortcuts cheat sheet does not say which shortcuts are global (⌥⌘B, Esc/Return while dragging) vs. only while Bitz is focused (after #93). | `AdvancedSettingsTabView.swift` "Keyboard Shortcuts" card |
| C9 | Debug simulation buttons ("Question / Chime", "All Done / Fanfare") sit in the AI Agents user settings; move them to Advanced → Simulation. | `AgentsSettingsTabView.swift:38-72` |
| C10 | Settings opens on **every** launch (since #58). With Launch at Login enabled this pops a window at each login. | `BitzApp.swift:266` |
| C11 | Custom-rule tag ternary has identical branches (`" (Custom Rule)"` both ways); show "Custom: Productive" / "Custom: Distraction". | `BehaviorSettingsTabView.swift:95` |

### D. To measure (no finding yet)
- D1: `BitzMenuBarContentView` observes `telemetryDashboard` (1–10 s polling) at the root. AGENTS.md §2.5 requires polling observers in leaf views. Measure idle CPU with the menu **closed**; if the menu body re-evaluates per tick, move the observer into a leaf view.

---

## Implementation Plan

Three PRs, each independently shippable, each `refs #<issue>`. WP1 first: it fixes wrong behavior and is small.

### WP1: Functional fixes (A1–A10) — small, low risk
| Step | Change | Files | Test |
|---|---|---|---|
| 1 | One Settings factory: pass an `onOpenSettings` closure into `BitzMenuBarContentView` (same pattern as `MascotOverlayView.onOpenSettings`) and delete the menu's `openSettingsWindow()` copy. | `BitzApp.swift` | `MenuBarContentViewTests`: menu-opened root uses the delegate's `paletteStore` / `interactionSettings` instances (`===`). |
| 2 | Render `updateStore.statusMessage` under the Advanced "Check for Updates" button; in the menu, show it as a disabled status line after a manual check. | `AdvancedSettingsTabView.swift`, `BitzApp.swift` | View test asserts status text present after a stubbed check. |
| 3 | A3: implement a one-line stats row in the menu gated on `displayInMenuBarMenu` **or** remove the toggle (decision D-2). | `BitzApp.swift` / `TelemetrySettingsTabView.swift` | Gate test. |
| 4 | A4: switch to `MenuBarExtra { … } label: { … }` with an icon + optional `Text`, driven by an observable title (e.g. publish it from `TelemetryDashboardService`). | `BitzApp.swift`, `TelemetryDashboardService.swift` | Title updates when the setting is toggled. |
| 5 | A5: ignore Bitz's own bundle ID in `performSampleTick` (keep the last non-Bitz app for display and scoring). | `ActivityMonitorService.swift` | `ActivityMonitorService` test with a mock provider returning Bitz's bundle ID. |
| 6 | A6: label shows per-tick values or converts with the polling interval. | `BehaviorSettingsTabView.swift` | Snapshot of label text. |
| 7 | A7: add a "Specific Display" tag (or show the selected display name) for `.specific`. | `GeneralSettingsTabView.swift` | `SettingsViewsTests`: picker selection valid for every `DisplayTargetMode`. |
| 8 | A8: preset pickers use an optional selection; no highlight when the value is between presets. | `GeneralSettingsTabView.swift` | Store at 1.10 → no preset selected. |
| 9 | A9: set `window.contentMinSize = 660×560` (single source of truth with the SwiftUI frame). | `SettingsWindowManager.swift` | Assert `contentMinSize` ≥ root min frame. |
| 10 | A10: add `BitzState.displayName` ("Super Charged", "Dopamine Sad", …) and use it in menu, badge and preview; preview label follows `previewSlot`. | `WellnessPointEngine.swift`, 3 views | Unit test for all cases. |

### WP2: Menu bar cleanup (B1–B8, D1) — needs decision D-1
- Remove shortcut text from titles (B1), drop the Esc key equivalent (B2), fixed "Show Mascot" label (B3), inline `Picker`s for volume/streak (B4), single Break Shield entry (B5), single points line (B6), replace the override `HStack` with a plain "Resume Live Sensors" button (B7).
- B8 target layout (proposal):
  ```
  Bitz — Balanced · 72 PTS · 25 min streak
  [warning lines, if any]
  ────────────
  Pet Bitz                     ⌘P
  ✓ Show Mascot
  Lock Position                (only while unlocked)
  Break Shield / Resume        (only when Flow Shield enabled)
  ✓ Sound                      (master mute only)
  Theme ▸
  ────────────
  Settings…                    ⌘,
  Check for Updates…
  Quit Bitz                    ⌘Q
  ```
  Per-sound toggles, volume, streak thresholds, size/opacity steps move to Settings only.
- D1: measure, then isolate the telemetry observer into a leaf view if needed.

### WP3: Settings window UX (C1–C11) — mostly removals
- Footer: keep "Show Mascot" + "Close"; remove the red Quit (C1). Remove hidden shortcut buttons (C2).
- Split General into **General** (visibility, placement, display routing, interaction) and **Appearance** (preview, size, opacity, theme & colours) (C3).
- C4–C11 as listed above.
- Keep the custom tab header (works, low ROI to replace); revisit native `TabView` styling separately if wanted.

## Decisions Needed
| ID | Decision | Recommendation |
|---|---|---|
| D-1 | How lean should the dropdown be (B8)? | Trim to the layout above; settings stay in Settings. Matches the original spec (FR-002 / NFR-003). |
| D-2 | "Menu Bar Dropdown Stats" (A3): build it or drop it? | Build one disabled text line (CPU · RAM · Disk) from the already-observed snapshot; drop the toggle if nobody wants it. |
| D-3 | Settings on every launch (C10)? | Open only on first launch and on Dock reopen; never at login. |

## Risks & Dependencies
- **Idle CPU (< 2 %)**: WP2 and WP3 touch views; run the AGENTS.md §2.8 live CPU check with Settings closed.
- **Window teardown (#70)**: keep `contentViewController = nil` on close and `sizingOptions = []`; A9 must not re-enable intrinsic sizing.
- **Click-through invariants**: no change to `MascotOverlayPanel` / `SpeechBubblePanel`.
- **#93 dependency**: C8 text depends on the scoped global hotkeys from #93.
- **Persistence**: A1 fix must not change UserDefaults keys; existing user preferences keep working.

## Verification
1. `xcrun swift test` — all green, new tests per WP.
2. `./Scripts/package_and_run.sh release`, close Settings, `top -pid $(pgrep -x Bitz)` → idle CPU < 2 %.
3. Manual checklist (visual items not provable in code):
   - Menu bar: no duplicated shortcut text; override row readable; volume/streak show a checkmark (B1, B4, B7).
   - Telemetry title item shows CPU/RAM text next to the cat icon when enabled (A4).
   - Change theme in Settings opened **from the menu bar after closing it once** → mascot updates live (A1).
   - Select a specific display → routing picker shows it (A7).
   - Shrink Settings window to minimum → nothing clipped (A9).
   - Open Settings from Chrome → Behaviors shows Chrome, not Bitz (A5).
