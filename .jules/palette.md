## 2024-03-24 - Accessibility Labels on UI Controls with ASCII Emoticons
**Learning:** ASCII emoticons in text labels like "Pet Bitz (<3)" are read out poorly by screen readers like VoiceOver, confusing users. Buttons and UI controls shouldn't rely on VoiceOver to parse ASCII art. Additionally, frequent or primary actions in menu bar utilities should offer keyboard shortcuts for power users.
**Action:** Use `.accessibilityLabel("Label")` to provide clean strings for screen readers when buttons contain non-standard ASCII art or emoticons. Use `.keyboardShortcut()` to assign fast, intuitive macOS native hotkeys like ⌘Q and ⌘P to important actions.

## 2023-10-28 - Missing Accessibility Labels on Non-Standard ASCII Buttons
**Learning:** Found non-standard ASCII strings like `(<3)` or `[⎋ Esc]` used in SwiftUI buttons missing accessibility labels. This can cause screen readers to read out confusing characters and provide a poor UX for a11y users.
**Action:** Applied `.accessibilityLabel` to correct this. Look for ASCII art and add an `.accessibilityLabel()` when it is used to supplement or act as a primary button text in SwiftUI.
