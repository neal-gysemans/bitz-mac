import XCTest
@testable import BitzCore

@MainActor
final class WellnessPointEngineTests: XCTestCase {

    // MARK: - Contract SSOT Mirror Assertions

    func testRiveContractConstantsMatchSpecificationByteForByte() {
        XCTAssertEqual(BitzRiveInputName.stateMachineName, "BitzStateMachine")
        XCTAssertEqual(BitzRiveInputName.speedMultiplier, "speedMultiplier")
        XCTAssertEqual(BitzRiveInputName.visorColor, "visorColor")
        XCTAssertEqual(BitzRiveInputName.isStandby, "isStandby")
        XCTAssertEqual(BitzRiveInputName.isGlitching, "isGlitching")
        XCTAssertEqual(BitzRiveInputName.triggerPet, "triggerPet")
        XCTAssertEqual(
            BitzRiveInputName.allInputNames,
            Set(["speedMultiplier", "visorColor", "isStandby", "isGlitching", "triggerPet"])
        )

        XCTAssertEqual(BitzVisorColor.cyan, 0.0)
        XCTAssertEqual(BitzVisorColor.magenta, 1.0)
        XCTAssertEqual(BitzVisorColor.amber, 2.0)
        XCTAssertEqual(BitzVisorColor.red, 3.0)
        XCTAssertEqual(BitzVisorColor.purple, 4.0)
        XCTAssertEqual(BitzVisorColor.green, 5.0)

        XCTAssertEqual(
            Set(BitzState.allCases.map(\.rawValue)),
            Set(["superCharged", "balanced", "dopamineSad", "overworked", "burnout", "charging", "overheating"])
        )
        XCTAssertEqual(WellnessPointEngine.thermalWarningText, "🔥 SYSTEM HOT! CLOSE HEAVY APPS TO COOL DOWN")
    }

    // MARK: - Initial State & Clamping

    func testInitialDefaultStateIsBalancedAtFiftyPoints() {
        let spy = SpyRiveController()
        let engine = WellnessPointEngine(riveController: spy)

        XCTAssertEqual(engine.currentPoints, 50.0, accuracy: 0.0001)
        XCTAssertEqual(engine.currentState, .balanced)
        XCTAssertNil(engine.activeSpeechBubbleText)
        XCTAssertEqual(engine.minPoints, 0.0)
        XCTAssertEqual(engine.maxPoints, 100.0)

        XCTAssertEqual(spy.floatInputs["speedMultiplier"], 1.0)
        XCTAssertEqual(spy.floatInputs["visorColor"], 0.0)
        XCTAssertEqual(spy.boolInputs["isStandby"], false)
        XCTAssertEqual(spy.boolInputs["isGlitching"], false)
    }

    func testInitialPointsClampToZeroAndOneHundred() {
        let spyLow = SpyRiveController()
        let lowEngine = WellnessPointEngine(initialPoints: -25.0, riveController: spyLow)
        XCTAssertEqual(lowEngine.currentPoints, 0.0, accuracy: 0.0001)
        XCTAssertEqual(lowEngine.currentState, .dopamineSad)
        XCTAssertEqual(spyLow.floatInputs["speedMultiplier"], 0.35)
        XCTAssertEqual(spyLow.floatInputs["visorColor"], BitzVisorColor.purple)

        let spyHigh = SpyRiveController()
        let highEngine = WellnessPointEngine(initialPoints: 150.0, riveController: spyHigh)
        XCTAssertEqual(highEngine.currentPoints, 100.0, accuracy: 0.0001)
        XCTAssertEqual(highEngine.currentState, .superCharged)
        XCTAssertEqual(spyHigh.floatInputs["speedMultiplier"], 2.0)
        XCTAssertEqual(spyHigh.floatInputs["visorColor"], 1.0)
    }

    // MARK: - Work Ticks, Dopamine Sad & Continuous Work Burnout

    func testProductiveWorkTickAddsHalfPointAndTransitionsToSuperCharged() {
        let spy = SpyRiveController()
        let engine = WellnessPointEngine(initialPoints: 79.5, riveController: spy)
        XCTAssertEqual(engine.currentState, .balanced)

        engine.evaluateWorkTick(isProductiveApp: true)
        XCTAssertEqual(engine.currentPoints, 80.0, accuracy: 0.0001)
        XCTAssertEqual(engine.currentState, .superCharged)
        XCTAssertEqual(spy.floatInputs["speedMultiplier"], 2.0)
        XCTAssertEqual(spy.floatInputs["visorColor"], 1.0)
        XCTAssertEqual(spy.boolInputs["isGlitching"], false)
        XCTAssertEqual(spy.boolInputs["isStandby"], false)
    }

    func testProductiveWorkTickClampsAtOneHundredPoints() {
        let spy = SpyRiveController()
        let engine = WellnessPointEngine(initialPoints: 99.8, riveController: spy)

        engine.evaluateWorkTick(isProductiveApp: true)
        XCTAssertEqual(engine.currentPoints, 100.0, accuracy: 0.0001)
        XCTAssertEqual(engine.currentState, .superCharged)

        engine.evaluateWorkTick(isProductiveApp: true)
        XCTAssertEqual(engine.currentPoints, 100.0, accuracy: 0.0001)
    }

    func testUnproductiveWorkTickDrainsIntoDopamineSadAndClampsAtZero() {
        let spy = SpyRiveController()
        let engine = WellnessPointEngine(initialPoints: 41.0, riveController: spy)
        XCTAssertEqual(engine.currentState, .balanced)

        // 41.0 - 1.5 = 39.5 -> .dopamineSad (Too much YouTube/Netflix)
        engine.evaluateWorkTick(isProductiveApp: false)
        XCTAssertEqual(engine.currentPoints, 39.5, accuracy: 0.0001)
        XCTAssertEqual(engine.currentState, .dopamineSad)
        XCTAssertEqual(engine.activeSpeechBubbleText, WellnessPointEngine.dopamineSadText)
        XCTAssertEqual(spy.floatInputs["speedMultiplier"], 0.35)
        XCTAssertEqual(spy.floatInputs["visorColor"], BitzVisorColor.purple)

        for _ in 0..<30 {
            engine.evaluateWorkTick(isProductiveApp: false)
        }
        XCTAssertEqual(engine.currentPoints, 0.0, accuracy: 0.0001)
        XCTAssertEqual(engine.currentState, .dopamineSad)
    }

    func testContinuousWorkWithoutBreakTriggersOverworkedAndBurnout() {
        let spy = SpyRiveController()
        let engine = WellnessPointEngine(initialPoints: 80.0, riveController: spy)
        XCTAssertEqual(engine.currentState, .superCharged)

        // Work 45 minutes continuously without a break -> .overworked
        engine.evaluateWorkTick(isProductiveApp: true, tickDurationMinutes: 45.0)
        XCTAssertEqual(engine.currentState, .overworked)
        XCTAssertEqual(engine.activeSpeechBubbleText, WellnessPointEngine.overworkedWarningText)
        XCTAssertEqual(spy.floatInputs["visorColor"], BitzVisorColor.amber)

        // Work another 45 minutes (total 90m) -> .burnout
        engine.evaluateWorkTick(isProductiveApp: true, tickDurationMinutes: 45.0)
        XCTAssertEqual(engine.currentState, .burnout)
        XCTAssertEqual(engine.activeSpeechBubbleText, WellnessPointEngine.burnoutWarningText)
        XCTAssertEqual(spy.boolInputs["isStandby"], true)
    }

    // MARK: - Exact Boundary Thresholds

    func testExactBoundaryThresholds() {
        XCTAssertEqual(WellnessPointEngine.state(forPoints: 100.0), .superCharged)
        XCTAssertEqual(WellnessPointEngine.state(forPoints: 80.0), .superCharged)
        XCTAssertEqual(WellnessPointEngine.state(forPoints: 79.999), .balanced)
        XCTAssertEqual(WellnessPointEngine.state(forPoints: 40.0), .balanced)
        XCTAssertEqual(WellnessPointEngine.state(forPoints: 39.999), .dopamineSad)
        XCTAssertEqual(WellnessPointEngine.state(forPoints: 0.0), .dopamineSad)
    }

    // MARK: - Charging & Offline Break Restoration

    func testChargingStateAndOfflineBreakRestoration() {
        let spy = SpyRiveController()
        let engine = WellnessPointEngine(initialPoints: 30.0, initialContinuousWorkMinutes: 95.0, riveController: spy)
        XCTAssertEqual(engine.currentState, .burnout)

        // User steps away from keyboard -> .charging
        engine.setChargingState(true)
        XCTAssertEqual(engine.currentState, .charging)
        XCTAssertEqual(engine.activeSpeechBubbleText, WellnessPointEngine.chargingStatusText)
        XCTAssertEqual(spy.floatInputs["visorColor"], BitzVisorColor.green)
        XCTAssertEqual(engine.currentPoints, 30.5, accuracy: 0.0001)

        // Return after 5 minutes (> 2.0m threshold) -> +25.0 pts (55.5) and resets continuousWorkMinutes to 0
        engine.applyOfflineBreak(minutes: 5.0)
        XCTAssertEqual(engine.currentPoints, 55.5, accuracy: 0.0001)
        XCTAssertEqual(engine.continuousWorkMinutes, 0.0, accuracy: 0.0001)
        XCTAssertEqual(engine.currentState, .balanced)
        XCTAssertNil(engine.activeSpeechBubbleText)
    }

    // MARK: - Thermal Warning Override & Recovery

    func testThermalWarningOverridesStateAndRestoresUnderlyingStateWhenCleared() {
        let spy = SpyRiveController()
        let engine = WellnessPointEngine(initialPoints: 85.0, riveController: spy)
        XCTAssertEqual(engine.currentState, .superCharged)
        XCTAssertNil(engine.activeSpeechBubbleText)

        // Trigger thermal warning with actionable message
        engine.triggerThermalWarning(
            isOverheating: true,
            actionMessage: "🔥 85°C — CLOSE HEAVY APPS TO COOL DOWN!"
        )
        XCTAssertEqual(engine.currentState, .overheating)
        XCTAssertEqual(engine.activeSpeechBubbleText, "🔥 85°C — CLOSE HEAVY APPS TO COOL DOWN!")
        XCTAssertEqual(spy.boolInputs["isGlitching"], true)
        XCTAssertEqual(spy.floatInputs["visorColor"], 3.0)

        // While overheating, work ticks update points but preserve .overheating override
        engine.evaluateWorkTick(isProductiveApp: false)
        XCTAssertEqual(engine.currentPoints, 83.5, accuracy: 0.0001)
        XCTAssertEqual(engine.currentState, .overheating)

        // Clear thermal warning -> restores .superCharged (83.5 pts)
        engine.triggerThermalWarning(isOverheating: false)
        XCTAssertEqual(engine.currentState, .superCharged)
        XCTAssertNil(engine.activeSpeechBubbleText)
        XCTAssertEqual(spy.boolInputs["isGlitching"], false)
        XCTAssertEqual(spy.floatInputs["visorColor"], 1.0)
        XCTAssertEqual(spy.floatInputs["speedMultiplier"], 2.0)
    }

    // MARK: - Agent Warning Visor (R10)

    /// The Rive `visorColor` input and the drawn visor must always show the same colour (charter DIR-004).
    func testWarningVisorDrivesRiveAmberAndMatchesDrawnVisor() {
        let spy = SpyRiveController()
        let engine = WellnessPointEngine(initialPoints: 50.0, riveController: spy)
        // The drawn colour each pushed Rive value stands for
        let drawnColorState: [Float: BitzState] = [
            BitzVisorColor.cyan: .balanced,
            BitzVisorColor.amber: .overworked,
            BitzVisorColor.red: .overheating,
        ]
        func assertVisor(_ riveValue: Float, state: BitzState, line: UInt = #line) {
            XCTAssertEqual(engine.currentState, state, "warning visor never changes the wellness state", line: line)
            XCTAssertEqual(spy.floatInputs["visorColor"], riveValue, line: line)
            let drawn = MascotOverlayView.visorRGB(for: engine.currentState, warningVisorActive: engine.isWarningVisorActive)
            let expected = MascotOverlayView.visorRGB(for: drawnColorState[riveValue]!)
            XCTAssertTrue(drawn == expected, "drawn visor must match the Rive input", line: line)
        }

        XCTAssertFalse(engine.isWarningVisorActive)
        assertVisor(BitzVisorColor.cyan, state: .balanced)

        engine.setWarningVisor(active: true)
        XCTAssertTrue(engine.isWarningVisorActive)
        assertVisor(BitzVisorColor.amber, state: .balanced)
        XCTAssertEqual(engine.currentPoints, 50.0)

        engine.triggerThermalWarning(isOverheating: true)
        assertVisor(BitzVisorColor.red, state: .overheating)

        engine.triggerThermalWarning(isOverheating: false)
        assertVisor(BitzVisorColor.amber, state: .balanced)

        engine.setWarningVisor(active: false)
        XCTAssertFalse(engine.isWarningVisorActive)
        assertVisor(BitzVisorColor.cyan, state: .balanced)
        XCTAssertEqual(engine.currentPoints, 50.0)
    }

    // MARK: - Pet Interaction Trigger & ProductionRiveController

    func testTriggerPetInteractionFiresRiveTriggerPetInput() {
        let spy = SpyRiveController()
        let engine = WellnessPointEngine(riveController: spy)

        engine.triggerPetInteraction()
        engine.triggerPetInteraction()

        XCTAssertEqual(spy.triggerCounts["triggerPet"], 2)
        XCTAssertEqual(spy.commands.last, .fireTrigger("triggerPet"))
    }

    func testProductionRiveControllerStoresInputsAndInvokesCallback() {
        var dispatched: [BitzRiveCommand] = []
        let controller = ProductionRiveController { command in
            dispatched.append(command)
        }
        let engine = WellnessPointEngine(initialPoints: 50.0, riveController: controller)

        XCTAssertEqual(controller.fileName, "bitz_cyber_cat")
        XCTAssertEqual(controller.stateMachineName, "BitzStateMachine")
        XCTAssertEqual(controller.floatInputs["speedMultiplier"], 1.0)
        XCTAssertEqual(controller.floatInputs["visorColor"], 0.0)
        XCTAssertEqual(controller.boolInputs["isStandby"], false)
        XCTAssertEqual(controller.boolInputs["isGlitching"], false)

        engine.triggerPetInteraction()
        XCTAssertEqual(controller.lastTriggeredInput, "triggerPet")
        XCTAssertEqual(controller.totalTriggerCount, 1)
        XCTAssertTrue(dispatched.contains(.fireTrigger("triggerPet")))
    }

    func testWellnessPointEnginePersistenceAndOfflineBreakRestoration() {
        let suiteName = "BitzEnginePersistenceTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        // 1. Initial engine with persistence enabled
        let firstEngine = WellnessPointEngine(initialPoints: 45.0, initialContinuousWorkMinutes: 20.0, userDefaults: defaults)
        firstEngine.evaluateWorkTick(isProductiveApp: true) // 45.5 pts, work streak ~20.08 min
        XCTAssertEqual(firstEngine.currentPoints, 45.5, accuracy: 0.0001)

        // 2. Re-instantiate from same suite without explicit initial points -> restores 45.5 pts
        let restoredEngine = WellnessPointEngine(userDefaults: defaults)
        XCTAssertEqual(restoredEngine.currentPoints, 45.5, accuracy: 0.0001)

        // 3. Test offline break restoration when elapsed time > 2.0 min
        defaults.set(20.0, forKey: WellnessPointEngine.pointsUserDefaultsKey)
        defaults.set(30.0, forKey: WellnessPointEngine.workMinutesUserDefaultsKey)
        // Saved 10 minutes ago
        defaults.set(Date().timeIntervalSince1970 - (10.0 * 60.0), forKey: WellnessPointEngine.lastSavedTimeUserDefaultsKey)

        let wakingEngine = WellnessPointEngine(userDefaults: defaults)
        // 20.0 + (10.0 min * 5.0 pts/min) = 70.0 pts, continuous streak reset to 0.0
        XCTAssertGreaterThanOrEqual(wakingEngine.currentPoints, 69.5)
        XCTAssertEqual(wakingEngine.continuousWorkMinutes, 0.0)
    }

    // MARK: - Edge Case Tests (Milestone 3 / F11 & F12)

    // Scenario 1: NaN / Non-Finite Points Sanitization
    func testNaNInitialPointsDoesNotPoisonEngineAndFallsBackToDefaultPoints() {
        let engineNaN = WellnessPointEngine(initialPoints: Double.nan)
        XCTAssertFalse(engineNaN.currentPoints.isNaN)
        XCTAssertEqual(engineNaN.currentPoints, WellnessPointEngine.defaultPoints)
        XCTAssertEqual(engineNaN.currentState, .balanced)

        let engineInf = WellnessPointEngine(initialPoints: Double.infinity)
        XCTAssertFalse(engineInf.currentPoints.isNaN)
        XCTAssertEqual(engineInf.currentPoints, WellnessPointEngine.defaultPoints)
        XCTAssertEqual(engineInf.currentState, .balanced)

        let engineNegInf = WellnessPointEngine(initialPoints: -Double.infinity)
        XCTAssertFalse(engineNegInf.currentPoints.isNaN)
        XCTAssertEqual(engineNegInf.currentPoints, WellnessPointEngine.defaultPoints)
        XCTAssertEqual(engineNegInf.currentState, .balanced)
    }

    func testSetPointsWithNonFiniteValuesSafelySanitizesToDefault() {
        let engine = WellnessPointEngine(initialPoints: 85.0)
        XCTAssertEqual(engine.currentPoints, 85.0)
        XCTAssertEqual(engine.currentState, .superCharged)

        engine.setPoints(Double.nan)
        XCTAssertFalse(engine.currentPoints.isNaN)
        XCTAssertEqual(engine.currentPoints, WellnessPointEngine.defaultPoints)
        XCTAssertEqual(engine.currentState, .balanced)

        engine.setPoints(Double.infinity)
        XCTAssertFalse(engine.currentPoints.isNaN)
        XCTAssertEqual(engine.currentPoints, WellnessPointEngine.defaultPoints)
        XCTAssertEqual(engine.currentState, .balanced)
    }

    func testStateForPointsWithNonFiniteAndOutOfRangePoints() {
        XCTAssertEqual(WellnessPointEngine.state(forPoints: Double.nan), .balanced)
        XCTAssertEqual(WellnessPointEngine.state(forPoints: Double.infinity), .balanced)
        XCTAssertEqual(WellnessPointEngine.state(forPoints: -Double.infinity), .balanced)
        XCTAssertEqual(WellnessPointEngine.state(forPoints: 105.0), .superCharged)
        XCTAssertEqual(WellnessPointEngine.state(forPoints: -15.0), .dopamineSad)
    }

    // Scenario 2: NaN / Non-Finite Work Tick Duration Sanitization
    func testEvaluateWorkTickWithNaNDurationDoesNotCorruptWorkStreak() {
        let engine = WellnessPointEngine(initialPoints: 60.0, initialContinuousWorkMinutes: 20.0)
        XCTAssertEqual(engine.continuousWorkMinutes, 20.0)

        engine.evaluateWorkTick(isProductiveApp: true, tickDurationMinutes: Double.nan)
        XCTAssertFalse(engine.continuousWorkMinutes.isNaN)
        XCTAssertEqual(engine.continuousWorkMinutes, 20.0, accuracy: 0.0001)
        XCTAssertFalse(engine.currentPoints.isNaN)
        XCTAssertEqual(engine.currentPoints, 60.5, accuracy: 0.0001)

        engine.evaluateWorkTick(isProductiveApp: true, tickDurationMinutes: Double.infinity)
        XCTAssertFalse(engine.continuousWorkMinutes.isNaN)
        XCTAssertEqual(engine.continuousWorkMinutes, 20.0, accuracy: 0.0001)
    }

    func testEvaluateWorkTickWithNegativeDurationClampsToZero() {
        let engine = WellnessPointEngine(initialPoints: 60.0, initialContinuousWorkMinutes: 20.0)
        engine.evaluateWorkTick(isProductiveApp: true, tickDurationMinutes: -15.0)
        XCTAssertEqual(engine.continuousWorkMinutes, 20.0, accuracy: 0.0001)
        XCTAssertEqual(engine.currentPoints, 60.5, accuracy: 0.0001)
    }

    func testApplyOfflineBreakWithNonFiniteOrNegativeMinutesDoesNotCorruptState() {
        let engine = WellnessPointEngine(initialPoints: 30.0, initialContinuousWorkMinutes: 25.0)

        engine.applyOfflineBreak(minutes: Double.nan)
        XCTAssertFalse(engine.currentPoints.isNaN)
        XCTAssertEqual(engine.currentPoints, 30.0)
        XCTAssertEqual(engine.continuousWorkMinutes, 25.0)

        engine.applyOfflineBreak(minutes: -10.0)
        XCTAssertEqual(engine.currentPoints, 30.0)
        XCTAssertEqual(engine.continuousWorkMinutes, 25.0)

        engine.applyOfflineBreak(minutes: Double.infinity)
        XCTAssertFalse(engine.currentPoints.isNaN)
        XCTAssertEqual(engine.currentPoints, 30.0)
        XCTAssertEqual(engine.continuousWorkMinutes, 25.0)
    }

    // Scenario 3: Clock Skew / Backward Time Jump Clamping
    func testPersistenceWithBackwardClockSkewClampsToZeroElapsed() {
        let suite = "BitzTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }

        let now = Date().timeIntervalSince1970
        defaults.set(35.0, forKey: WellnessPointEngine.pointsUserDefaultsKey)
        defaults.set(15.0, forKey: WellnessPointEngine.workMinutesUserDefaultsKey)
        // Saved 30 seconds ahead in the future (within maxFutureTimestampSkewSeconds of 60s)
        // simulating a minor NTP clock skew backward
        defaults.set(now + 30.0, forKey: WellnessPointEngine.lastSavedTimeUserDefaultsKey)

        let engine = WellnessPointEngine(userDefaults: defaults)
        // elapsedSec = max(0.0, now - lastTimestamp) -> 0.0. Break is not awarded (< 2.0 min).
        XCTAssertEqual(engine.currentPoints, 35.0, accuracy: 0.0001)
        XCTAssertEqual(engine.continuousWorkMinutes, 15.0, accuracy: 0.0001)
    }

    // Scenario 4: Epoch Zero (0.0) Timestamp Persistence Rejection
    func testPersistenceRejectsEpochZeroTimestampAndDoesNotGrantFiftyFourYearBreak() {
        let suite = "BitzTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }

        defaults.set(25.0, forKey: WellnessPointEngine.pointsUserDefaultsKey)
        defaults.set(45.0, forKey: WellnessPointEngine.workMinutesUserDefaultsKey)
        // Corrupted / zero timestamp
        defaults.set(0.0, forKey: WellnessPointEngine.lastSavedTimeUserDefaultsKey)

        let engine = WellnessPointEngine(userDefaults: defaults)
        // Pre-hardened code would award 100.0 points and set fatigue to 0.0!
        // Hardened code must reject timestamp < minimumValidTimestamp, preserving stored values without spurious break.
        XCTAssertEqual(engine.currentPoints, 25.0, accuracy: 0.0001)
        XCTAssertEqual(engine.continuousWorkMinutes, 45.0, accuracy: 0.0001)
        XCTAssertEqual(engine.currentState, .overworked)
    }

    // Scenario 5: Future Timestamp Persistence Rejection
    func testPersistenceRejectsFutureTimestampBeyondAllowedSkew() {
        let suite = "BitzTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }

        let now = Date().timeIntervalSince1970
        defaults.set(30.0, forKey: WellnessPointEngine.pointsUserDefaultsKey)
        defaults.set(20.0, forKey: WellnessPointEngine.workMinutesUserDefaultsKey)
        // Corrupted future timestamp (e.g. 1 day in the future)
        defaults.set(now + 86400.0, forKey: WellnessPointEngine.lastSavedTimeUserDefaultsKey)

        let engine = WellnessPointEngine(userDefaults: defaults)
        // Must reject future timestamp > now + 60s, preserving stored points and work streak
        XCTAssertEqual(engine.currentPoints, 30.0, accuracy: 0.0001)
        XCTAssertEqual(engine.continuousWorkMinutes, 20.0, accuracy: 0.0001)
    }

    // Scenario 8: Overheating Rive State Complete Synchronization
    func testOverheatingRiveStateFullySynchronizedFromBurnout() {
        let spy = SpyRiveController()
        let engine = WellnessPointEngine(initialPoints: 10.0, initialContinuousWorkMinutes: 95.0, riveController: spy)
        XCTAssertEqual(engine.currentState, .burnout)
        XCTAssertEqual(spy.floatInputs["speedMultiplier"], 0.0)
        XCTAssertEqual(spy.boolInputs["isStandby"], true)
        XCTAssertEqual(spy.boolInputs["isGlitching"], false)

        // Transition from .burnout to .overheating
        engine.triggerThermalWarning(isOverheating: true)
        XCTAssertEqual(engine.currentState, .overheating)
        // Pre-hardened code omitted setting speedMultiplier and isStandby in case .overheating!
        // As a result, speedMultiplier stayed at 0.0 and isStandby stayed at true.
        // Hardened code sets speedMultiplier = 2.5 and isStandby = false.
        XCTAssertEqual(spy.floatInputs["speedMultiplier"], 2.5)
        XCTAssertEqual(spy.floatInputs["visorColor"], BitzVisorColor.red)
        XCTAssertEqual(spy.boolInputs["isGlitching"], true)
        XCTAssertEqual(spy.boolInputs["isStandby"], false)
    }

    // Scenario 9: Charging Rive State Speed Alignment
    func testChargingRiveStateSpeedMultiplierMatchesStateMachineSpecification() {
        let spy = SpyRiveController()
        let engine = WellnessPointEngine(riveController: spy)

        engine.setChargingState(true)
        XCTAssertEqual(engine.currentState, .charging)
        // Pre-hardened code set speedMultiplier to 0.5.
        // Hardened code aligns with docs/STATE_MACHINE.md:50: speedMultiplier = 0.6.
        XCTAssertEqual(spy.floatInputs["speedMultiplier"], 0.6)
        XCTAssertEqual(spy.floatInputs["visorColor"], BitzVisorColor.green)
        XCTAssertEqual(spy.boolInputs["isStandby"], true)
        XCTAssertEqual(spy.boolInputs["isGlitching"], false)
    }

    // Scenario 10: Pet Interaction Rapid Burst Debounce & Cancellation
    func testRapidPetInteractionDebouncesAndCancelsPreviousDismissal() async {
        let engine = WellnessPointEngine()
        XCTAssertFalse(engine.isPetReactionActive)

        // First tap at t=0
        engine.triggerPetInteraction()
        XCTAssertTrue(engine.isPetReactionActive)

        // Wait 1.0 second, then tap again
        try? await Task.sleep(for: .seconds(1.0))
        XCTAssertTrue(engine.isPetReactionActive)
        engine.triggerPetInteraction()

        // Wait another 1.2 seconds (t = 2.2s total from start).
        // On pre-hardened code, Task 1 expired at t=2.0s and set isPetReactionActive = false!
        // On hardened code, Task 1 was cancelled by tap 2, so the reaction remains active until t=3.0s.
        try? await Task.sleep(for: .seconds(1.2))
        XCTAssertTrue(engine.isPetReactionActive, "Pet reaction should still be active because second tap reset the 2-second timer")

        // Wait remaining 1.0 second (t = 3.2s total) -> now reaction finishes
        try? await Task.sleep(for: .seconds(1.0))
        XCTAssertFalse(engine.isPetReactionActive, "Pet reaction should dismiss after 2 seconds from the LAST tap")
    }

    // Scenario 11: Test Suite Isolation (F12)
    func testEnginePersistenceUsesIsolatedUserDefaultsSuiteWithoutStandardLeakage() {
        let originalStandard = UserDefaults.standard.object(forKey: WellnessPointEngine.pointsUserDefaultsKey)
        let suite = "BitzTests.Isolation.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }

        defaults.set(77.0, forKey: WellnessPointEngine.pointsUserDefaultsKey)
        let engine = WellnessPointEngine(userDefaults: defaults)
        XCTAssertEqual(engine.currentPoints, 77.0)

        // Verify standard was not modified by initializing or persisting the engine with custom suite
        let afterStandard = UserDefaults.standard.object(forKey: WellnessPointEngine.pointsUserDefaultsKey)
        XCTAssertEqual(originalStandard as? Double, afterStandard as? Double)
    }
}
