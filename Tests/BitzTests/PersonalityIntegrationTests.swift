import XCTest
import Combine
@testable import BitzCore

@MainActor
final class PersonalityIntegrationTests: XCTestCase {

    private func makeIsolatedDefaults() -> (UserDefaults, String) {
        let suiteName = "PersonalityIntegrationTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        OverlayFixture.resetAgentMonitorDefaults()
        return (defaults, suiteName)
    }

    // MARK: - Idle Commentary Display

    func testIdleCommentaryDisplaysWhenNoActiveWarningOrPopup() {
        let (defaults, suite) = makeIsolatedDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }

        let engine = WellnessPointEngine(riveController: ProductionRiveController(), userDefaults: defaults)
        XCTAssertNil(engine.displayedSpeechBubbleText)

        engine.setIdleCommentaryText("Focused and purring.")
        XCTAssertEqual(engine.displayedSpeechBubbleText, "Focused and purring.")

        engine.setIdleCommentaryText(nil)
        XCTAssertNil(engine.displayedSpeechBubbleText)
    }

    func testActiveWarningOverridesIdleCommentary() {
        let (defaults, suite) = makeIsolatedDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }

        let engine = WellnessPointEngine(riveController: ProductionRiveController(), userDefaults: defaults)
        engine.setIdleCommentaryText("All systems normal.")
        XCTAssertEqual(engine.displayedSpeechBubbleText, "All systems normal.")

        // Thermal warning MUST take strict priority
        engine.triggerThermalWarning(isOverheating: true)
        XCTAssertEqual(engine.displayedSpeechBubbleText, WellnessPointEngine.thermalWarningText)

        // Once thermal condition clears, reverts to idle commentary
        engine.triggerThermalWarning(isOverheating: false)
        XCTAssertEqual(engine.displayedSpeechBubbleText, "All systems normal.")
    }

    func testBurnoutAndOverworkedOverrideIdleCommentary() {
        let (defaults, suite) = makeIsolatedDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }

        let engine = WellnessPointEngine(riveController: ProductionRiveController(), userDefaults: defaults)
        engine.setIdleCommentaryText("Coding away.")

        // Overworked streak (60+ min)
        engine.setPoints(60.0, continuousWorkMinutes: 65.0)
        XCTAssertEqual(engine.currentState, .overworked)
        XCTAssertEqual(engine.displayedSpeechBubbleText, WellnessPointEngine.overworkedWarningText)

        // Burnout streak (90+ min)
        engine.setPoints(60.0, continuousWorkMinutes: 95.0)
        XCTAssertEqual(engine.currentState, .burnout)
        XCTAssertEqual(engine.displayedSpeechBubbleText, WellnessPointEngine.burnoutWarningText)
    }

    // MARK: - Warning Rephraser Seam

    func testWarningRephraserSynchronousStaticFirstThenAsyncRephrase() async {
        let (defaults, suite) = makeIsolatedDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }

        let engine = WellnessPointEngine(riveController: ProductionRiveController(), userDefaults: defaults)

        let expectation = expectation(description: "Rephraser called")
        engine.warningRephraser = { warning, state in
            expectation.fulfill()
            return "Cat says: Mac is sizzling! 🌡️"
        }

        // Synchronous check: immediately set to static warning
        engine.triggerThermalWarning(isOverheating: true)
        XCTAssertEqual(engine.activeSpeechBubbleText, WellnessPointEngine.thermalWarningText)
        XCTAssertEqual(engine.displayedSpeechBubbleText, WellnessPointEngine.thermalWarningText)

        // Async check: after task runs, rephrased string replaces static warning
        await fulfillment(of: [expectation], timeout: 2.0)
        // Allow MainActor task block to update state
        try? await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertEqual(engine.activeSpeechBubbleText, "Cat says: Mac is sizzling! 🌡️")
        XCTAssertEqual(engine.displayedSpeechBubbleText, "Cat says: Mac is sizzling! 🌡️")
    }

    func testWarningRephraserDoesNotOverwriteIfStateCleared() async {
        let (defaults, suite) = makeIsolatedDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }

        let engine = WellnessPointEngine(riveController: ProductionRiveController(), userDefaults: defaults)

        let rephraserStarted = expectation(description: "Rephraser started")
        engine.warningRephraser = { warning, state in
            rephraserStarted.fulfill()
            try? await Task.sleep(nanoseconds: 100_000_000)
            return "Delayed rephrase"
        }

        engine.triggerThermalWarning(isOverheating: true)
        XCTAssertEqual(engine.activeSpeechBubbleText, WellnessPointEngine.thermalWarningText)

        await fulfillment(of: [rephraserStarted], timeout: 2.0)
        // Clear overheating BEFORE the rephraser finishes and sets text
        engine.triggerThermalWarning(isOverheating: false)
        XCTAssertNil(engine.activeSpeechBubbleText)

        // Wait for rephraser task to finish
        try? await Task.sleep(nanoseconds: 150_000_000)
        // Must NOT overwrite back to the rephrased warning!
        XCTAssertNil(engine.activeSpeechBubbleText)
    }

    // MARK: - SpeechBubbleContent Priority Hierarchy

    func testSpeechBubbleContentPrioritiesWithIdleCommentary() {
        let (defaults, suite) = makeIsolatedDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }

        let fixture = OverlayFixture(defaults: defaults)
        let engine = fixture.engine
        let agentMonitor = fixture.agentMonitor
        let updateStore = fixture.updateStore
        let telemetryDashboard = fixture.telemetryDashboard
        let telemetrySettings = fixture.telemetrySettings

        // Baseline: no bubble
        XCTAssertNil(
            SpeechBubbleContent.current(
                engine: engine,
                agentMonitor: agentMonitor,
                updateStore: updateStore,
                telemetryDashboard: telemetryDashboard,
                telemetrySettings: telemetrySettings
            )
        )

        // Idle commentary set
        engine.setIdleCommentaryText("Idle cat comment")
        if case .wellness(let text) = SpeechBubbleContent.current(
            engine: engine,
            agentMonitor: agentMonitor,
            updateStore: updateStore,
            telemetryDashboard: telemetryDashboard,
            telemetrySettings: telemetrySettings
        ) {
            XCTAssertEqual(text, "Idle cat comment")
        } else {
            XCTFail("Expected .wellness with idle commentary")
        }

        // Active thermal warning overrides idle commentary
        engine.triggerThermalWarning(isOverheating: true)
        if case .wellness(let text) = SpeechBubbleContent.current(
            engine: engine,
            agentMonitor: agentMonitor,
            updateStore: updateStore,
            telemetryDashboard: telemetryDashboard,
            telemetrySettings: telemetrySettings
        ) {
            XCTAssertEqual(text, WellnessPointEngine.thermalWarningText)
        } else {
            XCTFail("Expected .wellness with thermal warning")
        }

        // Agent approval popup overrides wellness
        fixture.showApprovalPopup("Need approval to run tests")
        if case .agentPopup(let currentPopup) = SpeechBubbleContent.current(
            engine: engine,
            agentMonitor: agentMonitor,
            updateStore: updateStore,
            telemetryDashboard: telemetryDashboard,
            telemetrySettings: telemetrySettings
        ) {
            XCTAssertEqual(currentPopup.agentName, "Claude")
            XCTAssertEqual(currentPopup.kind, .needsApproval)
        } else {
            XCTFail("Expected .agentPopup to override wellness")
        }
    }

    // MARK: - App Delegate Wiring

    func testBitzAppDelegatePersonalityWiring() async {
        let (defaults, suite) = makeIsolatedDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }

        let personalitySettings = PersonalitySettingsStore(userDefaults: defaults)
        personalitySettings.setEnabled(true)
        personalitySettings.setPreset(.snarky)

        let stub = StubCommentaryGenerator(stubbedResult: .success("App delegate says meow."))
        let personalityService = PersonalityService(
            primaryGenerator: stub,
            fallbackGenerator: stub,
            settingsStore: personalitySettings
        )

        let appDelegate = BitzAppDelegate(
            personalitySettings: personalitySettings,
            personalityService: personalityService,
            userDefaults: defaults
        )

        XCTAssertNotNil(appDelegate.personalityService)
        XCTAssertNotNil(appDelegate.personalitySettings)

        // Trigger tick with idle bubble
        let context = PersonalityContext(
            wellnessState: .balanced,
            currentPoints: 50.0,
            continuousWorkMinutes: 10.0,
            temperatureCelsius: 45.0,
            cpuLoadPercentage: 15.0,
            frontmostAppName: "Xcode",
            activeAgentNames: [],
            recentCommitCount: nil
        )
        await appDelegate.personalityService.tick(context: context, isBubbleIdle: true)
        appDelegate.engine.setIdleCommentaryText(appDelegate.personalityService.activeCommentary)

        XCTAssertEqual(appDelegate.engine.displayedSpeechBubbleText, "App delegate says meow.")

        // Toggle disabled clears commentary
        personalitySettings.setEnabled(false)
        // Allow Combine sink to deliver
        try? await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertNil(appDelegate.engine.idleCommentaryText)
        XCTAssertNil(appDelegate.engine.displayedSpeechBubbleText)
    }

    func testTogglingPersonalityEnabledTriggersImmediateTickAndDisplaysCommentary() async {
        let (defaults, suite) = makeIsolatedDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }

        let personalitySettings = PersonalitySettingsStore(userDefaults: defaults)
        personalitySettings.setEnabled(false)

        let stub = StubCommentaryGenerator(stubbedResult: .success("Instant commentary on toggle!"))
        let personalityService = PersonalityService(
            primaryGenerator: stub,
            fallbackGenerator: stub,
            settingsStore: personalitySettings
        )

        let appDelegate = BitzAppDelegate(
            personalitySettings: personalitySettings,
            personalityService: personalityService,
            userDefaults: defaults
        )

        XCTAssertFalse(appDelegate.personalitySettings.isEnabled)
        XCTAssertNil(appDelegate.engine.displayedSpeechBubbleText)

        // Toggle enabled on shared store
        appDelegate.personalitySettings.setEnabled(true)

        // Allow async Task on MainActor to complete
        for _ in 0..<10 {
            if appDelegate.engine.displayedSpeechBubbleText != nil { break }
            try? await Task.sleep(nanoseconds: 50_000_000)
        }

        XCTAssertEqual(appDelegate.engine.displayedSpeechBubbleText, "Instant commentary on toggle!")
    }
}
