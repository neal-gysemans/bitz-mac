import AppKit
import SwiftUI
import XCTest
@testable import BitzCore

@MainActor
final class MascotOverlayPanelTests: XCTestCase {

    func testOverlayPanelWindowInvariantsMatchContractByteForByte() {
        let panel = MascotOverlayPanel()

        XCTAssertTrue(panel.styleMask.contains(.nonactivatingPanel))
        XCTAssertTrue(panel.styleMask.contains(.borderless))
        XCTAssertEqual(panel.backingType, .buffered)
        XCTAssertTrue(panel.isFloatingPanel)
        XCTAssertEqual(panel.level, .floating)
        XCTAssertFalse(panel.isOpaque)
        XCTAssertEqual(panel.backgroundColor, .clear)
        XCTAssertFalse(panel.hasShadow)
        XCTAssertFalse(panel.isMovableByWindowBackground)
        XCTAssertTrue(panel.ignoresMouseEvents)
        XCTAssertFalse(panel.canBecomeKey)
        XCTAssertFalse(panel.canBecomeMain)

        let expectedBehavior: NSWindow.CollectionBehavior = [
            .canJoinAllSpaces,
            .fullScreenAuxiliary,
            .stationary
        ]
        XCTAssertTrue(panel.collectionBehavior.contains(expectedBehavior))
    }

    func testBottomRightOriginCalculationAndScreenPositioning() {
        let visibleFrame = NSRect(x: 0.0, y: 40.0, width: 1920.0, height: 1040.0)
        let origin = MascotOverlayPanel.calculateOrigin(for: visibleFrame)

        // maxX (1920) - width (250) - rightEdgePadding (20) = 1650
        // minY (40) + bottomEdgePadding (20) = 60
        XCTAssertEqual(origin.x, 1650.0, accuracy: 0.001)
        XCTAssertEqual(origin.y, 60.0, accuracy: 0.001)

        let panel = MascotOverlayPanel()
        panel.positionInBottomRight(of: nil)
        XCTAssertEqual(panel.frame.size.width, 250.0, accuracy: 0.001)
        XCTAssertEqual(panel.frame.size.height, 250.0, accuracy: 0.001)
    }

    func testMascotOverlayViewVisorColorMappingAndRendering() {
        let cyan = MascotOverlayView.visorRGB(for: .balanced)
        XCTAssertEqual(cyan.red, 0.0, accuracy: 0.001)
        XCTAssertEqual(cyan.green, 240.0 / 255.0, accuracy: 0.001)
        XCTAssertEqual(cyan.blue, 1.0, accuracy: 0.001)

        let magenta = MascotOverlayView.visorRGB(for: .superCharged)
        XCTAssertEqual(magenta.red, 1.0, accuracy: 0.001)
        XCTAssertEqual(magenta.green, 0.0, accuracy: 0.001)
        XCTAssertEqual(magenta.blue, 127.0 / 255.0, accuracy: 0.001)

        let amber = MascotOverlayView.visorRGB(for: .overworked)
        XCTAssertEqual(amber.red, 1.0, accuracy: 0.001)
        XCTAssertEqual(amber.green, 176.0 / 255.0, accuracy: 0.001)
        XCTAssertEqual(amber.blue, 0.0, accuracy: 0.001)

        let red = MascotOverlayView.visorRGB(for: .overheating)
        XCTAssertEqual(red.red, 1.0, accuracy: 0.001)
        XCTAssertEqual(red.green, 30.0 / 255.0, accuracy: 0.001)
        XCTAssertEqual(red.blue, 30.0 / 255.0, accuracy: 0.001)
    }

    func testBitzAppDelegateLifecycleWiresOverlayPanelAndActivityMonitor() {
        let suiteName = "BitzLifecycleTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let telemetry = MockTelemetryProvider()
        let scaleStore = AvatarScaleStore(userDefaults: defaults)
        let delegate = BitzAppDelegate(telemetryProvider: telemetry, scaleStore: scaleStore)

        delegate.applicationDidFinishLaunching(Notification(name: NSApplication.didFinishLaunchingNotification))

        XCTAssertNotNil(delegate.overlayPanel)
        XCTAssertEqual(delegate.overlayPanel?.ignoresMouseEvents, true)
        XCTAssertEqual(delegate.overlayPanel?.isOpaque, false)
        XCTAssertTrue(delegate.activityMonitor.isMonitoring)

        delegate.engine.triggerThermalWarning(isOverheating: true)
        XCTAssertEqual(delegate.engine.activeSpeechBubbleText, WellnessPointEngine.thermalWarningText)

        delegate.engine.triggerPetInteraction()
        XCTAssertEqual(delegate.riveController.lastTriggeredInput, "triggerPet")

        delegate.applicationWillTerminate(Notification(name: NSApplication.willTerminateNotification))
        XCTAssertFalse(delegate.activityMonitor.isMonitoring)
    }

    func testAvatarScaleStoreDefaultPresetsAndStepClamping() {
        let suiteName = "BitzScaleStoreTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let store = AvatarScaleStore(userDefaults: defaults)
        XCTAssertEqual(store.scaleFactor, 1.00, accuracy: 0.001)
        XCTAssertEqual(store.percentageInt, 100)
        XCTAssertEqual(store.pointDimensionInt, 250)
        XCTAssertEqual(store.formattedSizeSummary, "100% (250×250 pt)")
        XCTAssertTrue(store.isPresetSelected(.defaultSize))
        XCTAssertTrue(store.canStepDown)
        XCTAssertTrue(store.canStepUp)

        // Verify all 5 presets
        for preset in AvatarSizePreset.allCases {
            store.selectPreset(preset)
            XCTAssertEqual(store.scaleFactor, preset.rawValue, accuracy: 0.001)
            XCTAssertTrue(store.isPresetSelected(preset))
            XCTAssertFalse(preset.menuTitle.isEmpty)
            XCTAssertFalse(preset.percentageText.isEmpty)
        }

        // Step down repeatedly to minimum (0.50 / 50%)
        store.selectPreset(.small) // 0.60
        store.stepDown()
        XCTAssertEqual(store.scaleFactor, 0.50, accuracy: 0.001)
        XCTAssertFalse(store.canStepDown)
        store.stepDown() // Clamped at 0.50
        XCTAssertEqual(store.scaleFactor, 0.50, accuracy: 0.001)
        XCTAssertEqual(store.pointDimensionInt, 125)

        // Step up from quarter-step preset (1.25 -> 1.35 -> 1.45 -> 1.55 -> 1.65 -> 1.75)
        store.selectPreset(.large) // 1.25
        store.stepUp()
        XCTAssertEqual(store.scaleFactor, 1.35, accuracy: 0.001)
        for _ in 0..<10 {
            store.stepUp()
        }
        XCTAssertEqual(store.scaleFactor, 1.75, accuracy: 0.001)
        XCTAssertFalse(store.canStepUp)

        // Reset to default (1.00)
        store.resetToDefault()
        XCTAssertEqual(store.scaleFactor, 1.00, accuracy: 0.001)
        XCTAssertTrue(store.isPresetSelected(.defaultSize))
    }

    func testAvatarScaleStoreUserDefaultsPersistenceAndSanitization() {
        let suiteName = "BitzScalePersistenceTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let firstStore = AvatarScaleStore(userDefaults: defaults)
        firstStore.selectPreset(.large) // 1.25

        // Re-instantiate using the same UserDefaults suite
        let restoredStore = AvatarScaleStore(userDefaults: defaults)
        XCTAssertEqual(restoredStore.scaleFactor, 1.25, accuracy: 0.001)

        // Out-of-bounds high value clamps to 1.75
        defaults.set(3.50, forKey: AvatarScaleStore.userDefaultsKey)
        let highClampedStore = AvatarScaleStore(userDefaults: defaults)
        XCTAssertEqual(highClampedStore.scaleFactor, 1.75, accuracy: 0.001)

        // Out-of-bounds positive low value clamps to 0.50
        defaults.set(0.15, forKey: AvatarScaleStore.userDefaultsKey)
        let lowClampedStore = AvatarScaleStore(userDefaults: defaults)
        XCTAssertEqual(lowClampedStore.scaleFactor, 0.50, accuracy: 0.001)

        // Non-positive or NaN values fall back to default 1.00
        defaults.set(-1.0, forKey: AvatarScaleStore.userDefaultsKey)
        let negativeFallbackStore = AvatarScaleStore(userDefaults: defaults)
        XCTAssertEqual(negativeFallbackStore.scaleFactor, 1.00, accuracy: 0.001)
        XCTAssertEqual(AvatarScaleStore.sanitizeScaleFactor(.nan), 1.00, accuracy: 0.001)
    }

    func testPanelProportionalScalingAndBottomRightReAnchoring() {
        let visibleFrame = NSRect(x: 0.0, y: 50.0, width: 1440.0, height: 825.0)

        // Small (0.60x -> 150x150 pt)
        let smallSize = MascotOverlayPanel.calculatePanelSize(for: 0.60, visibleFrame: visibleFrame)
        XCTAssertEqual(smallSize.width, 150.0, accuracy: 0.001)
        XCTAssertEqual(smallSize.height, 150.0, accuracy: 0.001)
        let smallOrigin = MascotOverlayPanel.calculateOrigin(for: visibleFrame, panelSize: smallSize)
        XCTAssertEqual(smallOrigin.x, 1270.0, accuracy: 0.001) // 1440 - 150 - 20
        XCTAssertEqual(smallOrigin.y, 70.0, accuracy: 0.001)   // 50 + 20

        // XL (1.50x -> 375x375 pt)
        let xlSize = MascotOverlayPanel.calculatePanelSize(for: 1.50, visibleFrame: visibleFrame)
        XCTAssertEqual(xlSize.width, 375.0, accuracy: 0.001)
        XCTAssertEqual(xlSize.height, 375.0, accuracy: 0.001)
        let xlOrigin = MascotOverlayPanel.calculateOrigin(for: visibleFrame, panelSize: xlSize)
        XCTAssertEqual(xlOrigin.x, 1045.0, accuracy: 0.001)   // 1440 - 375 - 20
        XCTAssertEqual(xlOrigin.y, 70.0, accuracy: 0.001)

        // Constrained visibleFrame guard (e.g., 300x300 visible frame with 1.75x scale)
        let tinyFrame = NSRect(x: 0.0, y: 0.0, width: 300.0, height: 300.0)
        let boundedSize = MascotOverlayPanel.calculatePanelSize(for: 1.75, visibleFrame: tinyFrame)
        XCTAssertEqual(boundedSize.width, 260.0, accuracy: 0.001) // 300 - 40 margin

        // Verify live panel and hostingView resizing preserves click-through invariants
        let panel = MascotOverlayPanel()
        let hostingView = NSHostingView(rootView: EmptyView())
        panel.contentView = hostingView

        panel.applyScaleFactor(0.80, on: nil)
        XCTAssertEqual(panel.currentScaleFactor, 0.80, accuracy: 0.001)
        XCTAssertEqual(panel.frame.size.width, 200.0, accuracy: 0.001)
        XCTAssertEqual(panel.frame.size.height, 200.0, accuracy: 0.001)
        XCTAssertEqual(hostingView.frame.size.width, 200.0, accuracy: 0.001)
        XCTAssertEqual(hostingView.frame.size.height, 200.0, accuracy: 0.001)
        XCTAssertTrue(panel.ignoresMouseEvents)
        XCTAssertFalse(panel.isOpaque)
        XCTAssertFalse(panel.hasShadow)
        XCTAssertFalse(panel.canBecomeKey)
    }

    func testBitzAppDelegateRestoresPersistedScaleAndUpdatesPanel() {
        let suiteName = "BitzDelegateScaleTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        defaults.set(0.80, forKey: AvatarScaleStore.userDefaultsKey)
        let scaleStore = AvatarScaleStore(userDefaults: defaults)
        let delegate = BitzAppDelegate(
            telemetryProvider: MockTelemetryProvider(),
            scaleStore: scaleStore
        )

        delegate.setupOverlayPanel()
        XCTAssertEqual(delegate.overlayPanel?.frame.size.width ?? 0.0, 200.0, accuracy: 0.001)
        XCTAssertEqual(delegate.overlayPanel?.frame.size.height ?? 0.0, 200.0, accuracy: 0.001)

        // Changing scale via scaleStore dynamically resizes overlayPanel
        scaleStore.selectPreset(.extraLarge) // 1.50 -> 375x375
        XCTAssertEqual(delegate.overlayPanel?.frame.size.width ?? 0.0, 375.0, accuracy: 0.001)
        XCTAssertEqual(delegate.overlayPanel?.frame.size.height ?? 0.0, 375.0, accuracy: 0.001)
        XCTAssertEqual(delegate.overlayPanel?.ignoresMouseEvents, true)
    }

    func testAvatarOpacityStoreDefaultPresetsAndClamping() {
        let suiteName = "BitzOpacityStoreTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let store = AvatarOpacityStore(userDefaults: defaults)
        XCTAssertEqual(store.opacityFactor, 0.85, accuracy: 0.001)
        XCTAssertEqual(store.percentageInt, 85)
        XCTAssertEqual(store.formattedOpacitySummary, "85%")
        XCTAssertTrue(store.canStepDown)
        XCTAssertTrue(store.canStepUp)

        // Presets
        for preset in AvatarOpacityPreset.allCases {
            store.selectPreset(preset)
            XCTAssertEqual(store.opacityFactor, preset.rawValue, accuracy: 0.001)
            XCTAssertTrue(store.isPresetSelected(preset))
            XCTAssertFalse(preset.menuTitle.isEmpty)
            XCTAssertFalse(preset.percentageText.isEmpty)
        }

        // Stepping up to 1.00 max
        store.selectPreset(.solid)
        XCTAssertFalse(store.canStepUp)
        store.stepUp()
        XCTAssertEqual(store.opacityFactor, 1.00, accuracy: 0.001)

        // Stepping down to 0.20 min
        store.selectPreset(.stealth) // 0.25
        store.stepDown()
        XCTAssertEqual(store.opacityFactor, 0.20, accuracy: 0.001)
        XCTAssertFalse(store.canStepDown)
        store.stepDown()
        XCTAssertEqual(store.opacityFactor, 0.20, accuracy: 0.001)

        // Reset
        store.resetToDefault()
        XCTAssertEqual(store.opacityFactor, 0.85, accuracy: 0.001)

        // Sanitization
        XCTAssertEqual(AvatarOpacityStore.sanitizeOpacityFactor(-0.5), 0.85, accuracy: 0.001)
        XCTAssertEqual(AvatarOpacityStore.sanitizeOpacityFactor(3.0), 1.00, accuracy: 0.001)
        XCTAssertEqual(AvatarOpacityStore.sanitizeOpacityFactor(0.05), 0.20, accuracy: 0.001)
        XCTAssertEqual(AvatarOpacityStore.sanitizeOpacityFactor(.nan), 0.85, accuracy: 0.001)
    }

    func testScreenCornerAnchorsAndRepositioning() {
        let frame = NSRect(x: 0, y: 50, width: 1440, height: 800)
        let size = NSSize(width: 250, height: 250)

        // Bottom-Right: maxX (1440) - 250 - 20 = 1170, minY (50) + 20 = 70
        let br = MascotOverlayPanel.calculateOrigin(for: frame, panelSize: size, corner: .bottomRight)
        XCTAssertEqual(br.x, 1170.0, accuracy: 0.001)
        XCTAssertEqual(br.y, 70.0, accuracy: 0.001)

        // Bottom-Left: minX (0) + 20 = 20, minY (50) + 20 = 70
        let bl = MascotOverlayPanel.calculateOrigin(for: frame, panelSize: size, corner: .bottomLeft)
        XCTAssertEqual(bl.x, 20.0, accuracy: 0.001)
        XCTAssertEqual(bl.y, 70.0, accuracy: 0.001)

        // Top-Right: maxX (1440) - 250 - 20 = 1170, maxY (850) - 250 - 20 = 580
        let tr = MascotOverlayPanel.calculateOrigin(for: frame, panelSize: size, corner: .topRight)
        XCTAssertEqual(tr.x, 1170.0, accuracy: 0.001)
        XCTAssertEqual(tr.y, 580.0, accuracy: 0.001)

        // Top-Left: minX (0) + 20 = 20, maxY (850) - 250 - 20 = 580
        let tl = MascotOverlayPanel.calculateOrigin(for: frame, panelSize: size, corner: .topLeft)
        XCTAssertEqual(tl.x, 20.0, accuracy: 0.001)
        XCTAssertEqual(tl.y, 580.0, accuracy: 0.001)

        let panel = MascotOverlayPanel()
        panel.applyCornerAnchor(.topLeft, on: nil)
        XCTAssertEqual(panel.currentCornerAnchor, .topLeft)

        // Test AvatarPositionStore
        let suiteName = "BitzPositionStoreTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let posStore = AvatarPositionStore(userDefaults: defaults)
        XCTAssertEqual(posStore.cornerAnchor, .bottomRight)
        XCTAssertTrue(posStore.isCornerSelected(.bottomRight))

        var recordedCorner: ScreenCornerAnchor?
        posStore.onCornerChanged = { recordedCorner = $0 }
        posStore.selectCorner(.topRight)
        XCTAssertEqual(posStore.cornerAnchor, .topRight)
        XCTAssertEqual(recordedCorner, .topRight)
        XCTAssertTrue(posStore.isCornerSelected(.topRight))

        // Persistence in same suite
        let restoredPosStore = AvatarPositionStore(userDefaults: defaults)
        XCTAssertEqual(restoredPosStore.cornerAnchor, .topRight)
    }

    /// A resize or corner change keeps Bitz on its assigned display instead of jumping to the focused one.
    func testScaleAndCornerChangesKeepAssignedScreen() throws {
        guard let secondary = NSScreen.screens.first(where: { $0 != NSScreen.main }) else {
            throw XCTSkip("Needs a second display")
        }
        let panel = MascotOverlayPanel()
        panel.applyCornerAnchor(.bottomRight, on: secondary)

        panel.applyScaleFactor(1.2)
        XCTAssertTrue(panel.assignedScreen === secondary)
        XCTAssertTrue(secondary.frame.intersects(panel.frame))

        panel.applyCornerAnchor(.topLeft)
        XCTAssertTrue(panel.assignedScreen === secondary)
        XCTAssertTrue(secondary.frame.intersects(panel.frame))
    }
}
