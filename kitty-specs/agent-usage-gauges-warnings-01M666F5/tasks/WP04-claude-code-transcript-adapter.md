---
work_package_id: WP04
title: Claude Code Transcript Adapter
dependencies:
- WP03
requirement_refs:
- C-003
- FR-004
- FR-005
- FR-008
- FR-014
- NFR-004
planning_base_branch: feat/issue-38-agent-gauges-warnings
merge_target_branch: feat/issue-38-agent-gauges-warnings
branch_strategy: Planning artifacts for this mission were generated on feat/issue-38-agent-gauges-warnings. During /spec-kitty.implement this WP may branch from a dependency-specific base, but completed changes must merge back into feat/issue-38-agent-gauges-warnings unless the human explicitly redirects the landing branch.
subtasks:
- T020
- T021
- T022
phase: Phase 2 - Adapters
history:
- !!omap
  - at: '2026-10-30T13:37:15Z'
  - actor: system
  - action: Prompt generated via /spec-kitty.tasks
agent_profile: implementer-ivan
authoritative_surface: src/Services/ClaudeCodeTranscriptAdapter.swift
create_intent:
- src/Services/ClaudeCodeTranscriptAdapter.swift
- Tests/BitzTests/ClaudeCodeTranscriptAdapterTests.swift
execution_mode: code_change
model: ''
owned_files:
- src/Services/ClaudeCodeTranscriptAdapter.swift
- Tests/BitzTests/ClaudeCodeTranscriptAdapterTests.swift
role: implementer
tags: []
task_type: implement
tracker_refs: []
---

# Work Package Prompt: WP04 – Claude Code Transcript Adapter

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

A new `ClaudeCodeTranscriptAdapter` follows the active **top-level** Claude Code session log and emits `working`, `done`, loop `warning`, and `usage` events via WP03's `SessionLogTail` + `AgentSessionTracker` (FR-004, FR-005, FR-008, FR-014). No hooks, no writes anywhere (C-003). Done when fixture tests in a temp `projects/` directory reproduce the expected event sequences, including subagent/sidechain exclusion and silent seeding. Wiring into the app happens in WP06.

Definition of Done also includes:
- No new compiler warnings, measured with a clean build (`xcrun swift build --scratch-path "$(mktemp -d)" 2>&1 | grep 'warning:' | sort -u`): the only allowed lines are the 3 pre-existing Swift 6 warnings at `src/Views/MascotOverlayView.swift:142` (from #61), which WP06 removes. Incremental builds hide warnings, so don't use them for this check (charter quality gate; SwiftLint is not configured in this repo).

## Context & Constraints

- Read: `research.md` (Verified session-log facts, R3–R7), `data-model.md` (Adapter-side tracker).
- Pattern to mirror: `src/Services/AntigravityTranscriptAdapter.swift` (class shape, `@unchecked Sendable`, `NSLock`, 1.5 s poll `Task`, `setHandlerForTesting`, `checkForUpdates()` public for tests).
- Session logs: `~/.claude/projects/<project-dir>/<session-uuid>.jsonl`. Subagent logs live deeper (`<project-dir>/<session-uuid>/…/*.jsonl`) and must be ignored.
- NFR-004: read line text only transiently (interrupt marker prefix check); store nothing but tokens, tool names, fingerprints.

## Branch Strategy

- **Planning base branch**: `feat/issue-38-agent-gauges-warnings`
- **Merge target branch**: `feat/issue-38-agent-gauges-warnings`
- Execution worktrees are allocated per computed lane from `lanes.json`.
- Implementation command: `spec-kitty agent action implement WP04 --agent claude`

## Subtasks & Detailed Guidance

### Subtask T020 – Line parser → `SessionLogEntry`

- **File**: `src/Services/ClaudeCodeTranscriptAdapter.swift`
- ```swift
  /// Maps one Claude Code session-log line to tracker entries; unknown or sidechain lines yield [] (NFR-006).
  public static func entries(fromLine data: Data) -> [SessionLogEntry]
  ```
- **Rules** (`JSONSerialization` → `[String: Any]`, else `[]`):
  1. `isSidechain == true` → `[]`.
  2. `type == "assistant"`, `message` dict:
     - tokens = sum of `usage.input_tokens`, `usage.cache_creation_input_tokens`, `usage.cache_read_input_tokens` (missing parts = 0; no `usage` → `nil`) → `.assistantOutput(contextTokens:)` first.
     - each `content[]` block with `type == "tool_use"` → `.toolCall(id: block["id"], name: block["name"], fingerprint: AgentSessionTracker.fingerprint(name:input: block["input"]))`.
     - `stop_reason == "end_turn"` → `.turnEnd(isDone: true)` last.
  3. `type == "user"` (skip when `isMeta == true`), `message.content`:
     - array with `tool_result` blocks → `.toolResult(id: block["tool_use_id"])` each.
     - text (string content, or `text` blocks) starting with `"[Request interrupted"` → `.turnEnd(isDone: false)`.
     - other text without tool results → `.prompt`.
  4. `type == "system"`: `subtype` `turn_duration` or `stop_hook_summary` → `.turnEnd(isDone: false)`; `compact_boundary` → `.compaction`.
  5. Anything else (`attachment`, `file-history-snapshot`, `api-request*`, …) → `[]`.

### Subtask T021 – Adapter: discovery, polling, seeding

- **API** (mirror Antigravity):
  ```swift
  public final class ClaudeCodeTranscriptAdapter: AgentAdapter, @unchecked Sendable {
      public let id = "claude-code-transcript-adapter"
      public let agentID = "claude"           // matches AgentDefinition.builtInCatalog id
      public let agentName = "Claude"
      public static var defaultProjectsURL: URL { home/.claude/projects }
      public init(projectsURL: URL = defaultProjectsURL, pollInterval: TimeInterval = 1.5, clock: @escaping @Sendable () -> Date = { Date() })
      public func setHandlerForTesting(_ onEvent: @escaping @Sendable (AgentEvent) -> Void)
      public func start(onEvent:)      // attach to the current session (seed) then poll
      public func stop()
      public func checkForUpdates()    // one poll, public for tests
      public func sessionCandidates() -> [(url: URL, modified: Date)]  // depth-1 *.jsonl only
  }
  ```
- **Poll (`checkForUpdates`, under `lock`)**:
  1. `let chosen = SessionLogTail.pickSession(current: tail.url, candidates: sessionCandidates(), now: clock())`.
  2. If `chosen != tail.url` → `seed = tail.attach(to: chosen)`; `tracker.reset()`; tokens = last non-nil `contextTokens` from parsing seed lines (parse only; **do not** ingest into the tracker); if tokens found → emit `usage` with `seed: true` and `contextTokens`. Return.
  3. Else `read = tail.readNew()`; if `!read.grew && read.lines.isEmpty` → return. Events = `tracker.ingest(read.lines.flatMap(Self.entries), at: now)`; emit each; then if `read.grew` emit `tracker.usageEvent(at: now, seed: false)`.
- **Discovery**: `contentsOfDirectory(projectsURL)` → each subdirectory → its direct `*.jsonl` children with `.contentModificationDateKey`. No recursion.
- **start**: store handler, run one `checkForUpdates()` (attaches + seeds), then start the poll task. `stop` cancels, clears handler, resets tail/tracker.
- **Tracker**: `AgentSessionTracker(agentID: "claude", agentName: "Claude", startsTurnOnPrompt: false)`.

### Subtask T022 – Fixture tests

- **File**: `Tests/BitzTests/ClaudeCodeTranscriptAdapterTests.swift` (new); temp `projects/` per test; collector class like `AntigravityTranscriptAdapterTests`; inject a fixed clock.
- Build fixture lines with small helpers (no real transcript content), e.g.:
  ```swift
  func assistant(tokens: (Int, Int, Int)? = (1000, 0, 50_000), tools: [(id: String, name: String, input: [String: Any])] = [], stop: String? = "tool_use", sidechain: Bool = false) -> String
  func userPrompt(_ text: String = "do it") -> String
  func toolResult(_ id: String) -> String
  func system(_ subtype: String) -> String
  ```
- Cases:
  1. `testParserMapsAssistantUserAndSystemLines` (pure `entries(fromLine:)`).
  2. `testParserSkipsSidechainMetaAndUnknownLines`.
  3. `testFullTurnEmitsWorkingThenDoneAndUsage` — prompt → assistant(tool_use) → tool_result → assistant(end_turn); filter by kind and assert order `[.working, .done]` plus `usage` events with final `contextTokens` and `turnActive == false`.
  4. `testLocalCommandPromptWithoutReplyEmitsNoWorking`.
  5. `testInterruptEndsTurnSilently`.
  6. `testFourIdenticalToolCallsEmitOneLoopWarning` (`metadata.reason == "loop"`).
  7. `testPendingToolReportedWhileToolRuns`.
  8. `testIgnoresNestedSubagentLogs` — nested file modified later than the top-level one is never followed.
  9. `testStartupSeedsUsageSilentlyFromTail` — pre-existing file with an assistant line → first poll emits exactly one `usage` with `isSeed == true` and no working/done/warning.
  10. `testSwitchesToNewerSessionOnlyAfterIdleDelay` (advance clock past `SessionLogTail.idleSwitchDelay`).

## Test Strategy

- Pure parser tests first, then adapter polls driven by `checkForUpdates()` (no sleeps). Run `xcrun swift test --filter ClaudeCodeTranscriptAdapterTests` then the full suite.

## Risks & Mitigations

- **Format drift**: every field access is optional; unknown shapes return `[]`.
- **Directory scan cost**: depth-1 only; ~100 stats per 1.5 s poll measured acceptable (NFR-001); revisit if WP09's resource check fails.
- **Duplicate `done`** with the existing Stop hook: acceptable (spec Assumptions); no dedupe.

## Review Guidance

- Check depth-1 discovery and `isSidechain` skip.
- Check seed path never calls `tracker.ingest`.
- Check no line text is retained.

## Activity Log

- 2026-10-30T13:37:15Z – system – Prompt created.
