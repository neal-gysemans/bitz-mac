import XCTest
@testable import BitzCore

@MainActor
final class PersonalityServiceTests: XCTestCase {

    private func makeIsolatedStore() -> (PersonalitySettingsStore, UserDefaults, String) {
        let suiteName = "bitz.personality.service.tests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        let store = PersonalitySettingsStore(userDefaults: defaults)
        return (store, defaults, suiteName)
    }

    struct MockPower: PowerStateProviding {
        var batteryLevelPercentage: Double?
        var isLowPowerModeEnabled: Bool
        var thermalState: ProcessInfo.ThermalState

        init(
            batteryLevelPercentage: Double? = nil,
            isLowPowerModeEnabled: Bool = false,
            thermalState: ProcessInfo.ThermalState = .nominal
        ) {
            self.batteryLevelPercentage = batteryLevelPercentage
            self.isLowPowerModeEnabled = isLowPowerModeEnabled
            self.thermalState = thermalState
        }
    }

    // MARK: - Tests

    func testDisabledServiceIsCompleteNoOp() async {
        let (store, defaults, suite) = makeIsolatedStore()
        defer { defaults.removePersistentDomain(forName: suite) }

        XCTAssertFalse(store.isEnabled)
        let stub = StubCommentaryGenerator(stubbedResult: .success("I should not appear"))
        let service = PersonalityService(primaryGenerator: stub, settingsStore: store)

        await service.tick(context: PersonalityContext(), isBubbleIdle: true)

        XCTAssertNil(service.activeCommentary)
        XCTAssertNil(stub.lastGeneratedContext)
    }

    func testNonIdleBubbleBlocksGeneration() async {
        let (store, defaults, suite) = makeIsolatedStore()
        defer { defaults.removePersistentDomain(forName: suite) }
        store.setEnabled(true)

        let stub = StubCommentaryGenerator(stubbedResult: .success("I should not appear"))
        let service = PersonalityService(primaryGenerator: stub, settingsStore: store)

        // isBubbleIdle: false -> active agent popup or critical warning showing
        await service.tick(context: PersonalityContext(), isBubbleIdle: false)

        XCTAssertNil(service.activeCommentary)
        XCTAssertNil(stub.lastGeneratedContext)
    }

    func testSuccessfulGenerationPublishesAndRecordsQuota() async {
        let (store, defaults, suite) = makeIsolatedStore()
        defer { defaults.removePersistentDomain(forName: suite) }
        store.setEnabled(true)
        store.setPreset(.cute)

        let stub = StubCommentaryGenerator(stubbedResult: .success("Purring peacefully next to your code!"))
        var currentTime = Date(timeIntervalSince1970: 10_000)
        let service = PersonalityService(
            primaryGenerator: stub,
            powerStateProvider: MockPower(),
            settingsStore: store,
            clock: { currentTime }
        )

        let context = PersonalityContext(continuousWorkMinutes: 45.0, frontmostAppName: "Xcode")
        await service.tick(context: context, isBubbleIdle: true)

        XCTAssertEqual(service.activeCommentary, "Purring peacefully next to your code!")
        XCTAssertEqual(stub.lastGeneratedPreset, .cute)
        XCTAssertEqual(store.commentsGeneratedToday, 1)
        XCTAssertNil(service.lastError)

        // Immediate subsequent tick is rate limited
        currentTime = currentTime.addingTimeInterval(60) // 1 minute later
        await service.tick(context: context, isBubbleIdle: true)
        XCTAssertEqual(store.commentsGeneratedToday, 1, "Rate limiter should prevent second generation")
    }

    func testPrimaryErrorFallsBackToFallbackGenerator() async {
        let (store, defaults, suite) = makeIsolatedStore()
        defer { defaults.removePersistentDomain(forName: suite) }
        store.setEnabled(true)

        let failingPrimary = StubCommentaryGenerator(stubbedResult: .failure(PersonalityError.generationFailed("Model crash")))
        let fallback = StubCommentaryGenerator(stubbedResult: .success("Fallback line to the rescue!"))

        let service = PersonalityService(
            primaryGenerator: failingPrimary,
            fallbackGenerator: fallback,
            powerStateProvider: MockPower(),
            settingsStore: store
        )

        await service.tick(context: PersonalityContext(), isBubbleIdle: true)

        XCTAssertEqual(service.activeCommentary, "Fallback line to the rescue!")
        XCTAssertNil(service.lastError)
    }

    func testPrimaryTimeoutFallsBackToFallbackGenerator() async {
        let (store, defaults, suite) = makeIsolatedStore()
        defer { defaults.removePersistentDomain(forName: suite) }
        store.setEnabled(true)

        let slowPrimary = StubCommentaryGenerator(stubbedResult: .success("Too late"))
        // Artificial delay of 3.0s exceeds the 2.0s timeout limit
        slowPrimary.delayNanoseconds = 3_000_000_000

        let fallback = StubCommentaryGenerator(stubbedResult: .success("Quick fallback line!"))

        let service = PersonalityService(
            primaryGenerator: slowPrimary,
            fallbackGenerator: fallback,
            powerStateProvider: MockPower(),
            settingsStore: store
        )

        await service.tick(context: PersonalityContext(), isBubbleIdle: true)

        XCTAssertEqual(service.activeCommentary, "Quick fallback line!")
        XCTAssertNil(service.lastError)
    }

    func testHardwareGateBlocksGeneration() async {
        let (store, defaults, suite) = makeIsolatedStore()
        defer { defaults.removePersistentDomain(forName: suite) }
        store.setEnabled(true)

        let stub = StubCommentaryGenerator(stubbedResult: .success("Should not run"))
        let lowPowerState = MockPower(batteryLevelPercentage: 90.0, isLowPowerModeEnabled: true, thermalState: .nominal)

        let service = PersonalityService(
            primaryGenerator: stub,
            powerStateProvider: lowPowerState,
            settingsStore: store
        )

        await service.tick(context: PersonalityContext(), isBubbleIdle: true)

        XCTAssertNil(service.activeCommentary)
        XCTAssertEqual(service.lastError, .gated("Low Power Mode is active"))
        XCTAssertNil(stub.lastGeneratedContext)
    }

    func testRephraseWarningSucceedsOrFailsOpen() async {
        let (store, defaults, suite) = makeIsolatedStore()
        defer { defaults.removePersistentDomain(forName: suite) }

        // Disabled returns original text verbatim
        store.setEnabled(false)
        let stub = StubCommentaryGenerator()
        let service = PersonalityService(primaryGenerator: stub, settingsStore: store)

        let original = "Overheating warning: Mac is running hot."
        let disabledRephrase = await service.rephraseWarning(original, context: PersonalityContext())
        XCTAssertEqual(disabledRephrase, original)

        // Enabled with fallback generator produces contextual rephrase
        store.setEnabled(true)
        store.setPreset(.snarky)
        let templated = TemplatedCommentaryGenerator()
        let activeService = PersonalityService(primaryGenerator: templated, settingsStore: store)

        let snarkyRephrase = await activeService.rephraseWarning(original, context: PersonalityContext())
        XCTAssertTrue(snarkyRephrase.contains(original))
        XCTAssertTrue(snarkyRephrase.contains("Don't melt the silicon"))
    }

    func testClearCommentaryAndUnload() async {
        let (store, defaults, suite) = makeIsolatedStore()
        defer { defaults.removePersistentDomain(forName: suite) }
        store.setEnabled(true)

        let stub = StubCommentaryGenerator(stubbedResult: .success("Hello!"))
        let service = PersonalityService(primaryGenerator: stub, settingsStore: store)

        await service.tick(context: PersonalityContext(), isBubbleIdle: true)
        XCTAssertNotNil(service.activeCommentary)

        service.clearCommentary()
        XCTAssertNil(service.activeCommentary)

        await service.unloadBackend()
        XCTAssertEqual(stub.unloadCallCount, 1)
    }
}
