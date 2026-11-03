import XCTest
import SwiftUI
import AppKit
@testable import BitzCore

@MainActor
final class PawTapAttentionTests: XCTestCase {
    private func makeIsolatedDefaults() -> (UserDefaults, String) {
        let suiteName = "test.bitz.pawtap.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        return (defaults, suiteName)
    }

    func testCALayerMotionBridgeKind_PawTap_EqualityAndInequality() {
        let k1 = CALayerMotionBridge.Kind.pawTap(amplitude: 3.0, halfPeriod: 0.22)
        let k2 = CALayerMotionBridge.Kind.pawTap(amplitude: 3.0, halfPeriod: 0.22)
        let k3 = CALayerMotionBridge.Kind.pawTap(amplitude: 2.0, halfPeriod: 0.22)
        let k4 = CALayerMotionBridge.Kind.pawTap(amplitude: 3.0, halfPeriod: 0.15)
        let kNone = CALayerMotionBridge.Kind.none

        XCTAssertEqual(k1, k2, "Paw-tap kinds with identical parameters must be equal")
        XCTAssertNotEqual(k1, k3, "Different amplitudes must not be equal")
        XCTAssertNotEqual(k1, k4, "Different half-periods must not be equal")
        XCTAssertNotEqual(k1, kNone, "Paw-tap must not equal .none")
    }

    func testCALayerMotionBridgeAnchorView_PawTap_AppliesBasicAnimation() throws {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 200, height: 200),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        let contentView = NSView(frame: NSRect(x: 0, y: 0, width: 200, height: 200))
        contentView.wantsLayer = true
        window.contentView = contentView

        let groupView = NSView(frame: NSRect(x: 10, y: 10, width: 100, height: 100))
        groupView.wantsLayer = true
        contentView.addSubview(groupView)

        let wrapperView = NSView(frame: NSRect(x: 0, y: 0, width: 100, height: 100))
        wrapperView.wantsLayer = true
        groupView.addSubview(wrapperView)

        let anchorView = CALayerMotionBridge.AnchorView(frame: NSRect(x: 0, y: 0, width: 20, height: 20))
        wrapperView.addSubview(anchorView)

        anchorView.currentKind = .pawTap(amplitude: 3.0, halfPeriod: 0.22)
        anchorView.applyIfPossible()

        let anim = try XCTUnwrap(groupView.layer?.animation(forKey: "bitz.motion.primary") as? CABasicAnimation)
        XCTAssertEqual(anim.keyPath, "transform.translation.y")
        let from = try XCTUnwrap(anim.fromValue as? NSNumber)
        XCTAssertEqual(from.doubleValue, -3.0, accuracy: 0.001)
        let to = try XCTUnwrap(anim.toValue as? NSNumber)
        XCTAssertEqual(to.doubleValue, 3.0, accuracy: 0.001)
        XCTAssertEqual(anim.duration, 0.22, accuracy: 0.001)
        XCTAssertTrue(anim.autoreverses)
        XCTAssertEqual(anim.repeatCount, .infinity)
    }

    func testLiveBitzCharacterView_AttentionCuePropertyDefaultsAndPropagation() {
        let viewDefault = LiveBitzCharacterView(state: .balanced)
        XCTAssertFalse(viewDefault.isAttentionCueActive, "Default isAttentionCueActive must be false")

        let viewActive = LiveBitzCharacterView(state: .balanced, isAttentionCueActive: true)
        XCTAssertTrue(viewActive.isAttentionCueActive, "isAttentionCueActive must preserve true when passed")
    }

    func testMascotOverlayView_AttentionCueDrivenByNeedsApproval() {
        let (defaults, suiteName) = makeIsolatedDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let fixture = OverlayFixture(defaults: defaults)
        let paletteStore = AvatarPaletteStore(userDefaults: defaults)

        let overlay = MascotOverlayView(
            engine: fixture.engine,
            scaleStore: fixture.scaleStore,
            opacityStore: fixture.opacityStore,
            positionStore: fixture.positionStore,
            telemetryDashboard: fixture.telemetryDashboard,
            telemetrySettings: fixture.telemetrySettings,
            interactionSettings: MascotInteractionSettingsStore(userDefaults: defaults),
            paletteStore: paletteStore,
            agentMonitor: fixture.agentMonitor
        )

        XCTAssertFalse(overlay.isAttentionCueActive, "Attention cue must be inactive when no popup exists")

        // Trigger .needsApproval event
        let approvalEvent = AgentEvent(
            agentID: "claude",
            agentName: "Claude",
            kind: .needsApproval,
            message: "Approval required for command"
        )
        fixture.agentMonitor.handleEvent(approvalEvent)

        XCTAssertEqual(fixture.agentMonitor.activePopup?.kind, .needsApproval)
        XCTAssertTrue(overlay.isAttentionCueActive, "Attention cue must activate when an agent needs approval")

        // Dismiss popup
        fixture.agentMonitor.dismissPopup()

        XCTAssertNil(fixture.agentMonitor.activePopup)
        XCTAssertFalse(overlay.isAttentionCueActive, "Attention cue must immediately deactivate when popup is dismissed")
    }

    func testMascotOverlayView_NonApprovalPopupsDoNotTriggerAttentionCue() {
        let (defaults, suiteName) = makeIsolatedDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let fixture = OverlayFixture(defaults: defaults)
        let paletteStore = AvatarPaletteStore(userDefaults: defaults)

        let overlay = MascotOverlayView(
            engine: fixture.engine,
            scaleStore: fixture.scaleStore,
            opacityStore: fixture.opacityStore,
            positionStore: fixture.positionStore,
            telemetryDashboard: fixture.telemetryDashboard,
            telemetrySettings: fixture.telemetrySettings,
            interactionSettings: MascotInteractionSettingsStore(userDefaults: defaults),
            paletteStore: paletteStore,
            agentMonitor: fixture.agentMonitor
        )

        // Test .almostDone event
        let almostDoneEvent = AgentEvent(
            agentID: "claude",
            agentName: "Claude",
            kind: .almostDone,
            message: "Wrapping up"
        )
        fixture.agentMonitor.handleEvent(almostDoneEvent)
        XCTAssertEqual(fixture.agentMonitor.activePopup?.kind, .almostDone)
        XCTAssertFalse(overlay.isAttentionCueActive, "almostDone popups must NOT activate the paw-tap cue")

        // Test .working event
        let workingEvent = AgentEvent(
            agentID: "claude",
            agentName: "Claude",
            kind: .working,
            message: "Working on task"
        )
        fixture.agentMonitor.handleEvent(workingEvent)
        XCTAssertFalse(overlay.isAttentionCueActive, "working state must NOT activate the paw-tap cue")
    }

    func testMascotOverlayView_ExplicitAttentionCueOverride() {
        let (defaults, suiteName) = makeIsolatedDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let fixture = OverlayFixture(defaults: defaults)
        let paletteStore = AvatarPaletteStore(userDefaults: defaults)

        let overlayExplicitTrue = MascotOverlayView(
            engine: fixture.engine,
            paletteStore: paletteStore,
            agentMonitor: fixture.agentMonitor,
            isAttentionCueActive: true
        )
        XCTAssertTrue(overlayExplicitTrue.isAttentionCueActive, "Explicit true must override nil activePopup")

        let overlayExplicitFalse = MascotOverlayView(
            engine: fixture.engine,
            paletteStore: paletteStore,
            agentMonitor: fixture.agentMonitor,
            isAttentionCueActive: false
        )
        // Trigger .needsApproval
        let approvalEvent = AgentEvent(
            agentID: "claude",
            agentName: "Claude",
            kind: .needsApproval,
            message: "Approval required"
        )
        fixture.agentMonitor.handleEvent(approvalEvent)
        XCTAssertEqual(fixture.agentMonitor.activePopup?.kind, .needsApproval)
        XCTAssertFalse(overlayExplicitFalse.isAttentionCueActive, "Explicit false must override activePopup")
    }
}
