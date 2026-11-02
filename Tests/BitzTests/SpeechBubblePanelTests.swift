import AppKit
import SwiftUI
import XCTest
@testable import BitzCore

@MainActor
final class SpeechBubblePanelTests: XCTestCase {
    private let visibleFrame = NSRect(x: 0.0, y: 40.0, width: 1920.0, height: 1040.0)
    private let longMessage = "Claude Code needs your approval to run: git push --force-with-lease origin fix/overlay-bubble-clipping-61"

    private func createIsolatedDefaults() -> (UserDefaults, () -> Void) {
        let suiteName = "SpeechBubblePanelTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        OverlayFixture.resetAgentMonitorDefaults()
        let cleanup = {
            defaults.removePersistentDomain(forName: suiteName)
            OverlayFixture.resetAgentMonitorDefaults()
        }
        return (defaults, cleanup)
    }

    private func expectedBubbleOrigin(for panel: MascotOverlayPanel) -> NSPoint {
        SpeechBubblePanel.calculateOrigin(
            bubbleSize: panel.speechBubblePanel.frame.size,
            mascotFrame: panel.frame,
            visibleFrame: (panel.screen ?? panel.assignedScreen ?? NSScreen.main)?.visibleFrame ?? .zero,
            earTopInset: panel.earTopInset,
            scaleFactor: panel.currentScaleFactor
        )
    }

    func testBubblePanelNeverStealsFocusAndIsClickThroughByDefault() {
        let bubble = SpeechBubblePanel()

        XCTAssertTrue(bubble.styleMask.contains(.nonactivatingPanel))
        XCTAssertTrue(bubble.styleMask.contains(.borderless))
        XCTAssertEqual(bubble.level, .floating)
        XCTAssertFalse(bubble.isOpaque)
        XCTAssertEqual(bubble.backgroundColor, .clear)
        XCTAssertTrue(bubble.ignoresMouseEvents)
        XCTAssertFalse(bubble.canBecomeKey)
        XCTAssertFalse(bubble.canBecomeMain)
        XCTAssertTrue(bubble.collectionBehavior.contains([.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]))
    }

    func testBubbleIsCenteredJustAboveTheEars() {
        let mascotFrame = NSRect(x: 1650.0, y: 60.0, width: 250.0, height: 250.0)
        let origin = SpeechBubblePanel.calculateOrigin(
            bubbleSize: NSSize(width: 180.0, height: 40.0),
            mascotFrame: mascotFrame,
            visibleFrame: visibleFrame,
            earTopInset: 40.0
        )

        // midX (1775) - half width (90) = 1685
        // maxY (310) - (earTopInset 40 - earGap 10 + glowPadding 8) = 272
        XCTAssertEqual(origin.x, 1685.0, accuracy: 0.001)
        XCTAssertEqual(origin.y, 272.0, accuracy: 0.001)
    }

    func testBubbleFollowsTheEarsDownWhenBitzSitsLower() {
        let mascotFrame = NSRect(x: 1650.0, y: 60.0, width: 250.0, height: 250.0)
        let origin = SpeechBubblePanel.calculateOrigin(
            bubbleSize: NSSize(width: 180.0, height: 40.0),
            mascotFrame: mascotFrame,
            visibleFrame: visibleFrame,
            earTopInset: 90.0
        )

        // Loaf posture with the HUD off: 310 - (90 - 10 + 8) = 222
        XCTAssertEqual(origin.y, 222.0, accuracy: 0.001)
    }

    func testBubbleOffsetScalesWithMascotSize() {
        let mascotFrame = NSRect(x: 800.0, y: 60.0, width: 375.0, height: 375.0)
        let origin = SpeechBubblePanel.calculateOrigin(
            bubbleSize: NSSize(width: 180.0, height: 40.0),
            mascotFrame: mascotFrame,
            visibleFrame: visibleFrame,
            earTopInset: 40.0,
            scaleFactor: 1.5
        )

        // maxY (435) - 38 * 1.5 (57) = 378
        XCTAssertEqual(origin.y, 378.0, accuracy: 0.001)
    }

    func testBubbleFlipsBelowMascotWhenNoRoomAbove() {
        let mascotFrame = NSRect(x: 800.0, y: 810.0, width: 250.0, height: 250.0)
        let origin = SpeechBubblePanel.calculateOrigin(
            bubbleSize: NSSize(width: 180.0, height: 80.0),
            mascotFrame: mascotFrame,
            visibleFrame: visibleFrame,
            earTopInset: 40.0
        )

        // Above would end at 1022 + 80 = 1102 > 1080, so place under the panel: 810 - 80 = 730
        XCTAssertEqual(origin.y, 730.0, accuracy: 0.001)
    }

    func testBubbleIsClampedInsideScreenEdges() {
        let bubbleSize = NSSize(width: 300.0, height: 40.0)

        let left = SpeechBubblePanel.calculateOrigin(
            bubbleSize: bubbleSize,
            mascotFrame: NSRect(x: 0.0, y: 60.0, width: 250.0, height: 250.0),
            visibleFrame: visibleFrame,
            earTopInset: 40.0
        )
        XCTAssertEqual(left.x, 0.0, accuracy: 0.001)

        let right = SpeechBubblePanel.calculateOrigin(
            bubbleSize: bubbleSize,
            mascotFrame: NSRect(x: 1670.0, y: 60.0, width: 250.0, height: 250.0),
            visibleFrame: visibleFrame,
            earTopInset: 40.0
        )
        XCTAssertEqual(right.x, 1620.0, accuracy: 0.001)
    }

    func testBubbleStaysOnScreenWhenNeitherAboveNorBelowFits() {
        let smallScreen = NSRect(x: 0.0, y: 0.0, width: 800.0, height: 300.0)
        let origin = SpeechBubblePanel.calculateOrigin(
            bubbleSize: NSSize(width: 180.0, height: 120.0),
            mascotFrame: NSRect(x: 275.0, y: 25.0, width: 250.0, height: 250.0),
            visibleFrame: smallScreen,
            earTopInset: 40.0
        )

        XCTAssertEqual(origin.y, 180.0, accuracy: 0.001)
    }

    /// AppKit already moves child windows with their parent, so only a move into a screen corner
    /// (where the bubble must flip and clamp) proves the panel re-places it.
    func testBubbleIsReplacedWhenMascotMovesResizesOrEarsMove() throws {
        let panel = MascotOverlayPanel()
        defer { panel.close() }
        let bubble = panel.speechBubblePanel
        let screenFrame = try XCTUnwrap(NSScreen.main?.visibleFrame)

        XCTAssertTrue(panel.childWindows?.contains(bubble) ?? false, "Bubble must be a child so it hides and orders with Bitz")

        panel.setFrameOrigin(NSPoint(x: screenFrame.midX - 125.0, y: screenFrame.minY + 100.0))
        bubble.setFrame(NSRect(origin: bubble.frame.origin, size: NSSize(width: 300.0, height: 60.0)), display: false)
        XCTAssertEqual(bubble.frame.origin, expectedBubbleOrigin(for: panel), "Bubble must re-place itself after resizing")
        XCTAssertGreaterThan(bubble.frame.minY, panel.frame.midY, "Mid-screen the bubble sits above Bitz")

        panel.setFrameOrigin(NSPoint(x: screenFrame.minX, y: screenFrame.maxY - panel.frame.height))
        XCTAssertEqual(bubble.frame.maxY, panel.frame.minY, accuracy: 0.5, "In a top corner the bubble must flip below Bitz")
        XCTAssertEqual(bubble.frame.minX, screenFrame.minX, accuracy: 0.5, "At the left edge the bubble must be clamped on screen")

        panel.earTopInset += 30.0
        XCTAssertEqual(bubble.frame.origin, expectedBubbleOrigin(for: panel), "Bubble must follow the ears")

        panel.repositionOnScreen()
        XCTAssertEqual(bubble.frame.origin, expectedBubbleOrigin(for: panel), "Bubble must follow corner/scale repositioning")
    }

    func testBubbleHidesAndReturnsWithMascot() {
        let panel = MascotOverlayPanel()
        defer { panel.close() }
        let bubble = panel.speechBubblePanel
        bubble.setFrame(NSRect(origin: bubble.frame.origin, size: NSSize(width: 180.0, height: 40.0)), display: false)

        panel.orderFrontRegardless()
        XCTAssertTrue(bubble.isVisible)

        panel.orderOut(nil)
        XCTAssertFalse(bubble.isVisible, "Hiding Bitz must hide the bubble")

        panel.orderFrontRegardless()
        XCTAssertTrue(bubble.isVisible, "Showing Bitz must bring the bubble back")
        panel.orderOut(nil)
    }

    func testBubbleWindowSizesItselfToSpeechBubbleContent() {
        let (defaults, cleanup) = createIsolatedDefaults()
        defer { cleanup() }

        let fixture = OverlayFixture(defaults: defaults)
        let panel = MascotOverlayPanel()
        defer { panel.close() }
        let bubble = panel.speechBubblePanel
        let hostingView = NSHostingView(rootView: fixture.bubbleView)
        bubble.contentView = hostingView
        func windowMatchesBubble() -> Bool {
            bubble.frame.width > 0
                && abs(bubble.frame.width - hostingView.fittingSize.width) <= 1
                && abs(bubble.frame.height - hostingView.fittingSize.height) <= 1
        }

        fixture.showApprovalPopup("Claude needs approval!")
        XCTAssertTrue(spinRunLoop(until: windowMatchesBubble), "Window must match the bubble so nothing is clipped")
        let shortHeight = bubble.frame.height
        XCTAssertEqual(bubble.frame.origin, expectedBubbleOrigin(for: panel))

        fixture.showApprovalPopup(longMessage)
        XCTAssertTrue(spinRunLoop(until: { windowMatchesBubble() && bubble.frame.height > shortHeight }), "Long messages must grow the bubble, not be cut")
        XCTAssertEqual(bubble.frame.origin, expectedBubbleOrigin(for: panel))
    }

    func testMascotViewReportsEarTopForPostureAndHUD() {
        let (defaults, cleanup) = createIsolatedDefaults()
        defer { cleanup() }

        let fixture = OverlayFixture(defaults: defaults)
        var reported: CGFloat?
        let window = NSPanel(
            contentRect: NSRect(origin: .zero, size: MascotOverlayPanel.defaultPanelSize),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        defer { window.close() }
        let hostingView = NSHostingView(rootView: fixture.mascotView(onEarTopChanged: { reported = $0 }))
        window.contentView = hostingView
        // An off-screen window gets no display cycle on macOS 14, so force the layout pass an on-screen panel gets
        func reportArrives(_ condition: () -> Bool) -> Bool {
            spinRunLoop(until: {
                hostingView.layoutSubtreeIfNeeded()
                return condition()
            })
        }

        XCTAssertTrue(reportArrives { reported != nil }, "Mascot view must report its ear position")
        let standing = reported ?? 0
        XCTAssertGreaterThan(standing, 0, "Ears must sit inside the panel with the tallest HUD")

        fixture.engine.setChargingState(true)
        XCTAssertTrue(reportArrives { reported != standing }, "Posture change must be reported")
        let loaf = reported ?? 0
        XCTAssertEqual(
            loaf - standing,
            BitzCharacterView.earOverflow(isLoafPosture: false) - BitzCharacterView.earOverflow(isLoafPosture: true),
            accuracy: 0.5,
            "Loaf posture lowers the ears by the head-lift difference"
        )

        fixture.telemetrySettings.displayInMascotCyberHUD = false
        XCTAssertTrue(reportArrives { reported != loaf }, "HUD change must be reported")
        XCTAssertGreaterThan(reported ?? 0, loaf, "Without the HUD, Bitz and its ears sit lower")
    }

    // Synchronous on purpose: the delegate updates click-through from main-queue callbacks, which an async
    // test (itself a main-queue job) would block while spinning the run loop
    func testOnlyABubbleWithButtonsTakesClicks() throws {
        let (defaults, cleanup) = createIsolatedDefaults()
        defer { cleanup() }

        let positionStore = AvatarPositionStore(userDefaults: defaults)
        let updateStore = AppUpdateStore(
            currentVersionString: "1.2.0",
            updateService: StubUpdateService(release: OverlayFixture.release),
            userDefaults: defaults
        )
        let delegate = BitzAppDelegate(
            telemetryProvider: MockTelemetryProvider(),
            scaleStore: AvatarScaleStore(userDefaults: defaults),
            opacityStore: AvatarOpacityStore(userDefaults: defaults),
            positionStore: positionStore,
            displayStore: DisplayPreferenceStore(userDefaults: defaults),
            updateStore: updateStore,
            userDefaults: defaults
        )
        delegate.setupOverlayPanel()
        defer { delegate.overlayPanels.forEach { $0.close() } }

        let panel = try XCTUnwrap(delegate.overlayPanel)
        let bubble = panel.speechBubblePanel
        XCTAssertTrue(panel.ignoresMouseEvents)
        XCTAssertTrue(bubble.ignoresMouseEvents)

        Task { await updateStore.checkForUpdates(manual: true) }
        XCTAssertTrue(spinRunLoop(until: { !bubble.ignoresMouseEvents }), "Update bubble buttons must be clickable")
        XCTAssertTrue(panel.ignoresMouseEvents, "Mascot must stay click-through during update alerts")

        delegate.agentMonitor.handleEvent(AgentEvent(agentID: "claude", agentName: "Claude", kind: .needsApproval, message: "Claude needs approval!"))
        XCTAssertTrue(spinRunLoop(until: { bubble.ignoresMouseEvents }), "An agent popup covering the update alert has no buttons")

        delegate.agentMonitor.dismissPopup()
        XCTAssertTrue(spinRunLoop(until: { !bubble.ignoresMouseEvents }), "Update buttons are back once the popup is gone")

        updateStore.dismissAlert()
        XCTAssertTrue(spinRunLoop(until: { bubble.ignoresMouseEvents }))

        positionStore.unlockPosition()
        XCTAssertFalse(panel.ignoresMouseEvents, "Mascot takes clicks while dragging is unlocked")
        XCTAssertTrue(bubble.ignoresMouseEvents, "Bubble stays click-through while dragging")
        positionStore.lockPosition()
        XCTAssertTrue(panel.ignoresMouseEvents)
    }

    // Synchronous for the same reason as `testOnlyABubbleWithButtonsTakesClicks`
    func testWarningBubbleTakesClicksOnlyUntilAcknowledged() throws {
        let (defaults, cleanup) = createIsolatedDefaults()
        defer { cleanup() }

        let delegate = BitzAppDelegate(
            telemetryProvider: MockTelemetryProvider(),
            scaleStore: AvatarScaleStore(userDefaults: defaults),
            opacityStore: AvatarOpacityStore(userDefaults: defaults),
            positionStore: AvatarPositionStore(userDefaults: defaults),
            displayStore: DisplayPreferenceStore(userDefaults: defaults),
            updateStore: AppUpdateStore(userDefaults: defaults),
            userDefaults: defaults
        )
        delegate.setupOverlayPanel()
        defer { delegate.overlayPanels.forEach { $0.close() } }

        let panel = try XCTUnwrap(delegate.overlayPanel)
        let bubble = panel.speechBubblePanel
        XCTAssertTrue(bubble.ignoresMouseEvents)
        XCTAssertFalse(delegate.engine.isWarningVisorActive)

        delegate.agentMonitor.handleEvent(AgentEvent(
            agentID: "claude", agentName: "Claude", kind: .warning, message: "⚠️ Claude may be stuck",
            metadata: [AgentEvent.MetadataKey.reason: "reported"]
        ))
        XCTAssertTrue(spinRunLoop(until: { !bubble.ignoresMouseEvents }), "GOT IT must be clickable")
        XCTAssertTrue(panel.ignoresMouseEvents, "Mascot stays click-through during a warning")
        XCTAssertTrue(spinRunLoop(until: { delegate.engine.isWarningVisorActive }), "A warning turns the visor Amber")
        XCTAssertFalse(bubble.canBecomeKey, "Clicking GOT IT must not steal focus")

        // GOT IT's action
        delegate.agentMonitor.acknowledgeWarning()
        XCTAssertTrue(spinRunLoop(until: { bubble.ignoresMouseEvents }), "Bubble reverts to click-through right after GOT IT")
        XCTAssertTrue(spinRunLoop(until: { !delegate.engine.isWarningVisorActive }), "Acknowledging clears the Amber visor")

        delegate.agentMonitor.handleEvent(AgentEvent(agentID: "claude", agentName: "Claude", kind: .almostDone, message: "✨ Claude is almost done!"))
        XCTAssertEqual(delegate.agentMonitor.activePopup?.kind, .almostDone)
        XCTAssertFalse(spinRunLoop(until: { !bubble.ignoresMouseEvents }, timeout: 0.3), "The almost-done bubble has no buttons")
        XCTAssertFalse(bubble.canBecomeKey)
    }
}
