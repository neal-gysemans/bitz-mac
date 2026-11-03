import XCTest
@testable import BitzCore

final class FoundationModelsAvailabilityTests: XCTestCase {

    func testGeneratorThrowsWhenUnavailable() async {
        let generator = FoundationModelsCommentaryGenerator(
            availabilityOverride: { false },
            customResponder: nil
        )

        let isAvail = await generator.isAvailable
        XCTAssertFalse(isAvail)

        do {
            _ = try await generator.generate(context: PersonalityContext(), preset: .snarky)
            XCTFail("Expected modelUnavailable error")
        } catch let error as PersonalityError {
            if case .modelUnavailable = error {
                // Expected
            } else {
                XCTFail("Unexpected PersonalityError: \(error)")
            }
        } catch {
            XCTFail("Unexpected error type: \(error)")
        }
    }

    func testGeneratorExecutesWhenAvailable() async throws {
        let generator = FoundationModelsCommentaryGenerator(
            availabilityOverride: { true },
            customResponder: { prompt, preset in
                XCTAssertFalse(prompt.isEmpty)
                XCTAssertEqual(preset, .cute)
                return "Purrs happily at your progress!"
            }
        )

        let isAvail = await generator.isAvailable
        XCTAssertTrue(isAvail)

        let result = try await generator.generate(context: PersonalityContext(), preset: .cute)
        XCTAssertEqual(result, "Purrs happily at your progress!")
    }

    func testRephrasePreservesStaticWarningOnFailure() async throws {
        let generator = FoundationModelsCommentaryGenerator(
            availabilityOverride: { true },
            customResponder: { _, _ in
                throw PersonalityError.generationFailed("Timeout")
            }
        )

        let staticWarning = "System is overheating! Please pause."
        let result = try await generator.rephrase(warning: staticWarning, context: PersonalityContext(), preset: .snarky)
        XCTAssertEqual(result, staticWarning)
    }

    func testUnloadReleasesResourcesWithoutCrashing() async {
        let generator = FoundationModelsCommentaryGenerator()
        await generator.unload()
    }
}
