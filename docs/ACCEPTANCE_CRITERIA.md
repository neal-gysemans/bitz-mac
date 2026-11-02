# Bitz macOS Desktop Companion — Acceptance Criteria & Verification Matrix

## 1. Functional Requirements Traceability (`FR-001`–`FR-012`)

| ID | Requirement Summary | Implementation Surface | Automated Verification Test(s) | Status |
| :--- | :--- | :--- | :--- | :--- |
| `FR-001` | Transparent Click-Through Desktop Overlay (`MascotOverlayPanel`, `250x250`, bottom-right `maxX - 270`, `minY + 20`, `ignoresMouseEvents = true`, `.floating`, all spaces) | `src/App/Window/MascotOverlayPanel.swift` | `MascotOverlayPanelTests.testOverlayPanelWindowInvariantsMatchContractByteForByte`, `testBottomRightOriginCalculationAndScreenPositioning` | PASS |
| `FR-002` | Wellness Point Engine & Scoring Mechanics (`50.0` start, `+0.5` productive, `-1.5` unproductive, `+5.0/min` break `> 2.0` min, `0.0...100.0` clamp, hardened against non-finite values) | `src/Services/WellnessPointEngine.swift` | `WellnessPointEngineTests.testInitialDefaultStateIsBalancedAtFiftyPoints`, `testProductiveWorkTickAddsHalfPointAndTransitionsToSuperCharged`, `testProductiveWorkTickClampsAtOneHundredPoints`, `testUnproductiveWorkTickDrainsIntoDopamineSadAndClampsAtZero`, `testExactBoundaryThresholds`, `testNaNInitialPointsDoesNotPoisonEngineAndFallsBackToDefaultPoints`, `testSetPointsWithNonFiniteValuesSafelySanitizesToDefault`, `testEvaluateWorkTickWithNaNDurationDoesNotCorruptWorkStreak`, `testEvaluateWorkTickWithNegativeDurationClampsToZero`, `testApplyOfflineBreakWithNonFiniteOrNegativeMinutesDoesNotCorruptState`, `testStateForPointsWithNonFiniteAndOutOfRangePoints` | PASS |
| `FR-003` | Reactive Rive State Machine Bridge (`BitzStateMachine` inputs: `speedMultiplier = 0.6` charging, `2.5` overheating, `visorColor`, `isStandby = false` overheating, `isGlitching`) | `src/Services/WellnessPointEngine.swift` | `WellnessPointEngineTests.testRiveContractConstantsMatchSpecificationByteForByte`, `testExactBoundaryThresholds`, `testProductionRiveControllerStoresInputsAndInvokesCallback`, `testOverheatingRiveStateFullySynchronizedFromBurnout`, `testChargingRiveStateSpeedMultiplierMatchesStateMachineSpecification` | PASS |
| `FR-004` | Thermal Overheating Override & Speech Bubble Warning (`"SYSTEM HOT! > <"`, `isGlitching = true`, `visorColor = 3.0` Red, speed 2.5, state recovery) | `src/Services/WellnessPointEngine.swift`, `src/Views/MascotOverlayView.swift` | `WellnessPointEngineTests.testThermalWarningOverridesStateAndRestoresUnderlyingStateWhenCleared`, `ActivityMonitorServiceTests.testThermalOverheatingByTemperatureAndThermalStateAndRecovery` | PASS |
| `FR-005` | Privacy-Safe Foreground App & Idle Activity Monitoring (`NSWorkspace`, `CGEventSource`, `ProcessInfo.ThermalState`) | `src/Services/ActivityMonitorService.swift` | `ActivityMonitorServiceTests.testProductiveBundleIDClassification`, `testProductiveAndUnproductiveSampleTicksUpdateWellnessEngine`, `testIdleBreakEntryEntersChargingModeAndRecovers`, `testLongOfflineBreakRestoresWellnessPointsAndClearsBurnout`, `testActiveVideoPlaybackPreventsChargeModeWhenHandsFree`, `testWatchingYouTubeOrNetflixHandsFreeDoesNotEnterChargeModeAndContinuesDrainingPoints` | PASS |
| `FR-006` | Pet Interaction Trigger & Debounced Task Lifecycle (`triggerPet` via `triggerPetInteraction()` and `MenuBarExtra`, with cancellation debounce) | `src/Services/WellnessPointEngine.swift`, `src/App/BitzApp.swift` | `WellnessPointEngineTests.testTriggerPetInteractionFiresRiveTriggerPetInput`, `WellnessPointEngineTests.testRapidPetInteractionDebouncesAndCancelsPreviousDismissal`, `MascotOverlayPanelTests.testBitzAppDelegateLifecycleWiresOverlayPanelAndActivityMonitor` | PASS |
| `FR-007` | Living Project Documentation (`docs/ARCHITECTURE.md`, `docs/STATE_MACHINE.md`, `docs/ACCEPTANCE_CRITERIA.md`, `REPORT.md`) | `docs/`, `REPORT.md` | Verified in Milestone 4 (`F13`, `F14`, `F15`) | PASS |
| `FR-008` | Manual Avatar Resizing & Scale Persistence (`AvatarScaleStore`, `AvatarSizePreset` `60%`/`80%`/`100%`/`125%`/`150%`, `±10%` steps clamped to `50%...175%`, proportional `MascotOverlayPanel` & `MascotOverlayView` scaling, `UserDefaults` `"avatarScaleFactor"`) | `src/App/Window/MascotOverlayPanel.swift`, `src/Views/MascotOverlayView.swift`, `src/App/BitzApp.swift` | `MascotOverlayPanelTests.testAvatarScaleStoreDefaultPresetsAndStepClamping`, `testAvatarScaleStoreUserDefaultsPersistenceAndSanitization`, `testPanelProportionalScalingAndBottomRightReAnchoring`, `testBitzAppDelegateRestoresPersistedScaleAndUpdatesPanel` | PASS |
| `FR-009` | See-Through Mascot Opacity & Hologram Modes (`AvatarOpacityStore`, `AvatarOpacityPreset` `100%`/`80%`/`60%`/`40%`/`25%`, `±10%` steps clamped to `20%...100%`, `UserDefaults` `"avatarOpacityFactor"`) | `src/App/Window/MascotOverlayPanel.swift`, `src/Views/MascotOverlayView.swift`, `src/App/BitzApp.swift` | `MascotOverlayPanelTests.testAvatarOpacityStoreDefaultPresetsAndClamping` | PASS |
| `FR-010` | 4-Corner Desktop Positioning (`ScreenCornerAnchor` `.bottomRight`, `.bottomLeft`, `.topRight`, `.topLeft`, `repositionOnScreen()`, `UserDefaults` `"avatarCornerAnchor"`) | `src/App/Window/MascotOverlayPanel.swift`, `src/App/BitzApp.swift` | `MascotOverlayPanelTests.testScreenCornerAnchorsAndRepositioning` | PASS |
| `FR-011` | State & Sleep/Wake Session Persistence & Invariant Hardening (`UserDefaults` PTS, continuous work streak, `NSWorkspace` sleep/wake break crediting without double-counting, skew & epoch rejection, isolated test suites) | `src/Services/WellnessPointEngine.swift`, `src/Services/ActivityMonitorService.swift` | `WellnessPointEngineTests.testWellnessPointEnginePersistenceAndOfflineBreakRestoration`, `WellnessPointEngineTests.testPersistenceRejectsEpochZeroTimestampAndDoesNotGrantFiftyFourYearBreak`, `WellnessPointEngineTests.testPersistenceRejectsFutureTimestampBeyondAllowedSkew`, `WellnessPointEngineTests.testPersistenceWithBackwardClockSkewClampsToZeroElapsed`, `WellnessPointEngineTests.testEnginePersistenceUsesIsolatedUserDefaultsSuiteWithoutStandardLeakage`, `ActivityMonitorServiceTests.testSleepAndWakeBreakDoubleCountingPrevention`, `ActivityMonitorServiceTests.testSuccessiveSleepNotificationsPreserveInitialSleepTimestamp`, `ActivityMonitorServiceTests.testSleepWakeWithNegativeElapsedClockSkewDoesNotAwardBreak`, `ActivityMonitorServiceTests.testCustomAppRulesAndSleepWakeHandling` | PASS |
| `FR-012` | Browser Tab Inspection & Custom App Rules (Single-lookup `activeBrowserTab()`, Chromium SNSS session extraction, Firefox session recovery, Safari AppleScript, 1-click custom rules) | `src/Services/ActivityMonitorService.swift`, `src/App/BitzApp.swift` | `ActivityMonitorServiceTests.testChromiumSNSSSessionURLExtractionSupportsOtherBrowsers`, `ActivityMonitorServiceTests.testCustomAppRulesAndSleepWakeHandling` | PASS |

---

## 2. Test Suite Structure (49 Tests Across 3 Suites)

This is the baseline listing from the original mission. The suite has since grown; current totals are in §5.4.

The unit test suite consists of **49 tests** executed with zero failures:

1. **`ActivityMonitorServiceTests` (13 tests)**:
   - `testActiveVideoPlaybackPreventsChargeModeWhenHandsFree`
   - `testChromiumSNSSSessionURLExtractionSupportsOtherBrowsers`
   - `testCustomAppRulesAndSleepWakeHandling`
   - `testIdleBreakEntryEntersChargingModeAndRecovers`
   - `testLongOfflineBreakRestoresWellnessPointsAndClearsBurnout`
   - `testProductiveAndUnproductiveSampleTicksUpdateWellnessEngine`
   - `testProductiveBundleIDClassification`
   - `testSleepAndWakeBreakDoubleCountingPrevention`
   - `testSleepWakeWithNegativeElapsedClockSkewDoesNotAwardBreak`
   - `testStartAndStopMonitoringLifecycleAndSystemProvider`
   - `testSuccessiveSleepNotificationsPreserveInitialSleepTimestamp`
   - `testThermalOverheatingByTemperatureAndThermalStateAndRecovery`
   - `testWatchingYouTubeOrNetflixHandsFreeDoesNotEnterChargeModeAndContinuesDrainingPoints`

2. **`MascotOverlayPanelTests` (10 tests)**:
   - `testAvatarOpacityStoreDefaultPresetsAndClamping`
   - `testAvatarScaleStoreDefaultPresetsAndStepClamping`
   - `testAvatarScaleStoreUserDefaultsPersistenceAndSanitization`
   - `testBitzAppDelegateLifecycleWiresOverlayPanelAndActivityMonitor`
   - `testBitzAppDelegateRestoresPersistedScaleAndUpdatesPanel`
   - `testBottomRightOriginCalculationAndScreenPositioning`
   - `testMascotOverlayViewVisorColorMappingAndRendering`
   - `testOverlayPanelWindowInvariantsMatchContractByteForByte`
   - `testPanelProportionalScalingAndBottomRightReAnchoring`
   - `testScreenCornerAnchorsAndRepositioning`

3. **`WellnessPointEngineTests` (26 tests)**:
   - `testApplyOfflineBreakWithNonFiniteOrNegativeMinutesDoesNotCorruptState`
   - `testChargingRiveStateSpeedMultiplierMatchesStateMachineSpecification`
   - `testChargingStateAndOfflineBreakRestoration`
   - `testContinuousWorkWithoutBreakTriggersOverworkedAndBurnout`
   - `testEnginePersistenceUsesIsolatedUserDefaultsSuiteWithoutStandardLeakage`
   - `testEvaluateWorkTickWithNaNDurationDoesNotCorruptWorkStreak`
   - `testEvaluateWorkTickWithNegativeDurationClampsToZero`
   - `testExactBoundaryThresholds`
   - `testInitialDefaultStateIsBalancedAtFiftyPoints`
   - `testInitialPointsClampToZeroAndOneHundred`
   - `testNaNInitialPointsDoesNotPoisonEngineAndFallsBackToDefaultPoints`
   - `testOverheatingRiveStateFullySynchronizedFromBurnout`
   - `testPersistenceRejectsEpochZeroTimestampAndDoesNotGrantFiftyFourYearBreak`
   - `testPersistenceRejectsFutureTimestampBeyondAllowedSkew`
   - `testPersistenceWithBackwardClockSkewClampsToZeroElapsed`
   - `testProductionRiveControllerStoresInputsAndInvokesCallback`
   - `testProductiveWorkTickAddsHalfPointAndTransitionsToSuperCharged`
   - `testProductiveWorkTickClampsAtOneHundredPoints`
   - `testRapidPetInteractionDebouncesAndCancelsPreviousDismissal`
   - `testRiveContractConstantsMatchSpecificationByteForByte`
   - `testSetPointsWithNonFiniteValuesSafelySanitizesToDefault`
   - `testStateForPointsWithNonFiniteAndOutOfRangePoints`
   - `testThermalWarningOverridesStateAndRestoresUnderlyingStateWhenCleared`
   - `testTriggerPetInteractionFiresRiveTriggerPetInput`
   - `testUnproductiveWorkTickDrainsIntoDopamineSadAndClampsAtZero`
   - `testWellnessPointEnginePersistenceAndOfflineBreakRestoration`

---

## 3. Non-Functional Requirements & Constraints Verification (`NFR-001`–`NFR-004`, `C-001`–`C-004`)

| ID | Requirement / Constraint | Verification Method & Measured Result | Status |
| :--- | :--- | :--- | :--- |
| `NFR-001` | `< 2%` average CPU usage on Apple Silicon | Coalesced main run loop timer (`tolerance = intervalSeconds * 0.2`) in `ActivityMonitorService.startMonitoring(intervalSeconds:)` with zero busy-wait loops and single-lookup tab caching (`activeBrowserTab()`). Measured 2026-10-31 (M4 Max, release build, idle, `top` 10 s samples): **~42%** of one core on the PR #62 build, mostly SwiftUI timeline redraws of the mascot. Tracked in #70. | FAIL (#70) |
| `NFR-002` | `< 70MB` resident memory footprint at 60 FPS | Single `250x250` buffered `MascotOverlayPanel` canvas (`MascotOverlayPanel.defaultPanelSize`). Memory usage averages `< 35MB`. Screen observer token cleaned up on deinit. | PASS |
| `NFR-003` | `100%` mouse click-through (`0ms` interception) | WindowServer-level `ignoresMouseEvents = true` verified in `MascotOverlayPanelTests.testOverlayPanelWindowInvariantsMatchContractByteForByte`. | PASS |
| `NFR-004` | High unit test coverage across core domain & services | Measured via `/usr/bin/swift test --enable-code-coverage`: `WellnessPointEngine.swift` = **96.9% lines / 96.1% funcs**, `MascotOverlayPanel.swift` = **92.7% lines / 88.5% funcs**, `MascotOverlayView.swift` = **88.2% lines / 73.5% funcs**, `ActivityMonitorService.swift` = **61.0% lines / 64.4% funcs**, `MachCompatibility.swift` = **100% lines / 100% funcs**. | PASS |
| `C-001` | Zero Desktop Wallpaper Modification | Static code audit (`grep -rn "setDesktopImageURL" src/`) returns `0` matches. | PASS |
| `C-002` | macOS 14.0+ & Swift 6 Strict Concurrency | `Package.swift` uses `swift-tools-version: 6.0` and `.macOS(.v14)`; builds under `-Xswiftc -warnings-as-errors` with `0` warnings. | PASS |
| `C-003` | App Sandbox & Privacy Compliance | Static code audit (`grep -rn "AXIsProcessTrusted\|tapCreate" src/`) returns `0` matches. | PASS |
| `C-004` | Exact Rive Input Identifiers (`BitzStateMachine`) | Verified byte-for-byte in `WellnessPointEngineTests.testRiveContractConstantsMatchSpecificationByteForByte`. | PASS |

---

## 4. Automated Verification Commands

Run from the repository root using Xcode's toolchain:

```bash
# 1. Build all targets under Swift 6 strict concurrency with warnings as errors
/usr/bin/swift build -Xswiftc -warnings-as-errors

# 2. Execute the full unit test suite with code coverage enabled
/usr/bin/swift test --enable-code-coverage

# 3. Inspect per-file coverage summary
CODECOV_JSON=$(/usr/bin/swift test --show-codecov-path)
python3 -c 'import json, sys; data = json.load(open(sys.argv[1])); [print(f"{f[\"filename\"].split(\"/\")[-1]:32} | {round(f[\"summary\"][\"lines\"][\"percent\"], 1):5}% lines | {round(f[\"summary\"][\"functions\"][\"percent\"], 1):5}% functions") for exp in data["data"] for f in exp["files"] if "/src/" in f["filename"]]' "$CODECOV_JSON"

# 4. Verify zero forbidden wallpaper or keylogging/Accessibility APIs
! grep -rn "setDesktopImageURL\|AXIsProcessTrusted\|tapCreate" src/

# 5. Count compiler warnings in a clean build (incremental builds hide warnings); must print 0
xcrun swift build --scratch-path "$(mktemp -d)" 2>&1 | grep -c 'warning:'
```

---

## 5. Mission `agent-usage-gauges-warnings-01M666F5`: Agent Usage Gauges, Almost Done & Warnings (#38)

IDs in this section refer to the mission spec (`kitty-specs/agent-usage-gauges-warnings-01M666F5/spec.md`), not to §1–§3.

### 5.1 Functional Requirements (`FR-001`–`FR-014`)

| ID | Requirement Summary | Implementation Surface | Automated Verification Test(s) | Status |
| :--- | :--- | :--- | :--- | :--- |
| `FR-001` | Almost-Done Event: `almostDone` through the drop-box shows a distinct magenta-on-violet bubble that auto-dismisses after `6.0` s; toggle `almostDoneEnabled` | `src/Models/AgentModels.swift`, `src/Services/AgentMonitorService.swift`, `src/Views/SpeechBubbleView.swift`, `docs/agent-dropbox-event.schema.json` | `AgentModelsTests.testNewKindsDecode`, `DropboxAgentAdapterTests.testDropsV2EventWithMetadata`, `AgentSignalPolicyTests.testAlmostDonePopupAndToggle`, `AgentSignalPolicyTests.testWorkingAndAlmostDoneDoNotReplaceWarning`, `MascotOverlayLayoutTests.testAlmostDoneBubbleIsNotClippedByItsWindow` | PASS |
| `FR-002` | Warning Event: `warning` with `metadata.reason` ∈ `context` / `loop` / `stall` / `reported` (default `reported`), presented per `FR-010` | `src/Models/AgentModels.swift`, `src/Services/AgentMonitorService.swift` | `AgentModelsTests.testUnknownReasonFallsBackToReported`, `AgentSignalPolicyTests.testReportedWarningAlwaysShownAndLoopToggleRespected`, `DropboxAgentAdapterTests.testDropsV2EventWithMetadata` | PASS |
| `FR-003` | Event Details: optional string `metadata`; old payloads and the four original kinds decode unchanged; invalid numbers are ignored | `src/Models/AgentModels.swift`, `docs/agent-dropbox-event.schema.json` | `AgentModelsTests.testOldPayloadDecodesUnchanged`, `testMetadataDecodesStringsNumbersAndBools`, `testMalformedMetadataIsIgnoredNotFatal`, `testInvalidNumbersReturnNil`, `testMetadataRoundTripsThroughEncoding`, `DropboxAgentAdapterTests.testProcessesValidEventAndDeletesFile` | PASS |
| `FR-004` | Claude Code Session Tracking: depth-1 top-level session only (subagent logs and sidechain lines skipped); first reply → `working`, `end_turn` → `done`; a prompt without a reply starts no turn; no new hooks | `src/Services/ClaudeCodeTranscriptAdapter.swift`, `src/Services/AgentSessionTracker.swift`, `src/Services/SessionLogTail.swift`, `src/App/BitzApp.swift` | `ClaudeCodeTranscriptAdapterTests.testParserMapsAssistantUserAndSystemLines`, `testParserSkipsSidechainMetaAndUnknownLines`, `testFullTurnEmitsWorkingThenDoneAndUsage`, `testLocalCommandPromptWithoutReplyEmitsNoWorking`, `testInterruptEndsTurnSilently`, `testIgnoresNestedSubagentLogs`, `testSwitchesToNewerSessionOnlyAfterIdleDelay`, `AgentSessionTrackerTests.testClaudeStyleTurnEmitsWorkingOnFirstOutputThenDone`, `testPromptWithoutOutputNeverStartsTurn`, `testDuplicateTurnEndEmitsSingleDone`, `ClaudeCodeTranscriptAdapterTests.testParserSkipsSyntheticAssistantLines` | PASS (limitations L1, L2) |
| `FR-005` | Context Usage Measure: Claude Code `input + cache_creation + cache_read` tokens, Antigravity `input + cache_read` tokens of the latest turn; percent of the agent's window, capped at 100 | `src/Services/ClaudeCodeTranscriptAdapter.swift`, `src/Services/AntigravityTranscriptAdapter.swift`, `src/Models/AgentModels.swift` | `ClaudeCodeTranscriptAdapterTests.testParserMapsAssistantUserAndSystemLines`, `AntigravityTranscriptAdapterTests.testReportsContextUsageFromPlannerTokens`, `AgentSessionTrackerTests.testUsageEventCarriesMetadata`, `AgentModelsTests.testContextReadingPercentAndText`, `AgentModelsTests.testContextPercentDoesNotOverflowOnHugeTokenCounts` | PASS (limitation L6) |
| `FR-006` | Context Gauge Display: AI Agents metric shows `Claude ctx 148k · 74%` (summary), ` · 74%` (badge) and ` 74%` (menu bar title); the last reading stays after the turn ends (idle: `No agents currently active · Claude ctx 148k · 74%`, `CTX 74%`, `Ctx 74%`) | `src/Models/TelemetryModels.swift`, `src/Services/TelemetryDashboardService.swift` | `TelemetryDashboardServiceTests.testAgentsMetricShowsContextInBadgeSummaryAndTitle`, `testAgentsMetricUnchangedWithoutContext`, `testDashboardKeepsLastContextReadingAfterTurnEnds`, `testLastContextReadingStaysVisibleWhenNoAgentIsActive` | PASS |
| `FR-007` | Context Warning: one warning at the threshold (default `90` %), re-armed below it; none for a seed reading | `src/Services/AgentMonitorService.swift` | `AgentSignalPolicyTests.testContextWarningFiresOnceAndRearms`, `testSeedReadingAboveThresholdDoesNotWarnButMarksFired`, `testContextWarningToggleOffSuppressesWarningButKeepsReading`, `testWindowChangeRecomputesPercent`, `AgentSignalIntegrationTests.testReplayedSessionCrossingThresholdWarnsExactlyOnce` | PASS |
| `FR-008` | Loop Warning: one warning at 4 identical consecutive tool calls (name + SHA-256 of sorted-key input); text does not break the streak; a different call, compaction or new session resets it | `src/Services/AgentSessionTracker.swift`, `src/Services/ClaudeCodeTranscriptAdapter.swift`, `src/Services/AntigravityTranscriptAdapter.swift` | `AgentSessionTrackerTests.testLoopWarningFiresOnceAtFourIdenticalCalls`, `testDifferentCallOrCompactionResetsLoop`, `testToolResultsAndTextDoNotBreakStreak`, `testFingerprintIgnoresKeyOrderAndDiffersOnValue`, `testResetClearsStateButKeepsIdentity`, `ClaudeCodeTranscriptAdapterTests.testFourIdenticalToolCallsEmitOneLoopWarning`, `AntigravityTranscriptAdapterTests.testFourIdenticalNameArgsCallsEmitOneLoopWarning`, `AgentSignalIntegrationTests.testReplayedLoopOfFourIdenticalCallsWarnsOnce` | PASS |
| `FR-009` | Stall Warning: 5 s sweep raises one warning when mid-turn, no pending tool, not awaiting approval and no appended bytes for the timeout (default `3` min) | `src/Services/AgentMonitorService.swift`, `src/Services/AgentSessionTracker.swift`, `src/Services/SessionLogTail.swift` | `AgentSignalPolicyTests.testStallFiresOnceAfterTimeout`, `testNoStallWhilePendingToolOrAwaitingApprovalOrAfterDone`, `testStallToggleOffSuppressesStall`, `testActivityResetsStall`, `AgentSignalIntegrationTests.testReplayedFinishedTurnNeverStalls`, `testReplayedMidTurnSilenceStalls`, `ClaudeCodeTranscriptAdapterTests.testPendingToolReportedWhileToolRuns`, `AntigravityTranscriptAdapterTests.testPendingClearedByNextLine`, `AgentSessionTrackerTests.testPendingToolsTrackIDsAndAnonymous`, `SessionLogTailTests.testPartialLineIsCompletedNextReadAndCountsGrowthOnce`, `AgentSignalPolicyTests.testAgentWithoutSessionLogNeverStalls`, `testStallSweepTimerRaisesWarning` | PASS |
| `FR-010` | Warning Lifecycle: single slot; cleared by **Got it**, menu **Dismiss Agent Warning**, or the same agent's `done` / `needsApproval` (never a `source = process` `done`); newer replaces older; another agent's approval overrides the bubble and the warning returns afterwards | `src/Services/AgentMonitorService.swift`, `src/Services/ProcessAgentAdapter.swift`, `src/Views/SpeechBubbleView.swift`, `src/App/BitzApp.swift` | `AgentSignalPolicyTests.testWorkingAndAlmostDoneDoNotReplaceWarning`, `testSameAgentDoneClearsWarning`, `testSameAgentApprovalClearsWarning`, `testOtherAgentDoneKeepsWarning`, `testOtherAgentApprovalOverridesThenWarningReturns`, `testNewerWarningReplacesOlder`, `testAcknowledgeClearsWarningAndBubble`, `testDismissPopupKeepsWarning`, `testProcessPresenceDoneDoesNotClearWarningOrEndTurn`, `testStopMonitoringClearsSignalState`, `ProcessAgentAdapterTests.testDetectsStartedAndExitedAgent`, `MenuBarContentViewTests.testMenuBarShowsDismissForActiveWarning`, `SpeechBubblePanelTests.testWarningBubbleTakesClicksOnlyUntilAcknowledged`, `AgentWarningPresentationTests.testOnlyWarningAgentPopupIsInteractive`, `AgentSignalPolicyTests.testWarningWaitsBehindAnotherAgentsApproval` | PASS |
| `FR-011` | Amber Visor: `setWarningVisor(active:)` pushes `visorColor = 2.0` unless overheating; drawn visor matches; wellness state and thresholds unchanged | `src/Services/WellnessPointEngine.swift`, `src/Views/MascotOverlayView.swift`, `src/App/BitzApp.swift` | `WellnessPointEngineTests.testWarningVisorDrivesRiveAmberAndMatchesDrawnVisor`, `AgentWarningPresentationTests.testVisorAmberWhileWarningVisorActiveForEveryStateExceptOverheating`, `testVisorUnchangedWithoutWarningVisor`, `SpeechBubblePanelTests.testWarningBubbleTakesClicksOnlyUntilAcknowledged` | PASS |
| `FR-012` | Signal Settings: per-signal toggles, threshold `50...99` % (stepper step `5`), stall timeout `1...30` min, window per agent (200k / 1M / Custom); clamped, persisted, applied immediately | `src/Models/AgentModels.swift`, `src/Services/AgentMonitorService.swift`, `src/Views/Settings/AgentsSettingsTabView.swift` | `AgentModelsTests.testSignalSettingsDefaults`, `testSignalSettingsClamp`, `testSignalSettingsPartialDecodeKeepsDefaults`, `testSignalSettingsWarningToggles`, `AgentSignalPolicyTests.testSettingsDefaultWhenNothingStored`, `testSettingsPersistAndReloadClamped`, `SettingsViewsTests.testAgentSignalsCardSettingsPersistAndClamp`, `testContextWindowBindingsIgnoreInvalidTokensAndDeriveCustom` | PASS |
| `FR-013` | Existing Toggles Respected: bubbles off hides bubbles only (warning state, visor and gauge still update); disabling an agent clears its warning and reading | `src/Services/AgentMonitorService.swift` | `AgentSignalPolicyTests.testPopupsDisabledKeepsWarningStateWithoutBubble`, `testDisablingAgentClearsWarningReadingAndSession`, `testDisablingApprovingAgentRestoresWarningBubble`, `AgentMonitorServiceTests.testPopupsDisabledOptionSuppressesPopups` | PASS (limitation L4) |
| `FR-014` | Quiet Startup: ≤ 256 KB seed; `prime(fromSeed:)` restores a turn in progress without bubbles; loop streak fresh; seed `usage` never warns | `src/Services/SessionLogTail.swift`, `src/Services/AgentSessionTracker.swift`, `src/Services/ClaudeCodeTranscriptAdapter.swift`, `src/Services/AntigravityTranscriptAdapter.swift`, `src/Services/AgentMonitorService.swift` | `SessionLogTailTests.testAttachSeedsAtMostLastSeedLimitBytesAndDropsPartialFirstLine`, `ClaudeCodeTranscriptAdapterTests.testStartupSeedsUsageSilentlyFromTail`, `testFirstTurnInProgressOnAttachIsTracked`, `testAttachMidTurnEndsWithSingleDone`, `testSeedUsageEmittedWithoutTokensForFinishedSeed`, `AntigravityTranscriptAdapterTests.testStartupSeedIsSilent`, `testAttachMidTurnTracksTurnToDone`, `testAttachAfterFinishedTurnSeedsInactiveTurn`, `AgentSessionTrackerTests.testPrimeClaudeSeedAwaitingFirstOutputPicksUpTurn`, `testPrimeClaudeSeedMidTurnEndsWithSingleDone`, `testPrimeAntigravitySeedPromptMarksTurnActive`, `testPrimeSeedEndingWithTurnEndLeavesNoTurn`, `testPrimeClearsLoopStreak`, `testPrimeAfterResetYieldsOnlySeedState`, `AgentSessionTrackerTests.testPrimeSeedWithoutPromptButOutputSinceLastEndIsActive` | PASS (limitation L3) |

### 5.2 Non-Functional Requirements & Constraints

| ID | Requirement / Constraint | Verification Method & Result | Status |
| :--- | :--- | :--- | :--- |
| `NFR-001` | Incremental reads, polls no more often than every 1.5 s | `SessionLogTailTests.testNoNewBytesReadsZeroBytesAndNotGrew`, `testReadNewReturnsOnlyAppendedCompleteLines`, `testTruncationSkipsWithoutReplay`; both adapters poll every `1.5` s., `SessionLogTailTests.testFailedStatDoesNotReplayFromStart`, `testIsCurrentFreshFollowsModificationDate` | PASS |
| `NFR-002` | At most the last 256 KB read on attach | `SessionLogTailTests.testAttachSeedsAtMostLastSeedLimitBytesAndDropsPartialFirstLine` | PASS |
| `NFR-003` | Bubble or warning within 5 s of the log line | Drop-box path, manual timed step (2026-10-31): 3 runs of a dropped warning, each bubble appeared instantly (< 1 s). Session-log path not timed: it is bounded by the 1.5 s poll plus main-actor dispatch. | PASS (drop-box path) |
| `NFR-004` | Only token counts, tool names and fingerprints kept, in memory | Code review: `SessionLogEntry` carries no line text; `SessionLogTail` keeps only the URL and byte offsets; user text is only prefix-checked for `[Request interrupted`. `AgentSessionTrackerTests.testFingerprintIgnoresKeyOrderAndDiffersOnValue` | PASS |
| `NFR-005` | New settings in an injectable defaults domain | `AgentMonitorService(userDefaults:)`; new tests use `UserDefaults(suiteName:)` with cleanup, e.g. `AgentSignalPolicyTests.testSettingsPersistAndReloadClamped` | PASS |
| `NFR-006` | Malformed, partial and unknown lines skipped | `ClaudeCodeTranscriptAdapterTests.testParserSkipsSidechainMetaAndUnknownLines`, `AntigravityTranscriptAdapterTests.testLineParserRules`, `SessionLogTailTests.testBlankAndCRLFLinesHandled`, `testPartialLineIsCompletedNextReadAndCountsGrowthOnce`, `AgentModelsTests.testMalformedMetadataIsIgnoredNotFatal` | PASS |
| `C-002` | Overlay invariants: warning bubble takes clicks only while **GOT IT** is shown | `SpeechBubblePanelTests.testWarningBubbleTakesClicksOnlyUntilAcknowledged`, `AgentWarningPresentationTests.testOnlyWarningAgentPopupIsInteractive` | PASS |
| `C-003` | No new hooks, no writes to Claude Code settings | Code audit: `ClaudeCodeTranscriptAdapter` only reads; `AgentHookInstaller.swift` unchanged by this mission. | PASS |
| `C-004` | No cost, rate-limit or CPU alerts | Code audit: `AgentWarningReason` is limited to `context`, `loop`, `stall`, `reported`. | PASS |
| `C-005` | Nothing drawn outside its window | `MascotOverlayLayoutTests.testWarningBubbleWithButtonAtLargestScaleIsNotClippedByItsWindow`, `testAlmostDoneBubbleIsNotClippedByItsWindow`, `testMascotWithWarningVisorStaysInsidePanel` | PASS |

### 5.3 Known Limitations

| # | Limitation | Affects |
| :--- | :--- | :--- |
| `L1` | An image-only Claude Code prompt has no text block, so it is not read as a prompt and that turn shows no working or done bubble. Usage readings still update. | `FR-004` |
| `L2` | After an auto-compaction, the summary line Claude Code logs can be parsed as a new prompt, so the next assistant line may show one extra "working" bubble. | `FR-004` |
| `L3` | A pending approval that existed before Bitz attached is not re-shown, because seed priming emits no events. | `FR-014` |
| `L4` | With agent speech bubbles off, wellness and carousel bubble borders keep their state colour while the visor is Amber. | `FR-013` |
| `L5` | Resolved: the Antigravity flat `{name, args}` `ask_question` lookup from PR #65 (#63) is carried into this branch. | Antigravity approvals |
| `L6` | Session logs do not state the model's window size. The Claude Code default of 200k is wrong for 1M-context models; raw tokens are shown next to the percent, and the window is configurable. | `FR-005`, `FR-006` |
| `L7` | After an approval request, stall detection stays off for that turn until the agent's next `working` or `done` (fails safe: a missed stall warning, never a false one). | `FR-009` |
| `L8` | A session killed mid-turn (no turn end in its log) counts as an active turn when Bitz attaches to it, so it can raise one stall warning after the timeout. | `FR-009`, `FR-014` |

### 5.4 Verification Results

- 2026-10-30: clean production build (`xcrun swift build --scratch-path "$(mktemp -d)"`): **0** warnings.
- 2026-10-30: clean test build (`--build-tests`, same fresh scratch path): **0** warnings.
- 2026-10-30: `xcrun swift test`: `Executed 258 tests, with 0 failures (0 unexpected)` across 26 XCTest suites.
- Release run and quickstart walkthrough (2026-10-31, macOS 26.6.2, M4 Max), §1–§5: all pass. That covers almost-done, context and reported warnings, **GOT IT**, the approval override and its restore, menu **Dismiss Agent Warning** with bubbles on and off, a live Claude Code turn with a 90 s tool call and the stall timeout set to 1 min, with no stall warning during or after it, and settings that survive a relaunch. Not run live: §4.4 (quitting the Claude desktop app; `AgentSignalPolicyTests` cover it) and §3's timed loop warning from a real Claude session; no stall, loop or context warning was observed from a real session log (covered by `AgentSignalIntegrationTests` replays).
- 2026-10-31, after merging `main` (PR #65–#67; PR #65's flat `ask_question` lookup ported into the rewritten Antigravity adapter): clean build with tests, **0** warnings; `xcrun swift test`: `Executed 260 tests, with 0 failures (0 unexpected)`.
- 2026-10-31, after the independent pre-review fixes (PR #71): clean build with tests, **0** warnings; `xcrun swift test`: `Executed 269 tests, with 0 failures (0 unexpected)`.
- `NFR-003` latency (drop-box path): 3 timed runs, each < 1 s.
- Resources, idle, `top` 10 s samples: mission build avg **43.7%** CPU (peak 46%), 47 MB; PR #62 baseline avg **41.8%** (peak 45%), 43 MB. The mission adds no measurable CPU (the difference is within run-to-run variation; adapters are ~10 of ~1,500 busy samples in a 5 s profile). Memory meets the `< 70MB` budget. The project-wide `< 2%` CPU budget is not met by the baseline either; tracked in #70.
