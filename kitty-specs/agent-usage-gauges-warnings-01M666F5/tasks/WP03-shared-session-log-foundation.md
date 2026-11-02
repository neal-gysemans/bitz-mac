---
work_package_id: WP03
title: Shared Session-Log Foundation
dependencies:
- WP01
requirement_refs:
- FR-008
- FR-009
- FR-014
- NFR-001
- NFR-002
- NFR-004
- NFR-006
planning_base_branch: feat/issue-38-agent-gauges-warnings
merge_target_branch: feat/issue-38-agent-gauges-warnings
branch_strategy: Planning artifacts for this mission were generated on feat/issue-38-agent-gauges-warnings. During /spec-kitty.implement this WP may branch from a dependency-specific base, but completed changes must merge back into feat/issue-38-agent-gauges-warnings unless the human explicitly redirects the landing branch.
subtasks:
- T014
- T015
- T016
- T017
- T018
- T019
phase: Phase 1 - Session logs
history:
- !!omap
  - at: '2026-10-30T13:37:15Z'
  - actor: system
  - action: Prompt generated via /spec-kitty.tasks
agent_profile: implementer-ivan
authoritative_surface: src/Services/
create_intent:
- src/Services/SessionLogTail.swift
- src/Services/AgentSessionTracker.swift
- Tests/BitzTests/SessionLogTailTests.swift
- Tests/BitzTests/AgentSessionTrackerTests.swift
execution_mode: code_change
model: ''
owned_files:
- src/Services/SessionLogTail.swift
- src/Services/AgentSessionTracker.swift
- Tests/BitzTests/SessionLogTailTests.swift
- Tests/BitzTests/AgentSessionTrackerTests.swift
role: implementer
tags: []
task_type: implement
tracker_refs: []
---

# Work Package Prompt: WP03 – Shared Session-Log Foundation

## ⚡ Do This First: Load Agent Profile

Use the `/ad-hoc-profile-load` skill to load the agent profile specified in the frontmatter, and behave according to its guidance before parsing the rest of this prompt.

- **Profile**: `implementer-ivan`
- **Role**: `implementer`
- **Agent/tool**: `claude`

If no profile is specified, run `spec-kitty agent profile list` and select the best match for this work package's `task_type` and `authoritative_surface`.

---

## ⚠️ IMPORTANT: Review Feedback

- **Has review feedback?**: Check the `review_ref` field in the event log or the Activity Log below.
- **You must address all feedback** before your work is complete.

---

## Objectives & Success Criteria

Build three pure, adapter-agnostic pieces used by WP04 (Claude Code) and WP05 (Antigravity):
1. `SessionLogTail` — incremental reader of an append-only JSONL file with a bounded seed (NFR-001, NFR-002).
2. `SessionLogTail.pickSession(...)` — stable "most recently active session" choice with idle-switch hysteresis (research R7).
3. `AgentSessionTracker` + `SessionLogEntry` — turns parsed entries into `AgentEvent`s: working/done, loop warnings, usage readings; tracks pending tools and turn state (FR-008, FR-009 inputs, FR-014).

Done when all behaviour below is covered by `SessionLogTailTests` and `AgentSessionTrackerTests` and the full suite is green. No adapter or UI changes in this WP.

Definition of Done also includes:
- No new compiler warnings, measured with a clean build (`xcrun swift build --scratch-path "$(mktemp -d)" 2>&1 | grep 'warning:' | sort -u`): the only allowed lines are the 3 pre-existing Swift 6 warnings at `src/Views/MascotOverlayView.swift:142` (from #61), which WP06 removes. Incremental builds hide warnings, so don't use them for this check (charter quality gate; SwiftLint is not configured in this repo).

## Context & Constraints

- Read: `research.md` R4–R7, `data-model.md` (Adapter-side tracker table), `contracts/agent-event-contract.md` (usage metadata).
- Existing reference implementation of tail reading: `src/Services/AntigravityTranscriptAdapter.swift:105-150` (offset handling, partial lines, truncation) — reuse its ideas, fix its partial-line activity issue.
- NFR-004: keep only token counts, tool names and fingerprints; never store line text.
- `Sendable` value types; adapters wrap them in their own lock.

## Branch Strategy

- **Planning base branch**: `feat/issue-38-agent-gauges-warnings`
- **Merge target branch**: `feat/issue-38-agent-gauges-warnings`
- Execution worktrees are allocated per computed lane from `lanes.json`.
- Implementation command: `spec-kitty agent action implement WP03 --agent claude`

## Subtasks & Detailed Guidance

### Subtask T014 – `SessionLogTail` [P]

- **File**: `src/Services/SessionLogTail.swift` (new)
- **API**:
  ```swift
  /// Incremental reader for an append-only JSONL session log (NFR-001, NFR-002).
  public struct SessionLogTail: Sendable {
      public static let seedLimit = 256 * 1024
      public struct Read: Sendable, Equatable {
          public let lines: [Data]     // complete, non-blank lines
          public let grew: Bool        // file size increased since the previous call
          public let bytesRead: Int
      }
      public private(set) var url: URL?
      private var offset: UInt64 = 0      // first byte not yet parsed (start of a partial line, if any)
      private var knownSize: UInt64 = 0   // file size seen at the previous call
      public init() {}
      /// Switches to `url` and returns complete lines from at most the last `seedLimit` bytes.
      public mutating func attach(to url: URL) -> Read
      /// Returns lines completed since the previous call.
      public mutating func readNew() -> Read
  }
  ```
- **Rules**:
  1. `attach`: size = file size (0 if missing); start = `max(0, size - seedLimit)`; read `start..<size`; if `start > 0`, drop bytes up to and including the first `\n` (partial first line); parse complete lines; set `offset` just after the last `\n`, `knownSize = size`; `grew = false`.
  2. `readNew`: size = current size. If `size < knownSize` (truncated/recreated) → `offset = size`, `knownSize = size`, return empty with `grew = false` (skip, don't replay). If `size == offset` → return `Read(lines: [], grew: size > knownSize, bytesRead: 0)` **without opening a read** past the size check. Else read `offset..<size`, split at the last `\n`: complete lines are returned, `offset` advances past the last `\n` only; `grew = size > knownSize`; `knownSize = size`.
  3. A partial trailing line is re-read next time but does **not** count as growth again (activity = bytes appended, R4).
  4. Lines split on `0x0A`; trim `\r`; drop lines that are empty or whitespace-only.
  5. Use `FileHandle(forReadingFrom:)`, `seek(toOffset:)`, `read(upToCount:)`; close via `defer`. Size via `FileManager.attributesOfItem(...)[.size]`.
- **Notes**: No `print`/logging of content.

### Subtask T015 – Session selection with hysteresis [P]

- **File**: `src/Services/SessionLogTail.swift`
- **API**:
  ```swift
  public static let idleSwitchDelay: TimeInterval = 10
  /// Picks the session to follow: the newest candidate, but never leaves `current` while it was modified within `idleSwitchDelay`.
  public static func pickSession(current: URL?, candidates: [(url: URL, modified: Date)], now: Date) -> URL?
  ```
- **Rules**: newest = max by `modified`. If `current` is nil or not among candidates → newest. If `current`'s modified date is within `idleSwitchDelay` of `now` → keep `current`. Else → newest.
- **Why**: concurrent sessions would otherwise flip the followed file every poll, reseeding 256 KB and resetting loop/stall state each time.

### Subtask T016 – `SessionLogEntry` + `AgentSessionTracker` [P]

- **File**: `src/Services/AgentSessionTracker.swift` (new)
- **Types**:
  ```swift
  public enum SessionLogEntry: Equatable, Sendable {
      case prompt
      case assistantOutput(contextTokens: Int?)
      case toolCall(id: String?, name: String, fingerprint: String)
      case toolResult(id: String?)        // id nil = clears all anonymous pending calls
      case approvalRequest                // e.g. Antigravity ask_question
      case turnEnd(isDone: Bool)
      case compaction
  }

  public struct AgentSessionTracker: Sendable {
      public static let loopThreshold = 4
      public let agentID: String
      public let agentName: String
      /// Antigravity starts a turn on the prompt; Claude Code on the first assistant output (R4).
      public let startsTurnOnPrompt: Bool
      public private(set) var turnActive = false
      public private(set) var latestContextTokens: Int? = nil
      public var pendingTools: Int { pendingIDs.count + anonymousPending }
      public init(agentID: String, agentName: String, startsTurnOnPrompt: Bool)
      public mutating func ingest(_ entries: [SessionLogEntry], at now: Date) -> [AgentEvent]
      public func usageEvent(at now: Date, seed: Bool) -> AgentEvent
      public mutating func reset()   // new session: everything fresh except identity
  }
  ```
- **Rules** (one event list per `ingest`, in entry order):
  - `prompt`: if `startsTurnOnPrompt` → `turnActive = true`, emit `working` ("\(agentName) is working..."); else `awaitingFirstOutput = true`.
  - `assistantOutput(t)`: `latestContextTokens = t ?? latestContextTokens`; if `awaitingFirstOutput` → `awaitingFirstOutput = false`, `turnActive = true`, emit `working`.
  - `toolCall(id, name, fp)`: id non-nil → `pendingIDs.insert(id)` else `anonymousPending += 1`. Loop: `fp == loopFingerprint ? loopCount += 1 : (loopFingerprint = fp, loopCount = 1, loopFired = false)`; when `loopCount >= loopThreshold && !loopFired` → `loopFired = true`, emit `warning` with message `"⚠️ \(agentName) may be stuck in a tool loop (\(name) ×\(loopCount))."` and metadata `[reason: "loop"]`.
  - `toolResult(id)`: id non-nil → `pendingIDs.remove(id)`; nil → `anonymousPending = 0`. Does **not** break the loop streak.
  - `approvalRequest`: emit `needsApproval` ("\(agentName) needs input!").
  - `turnEnd(isDone)`: if `turnActive || awaitingFirstOutput` → clear both, clear pending; emit `done` ("\(agentName) is done!") only if `isDone && wasTurnActive`. Otherwise no-op (duplicate end markers).
  - `compaction`: reset loop streak only.
  - `usageEvent`: kind `.usage`, metadata `pendingTools`, `turnActive`, `seed` ("true"/"false"), plus `contextTokens` when known.
- **Notes**: Messages must keep `"Antigravity is working..."` / `"Antigravity is done!"` byte-identical (existing tests).

### Subtask T017 – Tool-call fingerprint [P]

- **File**: `src/Services/AgentSessionTracker.swift`
- ```swift
  import CryptoKit
  /// Tool name + SHA-256 of the input serialized with sorted keys; identical inputs match regardless of key order (R6).
  public static func fingerprint(name: String, input: Any?) -> String
  ```
  Serialize with `JSONSerialization.data(withJSONObject:options: [.sortedKeys, .fragmentsAllowed])` when `JSONSerialization.isValidJSONObject(input)` or input is a scalar; `nil`/unserializable → empty `Data`. Return `name + ":" + hex(SHA256)`.

### Subtask T018 – `SessionLogTail` tests

- **File**: `Tests/BitzTests/SessionLogTailTests.swift` (new); temp dir per test, removed in `tearDown`.
- Cases:
  1. `testAttachToMissingFileReturnsNothing`.
  2. `testAttachSeedsAtMostLastSeedLimitBytesAndDropsPartialFirstLine` — write ~300 KB of numbered lines; assert first returned line is complete and total bytes ≤ `seedLimit`.
  3. `testReadNewReturnsOnlyAppendedCompleteLines`.
  4. `testNoNewBytesReadsZeroBytesAndNotGrew` (NFR-001).
  5. `testPartialLineIsCompletedNextReadAndCountsGrowthOnce`.
  6. `testBlankAndCRLFLinesHandled`.
  7. `testTruncationSkipsWithoutReplay`.
  8. `testPickSessionHysteresis` — newest wins with no current; current kept while modified 5 s ago; switches when current idle 11 s; current deleted → newest.

### Subtask T019 – `AgentSessionTracker` tests

- **File**: `Tests/BitzTests/AgentSessionTrackerTests.swift` (new)
- Cases:
  1. `testClaudeStyleTurnEmitsWorkingOnFirstOutputThenDone`.
  2. `testPromptWithoutOutputNeverStartsTurn` (local slash command) and `turnEnd(isDone:false)` emits nothing.
  3. `testAntigravityStyleTurnStartsOnPrompt`.
  4. `testLoopWarningFiresOnceAtFourIdenticalCalls` (3 → none; 4 → one; 5,6 → none).
  5. `testDifferentCallOrCompactionResetsLoop`; `testToolResultsAndTextDoNotBreakStreak`.
  6. `testPendingToolsTrackIDsAndAnonymous`.
  7. `testUsageEventCarriesMetadata` (tokens, pending, turnActive, seed).
  8. `testFingerprintIgnoresKeyOrderAndDiffersOnValue`.
  9. `testResetClearsStateButKeepsIdentity`.
  10. `testDuplicateTurnEndEmitsSingleDone`.

## Test Strategy

- TDD per subtask; all tests are deterministic (explicit dates, temp files). Run `xcrun swift test --filter SessionLogTailTests` / `--filter AgentSessionTrackerTests`, then the full suite.

## Risks & Mitigations

- **Large single append** (e.g. a big snapshot line): reading is bounded by appended size per poll; acceptable.
- **Hash cost**: SHA-256 over tool inputs is microseconds; only computed for tool calls.

## Review Guidance

- Verify `grew` semantics with a partial line (T014 rule 3) — this is what keeps stall detection honest.
- Verify no line text is stored in any property.

## Activity Log

- 2026-10-30T13:37:15Z – system – Prompt created.
