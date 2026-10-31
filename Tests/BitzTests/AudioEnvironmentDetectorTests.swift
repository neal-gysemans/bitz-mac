import XCTest
@testable import BitzCore

final class AudioEnvironmentDetectorTests: XCTestCase {

    func testMockAudioEnvironmentDetectorCustomProperties() {
        let detector = MockAudioEnvironmentDetector(isMuted: true, isMicActive: true, isDNDActive: true)

        XCTAssertTrue(detector.isSystemOutputMuted())
        XCTAssertTrue(detector.isMicrophoneOrScreenCaptureActive())
        XCTAssertTrue(detector.isFocusOrDNDActive())

        detector.isMuted = false
        detector.isMicActive = false
        detector.isDNDActive = false

        XCTAssertFalse(detector.isSystemOutputMuted())
        XCTAssertFalse(detector.isMicrophoneOrScreenCaptureActive())
        XCTAssertFalse(detector.isFocusOrDNDActive())
    }

    func testRealDetectorInitializationDoesNotCrash() {
        let detector = AudioEnvironmentDetector()
        // Calling CoreAudio queries in CI should return safe boolean without throwing or crashing
        _ = detector.isSystemOutputMuted()
        _ = detector.isMicrophoneOrScreenCaptureActive()
        _ = detector.isFocusOrDNDActive()
    }
}
