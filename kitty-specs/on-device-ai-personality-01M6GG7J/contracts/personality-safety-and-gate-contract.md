# Contract: Personality Guard Rails & Resource Gating

**Mission**: `on-device-ai-personality-01M6GG7J`  
**Components**: `src/Services/PersonalityGate.swift`, `src/Services/PersonalityRateLimiter.swift`, `src/Services/CommentarySanitizer.swift`

---

## 1. Gating & Thermal Invariants

`PersonalityGate` MUST evaluate system power and thermal conditions before invoking any generator:

| Condition | Action | Rationale |
| :--- | :--- | :--- |
| `ProcessInfo.thermalState >= .serious` | Gate block (`.thermalThrottled`) | Avoid heating machine when thermals are high. |
| Low Power Mode active (`isLowPowerModeEnabled == true`) | Gate block (`.lowPowerMode`) | Preserve energy budget when OS is in power-saving mode. |
| Battery level `< 20%` (on battery) | Gate block (`.lowBattery`) | Avoid battery drain under critical charge. |
| Thermal critical warning in `WellnessPointEngine` | Gated / Prioritized | Critical warnings take precedence over idle chatter. |

---

## 2. Rate Limiting Invariants

`PersonalityRateLimiter` enforces temporal bounds to eliminate user distraction and runaway execution:

1. **Cadence Gap**:
   A minimum interval (default 10 minutes, configurable from 5 to 60 minutes) MUST elapse between successive commentary bubbles.
2. **Daily Cap**:
   A hard daily limit (default 20, configurable from 5 to 50 comments) resets automatically at local midnight.
3. **Persistence**:
   Last trigger timestamp and daily emission count MUST persist in `UserDefaults` across app restarts.

---

## 3. Output Sanitization & Content Safety

`CommentarySanitizer` MUST strictly filter all candidate strings before speech bubble display:

1. **Length Cap**:
   Truncates text to maximum 80 characters, snapping to clean word boundaries where possible.
2. **Formatting Strip**:
   Removes quotation marks, markdown formatting (`**`, `_`, `` ` ``), newlines, and bullet characters.
3. **App Echo Prevention**:
   Strips or replaces raw application titles or bundle names to prevent private window title leaks.
4. **Link / URL Redaction**:
   Drops any output containing web URLs (`http://`, `https://`, `.com`, `.org`).
