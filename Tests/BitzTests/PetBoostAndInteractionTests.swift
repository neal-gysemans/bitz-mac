import AppKit
import XCTest
@testable import BitzCore

@MainActor
final class PetBoostAndInteractionTests: XCTestCase {
    private func makeDefaults() -> (UserDefaults, String) {
        let name = "PetBoostTests.\(UUID().uuidString)"
        return (UserDefaults(suiteName: name)!, name)
    }

    // MARK: - applyPetBoost

    func testBoostGrantsPointsOnce() {
        let engine = WellnessPointEngine(initialPoints: 50.0)
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        XCTAssertEqual(engine.applyPetBoost(now: now), 2.0, accuracy: 0.0001)
        XCTAssertEqual(engine.currentPoints, 52.0, accuracy: 0.0001)
    }

    func testBoostRespectsCooldown() {
        let engine = WellnessPointEngine(initialPoints: 50.0)
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        engine.applyPetBoost(now: now)
        XCTAssertEqual(engine.applyPetBoost(now: now.addingTimeInterval(30)), 0.0)
        XCTAssertEqual(engine.currentPoints, 52.0, accuracy: 0.0001)
        XCTAssertEqual(engine.applyPetBoost(now: now.addingTimeInterval(61)), 2.0, accuracy: 0.0001)
    }

    func testDailyCapAndNextDayReset() {
        let engine = WellnessPointEngine(initialPoints: 20.0)
        var now = Date(timeIntervalSince1970: 1_800_000_000)
        var total = 0.0
        for _ in 0..<10 {
            total += engine.applyPetBoost(now: now)
            now = now.addingTimeInterval(61)
        }
        XCTAssertEqual(total, 10.0, accuracy: 0.0001, "daily cap is +10")
        XCTAssertEqual(engine.applyPetBoost(now: now), 0.0)

        let nextDay = now.addingTimeInterval(36 * 3600)
        XCTAssertEqual(engine.applyPetBoost(now: nextDay), 2.0, accuracy: 0.0001)
    }

    func testBoostClampsAtMaxPoints() {
        let engine = WellnessPointEngine(initialPoints: 99.0)
        XCTAssertEqual(engine.applyPetBoost(now: Date()), 1.0, accuracy: 0.0001)
        XCTAssertEqual(engine.currentPoints, 100.0, accuracy: 0.0001)
        XCTAssertEqual(engine.applyPetBoost(now: Date().addingTimeInterval(120)), 0.0)
    }

    func testPettingDuringCooldownStillShowsReaction() {
        let engine = WellnessPointEngine(initialPoints: 50.0)
        let now = Date()
        engine.triggerPetInteraction(now: now)
        engine.triggerPetInteraction(now: now.addingTimeInterval(5))
        XCTAssertTrue(engine.isPetReactionActive)
        XCTAssertEqual(engine.currentPoints, 52.0, accuracy: 0.0001)
    }

    func testDailyCapPersistsAcrossRestart() {
        let (defaults, name) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: name) }
        var now = Date(timeIntervalSince1970: 1_800_000_000)
        let first = WellnessPointEngine(initialPoints: 20.0, userDefaults: defaults)
        for _ in 0..<5 {
            first.applyPetBoost(now: now)
            now = now.addingTimeInterval(61)
        }
        let second = WellnessPointEngine(initialPoints: 20.0, userDefaults: defaults)
        XCTAssertEqual(second.applyPetBoost(now: now), 0.0, "cap carries over a restart on the same day")
    }

    func testTransientBubbleLosesToWellnessText() {
        let engine = WellnessPointEngine(initialPoints: 50.0)
        engine.showTransientBubble("📋 Copied path: a.txt", duration: 60)
        XCTAssertEqual(engine.displayedSpeechBubbleText, "📋 Copied path: a.txt")
        engine.triggerThermalWarning(isOverheating: true, actionMessage: "HOT")
        XCTAssertEqual(engine.displayedSpeechBubbleText, "HOT")
    }

    // MARK: - Settings store

    func testSettingsDefaultsAndPersistence() {
        let (defaults, name) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: name) }
        let store = MascotInteractionSettingsStore(userDefaults: defaults)
        XCTAssertTrue(store.isHoldToInteractEnabled)
        XCTAssertEqual(store.holdModifier, .option)
        XCTAssertTrue(store.isStrokeToPetEnabled)
        XCTAssertTrue(store.isFileDropEnabled)
        XCTAssertFalse(store.isInboxHandoffEnabled)

        store.holdModifier = .control
        store.isInboxHandoffEnabled = true
        let reloaded = MascotInteractionSettingsStore(userDefaults: defaults)
        XCTAssertEqual(reloaded.holdModifier, .control)
        XCTAssertTrue(reloaded.isInboxHandoffEnabled)
    }

    func testModifierMatching() {
        let (defaults, name) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: name) }
        let store = MascotInteractionSettingsStore(userDefaults: defaults)
        XCTAssertTrue(store.isHoldActive(for: [.option]))
        XCTAssertFalse(store.isHoldActive(for: [.control]))
        store.holdModifier = .shift
        XCTAssertTrue(store.isHoldActive(for: [.shift]))
        XCTAssertFalse(store.isHoldActive(for: [.option]))
        store.isHoldToInteractEnabled = false
        XCTAssertFalse(store.isHoldActive(for: [.shift]))
        XCTAssertEqual(HoldModifierKey.option.displayName, "⌥ Option")
    }

    // MARK: - Stroke detector

    private func sweep(_ detector: inout PetStrokeDetector, buttons: Int) -> Bool {
        var fired = false
        var t = 0.0
        var x = 0.0
        for leg in 0..<5 {
            let step: Double = leg % 2 == 0 ? 8 : -8
            for _ in 0..<5 {
                x += step
                t += 0.04
                if detector.feed(x: x, at: t, mouseButtonsPressed: buttons) { fired = true }
            }
        }
        return fired
    }

    func testStrokeFiresOnBackAndForthSweep() {
        var detector = PetStrokeDetector()
        XCTAssertTrue(sweep(&detector, buttons: 0))
    }

    func testStrokeDoesNotFireWhileMouseButtonPressed() {
        var detector = PetStrokeDetector()
        XCTAssertFalse(sweep(&detector, buttons: 1), "dragging must never count as petting")
    }

    func testStraightMovementDoesNotFire() {
        var detector = PetStrokeDetector()
        var fired = false
        for i in 0..<200 {
            if detector.feed(x: Double(i) * 5, at: Double(i) * 0.01, mouseButtonsPressed: 0) { fired = true }
        }
        XCTAssertFalse(fired)
    }
}
