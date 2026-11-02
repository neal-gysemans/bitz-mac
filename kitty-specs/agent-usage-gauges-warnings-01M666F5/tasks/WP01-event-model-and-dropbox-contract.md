---
work_package_id: WP01
title: Event Model & Drop-box Contract
dependencies: []
requirement_refs:
- C-001
- FR-001
- FR-002
- FR-003
planning_base_branch: feat/issue-38-agent-gauges-warnings
merge_target_branch: feat/issue-38-agent-gauges-warnings
branch_strategy: Planning artifacts for this mission were generated on feat/issue-38-agent-gauges-warnings. During /spec-kitty.implement this WP may branch from a dependency-specific base, but completed changes must merge back into feat/issue-38-agent-gauges-warnings unless the human explicitly redirects the landing branch.
subtasks:
- T001
- T002
- T003
- T004
- T005
- T006
phase: Phase 0 - Foundation
history:
- !!omap
  - at: '2026-10-30T13:37:15Z'
  - actor: system
  - action: Prompt generated via /spec-kitty.tasks
agent_profile: implementer-ivan
authoritative_surface: src/Models/
create_intent:
- Tests/BitzTests/AgentModelsTests.swift
execution_mode: code_change
model: ''
owned_files:
- src/Models/AgentModels.swift
- docs/agent-dropbox-event.schema.json
- Tests/BitzTests/AgentModelsTests.swift
- Tests/BitzTests/DropboxAgentAdapterTests.swift
role: implementer
tags: []
task_type: implement
tracker_refs: []
---

# Work Package Prompt: WP01 – Event Model & Drop-box Contract

## ⚡ Do This First: Load Agent Profile

Use the `/ad-hoc-profile-load` skill to load the agent profile specified in the frontmatter, and behave according to its guidance before parsing the rest of this prompt.

- **Profile**: `implementer-ivan`
- **Role**: `implementer`
- **Agent/tool**: `claude`

If no profile is specified, run `spec-kitty agent profile list` and select the best match for this work package's `task_type` and `authoritative_surface`.

---

## ⚠️ IMPORTANT: Review Feedback

- **Has review feedback?**: Check the `review_ref` field in the event log (via `spec-kitty agent tasks status`) or the Activity Log below.
- **You must address all feedback** before your work is complete.

---

## Objectives & Success Criteria

Satisfies FR-001, FR-002, FR-003, C-001 (see `kitty-specs/agent-usage-gauges-warnings-01M666F5/spec.md`).

Done when:
- `AgentEventKind` has `almostDone`, `warning`, `usage` in addition to the four existing kinds.
- `AgentEvent` has an optional `metadata: [String: String]?` that decodes from strings, numbers or booleans, and is `nil` when absent or malformed.
- Old drop-box payloads (no `metadata`, original kinds) decode to exactly the same values as before.
- New value types exist: `AgentWarningReason`, `AgentWarning`, `AgentContextReading`, `AgentSignalSettings` (see `data-model.md`).
- `docs/agent-dropbox-event.schema.json` matches `contracts/agent-event-contract.md`.
- `xcrun swift build` and `xcrun swift test` are green (the two exhaustive switches compile via placeholder cases).
- `xcrun swift build 2>&1 | grep -c 'warning:'` prints `0` (charter quality gate: zero compiler warnings; SwiftLint is not configured in this repo).

## Context & Constraints

- Read first: `kitty-specs/agent-usage-gauges-warnings-01M666F5/data-model.md`, `contracts/agent-event-contract.md`, `research.md` (R2, R3).
- Charter: Swift 6 strict concurrency; every new type is `Sendable`. No third-party dependencies.
- Code style: match `src/Models/AgentModels.swift` — `public` types, `///` doc comment per type, explicit `public init`.
- Toolchain: always `xcrun swift build` / `xcrun swift test` (AGENTS.md §3.1).

## Branch Strategy

- **Strategy**: Planning artifacts were generated on `feat/issue-38-agent-gauges-warnings`; completed changes merge back into `feat/issue-38-agent-gauges-warnings`.
- **Planning base branch**: `feat/issue-38-agent-gauges-warnings`
- **Merge target branch**: `feat/issue-38-agent-gauges-warnings`
- Execution worktrees are allocated per computed lane from `lanes.json`.
- Implementation command: `spec-kitty agent action implement WP01 --agent claude`

## Subtasks & Detailed Guidance

### Subtask T001 – Extend `AgentEventKind` + `AgentEvent.metadata`

- **Purpose**: New kinds carry almost-done milestones, warnings and never-shown usage readings; metadata carries details (FR-001–FR-003).
- **Steps**:
  1. In `src/Models/AgentModels.swift`, add cases to `AgentEventKind` after `done`:
     ```swift
     case almostDone
     case warning
     /// Context reading / activity heartbeat; never shown as a bubble.
     case usage
     ```
  2. Add `public let metadata: [String: String]?` to `AgentEvent`; add `metadata: [String: String]? = nil` as the **last** `init` parameter so every existing call site keeps compiling.
  3. Add `metadata` to `CodingKeys`. In `init(from:)`, decode leniently:
     ```swift
     self.metadata = (try? container.decodeIfPresent([String: MetadataValue].self, forKey: .metadata))?
         .mapValues(\.string)
     ```
     with a `private struct MetadataValue: Decodable` that accepts `String`, `Int`, `Double`, `Bool` (single-value container, try in that order; `Bool` → `"true"`/`"false"`, `Double` with no fraction → integer string, e.g. `185000.0` → `"185000"`). A value of any other shape makes the whole map `nil` (the `try?`), never a decode failure of the event.
  4. Encoding stays synthesized (`Codable`); confirm `metadata` is emitted when non-nil.
- **Files**: `src/Models/AgentModels.swift`
- **Notes**: Do not change `id`/`timestamp` fallback behaviour. `Equatable` stays synthesized.

### Subtask T002 – Metadata keys + typed accessors

- **Purpose**: One place for key names so adapters, monitor and tests never use string literals.
- **Steps**:
  1. Add inside an `extension AgentEvent`:
     ```swift
     public enum MetadataKey {
         public static let reason = "reason"
         public static let contextTokens = "contextTokens"
         public static let pendingTools = "pendingTools"
         public static let turnActive = "turnActive"
         public static let seed = "seed"
         /// `process` on ProcessAgentAdapter events (app presence); see data-model.md.
         public static let source = "source"
     }
     public var contextTokens: Int? { metadata?[MetadataKey.contextTokens].flatMap(Int.init).flatMap { $0 >= 0 ? $0 : nil } }
     public var pendingTools: Int? { metadata?[MetadataKey.pendingTools].flatMap(Int.init).flatMap { $0 >= 0 ? $0 : nil } }
     public var turnActive: Bool? { metadata?[MetadataKey.turnActive].flatMap(Bool.init) }
     public var isSeed: Bool { metadata?[MetadataKey.seed] == "true" }
     public var isProcessPresence: Bool { metadata?[MetadataKey.source] == "process" }
     public var warningReason: AgentWarningReason { metadata?[MetadataKey.reason].flatMap(AgentWarningReason.init(rawValue:)) ?? .reported }
     ```
  2. Non-integer or negative values return `nil` (contract: "ignored, never crash").
- **Files**: `src/Models/AgentModels.swift`

### Subtask T003 – Value types for warnings, readings and settings

- **Purpose**: Shared types consumed by WP02 (policy), WP03–05 (adapters), WP06–08 (UI).
- **Steps** (all `public`, `Sendable`, `Equatable`; doc comment each):
  1. `AgentWarningReason: String, Codable, CaseIterable` — `context`, `loop`, `stall`, `reported`.
  2. `AgentWarning` — `agentID`, `agentName`, `reason`, `text` + memberwise `public init`.
  3. `AgentContextReading` — `agentID`, `agentName`, `tokens: Int`, `windowTokens: Int`; computed:
     ```swift
     public var percent: Int { windowTokens > 0 ? min(100, tokens * 100 / windowTokens) : 0 }
     public var compactText: String { "\(agentName) ctx \(Self.formatTokens(tokens)) · \(percent)%" }
     public static func formatTokens(_ t: Int) -> String {
         if t < 1_000 { return "\(t)" }
         if t < 1_000_000 { return "\(t / 1_000)k" }
         return String(format: "%.1fM", Double(t) / 1_000_000)
     }
     ```
  4. `AgentSignalSettings: Codable` with defaults from `data-model.md`:
     ```swift
     public static let defaultContextWindow = 200_000
     public static let `default` = AgentSignalSettings()
     public var almostDoneEnabled = true
     public var contextWarningEnabled = true
     public var loopWarningEnabled = true
     public var stallWarningEnabled = true
     public var contextThresholdPercent = 90      // 50...99
     public var stallTimeoutMinutes = 3           // 1...30
     public var contextWindowTokens: [String: Int] = ["claude": 200_000, "antigravity": 1_000_000]
     public func contextWindow(for agentID: String) -> Int
     public func isEnabled(_ reason: AgentWarningReason) -> Bool   // reported → true
     public func clamped() -> AgentSignalSettings                  // clamp ranges, drop windows <= 0
     ```
     Custom `init(from:)` using `decodeIfPresent` per field so a stored blob missing a future field keeps the other values (falls back to the default for the missing one). Provide `public init()` with the defaults.
- **Files**: `src/Models/AgentModels.swift`
- **Notes**: No persistence here; WP02 persists via injected `UserDefaults`.

### Subtask T004 – Keep exhaustive switches compiling

- **Purpose**: Adding enum cases breaks `AgentMonitorService.handleEvent` (`src/Services/AgentMonitorService.swift:155`) and `SpeechBubbleView.agentPopupColors` (`src/Views/SpeechBubbleView.swift:130`).
- **Steps**:
  1. `AgentMonitorService.handleEvent`: add `case .almostDone, .warning, .usage: break` with a one-line comment `// Handled by the signal policy (WP02).`
  2. `SpeechBubbleView.agentPopupColors`: map `.almostDone, .warning, .usage` to the existing cyan pair with comment `// Distinct styles added in WP06.`
- **Files**: out-of-map edits, justified: the build must stay green; WP02 / WP06 own and replace these lines. Record the rationale in the Activity Log.
- **Notes**: Nothing else in those files changes.

### Subtask T005 – Update the drop-box JSON schema [P]

- **Purpose**: Integrators validate against `docs/agent-dropbox-event.schema.json`; it currently enumerates only four kinds and forbids extra properties.
- **Steps**:
  1. `kind.enum` → `["started","working","needsApproval","done","almostDone","warning","usage"]`; update the description.
  2. Add `metadata`: `{"type":"object","additionalProperties":{"type":["string","number","boolean"]},"description":"Optional details. Keys: reason (context|loop|stall|reported), contextTokens, pendingTools, turnActive, seed, source (set by Bitz only)."}`.
  3. Keep `additionalProperties: false` at the top level and the existing `required` list.
- **Files**: `docs/agent-dropbox-event.schema.json`
- **Validation**: `/usr/bin/python3 -I -c "import json;json.load(open('docs/agent-dropbox-event.schema.json'))"` parses.

### Subtask T006 – Model + drop-box decoding tests

- **Purpose**: Prove backward compatibility and lenient metadata decoding (NFR-006 spirit for the drop-box trust boundary).
- **Steps** — create `Tests/BitzTests/AgentModelsTests.swift` (`final class AgentModelsTests: XCTestCase`, ISO-8601 decoder like `DropboxAgentAdapter`):
  1. `testOldPayloadDecodesUnchanged` — original 6-field JSON → `metadata == nil`, fields equal.
  2. `testMetadataDecodesStringsNumbersAndBools` — `{"contextTokens":185000,"turnActive":true,"reason":"context"}` → `contextTokens == 185000`, `turnActive == true`, `warningReason == .context`.
  3. `testMalformedMetadataIsIgnoredNotFatal` — `"metadata":{"x":[1,2]}` → event decodes, `metadata == nil`.
  4. `testInvalidNumbersReturnNil` — `"contextTokens":"abc"` and `"-5"` → `nil`.
  5. `testUnknownReasonFallsBackToReported` and `testProcessPresenceFlagFromSourceMetadata`.
  6. `testContextReadingPercentAndText` — 148_000 / 200_000 → 74, `"Claude ctx 148k · 74%"`; 943_000 / 200_000 → 100; 1_200_000 → `"1.2M"`; window 0 → 0%.
  7. `testSignalSettingsDefaultsClampAndPartialDecode` — defaults; `clamped()` maps threshold 120 → 99, 10 → 50, stall 0 → 1, 99 → 30, drops `["x": 0]`; decoding `{"loopWarningEnabled":false}` keeps all other defaults; `contextWindow(for: "unknown") == 200_000`.
  8. In `Tests/BitzTests/DropboxAgentAdapterTests.swift` add `testDropsV2EventWithMetadata` — write a v2 file with `"kind":"usage","metadata":{"contextTokens":"1234"}` and assert the handler receives `kind == .usage`, `contextTokens == 1234`. Follow the existing file's temp-dir pattern.
- **Files**: `Tests/BitzTests/AgentModelsTests.swift` (new), `Tests/BitzTests/DropboxAgentAdapterTests.swift`

## Test Strategy

- TDD: write T006 tests first (red), implement T001–T003 (green).
- Run: `xcrun swift test --filter AgentModelsTests` and `--filter DropboxAgentAdapterTests`, then the full `xcrun swift test`.

## Risks & Mitigations

- **Silent payload rejection**: a typo in `MetadataValue` decoding could drop events → test 2/3 cover both paths.
- **Equatable churn**: adding `metadata` changes equality; no existing test compares events with metadata, so expect no fallout.

## Review Guidance

- Old payload test must use the exact JSON shape `AgentHookInstaller.claudeSettingsSnippet()` writes.
- Placeholder switch cases are the only edits outside owned files.
- No persistence or UI logic in this WP.

## Activity Log

- 2026-10-30T13:37:15Z – system – Prompt created.
