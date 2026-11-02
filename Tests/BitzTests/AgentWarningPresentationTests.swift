import XCTest
@testable import BitzCore

/// How agent warnings look on Bitz: the Amber warning visor and which agent bubbles take clicks (FR-010, R10).
@MainActor
final class AgentWarningPresentationTests: XCTestCase {
    /// Warning Amber (#FFB000).
    private let amber = (red: 1.0, green: 176.0 / 255.0, blue: 0.0)

    func testVisorAmberWhileWarningVisorActiveForEveryStateExceptOverheating() {
        for state in BitzState.allCases {
            let drawn = MascotOverlayView.visorRGB(for: state, warningVisorActive: true)
            let expected = state == .overheating ? MascotOverlayView.visorRGB(for: .overheating) : amber
            XCTAssertTrue(drawn == expected, "\(state): warning visor must be Amber unless overheating (red wins)")
        }
    }

    func testVisorUnchangedWithoutWarningVisor() {
        for state in BitzState.allCases {
            XCTAssertTrue(
                MascotOverlayView.visorRGB(for: state, warningVisorActive: false) == MascotOverlayView.visorRGB(for: state),
                "\(state): no warning, no change"
            )
        }
    }

    func testOnlyWarningAgentPopupIsInteractive() {
        for kind in AgentEventKind.allCases {
            let popup = AgentPopupState(text: "Claude", kind: kind, agentName: "Claude", expiresAt: nil)
            XCTAssertEqual(SpeechBubbleContent.agentPopup(popup).isInteractive, kind == .warning, "\(kind)")
        }
        XCTAssertTrue(SpeechBubbleContent.update(OverlayFixture.release).isInteractive)
        XCTAssertFalse(SpeechBubbleContent.wellness("SYSTEM HOT!").isInteractive)
        XCTAssertFalse(SpeechBubbleContent.carousel("CPU 12%").isInteractive)
    }
}
