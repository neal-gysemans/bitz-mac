## 2024-03-24 - Accessibility Labels on UI Controls with ASCII Emoticons
**Learning:** ASCII emoticons in text labels like "Pet Bitz (<3)" are read out poorly by screen readers like VoiceOver, confusing users. Buttons and UI controls shouldn't rely on VoiceOver to parse ASCII art. Additionally, frequent or primary actions in menu bar utilities should offer keyboard shortcuts for power users.
**Action:** Use `.accessibilityLabel("Label")` to provide clean strings for screen readers when buttons contain non-standard ASCII art or emoticons. Use `.keyboardShortcut()` to assign fast, intuitive macOS native hotkeys like ⌘Q and ⌘P to important actions.

## 2023-10-28 - Missing Accessibility Labels on Non-Standard ASCII Buttons
**Learning:** Found non-standard ASCII strings like `(<3)` or `[⎋ Esc]` used in SwiftUI buttons missing accessibility labels. This can cause screen readers to read out confusing characters and provide a poor UX for a11y users.
**Action:** Applied `.accessibilityLabel` to correct this. Look for ASCII art and add an `.accessibilityLabel()` when it is used to supplement or act as a primary button text in SwiftUI.

## 2026-11-03 - Missing Tooltips on Small HUD Buttons
**Learning:** Buttons in small HUDs (like speech bubbles) often use abbreviated text (e.g., "JUMP" or "DIFF") to save space. This can make their purpose unclear to users, hurting discoverability and usability.
**Action:** Use `.help("Descriptive tooltip")` on custom small HUD buttons with abbreviated text to provide context on hover. Also ensure they have an `.accessibilityLabel()` for screen reader users.
## 2024-05-19 - Added accessibility labels and help tooltips to icon buttons
**Learning:** Found small, icon-centric buttons or buttons using heavily abbreviated text in HUD overlays (like "LOCK") and popovers (like `ProBadgeView`) that lacked `.help()` context and standard screen reader `.accessibilityLabel()`.
**Action:** Always add `.help("Description")` and `.accessibilityLabel("Description")` to any small utility button, especially those using system images, icons, or constrained text in HUDs, ensuring they match existing patterns in `AgentApprovalHUDView` and `SpeechBubbleView`.
## 2024-05-24 - Accessibility labels for icon-only buttons
**Learning:** Custom UI elements like icon-only buttons and ProBadgeView buttons were missing `.accessibilityLabel()` modifiers, making them opaque to VoiceOver users. Also, custom buttons using `.help()` should generally also have an `.accessibilityLabel()` if they are icon-only.
**Action:** When adding new icon-only buttons or custom button views, ensure `.accessibilityLabel()` is applied for screen readers. Use `.help()` alongside it to provide on-hover tooltips for mouse users.

## 2024-11-09 - Avoid Redundant Accessibility Labels on Standard SwiftUI Buttons
**Learning:** In SwiftUI, `Button` or `Label` components natively use their text content as their accessibility label for VoiceOver. Adding an explicit `.accessibilityLabel()` to standard readable text (e.g., `Label("Quit Bitz")`) is redundant and does not improve the accessibility experience.
**Action:** Reserve explicit `.accessibilityLabel()` usage strictly for overriding unreadable strings, parenthetical hints (like "(Drag)"), or non-standard ASCII elements. Do not apply them to clean, standard text strings.
