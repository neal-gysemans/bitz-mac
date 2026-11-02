import AppKit
import SwiftUI
import XCTest
@testable import BitzCore

/// Regression guard for #61: each overlay window is exactly the size of its SwiftUI content, so anything
/// drawn outside that size is clipped by the window. These tests render the content inside an empty
/// margin and assert nothing visible lands in that margin.
@MainActor
final class MascotOverlayLayoutTests: XCTestCase {
    private let margin: CGFloat = 40
    private let renderScale: CGFloat = 2
    // Drag-mode border stroke is centered on the frame edge, so half of it sits just outside
    private let edgeTolerance: CGFloat = 2

    private var defaults: UserDefaults!
    private var suiteName: String!

    override func setUp() async throws {
        suiteName = "MascotOverlayLayoutTests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
        OverlayFixture.resetAgentMonitorDefaults()
    }

    override func tearDown() async throws {
        defaults.removePersistentDomain(forName: suiteName)
        OverlayFixture.resetAgentMonitorDefaults()
    }

    func testMascotWithFullHUDStaysInsidePanel() throws {
        let fixture = OverlayFixture(defaults: defaults)
        try assertNothingDrawnOutside(fixture.mascotView(), size: MascotOverlayPanel.defaultPanelSize)
    }

    func testMascotInDragModeStaysInsidePanel() throws {
        let fixture = OverlayFixture(defaults: defaults)
        fixture.positionStore.unlockPosition()
        try assertNothingDrawnOutside(fixture.mascotView(), size: MascotOverlayPanel.defaultPanelSize)
    }

    func testLongAgentBubbleIsNotClippedByItsWindow() throws {
        let fixture = OverlayFixture(defaults: defaults)
        fixture.showApprovalPopup("Claude Code needs your approval to run: git push --force-with-lease origin fix/overlay-bubble-clipping-61")
        XCTAssertNotNil(fixture.agentMonitor.activePopup, "Agent bubble must be showing")
        try assertBubbleFitsItsWindow(fixture.bubbleView)
    }

    func testUpdateBubbleAtLargestScaleIsNotClippedByItsWindow() async throws {
        let fixture = OverlayFixture(defaults: defaults)
        fixture.scaleStore.setScale(AvatarScaleStore.maxScaleFactor)
        await fixture.updateStore.checkForUpdates(manual: true)
        XCTAssertTrue(fixture.updateStore.isSpeechBubbleAlertActive, "Update bubble must be showing")
        try assertBubbleFitsItsWindow(fixture.bubbleView)
    }

    func testWarningBubbleWithButtonAtLargestScaleIsNotClippedByItsWindow() throws {
        let fixture = OverlayFixture(defaults: defaults)
        fixture.scaleStore.setScale(AvatarScaleStore.maxScaleFactor)
        fixture.showWarning("⚠️ Claude may be stuck in a tool loop (Bash ×4): swift test --filter MascotOverlayLayoutTests --parallel")
        XCTAssertEqual(fixture.agentMonitor.activePopup?.kind, .warning, "Warning bubble must be showing")
        try assertBubbleFitsItsWindow(fixture.bubbleView)
    }

    func testAlmostDoneBubbleIsNotClippedByItsWindow() throws {
        let fixture = OverlayFixture(defaults: defaults)
        fixture.showAlmostDone("✨ Claude is almost done! Wrapping up the overlay layout fixes and running the full test suite")
        XCTAssertEqual(fixture.agentMonitor.activePopup?.kind, .almostDone, "Almost-done bubble must be showing")
        try assertBubbleFitsItsWindow(fixture.bubbleView)
    }

    func testMascotWithWarningVisorStaysInsidePanel() throws {
        let fixture = OverlayFixture(defaults: defaults)
        fixture.engine.setWarningVisor(active: true)
        try assertNothingDrawnOutside(fixture.mascotView(), size: MascotOverlayPanel.defaultPanelSize)
    }

    /// The bubble is anchored to `earOverflow`, so it must match where the ears are actually drawn.
    func testEarOverflowMatchesDrawnEarTips() throws {
        for isLoafPosture in [false, true] {
            // time 0 puts the breathing offset at rest; particles would float above the ears
            let character = BitzCharacterView(state: .balanced, time: 0, isLoafPosture: isLoafPosture, showParticles: false)
            let renderer = ImageRenderer(content: character.padding(margin))
            renderer.scale = renderScale
            let image = try XCTUnwrap(renderer.cgImage)
            let topRow = try XCTUnwrap(topmostVisibleRow(in: image), "Character must draw something")

            let earTipAboveFrame = margin - CGFloat(topRow) / renderScale
            XCTAssertEqual(
                earTipAboveFrame,
                BitzCharacterView.earOverflow(isLoafPosture: isLoafPosture),
                accuracy: 1.5,
                "Ear tips must rise earOverflow above the frame (loaf: \(isLoafPosture))"
            )
        }
    }

    /// ⌥ is used for typing on AZERTY layouts; holding it must not swap the HUD for the drag pill.
    func testHoldingOptionKeepsHUDVisible() throws {
        let fixture = OverlayFixture(defaults: defaults)
        // HUD band, clear of the character above and of the drag border's glow (~12 pt in from each edge)
        let hudBand = CGRect(x: 20, y: 214, width: 210, height: 20)

        let normal = try render(fixture.mascotView())
        fixture.positionStore.setModifierHeld(true)
        let optionHeld = try render(fixture.mascotView())
        fixture.positionStore.setModifierHeld(false)
        fixture.positionStore.unlockPosition()
        let unlocked = try render(fixture.mascotView())

        XCTAssertEqual(differingPixels(normal, optionHeld, in: hudBand), 0, "Holding ⌥ must leave the HUD untouched")
        XCTAssertGreaterThan(differingPixels(normal, unlocked, in: hudBand), 100, "Unlocking must swap the HUD for the drag pill")
    }

    /// The bubble window takes the hosting view's fitting size, so drawing must stay within it.
    private func assertBubbleFitsItsWindow(
        _ view: SpeechBubbleView,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws {
        let windowSize = NSHostingView(rootView: view).fittingSize
        XCTAssertGreaterThan(windowSize.width, 0, "Bubble must have content", file: file, line: line)
        try assertNothingDrawnOutside(view, size: windowSize, file: file, line: line)
    }

    private func assertNothingDrawnOutside<V: View>(
        _ view: V,
        size: NSSize,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws {
        let image = try render(view.frame(width: size.width, height: size.height).padding(margin))

        XCTAssertEqual(
            visiblePixelsOutside(size: size, in: image),
            0,
            "Content is drawn outside its \(Int(size.width))×\(Int(size.height)) pt window and will be clipped",
            file: file,
            line: line
        )
    }

    private func render<V: View>(_ view: V) throws -> CGImage {
        let renderer = ImageRenderer(content: view)
        renderer.scale = renderScale
        return try XCTUnwrap(renderer.cgImage)
    }

    /// RGBA bytes with row 0 at the top of the image.
    private func rgbaPixels(of image: CGImage) -> [UInt8] {
        var pixels = [UInt8](repeating: 0, count: image.width * image.height * 4)
        let context = CGContext(
            data: &pixels,
            width: image.width,
            height: image.height,
            bitsPerComponent: 8,
            bytesPerRow: image.width * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )
        context?.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        return pixels
    }

    /// Counts clearly visible pixels outside the window rect; faint glows and shadows are ignored.
    private func visiblePixelsOutside(size: NSSize, in image: CGImage) -> Int {
        let pixels = rgbaPixels(of: image)
        let start = Int(((margin - edgeTolerance) * renderScale).rounded(.down))
        let xRange = start..<Int(((margin + size.width + edgeTolerance) * renderScale).rounded(.up))
        let yRange = start..<Int(((margin + size.height + edgeTolerance) * renderScale).rounded(.up))

        var count = 0
        for y in 0..<image.height {
            for x in 0..<image.width where !(xRange.contains(x) && yRange.contains(y)) {
                if pixels[(y * image.width + x) * 4 + 3] > 128 {
                    count += 1
                }
            }
        }
        return count
    }

    private func topmostVisibleRow(in image: CGImage) -> Int? {
        let pixels = rgbaPixels(of: image)
        return (0..<image.height).first { y in
            (0..<image.width).contains { x in pixels[(y * image.width + x) * 4 + 3] > 128 }
        }
    }

    /// Counts pixels inside `rect` (pt, from the top-left) that visibly differ between two same-size renders;
    /// faint glow tails (any channel within 16/255) are ignored.
    private func differingPixels(_ first: CGImage, _ second: CGImage, in rect: CGRect) -> Int {
        let a = rgbaPixels(of: first)
        let b = rgbaPixels(of: second)
        var count = 0
        for y in Int(rect.minY * renderScale)..<Int(rect.maxY * renderScale) {
            for x in Int(rect.minX * renderScale)..<Int(rect.maxX * renderScale) {
                let i = (y * first.width + x) * 4
                if (i..<i + 4).contains(where: { abs(Int(a[$0]) - Int(b[$0])) > 16 }) {
                    count += 1
                }
            }
        }
        return count
    }
}
