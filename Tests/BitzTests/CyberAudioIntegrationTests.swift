import XCTest
@testable import BitzCore

private final class TestClock: @unchecked Sendable {
    private var time: Date
    private let lock = NSLock()

    init(_ initial: Date = Date(timeIntervalSince1970: 1000)) {
        self.time = initial
    }

    var now: Date {
        get {
            lock.lock()
            defer { lock.unlock() }
            return time
        }
        set {
            lock.lock()
            defer { lock.unlock() }
            time = newValue
        }
    }

    func advance(by seconds: TimeInterval) {
        lock.lock()
        defer { lock.unlock() }
        time = time.addingTimeInterval(seconds)
    }
}

@MainActor
final class CyberAudioIntegrationTests: XCTestCase {

    func testStateTransitionsTriggerSoundsExclusivelyOnTransition() {
        let suiteName = "BitzAudioIntegrationTest.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let store = CyberAudioSettingsStore(userDefaults: defaults)
        store.setEnabled(true)

        let clock = TestClock()
        let mockDetector = MockAudioEnvironmentDetector()

        let service = CyberAudioService(
            settingsStore: store,
            environmentDetector: mockDetector,
            dateProvider: { clock.now }
        )

        // 1. Transition into burnout
        service.handleStateTransition(from: .balanced, to: .burnout)
        XCTAssertEqual(service.lastObservedState, .burnout)
        XCTAssertNotNil(service.lastOneShotPlayedAt)

        let burnoutTime = service.lastOneShotPlayedAt

        // 2. Repeat tick in burnout (state unchanged)
        clock.advance(by: 5.0)
        service.handleStateTransition(from: .burnout, to: .burnout)
        // lastOneShotPlayedAt should NOT change because no sound was played on identical state
        XCTAssertEqual(service.lastOneShotPlayedAt, burnoutTime)

        // 3. Transition into superCharged (starts purring)
        clock.advance(by: 5.0)
        service.handleStateTransition(from: .burnout, to: .superCharged)
        XCTAssertTrue(service.isPurring)

        // 4. Transition out of superCharged (stops purring)
        clock.advance(by: 5.0)
        service.handleStateTransition(from: .superCharged, to: .balanced)
        XCTAssertFalse(service.isPurring)
    }

    func testAgentChimeCooldownEnforcement() {
        let suiteName = "BitzAudioIntegrationTest.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let store = CyberAudioSettingsStore(userDefaults: defaults)
        store.setEnabled(true)

        let clock = TestClock()
        let mockDetector = MockAudioEnvironmentDetector()

        let service = CyberAudioService(
            settingsStore: store,
            environmentDetector: mockDetector,
            dateProvider: { clock.now }
        )

        // First chime for agent "claude-1"
        let check1 = service.canPlay(.agentNeedsApproval, agentId: "claude-1", now: clock.now)
        XCTAssertTrue(check1.allowed)
        service.play(.agentNeedsApproval, agentId: "claude-1")

        // Immediate repeat for same agent within 0.5s should be suppressed by global rate limit
        clock.advance(by: 0.5)
        let check2 = service.canPlay(.agentNeedsApproval, agentId: "claude-1", now: clock.now)
        XCTAssertFalse(check2.allowed)
        XCTAssertEqual(check2.reason, .rateLimited) // hit 1.5s global

        // After global interval (e.g. t = 2.5s), hit per-agent cooldown specifically (< 10s)
        clock.advance(by: 2.0)
        let check3 = service.canPlay(.agentNeedsApproval, agentId: "claude-1", now: clock.now)
        XCTAssertFalse(check3.allowed)
        XCTAssertEqual(check3.reason, .cooldownActive)

        // After 10s have passed (t = 11.0s), chime is allowed again
        clock.advance(by: 8.5)
        let check4 = service.canPlay(.agentNeedsApproval, agentId: "claude-1", now: clock.now)
        XCTAssertTrue(check4.allowed)

        // Different agent "gemini-2" at t = 13.0s
        clock.advance(by: 2.0)
        let checkOtherAgent = service.canPlay(.agentNeedsApproval, agentId: "gemini-2", now: clock.now)
        XCTAssertTrue(checkOtherAgent.allowed)
    }

    func testAllDoneFanfareCooldownEnforcement() {
        let suiteName = "BitzAudioIntegrationTest.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let store = CyberAudioSettingsStore(userDefaults: defaults)
        store.setEnabled(true)

        let clock = TestClock()
        let mockDetector = MockAudioEnvironmentDetector()

        let service = CyberAudioService(
            settingsStore: store,
            environmentDetector: mockDetector,
            dateProvider: { clock.now }
        )

        // First fanfare
        XCTAssertTrue(service.canPlay(.allAgentsDone, now: clock.now).allowed)
        service.play(.allAgentsDone)

        // Repeat within 60s should be cooldown suppressed
        clock.advance(by: 30.0)
        let check = service.canPlay(.allAgentsDone, now: clock.now)
        XCTAssertFalse(check.allowed)
        XCTAssertEqual(check.reason, .cooldownActive)

        // After 61s, allowed again
        clock.advance(by: 31.0)
        XCTAssertTrue(service.canPlay(.allAgentsDone, now: clock.now).allowed)
    }

    func testEnvironmentalSuppressionRules() {
        let suiteName = "BitzAudioIntegrationTest.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let store = CyberAudioSettingsStore(userDefaults: defaults)
        store.setEnabled(true)

        let mockDetector = MockAudioEnvironmentDetector()
        let service = CyberAudioService(
            settingsStore: store,
            environmentDetector: mockDetector
        )

        // 1. Mute suppression
        mockDetector.isMuted = true
        let checkMute = service.canPlay(.burnout)
        XCTAssertFalse(checkMute.allowed)
        XCTAssertEqual(checkMute.reason, .systemMuted)
        mockDetector.isMuted = false

        // 2. Microphone / call active suppression
        mockDetector.isMicActive = true
        let checkMic = service.canPlay(.burnout)
        XCTAssertFalse(checkMic.allowed)
        XCTAssertEqual(checkMic.reason, .callOrScreenSharingActive)

        // Disabling call suppression in settings allows playback during calls
        store.setCallSuppressionEnabled(false)
        let checkMicAllowed = service.canPlay(.burnout)
        XCTAssertTrue(checkMicAllowed.allowed)
        store.setCallSuppressionEnabled(true)
        mockDetector.isMicActive = false

        // 3. Do Not Disturb suppression
        mockDetector.isDNDActive = true
        let checkDND = service.canPlay(.burnout)
        XCTAssertFalse(checkDND.allowed)
        XCTAssertEqual(checkDND.reason, .focusActive)
    }
}
