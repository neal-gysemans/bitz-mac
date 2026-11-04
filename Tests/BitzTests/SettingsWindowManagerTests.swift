import XCTest
import SwiftUI
@testable import BitzCore

@MainActor
final class SettingsWindowManagerTests: XCTestCase {
    func testSettingsWindowManagerInitialState() {
        let manager = SettingsWindowManager()
        XCTAssertFalse(manager.isWindowOpen)
        XCTAssertNil(manager.window)
    }

    func testShowSettingsWindowCreatesAndConfiguresWindow() {
        let manager = SettingsWindowManager()
        let sampleView = Text("Hello Settings")

        manager.showSettingsWindow(rootView: sampleView)

        XCTAssertTrue(manager.isWindowOpen)
        guard let window = manager.window else {
            XCTFail("Expected window to be instantiated")
            return
        }

        XCTAssertEqual(window.title, "Bitz Settings")
        XCTAssertTrue(window.styleMask.contains(.titled))
        XCTAssertTrue(window.styleMask.contains(.closable))
        XCTAssertTrue(window.styleMask.contains(.miniaturizable))
        XCTAssertFalse(window.isReleasedWhenClosed)

        manager.closeSettingsWindow()
        XCTAssertFalse(manager.isWindowOpen)
    }

    func testShowSettingsWindowReusesExistingWindowInstance() {
        let manager = SettingsWindowManager()
        let sampleView1 = Text("Tab 1")
        let sampleView2 = Text("Tab 2")

        manager.showSettingsWindow(rootView: sampleView1)
        let firstWindow = manager.window

        manager.showSettingsWindow(rootView: sampleView2)
        let secondWindow = manager.window

        XCTAssertTrue(manager.isWindowOpen)
        XCTAssertEqual(firstWindow, secondWindow, "Window manager must reuse existing window instance")

        manager.closeSettingsWindow()
        XCTAssertFalse(manager.isWindowOpen)
    }

    func testSettingsWindowCloseInvokesOnWindowClosed() {
        let manager = SettingsWindowManager()
        var closeCallbackCount = 0
        manager.onWindowClosed = {
            closeCallbackCount += 1
        }

        manager.showSettingsWindow(rootView: Text("Settings Content"))
        XCTAssertTrue(manager.isWindowOpen)
        XCTAssertEqual(closeCallbackCount, 0)

        manager.closeSettingsWindow()
        XCTAssertFalse(manager.isWindowOpen)
        XCTAssertEqual(closeCallbackCount, 1, "onWindowClosed must fire exactly once on close")
    }

    func testCloseDetachesHostingControllerAndReopenReattachesWithoutIntrinsicSizing() throws {
        let manager = SettingsWindowManager()
        manager.showSettingsWindow(rootView: Text("Settings Content"))

        let window = try XCTUnwrap(manager.window)
        let initialHosting = try XCTUnwrap(window.contentViewController as? NSHostingController<Text>)
        XCTAssertEqual(initialHosting.sizingOptions, [], "Settings NSHostingController must disable sizingOptions to avoid 30 fps layout thrash (#70)")

        manager.closeSettingsWindow()
        XCTAssertFalse(manager.isWindowOpen)
        XCTAssertFalse(manager.isWindowVisible)
        XCTAssertNil(window.contentViewController, "Closing Settings must detach contentViewController so background TimelineViews stop (#70)")

        // Reopen must reuse the same NSWindow shell and reattach a fresh hosting controller with sizingOptions == []
        manager.showSettingsWindow(rootView: Text("Reopened Settings Content"))
        XCTAssertTrue(manager.isWindowOpen)
        XCTAssertTrue(manager.window === window, "Reopening Settings must reuse the existing NSWindow instance")
        let reopenedHosting = try XCTUnwrap(window.contentViewController as? NSHostingController<Text>)
        XCTAssertEqual(reopenedHosting.sizingOptions, [])

        manager.closeSettingsWindow()
    }

    func testAnimatedBitzCharacterViewAdaptiveFrameInterval() {
        XCTAssertEqual(AnimatedBitzCharacterView.frameInterval(for: .balanced), 1.0 / 15.0, accuracy: 0.0001)
        XCTAssertEqual(AnimatedBitzCharacterView.frameInterval(for: .charging), 1.0 / 15.0, accuracy: 0.0001)
        XCTAssertEqual(AnimatedBitzCharacterView.frameInterval(for: .burnout), 1.0 / 15.0, accuracy: 0.0001)
        XCTAssertEqual(AnimatedBitzCharacterView.frameInterval(for: .overworked), 1.0 / 15.0, accuracy: 0.0001)
        XCTAssertEqual(AnimatedBitzCharacterView.frameInterval(for: .dopamineSad), 1.0 / 15.0, accuracy: 0.0001)

        XCTAssertEqual(AnimatedBitzCharacterView.frameInterval(for: .superCharged), 1.0 / 30.0, accuracy: 0.0001)
        XCTAssertEqual(AnimatedBitzCharacterView.frameInterval(for: .overheating), 1.0 / 30.0, accuracy: 0.0001)
        XCTAssertEqual(AnimatedBitzCharacterView.frameInterval(for: .balanced, isPetReactionActive: true), 1.0 / 30.0, accuracy: 0.0001)
    }

    /// #94 A9: AppKit gets the SwiftUI content minimum, so the window can't shrink below it.
    func testWindowContentMinSizeMatchesRootMinimum() {
        let manager = SettingsWindowManager()
        manager.showSettingsWindow(rootView: Text("Min"))
        defer { manager.closeSettingsWindow() }

        XCTAssertEqual(manager.window?.contentMinSize, SettingsWindowManager.minimumContentSize)

        // Reopen re-hosts the content after teardown, which must not drop the minimum
        manager.closeSettingsWindow()
        manager.showSettingsWindow(rootView: Text("Min"))
        XCTAssertEqual(manager.window?.contentMinSize, SettingsWindowManager.minimumContentSize)
    }
}
