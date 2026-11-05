import XCTest
@testable import BitzCore

/// #43: `CGPreflightScreenCaptureAccess` can say no for a granted app, so a ScreenCaptureKit probe has the last word.
final class MeetingPermissionCheckerTests: XCTestCase {
    private final class Calls: @unchecked Sendable { var probes = 0; var requests = 0 }

    private var suiteName: String!
    private var defaults: UserDefaults!

    override func setUp() {
        suiteName = "MeetingPermissionCheckerTests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)!
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
    }

    private func makeChecker(preflight: Bool, probe: Bool, calls: Calls) -> SystemMeetingPermissionChecker {
        SystemMeetingPermissionChecker(
            userDefaults: defaults,
            preflightScreenCapture: { preflight },
            requestScreenCapture: { calls.requests += 1; return false },
            probeScreenCapture: { calls.probes += 1; return probe }
        )
    }

    private func requestSystemAudio(_ checker: SystemMeetingPermissionChecker) async -> MeetingPermissionState {
        await checker.requestPermissions(captureMicrophone: false, captureSystemAudio: true, transcribe: false)
    }

    func testPreflightFalseButProbeSucceedsIsAuthorizedWithoutPrompt() async {
        let calls = Calls()
        let checker = makeChecker(preflight: false, probe: true, calls: calls)

        let state = await requestSystemAudio(checker)

        XCTAssertEqual(state.screenAudio, .authorized)
        XCTAssertEqual(calls.requests, 0, "no CGRequestScreenCaptureAccess prompt")
        XCTAssertFalse(defaults.bool(forKey: SystemMeetingPermissionChecker.screenCaptureRequestedKey))
        XCTAssertEqual(checker.currentPermissions().screenAudio, .authorized, "the cached probe feeds the Settings pills")
    }

    func testPreflightFalseAndProbeDeclinedTakesTheRequestPath() async {
        let calls = Calls()
        let checker = makeChecker(preflight: false, probe: false, calls: calls)

        let state = await requestSystemAudio(checker)

        XCTAssertEqual(state.screenAudio, .denied)
        XCTAssertEqual(calls.requests, 1)
        XCTAssertTrue(defaults.bool(forKey: SystemMeetingPermissionChecker.screenCaptureRequestedKey))
        XCTAssertEqual(checker.currentPermissions().screenAudio, .denied)
    }

    func testPreflightTrueIsAuthorizedWithoutProbe() async {
        let calls = Calls()
        let checker = makeChecker(preflight: true, probe: false, calls: calls)

        let state = await requestSystemAudio(checker)
        let refreshed = await checker.refreshedPermissions()

        XCTAssertEqual(state.screenAudio, .authorized)
        XCTAssertEqual(refreshed.screenAudio, .authorized)
        XCTAssertEqual(calls.probes, 0)
        XCTAssertEqual(calls.requests, 0)
    }

    func testRefreshProbesOnlyAfterARequestAndNoticesARevokedGrant() async {
        let calls = Calls()
        let fresh = makeChecker(preflight: false, probe: true, calls: calls)
        let untouched = await fresh.refreshedPermissions()
        XCTAssertEqual(untouched.screenAudio, .notDetermined)
        XCTAssertEqual(calls.probes, 0, "opening Settings never probes (and so never prompts) before anything asked")

        defaults.set(true, forKey: SystemMeetingPermissionChecker.screenCaptureRequestedKey)
        let granted = await fresh.refreshedPermissions()
        XCTAssertEqual(granted.screenAudio, .authorized, "the false preflight denial is corrected")

        let revoked = await makeChecker(preflight: false, probe: false, calls: calls).refreshedPermissions()
        XCTAssertEqual(revoked.screenAudio, .denied)
        XCTAssertEqual(calls.requests, 0)
    }
}
