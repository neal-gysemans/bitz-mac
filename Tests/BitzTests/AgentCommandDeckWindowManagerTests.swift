import XCTest
import SwiftUI
import AppKit
@testable import BitzCore

@MainActor
final class AgentCommandDeckWindowManagerTests: XCTestCase {

    private func makeIsolatedDefaults() -> (UserDefaults, () -> Void) {
        let suiteName = "AgentCommandDeckWindowManagerTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        let cleanup: () -> Void = {
            defaults.removePersistentDomain(forName: suiteName)
        }
        return (defaults, cleanup)
    }

    // MARK: - 1. Initial State

    func testCommandDeckWindowManagerInitialState() {
        let manager = AgentCommandDeckWindowManager()
        XCTAssertFalse(manager.isWindowOpen)
        XCTAssertFalse(manager.isWindowVisible)
        XCTAssertNil(manager.window)
    }

    // MARK: - 2. Window Configuration

    func testShowCommandDeckWindowCreatesAndConfiguresWindow() throws {
        let manager = AgentCommandDeckWindowManager()
        let sampleView = Text("Hello Command Deck")

        manager.showCommandDeckWindow(rootView: sampleView)
        defer { manager.closeCommandDeckWindow() }

        XCTAssertTrue(manager.isWindowOpen)
        let window = try XCTUnwrap(manager.window, "Expected window to be instantiated")

        XCTAssertEqual(window.title, "Bitz — Agent Command Deck")
        XCTAssertTrue(window.styleMask.contains(.titled))
        XCTAssertTrue(window.styleMask.contains(.closable))
        XCTAssertTrue(window.styleMask.contains(.miniaturizable))
        XCTAssertTrue(window.styleMask.contains(.resizable))
        XCTAssertFalse(window.isReleasedWhenClosed)
        XCTAssertEqual(window.contentMinSize, AgentCommandDeckWindowManager.minimumContentSize)
        XCTAssertEqual(AgentCommandDeckWindowManager.minimumContentSize, NSSize(width: 900, height: 600))
        XCTAssertEqual(AgentCommandDeckWindowManager.defaultInitialSize, NSSize(width: 1080, height: 720))
    }

    // MARK: - 3. Window Instance Reuse

    func testShowCommandDeckWindowReusesExistingWindowInstance() {
        let manager = AgentCommandDeckWindowManager()
        let sampleView1 = Text("View 1")
        let sampleView2 = Text("View 2")

        manager.showCommandDeckWindow(rootView: sampleView1)
        let firstWindow = manager.window

        manager.showCommandDeckWindow(rootView: sampleView2)
        let secondWindow = manager.window

        XCTAssertTrue(manager.isWindowOpen)
        XCTAssertTrue(firstWindow === secondWindow, "Window manager must reuse existing window instance")

        manager.closeCommandDeckWindow()
        XCTAssertFalse(manager.isWindowOpen)
    }

    // MARK: - 4. Close Callback

    func testCommandDeckWindowCloseInvokesOnWindowClosed() {
        let manager = AgentCommandDeckWindowManager()
        var closeCallbackCount = 0
        manager.onWindowClosed = {
            closeCallbackCount += 1
        }

        manager.showCommandDeckWindow(rootView: Text("Deck Content"))
        XCTAssertTrue(manager.isWindowOpen)
        XCTAssertEqual(closeCallbackCount, 0)

        manager.closeCommandDeckWindow()
        XCTAssertFalse(manager.isWindowOpen)
        XCTAssertEqual(closeCallbackCount, 1, "onWindowClosed must fire exactly once on close")

        // Calling close on already-closed window must not fire callback again
        manager.closeCommandDeckWindow()
        XCTAssertEqual(closeCallbackCount, 1)
    }

    // MARK: - 5. Teardown on Close & Reopen Sizing Options

    func testCloseDetachesHostingControllerAndReopenReattachesWithoutIntrinsicSizing() throws {
        let manager = AgentCommandDeckWindowManager()
        manager.showCommandDeckWindow(rootView: Text("Deck Content"))

        let window = try XCTUnwrap(manager.window)
        let initialHosting = try XCTUnwrap(window.contentViewController as? NSHostingController<Text>)
        XCTAssertEqual(
            initialHosting.sizingOptions,
            [],
            "Command Deck NSHostingController must disable sizingOptions to avoid layout thrash (AGENTS.md §2.4)"
        )

        manager.closeCommandDeckWindow()
        XCTAssertFalse(manager.isWindowOpen)
        XCTAssertFalse(manager.isWindowVisible)
        XCTAssertNil(
            window.contentViewController,
            "Closing Command Deck must detach contentViewController so SceneKit and SwiftUI drop to 0.0% CPU and 0 MB RAM (AGENTS.md §2.3)"
        )

        // Reopen must reuse the same NSWindow shell and reattach a fresh hosting controller with sizingOptions == []
        manager.showCommandDeckWindow(rootView: Text("Reopened Deck Content"))
        XCTAssertTrue(manager.isWindowOpen)
        XCTAssertTrue(manager.window === window, "Reopening Command Deck must reuse the existing NSWindow instance")
        let reopenedHosting = try XCTUnwrap(window.contentViewController as? NSHostingController<Text>)
        XCTAssertEqual(reopenedHosting.sizingOptions, [])

        manager.closeCommandDeckWindow()
    }

    // MARK: - 6. Content Minimum Size Retention

    func testWindowContentMinSizeMatchesRootMinimum() {
        let manager = AgentCommandDeckWindowManager()
        manager.showCommandDeckWindow(rootView: Text("Min Content"))
        defer { manager.closeCommandDeckWindow() }

        XCTAssertEqual(manager.window?.contentMinSize, AgentCommandDeckWindowManager.minimumContentSize)

        // Reopen re-hosts the content after teardown, which must not drop the minimum
        manager.closeCommandDeckWindow()
        manager.showCommandDeckWindow(rootView: Text("Min Content Reopened"))
        XCTAssertEqual(manager.window?.contentMinSize, AgentCommandDeckWindowManager.minimumContentSize)
    }

    // MARK: - 7. Occlusion & Miniaturization Visibility Tracking

    func testOcclusionAndMiniaturizationVisibilityTracking() throws {
        let manager = AgentCommandDeckWindowManager()
        manager.showCommandDeckWindow(rootView: Text("Visibility Test"))
        defer { manager.closeCommandDeckWindow() }

        let mockWindow = MockVisibilityTrackedWindow(
            contentRect: NSRect(x: 0, y: 0, width: 900, height: 600),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )

        // 1. Initial visible state
        mockWindow.stubIsMiniaturized = false
        mockWindow.stubOcclusionState = .visible
        manager.windowDidDeminiaturize(Notification(name: NSWindow.didDeminiaturizeNotification, object: mockWindow))
        XCTAssertTrue(manager.isWindowVisible)

        // 2. Miniaturization event hides window
        mockWindow.stubIsMiniaturized = true
        manager.windowDidMiniaturize(Notification(name: NSWindow.didMiniaturizeNotification, object: mockWindow))
        XCTAssertFalse(manager.isWindowVisible)

        // 3. Deminiaturization event restores visibility
        mockWindow.stubIsMiniaturized = false
        manager.windowDidDeminiaturize(Notification(name: NSWindow.didDeminiaturizeNotification, object: mockWindow))
        XCTAssertTrue(manager.isWindowVisible)

        // 4. Occlusion event: fully covered window stops rendering
        mockWindow.stubOcclusionState = [] // Not visible
        manager.windowDidChangeOcclusionState(Notification(name: NSWindow.didChangeOcclusionStateNotification, object: mockWindow))
        XCTAssertFalse(manager.isWindowVisible)

        // 5. Occlusion event: partially/fully uncovered window resumes rendering
        mockWindow.stubOcclusionState = .visible
        manager.windowDidChangeOcclusionState(Notification(name: NSWindow.didChangeOcclusionStateNotification, object: mockWindow))
        XCTAssertTrue(manager.isWindowVisible)

        // 6. Window close forces visibility to false
        manager.closeCommandDeckWindow()
        XCTAssertFalse(manager.isWindowVisible)
        XCTAssertFalse(manager.isWindowOpen)
    }

    // MARK: - 8. Tier Gating: Multi-Agent Swarm (Free vs Pro)

    func testMultiAgentSwarmTierGatingFreeTierLimitsToOneCrewmateAndShowsBanner() {
        let (defaults, cleanup) = makeIsolatedDefaults()
        defer { cleanup() }

        let mockLicensing = MockDeckLicensingService(unlockedFeatures: [])
        let agentMonitor = AgentMonitorService(userDefaults: defaults)

        // Simulate two active agent sessions
        agentMonitor.handleEvent(AgentEvent(
            agentID: "claude",
            agentName: "Claude",
            kind: .working,
            metadata: [AgentEvent.MetadataKey.sessionID: "sess-claude-1"]
        ))
        agentMonitor.handleEvent(AgentEvent(
            agentID: "antigravity",
            agentName: "Antigravity",
            kind: .working,
            metadata: [AgentEvent.MetadataKey.sessionID: "sess-antigravity-1"]
        ))

        XCTAssertEqual(agentMonitor.sessionSnapshots.count, 2)

        let deckView = AgentCommandDeckView(
            agentMonitor: agentMonitor,
            licensingService: mockLicensing
        )

        XCTAssertFalse(deckView.isSwarmUnlocked)
        XCTAssertEqual(deckView.visibleSessions.count, 1, "Free tier must clamp visible crewmates to 1")
        XCTAssertTrue(deckView.showsUpgradeBanner, "Free tier with 2+ sessions must show Pro upgrade banner")
    }

    func testMultiAgentSwarmTierGatingProTierUnlocksFullSquad() {
        let (defaults, cleanup) = makeIsolatedDefaults()
        defer { cleanup() }

        let mockLicensing = MockDeckLicensingService(unlockedFeatures: [.multiAgentSwarm])
        let agentMonitor = AgentMonitorService(userDefaults: defaults, licensingService: mockLicensing)

        // Simulate two active agent sessions
        agentMonitor.handleEvent(AgentEvent(
            agentID: "claude",
            agentName: "Claude",
            kind: .working,
            metadata: [AgentEvent.MetadataKey.sessionID: "sess-claude-1"]
        ))
        agentMonitor.handleEvent(AgentEvent(
            agentID: "antigravity",
            agentName: "Antigravity",
            kind: .working,
            metadata: [AgentEvent.MetadataKey.sessionID: "sess-antigravity-1"]
        ))

        XCTAssertEqual(agentMonitor.sessionSnapshots.count, 2)

        let deckView = AgentCommandDeckView(
            agentMonitor: agentMonitor,
            licensingService: mockLicensing
        )

        XCTAssertTrue(deckView.isSwarmUnlocked)
        XCTAssertEqual(deckView.visibleSessions.count, 2, "Pro tier must display all active crewmates")
        XCTAssertFalse(deckView.showsUpgradeBanner, "Pro tier must not show upgrade banner")
    }

    func testMultiAgentSwarmTierGatingFreeTierSingleSessionDoesNotShowBanner() {
        let (defaults, cleanup) = makeIsolatedDefaults()
        defer { cleanup() }

        let mockLicensing = MockDeckLicensingService(unlockedFeatures: [])
        let agentMonitor = AgentMonitorService(userDefaults: defaults)

        // Single active session
        agentMonitor.handleEvent(AgentEvent(
            agentID: "claude",
            agentName: "Claude",
            kind: .working,
            metadata: [AgentEvent.MetadataKey.sessionID: "sess-single-1"]
        ))

        XCTAssertEqual(agentMonitor.sessionSnapshots.count, 1)

        let deckView = AgentCommandDeckView(
            agentMonitor: agentMonitor,
            licensingService: mockLicensing
        )

        XCTAssertFalse(deckView.isSwarmUnlocked)
        XCTAssertEqual(deckView.visibleSessions.count, 1)
        XCTAssertFalse(deckView.showsUpgradeBanner, "Free tier with only 1 session does not trigger upgrade banner")
    }

    // MARK: - 9. Entry Points in BitzAppDelegate

    func testBitzAppDelegateCommandDeckWindowMethodsAndShortcuts() {
        let (defaults, cleanup) = makeIsolatedDefaults()
        defer {
            cleanup()
            AgentCommandDeckWindowManager.shared.closeCommandDeckWindow()
        }

        let delegate = BitzAppDelegate(userDefaults: defaults)
        AgentCommandDeckWindowManager.shared.closeCommandDeckWindow()
        XCTAssertFalse(AgentCommandDeckWindowManager.shared.isWindowOpen)

        // Test showCommandDeckWindow()
        delegate.showCommandDeckWindow()
        XCTAssertTrue(AgentCommandDeckWindowManager.shared.isWindowOpen)

        // Test toggleCommandDeckWindow() closes it
        delegate.toggleCommandDeckWindow()
        XCTAssertFalse(AgentCommandDeckWindowManager.shared.isWindowOpen)

        // Test toggleCommandDeckWindow() reopens it
        delegate.toggleCommandDeckWindow()
        XCTAssertTrue(AgentCommandDeckWindowManager.shared.isWindowOpen)

        AgentCommandDeckWindowManager.shared.closeCommandDeckWindow()
        XCTAssertFalse(AgentCommandDeckWindowManager.shared.isWindowOpen)

        // Test setupApplicationMenu registers ⌘D
        NSApp?.mainMenu = nil
        delegate.setupApplicationMenu()
        guard let appMenu = NSApp?.mainMenu?.items.first?.submenu else {
            XCTFail("Expected appMenu to exist")
            return
        }

        let commandDeckMenuItem = appMenu.items.first { $0.title == "Agent Command Deck..." }
        XCTAssertNotNil(commandDeckMenuItem, "Agent Command Deck... menu item must be present in app menu")
        XCTAssertEqual(commandDeckMenuItem?.keyEquivalent, "d")
        XCTAssertEqual(commandDeckMenuItem?.action, #selector(BitzAppDelegate.showCommandDeckWindow))
    }

    func testGlobalOptionCommandDTogglesCommandDeckWindow() throws {
        let (defaults, cleanup) = makeIsolatedDefaults()
        defer {
            cleanup()
            AgentCommandDeckWindowManager.shared.closeCommandDeckWindow()
        }

        let delegate = BitzAppDelegate(userDefaults: defaults)
        AgentCommandDeckWindowManager.shared.closeCommandDeckWindow()
        XCTAssertFalse(AgentCommandDeckWindowManager.shared.isWindowOpen)

        let event = try XCTUnwrap(NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: [.option, .command],
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            characters: "d",
            charactersIgnoringModifiers: "d",
            isARepeat: false,
            keyCode: 2
        ))

        XCTAssertTrue(delegate.handleKeyEvent(event, isGlobal: true))
        XCTAssertTrue(AgentCommandDeckWindowManager.shared.isWindowOpen)

        XCTAssertTrue(delegate.handleKeyEvent(event, isGlobal: true))
        XCTAssertFalse(AgentCommandDeckWindowManager.shared.isWindowOpen)
    }

    func testAgentsSettingsTabViewCommandDeckEntryCard() {
        let (defaults, cleanup) = makeIsolatedDefaults()
        defer {
            cleanup()
            AgentCommandDeckWindowManager.shared.closeCommandDeckWindow()
        }

        _ = NSApplication.shared
        let delegate = BitzAppDelegate(userDefaults: defaults)
        AgentCommandDeckWindowManager.shared.closeCommandDeckWindow()
        XCTAssertFalse(AgentCommandDeckWindowManager.shared.isWindowOpen)

        let agentMonitor = AgentMonitorService(userDefaults: defaults)
        _ = AgentsSettingsTabView(agentMonitor: agentMonitor)

        let handled = NSApp.sendAction(#selector(BitzAppDelegate.showCommandDeckWindow), to: delegate, from: nil)
        XCTAssertTrue(handled)
        XCTAssertTrue(AgentCommandDeckWindowManager.shared.isWindowOpen)
    }

    func testBitzMenuBarContentViewCommandDeckCallback() {
        let (defaults, cleanup) = makeIsolatedDefaults()
        defer { cleanup() }

        var openDeckCalled = false
        let engine = WellnessPointEngine()
        let telemetry = SystemActivityTelemetryProvider()
        let activityMonitor = ActivityMonitorService(engine: engine, telemetry: telemetry)
        let positionStore = AvatarPositionStore(userDefaults: defaults)
        let agentMonitor = AgentMonitorService(adapters: [], userDefaults: defaults)
        let updateStore = AppUpdateStore(userDefaults: defaults)
        let telemetrySettings = TelemetrySettingsStore(userDefaults: defaults)
        let telemetryDashboard = TelemetryDashboardService(settingsStore: telemetrySettings)

        let menuView = BitzMenuBarContentView(
            engine: engine,
            activityMonitor: activityMonitor,
            positionStore: positionStore,
            agentMonitor: agentMonitor,
            updateStore: updateStore,
            telemetryDashboard: telemetryDashboard,
            telemetrySettings: telemetrySettings,
            onOpenCommandDeck: {
                openDeckCalled = true
            }
        )

        menuView.onOpenCommandDeck()
        XCTAssertTrue(openDeckCalled)
    }
}

// MARK: - Test Helpers

private final class MockVisibilityTrackedWindow: NSWindow, @unchecked Sendable {
    var stubIsMiniaturized: Bool = false
    var stubOcclusionState: NSWindow.OcclusionState = .visible

    override var isMiniaturized: Bool { stubIsMiniaturized }
    override var occlusionState: NSWindow.OcclusionState { stubOcclusionState }
}

@MainActor
private final class MockDeckLicensingService: LicensingServiceProtocol {
    @Published var currentTier: BitzTier = .free
    @Published var activeLicense: LicensePayload? = nil
    var unlockedFeatures: Set<BitzFeature>

    init(unlockedFeatures: Set<BitzFeature>) {
        self.unlockedFeatures = unlockedFeatures
        self.currentTier = unlockedFeatures.contains(.multiAgentSwarm) ? .pro : .free
    }

    func isFeatureUnlocked(_ feature: BitzFeature) -> Bool {
        unlockedFeatures.contains(feature)
    }

    func activateLicense(key: String) throws {
        currentTier = .pro
        unlockedFeatures = Set(BitzFeature.allCases)
    }

    func deactivateLicense() throws {
        currentTier = .free
        unlockedFeatures = []
    }
}
