import XCTest
@testable import BitzCore

final class PersonalityGuardRailTests: XCTestCase {

    // MARK: - Test Doubles

    struct MockPowerState: PowerStateProviding {
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

    // MARK: - PersonalityGate Tests

    func testPersonalityGateAllowsNominalConditions() {
        let gate = PersonalityGate()
        let power = MockPowerState(batteryLevelPercentage: 85.0, isLowPowerModeEnabled: false, thermalState: .nominal)
        let context = PersonalityContext(wellnessState: .balanced)

        let result = gate.evaluate(powerState: power, context: context)
        XCTAssertEqual(result, .allowed)
        XCTAssertTrue(result.isAllowed)
        XCTAssertNil(result.error)
    }

    func testPersonalityGateAllowsDesktopWithoutBattery() {
        let gate = PersonalityGate()
        let power = MockPowerState(batteryLevelPercentage: nil, isLowPowerModeEnabled: false, thermalState: .fair)
        let context = PersonalityContext(wellnessState: .balanced)

        let result = gate.evaluate(powerState: power, context: context)
        XCTAssertEqual(result, .allowed)
    }

    func testPersonalityGateBlocksLowPowerMode() {
        let gate = PersonalityGate()
        let power = MockPowerState(batteryLevelPercentage: 90.0, isLowPowerModeEnabled: true, thermalState: .nominal)
        let context = PersonalityContext(wellnessState: .balanced)

        let result = gate.evaluate(powerState: power, context: context)
        XCTAssertEqual(result, .blocked(.gated("Low Power Mode is active")))
        XCTAssertFalse(result.isAllowed)
    }

    func testPersonalityGateBlocksThermalSeriousAndCritical() {
        let gate = PersonalityGate()
        let context = PersonalityContext(wellnessState: .balanced)

        let seriousPower = MockPowerState(batteryLevelPercentage: 90.0, thermalState: .serious)
        XCTAssertEqual(gate.evaluate(powerState: seriousPower, context: context), .blocked(.gated("Thermal state is serious")))

        let criticalPower = MockPowerState(batteryLevelPercentage: 90.0, thermalState: .critical)
        XCTAssertEqual(gate.evaluate(powerState: criticalPower, context: context), .blocked(.gated("Thermal state is critical")))
    }

    func testPersonalityGateBlocksLowBattery() {
        let gate = PersonalityGate(lowBatteryThresholdPercent: 20.0)
        let context = PersonalityContext(wellnessState: .balanced)

        let lowPower = MockPowerState(batteryLevelPercentage: 15.0)
        XCTAssertEqual(gate.evaluate(powerState: lowPower, context: context), .blocked(.gated("Battery is low (15%)")))

        let borderPower = MockPowerState(batteryLevelPercentage: 20.0)
        XCTAssertEqual(gate.evaluate(powerState: borderPower, context: context), .allowed)
    }

    func testPersonalityGateBlocksOverheatingWellnessState() {
        let gate = PersonalityGate()
        let power = MockPowerState(batteryLevelPercentage: 90.0, thermalState: .nominal)
        let context = PersonalityContext(wellnessState: .overheating)

        let result = gate.evaluate(powerState: power, context: context)
        XCTAssertEqual(result, .blocked(.gated("System is overheating")))
    }

    // MARK: - PersonalityRateLimiter Tests

    func testPersonalityRateLimiterCooldownAndCap() {
        var limiter = PersonalityRateLimiter()
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!

        let t0 = Date(timeIntervalSince1970: 100_000)
        let tPlus5Min = Date(timeIntervalSince1970: 100_000 + 300)
        let tPlus11Min = Date(timeIntervalSince1970: 100_000 + 660)

        // First attempt allowed
        XCTAssertEqual(limiter.evaluate(now: t0, minIntervalMinutes: 10, dailyCap: 2, calendar: calendar), .allowed)
        XCTAssertTrue(limiter.evaluate(now: t0, minIntervalMinutes: 10, dailyCap: 2, calendar: calendar).isAllowed)
        limiter.recordGeneration(now: t0, calendar: calendar)

        // 5 minutes later: rejected (cooldown active)
        XCTAssertEqual(limiter.evaluate(now: tPlus5Min, minIntervalMinutes: 10, dailyCap: 2, calendar: calendar), .rateLimited)

        // 11 minutes later: allowed
        XCTAssertEqual(limiter.evaluate(now: tPlus11Min, minIntervalMinutes: 10, dailyCap: 2, calendar: calendar), .allowed)
        limiter.recordGeneration(now: tPlus11Min, calendar: calendar)

        // Now daily cap (2) is reached
        let tPlus25Min = Date(timeIntervalSince1970: 100_000 + 1500)
        XCTAssertEqual(limiter.evaluate(now: tPlus25Min, minIntervalMinutes: 10, dailyCap: 2, calendar: calendar), .rateLimited)
    }

    func testPersonalityRateLimiterDayRollover() {
        var limiter = PersonalityRateLimiter()
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!

        let day1 = calendar.date(from: DateComponents(year: 2026, month: 11, day: 3, hour: 12))!
        let day2 = calendar.date(from: DateComponents(year: 2026, month: 11, day: 4, hour: 12))!

        // Cap out day 1
        XCTAssertEqual(limiter.evaluate(now: day1, minIntervalMinutes: 5, dailyCap: 1, calendar: calendar), .allowed)
        limiter.recordGeneration(now: day1, calendar: calendar)
        XCTAssertEqual(limiter.evaluate(now: day1, minIntervalMinutes: 5, dailyCap: 1, calendar: calendar), .rateLimited)

        // Day 2 rolls over
        XCTAssertEqual(limiter.evaluate(now: day2, minIntervalMinutes: 5, dailyCap: 1, calendar: calendar), .allowed)
        XCTAssertEqual(limiter.commentsGeneratedToday, 0)
    }

    // MARK: - CommentarySanitizer Tests

    func testCommentarySanitizerFlattensWhitespaceAndStripsQuotes() {
        let sanitizer = CommentarySanitizer()

        let raw = "\n  \"89°C... are we frying eggs\r\non this M-chip?\" \t "
        let result = sanitizer.sanitize(raw)
        XCTAssertEqual(result, .success("89°C... are we frying eggs on this M-chip?"))

        let smartQuotes = "“Xcode for 2 hours straight.”"
        XCTAssertEqual(sanitizer.sanitize(smartQuotes), .success("Xcode for 2 hours straight."))
    }

    func testCommentarySanitizerStripsMarkdownAndURLs() {
        let sanitizer = CommentarySanitizer()

        let raw = "Check out **activity** at https://apple.com/macos now!"
        let result = sanitizer.sanitize(raw)
        XCTAssertEqual(result, .success("Check out activity at now!"))
    }

    func testCommentarySanitizerRejectsPureURLsOrEmpty() {
        let sanitizer = CommentarySanitizer()

        XCTAssertEqual(sanitizer.sanitize(""), .failure(.outputEmpty))
        XCTAssertEqual(sanitizer.sanitize("   \n\t "), .failure(.outputEmpty))
        XCTAssertEqual(sanitizer.sanitize("https://github.com/AkramKs/bitz-mac"), .failure(.outputSanitizedAway))
        XCTAssertEqual(sanitizer.sanitize("... --- ..."), .failure(.outputSanitizedAway))
    }

    func testCommentarySanitizerRejectsEchoingFrontmostApp() {
        let sanitizer = CommentarySanitizer()
        let context = PersonalityContext(frontmostAppName: "Xcode")

        XCTAssertEqual(sanitizer.sanitize("Xcode", context: context), .failure(.outputSanitizedAway))
        XCTAssertEqual(sanitizer.sanitize("xcode", context: context), .failure(.outputSanitizedAway))
        XCTAssertEqual(sanitizer.sanitize("Xcode is running smoothly today.", context: context), .success("Xcode is running smoothly today."))
    }

    func testCommentarySanitizerWordBoundaryTruncation() {
        let sanitizer = CommentarySanitizer(maxCharacterLength: 50)
        let longText = "This is a very long commentary statement that should be gracefully truncated at a word boundary."

        let result = sanitizer.sanitize(longText)
        guard case .success(let text) = result else {
            return XCTFail("Expected successful truncation")
        }

        XCTAssertTrue(text.count <= 50)
        XCTAssertTrue(text.hasSuffix("…"))
        XCTAssertFalse(text.contains("  "))
    }
}
