import XCTest
@testable import BitzCore

@MainActor
final class PersonalityCoreTests: XCTestCase {

    private func makeIsolatedDefaults() -> (UserDefaults, String) {
        let suiteName = "bitz.personality.core.tests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        return (defaults, suiteName)
    }

    // MARK: - Presets Tests

    func testPersonalityPresetPromptsAndToneAreDistinct() {
        let presets = PersonalityPreset.allCases
        XCTAssertEqual(presets.count, 3)

        var displayNames = Set<String>()
        var systemPrompts = Set<String>()
        var toneGuides = Set<String>()

        for preset in presets {
            XCTAssertFalse(preset.displayName.isEmpty)
            XCTAssertFalse(preset.systemPrompt.isEmpty)
            XCTAssertFalse(preset.toneGuide.isEmpty)

            displayNames.insert(preset.displayName)
            systemPrompts.insert(preset.systemPrompt)
            toneGuides.insert(preset.toneGuide)
        }

        XCTAssertEqual(displayNames.count, 3)
        XCTAssertEqual(systemPrompts.count, 3)
        XCTAssertEqual(toneGuides.count, 3)
    }

    // MARK: - Context Tests

    func testPersonalityContextDefaultsAndCodableRoundtrip() throws {
        let defaultContext = PersonalityContext()
        XCTAssertEqual(defaultContext.wellnessState, .balanced)
        XCTAssertEqual(defaultContext.currentPoints, 50.0)
        XCTAssertEqual(defaultContext.continuousWorkMinutes, 0.0)
        XCTAssertNil(defaultContext.temperatureCelsius)
        XCTAssertNil(defaultContext.cpuLoadPercentage)
        XCTAssertNil(defaultContext.frontmostAppName)
        XCTAssertNil(defaultContext.isFrontmostProductive)
        XCTAssertTrue(defaultContext.activeAgentNames.isEmpty)
        XCTAssertNil(defaultContext.recentCommitCount)

        let customContext = PersonalityContext(
            wellnessState: .overheating,
            currentPoints: 22.5,
            continuousWorkMinutes: 120.0,
            temperatureCelsius: 89.4,
            cpuLoadPercentage: 94.2,
            frontmostAppName: "Xcode",
            isFrontmostProductive: true,
            activeAgentNames: ["Claude", "Antigravity"],
            recentCommitCount: 8
        )

        let data = try JSONEncoder().encode(customContext)
        let decoded = try JSONDecoder().decode(PersonalityContext.self, from: data)
        XCTAssertEqual(decoded, customContext)
    }

    // MARK: - Stub Commentary Generator Tests

    func testStubCommentaryGeneratorExecutionAndUnload() async throws {
        let stub = StubCommentaryGenerator(stubbedResult: .success("Cat nap time!"))
        let context = PersonalityContext(wellnessState: .balanced, frontmostAppName: "Safari")

        let result = try await stub.generate(context: context, preset: .cute)
        XCTAssertEqual(result, "Cat nap time!")
        XCTAssertEqual(stub.lastGeneratedContext, context)
        XCTAssertEqual(stub.lastGeneratedPreset, .cute)

        XCTAssertEqual(stub.unloadCallCount, 0)
        await stub.unload()
        XCTAssertEqual(stub.unloadCallCount, 1)
    }

    func testStubCommentaryGeneratorErrorPropagation() async {
        let stub = StubCommentaryGenerator(stubbedResult: .failure(PersonalityError.generationFailed("Model busy")))
        do {
            _ = try await stub.generate(context: PersonalityContext(), preset: .snarky)
            XCTFail("Expected generator to throw")
        } catch let error as PersonalityError {
            XCTAssertEqual(error, .generationFailed("Model busy"))
        } catch {
            XCTFail("Unexpected error type: \(error)")
        }
    }

    func testNoOpGitActivityProviderReturnsNil() async {
        let provider = NoOpGitActivityProvider()
        let count = await provider.recentCommitCount(sinceMinutes: 60)
        XCTAssertNil(count)
    }

    // MARK: - PersonalitySettingsStore Tests

    func testPersonalitySettingsStoreDefaults() {
        let (defaults, suiteName) = makeIsolatedDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let store = PersonalitySettingsStore(userDefaults: defaults)
        XCTAssertFalse(store.isEnabled, "Feature must be OFF by default")
        XCTAssertEqual(store.preset, .snarky)
        XCTAssertEqual(store.minIntervalMinutes, 10)
        XCTAssertEqual(store.dailyCap, 20)
        XCTAssertTrue(store.watchedRepoPaths.isEmpty)
        XCTAssertEqual(store.commentsGeneratedToday, 0)
    }

    func testPersonalitySettingsStorePersistenceRoundtrip() {
        let (defaults, suiteName) = makeIsolatedDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }

        var changeCount = 0
        let store1 = PersonalitySettingsStore(userDefaults: defaults)
        store1.onSettingsChanged = { changeCount += 1 }

        store1.setEnabled(true)
        store1.setPreset(.supportive)
        store1.setMinIntervalMinutes(15)
        store1.setDailyCap(35)
        store1.setWatchedRepoPaths(["/Users/dev/project1", "/Users/dev/project2"])

        XCTAssertTrue(changeCount >= 5)

        // Instantiate fresh store with same UserDefaults suite
        let store2 = PersonalitySettingsStore(userDefaults: defaults)
        XCTAssertTrue(store2.isEnabled)
        XCTAssertEqual(store2.preset, .supportive)
        XCTAssertEqual(store2.minIntervalMinutes, 15)
        XCTAssertEqual(store2.dailyCap, 35)
        XCTAssertEqual(store2.watchedRepoPaths, ["/Users/dev/project1", "/Users/dev/project2"])
    }

    func testPersonalitySettingsStoreRepoPathHelpers() {
        let (defaults, suiteName) = makeIsolatedDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let store = PersonalitySettingsStore(userDefaults: defaults)
        store.addWatchedRepoPath("/repo/a")
        store.addWatchedRepoPath("/repo/b")
        // Duplicate should be ignored
        store.addWatchedRepoPath("/repo/a")

        XCTAssertEqual(store.watchedRepoPaths, ["/repo/a", "/repo/b"])

        store.removeWatchedRepoPath("/repo/a")
        XCTAssertEqual(store.watchedRepoPaths, ["/repo/b"])
    }

    func testPersonalitySettingsStoreDailyQuotaAndRollover() {
        let (defaults, suiteName) = makeIsolatedDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }

        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!

        let day1 = calendar.date(from: DateComponents(year: 2026, month: 11, day: 3, hour: 10))!
        let day2 = calendar.date(from: DateComponents(year: 2026, month: 11, day: 4, hour: 10))!

        let store = PersonalitySettingsStore(userDefaults: defaults, calendar: calendar)
        store.setDailyCap(2)

        XCTAssertTrue(store.canGenerateCommentToday(for: day1))
        store.recordCommentGenerated(on: day1)
        XCTAssertEqual(store.commentsGeneratedToday, 1)

        XCTAssertTrue(store.canGenerateCommentToday(for: day1))
        store.recordCommentGenerated(on: day1)
        XCTAssertEqual(store.commentsGeneratedToday, 2)

        // Cap reached on day 1
        XCTAssertFalse(store.canGenerateCommentToday(for: day1))

        // Next calendar day rolls over counter
        XCTAssertTrue(store.canGenerateCommentToday(for: day2))
        XCTAssertEqual(store.commentsGeneratedToday, 0)
    }
}
