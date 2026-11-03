import AppKit
import SwiftUI
import XCTest
@testable import BitzCore

@MainActor
final class KeyboardShortcutsTests: XCTestCase {

    private func makeSyntheticKeyEvent(
        keyCode: UInt16,
        characters: String,
        modifiers: NSEvent.ModifierFlags = []
    ) -> NSEvent {
        NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: modifiers,
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            characters: characters,
            charactersIgnoringModifiers: characters,
            isARepeat: false,
            keyCode: keyCode
        )!
    }

    func testHandleKeyEventToggleSettingsWindowWithOptionCommandB() {
        let suiteName = "KeyboardShortcutsTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer {
            defaults.removePersistentDomain(forName: suiteName)
            SettingsWindowManager.shared.closeSettingsWindow()
        }

        let delegate = BitzAppDelegate(userDefaults: defaults)
        SettingsWindowManager.shared.closeSettingsWindow()
        XCTAssertFalse(SettingsWindowManager.shared.isWindowOpen)

        // ⌥⌘B opens Settings window
        let openEvent = makeSyntheticKeyEvent(keyCode: 11, characters: "b", modifiers: [.option, .command])
        let handledOpen = delegate.handleKeyEvent(openEvent)
        XCTAssertTrue(handledOpen)
        XCTAssertTrue(SettingsWindowManager.shared.isWindowOpen)

        // ⌥⌘B toggles Settings window closed
        let closeEvent = makeSyntheticKeyEvent(keyCode: 11, characters: "b", modifiers: [.option, .command])
        let handledClose = delegate.handleKeyEvent(closeEvent)
        XCTAssertTrue(handledClose)
        XCTAssertFalse(SettingsWindowManager.shared.isWindowOpen)
    }

    func testHandleKeyEventOpenSettingsWindowWithCommandComma() {
        let suiteName = "KeyboardShortcutsTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer {
            defaults.removePersistentDomain(forName: suiteName)
            SettingsWindowManager.shared.closeSettingsWindow()
        }

        let delegate = BitzAppDelegate(userDefaults: defaults)
        SettingsWindowManager.shared.closeSettingsWindow()
        XCTAssertFalse(SettingsWindowManager.shared.isWindowOpen)

        // ⌘, opens Settings window
        let event = makeSyntheticKeyEvent(keyCode: 43, characters: ",", modifiers: [.command])
        let handled = delegate.handleKeyEvent(event)
        XCTAssertTrue(handled)
        XCTAssertTrue(SettingsWindowManager.shared.isWindowOpen)
    }

    func testHandleKeyEventLockPositionWithEscapeAndReturnWhenInteractivityEnabled() {
        let suiteName = "KeyboardShortcutsTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let positionStore = AvatarPositionStore(userDefaults: defaults)
        let delegate = BitzAppDelegate(positionStore: positionStore, userDefaults: defaults)

        // Case 1: Unlocked position + Escape
        positionStore.unlockPosition()
        XCTAssertTrue(positionStore.isInteractivityEnabled)
        let escEvent = makeSyntheticKeyEvent(keyCode: 53, characters: "\u{1b}")
        let handledEsc = delegate.handleKeyEvent(escEvent)
        XCTAssertTrue(handledEsc)
        XCTAssertFalse(positionStore.isInteractivityEnabled)
        XCTAssertFalse(positionStore.isPositionUnlocked)

        // Case 2: Dragging via Option held + Return
        positionStore.setModifierHeld(true)
        XCTAssertTrue(positionStore.isInteractivityEnabled)
        let returnEvent = makeSyntheticKeyEvent(keyCode: 36, characters: "\r")
        let handledReturn = delegate.handleKeyEvent(returnEvent)
        XCTAssertTrue(handledReturn)
        XCTAssertFalse(positionStore.isInteractivityEnabled)
        XCTAssertFalse(positionStore.isModifierHeld)

        // Case 3: When not interacting, Escape is NOT intercepted (Zero focus stealing)
        XCTAssertFalse(positionStore.isInteractivityEnabled)
        let passThroughEsc = delegate.handleKeyEvent(escEvent)
        XCTAssertFalse(passThroughEsc, "Escape must pass through when mascot is not interactive")
    }

    func testHandleKeyEventScaleMascotUpAndDown() {
        let suiteName = "KeyboardShortcutsTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let scaleStore = AvatarScaleStore(userDefaults: defaults)
        scaleStore.selectPreset(.defaultSize)
        let initialScale = scaleStore.scaleFactor
        let delegate = BitzAppDelegate(scaleStore: scaleStore, userDefaults: defaults)

        // ⌘= scales up
        let scaleUpEvent = makeSyntheticKeyEvent(keyCode: 24, characters: "=", modifiers: [.command])
        let handledUp = delegate.handleKeyEvent(scaleUpEvent)
        XCTAssertTrue(handledUp)
        XCTAssertGreaterThan(scaleStore.scaleFactor, initialScale)

        // ⌘- scales down
        let scaleDownEvent = makeSyntheticKeyEvent(keyCode: 27, characters: "-", modifiers: [.command])
        let handledDown = delegate.handleKeyEvent(scaleDownEvent)
        XCTAssertTrue(handledDown)
        XCTAssertEqual(scaleStore.scaleFactor, initialScale, accuracy: 0.001)
    }

    func testHandleKeyEventOpacityMascotUpAndDown() {
        let suiteName = "KeyboardShortcutsTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let opacityStore = AvatarOpacityStore(userDefaults: defaults)
        opacityStore.selectPreset(.translucent) // 0.80
        let initialOpacity = opacityStore.opacityFactor
        let delegate = BitzAppDelegate(opacityStore: opacityStore, userDefaults: defaults)

        // ⌘] increases opacity
        let opacityUpEvent = makeSyntheticKeyEvent(keyCode: 30, characters: "]", modifiers: [.command])
        let handledUp = delegate.handleKeyEvent(opacityUpEvent)
        XCTAssertTrue(handledUp)
        XCTAssertGreaterThan(opacityStore.opacityFactor, initialOpacity)

        // ⌘[ decreases opacity
        let opacityDownEvent = makeSyntheticKeyEvent(keyCode: 33, characters: "[", modifiers: [.command])
        let handledDown = delegate.handleKeyEvent(opacityDownEvent)
        XCTAssertTrue(handledDown)
        XCTAssertEqual(opacityStore.opacityFactor, initialOpacity, accuracy: 0.001)
    }

    func testHandleKeyEventPetBitzWithCommandPAndBareP() {
        let suiteName = "KeyboardShortcutsTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let riveController = ProductionRiveController()
        let delegate = BitzAppDelegate(riveController: riveController, userDefaults: defaults)

        XCTAssertEqual(riveController.totalTriggerCount, 0)

        // ⌘P triggers pet
        let cmdPEvent = makeSyntheticKeyEvent(keyCode: 35, characters: "p", modifiers: [.command])
        let handledCmdP = delegate.handleKeyEvent(cmdPEvent)
        XCTAssertTrue(handledCmdP)
        XCTAssertEqual(riveController.totalTriggerCount, 1)
        XCTAssertEqual(riveController.lastTriggeredInput, BitzRiveInputName.triggerPet)

        // Bare 'P' (when not in a text field) triggers pet
        let barePEvent = makeSyntheticKeyEvent(keyCode: 35, characters: "p")
        let handledBareP = delegate.handleKeyEvent(barePEvent)
        XCTAssertTrue(handledBareP)
        XCTAssertEqual(riveController.totalTriggerCount, 2)
        XCTAssertEqual(riveController.lastTriggeredInput, BitzRiveInputName.triggerPet)
    }

    func testGlobalKeyEventsOnlyHandleBitzHotkeys() {
        let suiteName = "KeyboardShortcutsTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer {
            defaults.removePersistentDomain(forName: suiteName)
            SettingsWindowManager.shared.closeSettingsWindow()
        }

        let riveController = ProductionRiveController()
        let scaleStore = AvatarScaleStore(userDefaults: defaults)
        scaleStore.selectPreset(.defaultSize)
        let opacityStore = AvatarOpacityStore(userDefaults: defaults)
        opacityStore.selectPreset(.translucent) // 0.80
        let positionStore = AvatarPositionStore(userDefaults: defaults)
        let delegate = BitzAppDelegate(
            riveController: riveController,
            scaleStore: scaleStore,
            opacityStore: opacityStore,
            positionStore: positionStore,
            userDefaults: defaults
        )
        SettingsWindowManager.shared.closeSettingsWindow()
        let initialScale = scaleStore.scaleFactor
        let initialOpacity = opacityStore.opacityFactor

        // Keystrokes typed in other apps belong to those apps (#93); ⌘Q last so a regression can't skip the rest
        let foreignShortcuts = [
            makeSyntheticKeyEvent(keyCode: 43, characters: ",", modifiers: [.command]),
            makeSyntheticKeyEvent(keyCode: 24, characters: "=", modifiers: [.command]),
            makeSyntheticKeyEvent(keyCode: 27, characters: "-", modifiers: [.command]),
            makeSyntheticKeyEvent(keyCode: 30, characters: "]", modifiers: [.command]),
            makeSyntheticKeyEvent(keyCode: 33, characters: "[", modifiers: [.command]),
            makeSyntheticKeyEvent(keyCode: 35, characters: "p", modifiers: [.command]),
            makeSyntheticKeyEvent(keyCode: 35, characters: "p"),
            makeSyntheticKeyEvent(keyCode: 12, characters: "q", modifiers: [.command])
        ]
        for event in foreignShortcuts {
            XCTAssertFalse(
                delegate.handleKeyEvent(event, isGlobal: true),
                "Global \(event.modifierFlags.contains(.command) ? "⌘" : "")\(event.charactersIgnoringModifiers ?? "") must pass through"
            )
        }
        XCTAssertEqual(riveController.totalTriggerCount, 0)
        XCTAssertEqual(scaleStore.scaleFactor, initialScale, accuracy: 0.001)
        XCTAssertEqual(opacityStore.opacityFactor, initialOpacity, accuracy: 0.001)
        XCTAssertFalse(SettingsWindowManager.shared.isWindowOpen)

        // ⌥⌘B and the Esc lock stay global hotkeys
        let toggleEvent = makeSyntheticKeyEvent(keyCode: 11, characters: "b", modifiers: [.option, .command])
        XCTAssertTrue(delegate.handleKeyEvent(toggleEvent, isGlobal: true))
        XCTAssertTrue(SettingsWindowManager.shared.isWindowOpen)

        positionStore.unlockPosition()
        let escEvent = makeSyntheticKeyEvent(keyCode: 53, characters: "\u{1b}")
        XCTAssertTrue(delegate.handleKeyEvent(escEvent, isGlobal: true))
        XCTAssertFalse(positionStore.isInteractivityEnabled)
    }

    func testSetupApplicationMenuRegistersExpectedShortcuts() {
        let suiteName = "KeyboardShortcutsTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let delegate = BitzAppDelegate(userDefaults: defaults)
        NSApp?.mainMenu = nil
        delegate.setupApplicationMenu()

        guard let appMenu = NSApp?.mainMenu?.items.first?.submenu else {
            XCTFail("Application submenu must exist")
            return
        }

        let keyEquivalents = Set(appMenu.items.map(\.keyEquivalent).filter { !$0.isEmpty })
        let expectedShortcuts: Set<String> = [",", "p", "=", "-", "]", "[", "w", "q"]

        XCTAssertTrue(
            expectedShortcuts.isSubset(of: keyEquivalents),
            "Expected shortcuts \(expectedShortcuts) must all be present in menu, found \(keyEquivalents)"
        )
    }
}
