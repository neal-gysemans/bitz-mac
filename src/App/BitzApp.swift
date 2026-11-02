import AppKit
import Combine
import ServiceManagement
import SwiftUI

/// Application delegate managing the transparent `MascotOverlayPanel`, `WellnessPointEngine`,
/// `ActivityMonitorService`, `AvatarScaleStore`, and `AvatarOpacityStore` lifecycle (`FR-001`, `FR-005`, `FR-006`).
@MainActor
public final class BitzAppDelegate: NSObject, NSApplicationDelegate {
    public let riveController: ProductionRiveController
    public let engine: WellnessPointEngine
    public let activityMonitor: ActivityMonitorService
    public let scaleStore: AvatarScaleStore
    public let opacityStore: AvatarOpacityStore
    public let positionStore: AvatarPositionStore
    public let displayStore: DisplayPreferenceStore
    public let agentMonitor: AgentMonitorService
    public let updateStore: AppUpdateStore
    public let telemetrySettings: TelemetrySettingsStore
    public let telemetryDashboard: TelemetryDashboardService
    @Published public private(set) var menuBarTitle: String = "Bitz"
    public private(set) var overlayPanels: [MascotOverlayPanel] = []
    public var overlayPanel: MascotOverlayPanel? { overlayPanels.first }

    nonisolated(unsafe) private var screenParametersObserverToken: (any NSObjectProtocol)?
    nonisolated(unsafe) private var appActivationObserverToken: (any NSObjectProtocol)?
    nonisolated(unsafe) private var localFlagsMonitor: Any?
    nonisolated(unsafe) private var globalFlagsMonitor: Any?
    nonisolated(unsafe) private var localKeyMonitor: Any?
    nonisolated(unsafe) private var globalKeyMonitor: Any?
    private var bubbleInteractivityCancellable: AnyCancellable?
    private var warningVisorCancellable: AnyCancellable?
    private var screenReconfigTask: Task<Void, Never>?

    public override convenience init() {
        self.init(
            riveController: ProductionRiveController(),
            telemetryProvider: SystemActivityTelemetryProvider(),
            scaleStore: AvatarScaleStore(),
            opacityStore: AvatarOpacityStore(),
            positionStore: AvatarPositionStore(),
            displayStore: DisplayPreferenceStore(),
            updateStore: AppUpdateStore()
        )
    }

    public init(
        riveController: ProductionRiveController = ProductionRiveController(),
        telemetryProvider: ActivityTelemetryProviding = SystemActivityTelemetryProvider(),
        scaleStore: AvatarScaleStore = AvatarScaleStore(),
        opacityStore: AvatarOpacityStore = AvatarOpacityStore(),
        positionStore: AvatarPositionStore = AvatarPositionStore(),
        displayStore: DisplayPreferenceStore = DisplayPreferenceStore(),
        updateStore: AppUpdateStore = AppUpdateStore(),
        telemetrySettings: TelemetrySettingsStore? = nil,
        telemetryDashboard: TelemetryDashboardService? = nil,
        userDefaults: UserDefaults = .standard
    ) {
        self.riveController = riveController
        self.engine = WellnessPointEngine(riveController: riveController, userDefaults: userDefaults)
        self.activityMonitor = ActivityMonitorService(engine: self.engine, telemetry: telemetryProvider)
        self.scaleStore = scaleStore
        self.opacityStore = opacityStore
        self.positionStore = positionStore
        self.displayStore = displayStore
        self.updateStore = updateStore

        let resolvedTelemetrySettings = telemetrySettings ?? TelemetrySettingsStore(userDefaults: userDefaults)
        self.telemetrySettings = resolvedTelemetrySettings
        self.telemetryDashboard = telemetryDashboard ?? TelemetryDashboardService(settingsStore: resolvedTelemetrySettings)

        // Wire agent detection adapters
        let processAdapter = ProcessAgentAdapter()
        let dropboxAdapter = DropboxAgentAdapter()
        let antigravityAdapter = AntigravityTranscriptAdapter()
        let claudeAdapter = ClaudeCodeTranscriptAdapter()
        self.agentMonitor = AgentMonitorService(
            adapters: [processAdapter, dropboxAdapter, antigravityAdapter, claudeAdapter],
            userDefaults: userDefaults
        )

        self.telemetryDashboard.bindDependencies(
            agentMonitor: self.agentMonitor,
            activityMonitor: self.activityMonitor,
            engine: self.engine,
            displayStore: self.displayStore
        )

        super.init()

        self.telemetryDashboard.onTitleChanged = { [weak self] newTitle in
            guard let self, self.menuBarTitle != newTitle else { return }
            self.menuBarTitle = newTitle
        }

        self.scaleStore.onScaleChanged = { [weak self] newScale in
            self?.overlayPanels.forEach { $0.applyScaleFactor(newScale) }
        }
        self.positionStore.onCornerChanged = { [weak self] newCorner in
            self?.overlayPanels.forEach { $0.applyCornerAnchor(newCorner) }
        }
        self.positionStore.onCustomPositionChanged = { [weak self] newOrigin in
            self?.overlayPanels.forEach { $0.applyCustomOrigin(newOrigin) }
        }
        self.positionStore.onInteractivityToggled = { [weak self] _ in
            self?.updatePanelsInteractivity()
        }
        self.positionStore.onVisibilityChanged = { [weak self] _ in
            self?.syncOverlayPanels()
        }
        SettingsWindowManager.shared.onWindowClosed = { [weak self] in
            self?.positionStore.lockPosition()
            self?.updatePanelsInteractivity()
        }
        // An agent popup can cover the update alert's buttons, so re-check on either change
        self.bubbleInteractivityCancellable = Publishers.Merge(
            self.updateStore.$isSpeechBubbleAlertActive.map { _ in () },
            self.agentMonitor.$activePopup.map { _ in () }
        )
        .receive(on: DispatchQueue.main)
        .sink { [weak self] in
            self?.updatePanelsInteractivity()
        }
        // The engine only gets a flag, so agent policy stays in AgentMonitorService (R10)
        self.warningVisorCancellable = self.agentMonitor.$activeWarning
            .map { $0 != nil }
            .removeDuplicates()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] active in
                self?.engine.setWarningVisor(active: active)
            }
        self.displayStore.onDisplayPreferenceChanged = { [weak self] in
            self?.syncOverlayPanels()
        }

        self.screenParametersObserverToken = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.handleScreenParametersChangedDebounced()
            }
        }

        self.appActivationObserverToken = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, self.displayStore.targetMode == .followActive else { return }
                self.syncOverlayPanels()
            }
        }

        self.localFlagsMonitor = NSEvent.addLocalMonitorForEvents(matching: .flagsChanged) { [weak self] event in
            let optionHeld = event.modifierFlags.contains(.option)
            self?.positionStore.setModifierHeld(optionHeld)
            return event
        }

        self.globalFlagsMonitor = NSEvent.addGlobalMonitorForEvents(matching: .flagsChanged) { [weak self] event in
            let optionHeld = event.modifierFlags.contains(.option)
            Task { @MainActor [weak self] in
                self?.positionStore.setModifierHeld(optionHeld)
            }
        }

        self.localKeyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            // Option + Command + B (KeyCode 11) -> Toggle Settings Window
            if event.modifierFlags.contains([.option, .command]) && event.keyCode == 11 {
                if SettingsWindowManager.shared.isWindowOpen {
                    SettingsWindowManager.shared.closeSettingsWindow()
                } else {
                    self?.showSettingsWindow()
                }
                return nil
            }
            guard let self, self.positionStore.isPositionUnlocked else { return event }
            // Escape (53) or Return (36) immediately locks position
            if event.keyCode == 53 || event.keyCode == 36 {
                self.positionStore.lockPosition()
                return nil
            }
            return event
        }

        self.globalKeyMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self else { return }
            // Option + Command + B (KeyCode 11) -> Toggle Settings Window
            if event.modifierFlags.contains([.option, .command]) && event.keyCode == 11 {
                Task { @MainActor [weak self] in
                    if SettingsWindowManager.shared.isWindowOpen {
                        SettingsWindowManager.shared.closeSettingsWindow()
                    } else {
                        self?.showSettingsWindow()
                    }
                }
                return
            }
            guard self.positionStore.isPositionUnlocked else { return }
            // Escape (53) or Return (36) immediately locks position
            if event.keyCode == 53 || event.keyCode == 36 {
                Task { @MainActor [weak self] in
                    self?.positionStore.lockPosition()
                }
            }
        }
    }

    deinit {
        screenReconfigTask?.cancel()
        if let token = screenParametersObserverToken {
            NotificationCenter.default.removeObserver(token)
        }
        if let token = appActivationObserverToken {
            NSWorkspace.shared.notificationCenter.removeObserver(token)
        }
        if let local = localFlagsMonitor {
            NSEvent.removeMonitor(local)
        }
        if let global = globalFlagsMonitor {
            NSEvent.removeMonitor(global)
        }
        if let localKey = localKeyMonitor {
            NSEvent.removeMonitor(localKey)
        }
        if let globalKey = globalKeyMonitor {
            NSEvent.removeMonitor(globalKey)
        }
    }

    /// Mascot panel takes clicks only while dragging; the bubble panel only while the bubble on screen has buttons.
    public func updatePanelsInteractivity() {
        let bubbleIsInteractive = SpeechBubbleContent.current(
            engine: engine,
            agentMonitor: agentMonitor,
            updateStore: updateStore,
            telemetryDashboard: telemetryDashboard,
            telemetrySettings: telemetrySettings
        )?.isInteractive ?? false
        overlayPanels.forEach { panel in
            panel.ignoresMouseEvents = !positionStore.isInteractivityEnabled
            panel.speechBubblePanel.ignoresMouseEvents = !bubbleIsInteractive
        }
    }

    public func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp?.setActivationPolicy(.accessory)
        setupApplicationMenu()
        setupOverlayPanel()
        activityMonitor.startMonitoring()
        agentMonitor.startMonitoring()
        telemetryDashboard.start()
        updateStore.startPeriodicChecks()
        showSettingsWindow()
    }

    public func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showSettingsWindow()
        return true
    }

    public func applicationWillTerminate(_ notification: Notification) {
        overlayPanels.forEach { panel in
            panel.orderOut(nil)
            panel.close()
        }
        overlayPanels.removeAll()
        SettingsWindowManager.shared.closeSettingsWindow()
        activityMonitor.stopMonitoring()
        agentMonitor.stopMonitoring()
        telemetryDashboard.stop()
        updateStore.stopPeriodicChecks()
        engine.persistState()
    }

    /// Configures standard application menu shortcuts (`⌘Q` to Quit, `⌘W` to Close, `⌘,` for Settings)
    /// even when running as an accessory menu bar application.
    public func setupApplicationMenu() {
        guard NSApp?.mainMenu == nil else { return }
        let mainMenu = NSMenu()
        let appMenuItem = NSMenuItem()
        mainMenu.addItem(appMenuItem)

        let appMenu = NSMenu(title: "Bitz")
        appMenuItem.submenu = appMenu

        let aboutItem = NSMenuItem(
            title: "About Bitz",
            action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)),
            keyEquivalent: ""
        )
        appMenu.addItem(aboutItem)
        appMenu.addItem(NSMenuItem.separator())

        let settingsItem = NSMenuItem(
            title: "Settings...",
            action: #selector(showSettingsWindow),
            keyEquivalent: ","
        )
        settingsItem.target = self
        appMenu.addItem(settingsItem)
        appMenu.addItem(NSMenuItem.separator())

        let closeItem = NSMenuItem(
            title: "Close Window",
            action: #selector(NSWindow.performClose(_:)),
            keyEquivalent: "w"
        )
        appMenu.addItem(closeItem)
        appMenu.addItem(NSMenuItem.separator())

        let quitItem = NSMenuItem(
            title: "Quit Bitz",
            action: #selector(NSApplication.terminate(_:)),
            keyEquivalent: "q"
        )
        appMenu.addItem(quitItem)

        NSApp?.mainMenu = mainMenu
    }

    @objc public func showSettingsWindow() {
        SettingsWindowManager.shared.showSettingsWindow(
            rootView: SettingsRootView(
                engine: engine,
                activityMonitor: activityMonitor,
                scaleStore: scaleStore,
                opacityStore: opacityStore,
                positionStore: positionStore,
                displayStore: displayStore,
                agentMonitor: agentMonitor,
                updateStore: updateStore,
                telemetryDashboard: telemetryDashboard,
                telemetrySettings: telemetrySettings
            )
        )
    }

    /// Instantiates and positions the borderless, click-through `MascotOverlayPanel`(s)
    /// hosting `MascotOverlayView` according to the active `displayStore.targetMode`.
    public func setupOverlayPanel() {
        syncOverlayPanels()
    }

    /// Synchronizes overlay panels across screens based on `displayStore.targetMode`.
    public func syncOverlayPanels() {
        displayStore.refreshConnectedScreens()

        guard positionStore.isMascotVisible else {
            overlayPanels.forEach { $0.orderOut(nil) }
            return
        }

        if displayStore.targetMode == .allDisplays {
            let screens = NSScreen.screens
            while overlayPanels.count > screens.count {
                let panel = overlayPanels.removeLast()
                panel.orderOut(nil)
            }
            for (index, screen) in screens.enumerated() {
                let panel: MascotOverlayPanel
                if index < overlayPanels.count {
                    panel = overlayPanels[index]
                } else {
                    panel = createConfiguredPanel()
                    overlayPanels.append(panel)
                }
                panel.assignedScreen = screen
                panel.applyScaleFactor(CGFloat(scaleStore.scaleFactor), on: screen)
                if let customOrigin = positionStore.customOrigin {
                    panel.applyCustomOrigin(customOrigin, on: screen)
                } else {
                    panel.applyCornerAnchor(positionStore.cornerAnchor, on: screen)
                }
                panel.orderFrontRegardless()
            }
        } else {
            let targetScreen = displayStore.resolveScreen()
            while overlayPanels.count > 1 {
                let panel = overlayPanels.removeLast()
                panel.orderOut(nil)
            }
            let panel: MascotOverlayPanel
            if let existing = overlayPanels.first {
                panel = existing
            } else {
                panel = createConfiguredPanel()
                overlayPanels.append(panel)
            }
            panel.assignedScreen = targetScreen
            panel.applyScaleFactor(CGFloat(scaleStore.scaleFactor), on: targetScreen)
            if let customOrigin = positionStore.customOrigin {
                panel.applyCustomOrigin(customOrigin, on: targetScreen)
            } else {
                panel.applyCornerAnchor(positionStore.cornerAnchor, on: targetScreen)
            }
            panel.orderFrontRegardless()
        }
        updatePanelsInteractivity()
    }

    /// Debounces display change notifications to prevent stutter and layout flashes.
    public func handleScreenParametersChangedDebounced() {
        screenReconfigTask?.cancel()
        screenReconfigTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 250_000_000)
            guard !Task.isCancelled else { return }
            self?.syncOverlayPanels()
        }
    }

    private func createConfiguredPanel() -> MascotOverlayPanel {
        let panel = MascotOverlayPanel()
        panel.speechBubblePanel.contentView = NSHostingView(
            rootView: SpeechBubbleView(
                engine: engine,
                scaleStore: scaleStore,
                agentMonitor: agentMonitor,
                updateStore: updateStore,
                telemetryDashboard: telemetryDashboard,
                telemetrySettings: telemetrySettings
            )
        )
        panel.onRightMouseDown = { [weak self] in
            Task { @MainActor [weak self] in
                self?.positionStore.lockPosition()
            }
        }
        let rootView = MascotOverlayView(
            engine: engine,
            scaleStore: scaleStore,
            opacityStore: opacityStore,
            positionStore: positionStore,
            telemetryDashboard: telemetryDashboard,
            telemetrySettings: telemetrySettings,
            onDragChanged: { [weak panel] origin, _ in
                panel?.setFrameOrigin(origin)
            },
            onDragEnded: { [weak self, weak panel] finalOrigin, targetScreen in
                panel?.applyCustomOrigin(finalOrigin, on: targetScreen)
                if let targetScreen, let targetID = targetScreen.displayID {
                    if self?.displayStore.targetMode == .specific {
                        self?.displayStore.selectSpecificDisplay(id: targetID, name: targetScreen.localizedName)
                    }
                }
            },
            onGetOrigin: { [weak panel] in
                panel?.frame.origin
            },
            onGetSize: { [weak panel] in
                panel?.frame.size ?? MascotOverlayPanel.defaultPanelSize
            },
            onOpenSettings: { [weak self] in
                self?.showSettingsWindow()
            },
            onEarTopChanged: { [weak panel] earTop in
                panel?.earTopInset = earTop
            }
        )
        let hostingView = NSHostingView(rootView: rootView)
        let initialSize = MascotOverlayPanel.calculatePanelSize(for: CGFloat(scaleStore.scaleFactor))
        hostingView.frame = NSRect(origin: .zero, size: initialSize)
        panel.contentView = hostingView
        return panel
    }
}

/// Observable Menu Bar content view displaying live hardware sensor telemetry,
/// wellness score, manual avatar resizing & opacity controls, and interactive state controls.
@MainActor
struct BitzMenuBarContentView: View {
    @ObservedObject var engine: WellnessPointEngine
    @ObservedObject var activityMonitor: ActivityMonitorService
    @ObservedObject var scaleStore: AvatarScaleStore
    @ObservedObject var opacityStore: AvatarOpacityStore
    @ObservedObject var positionStore: AvatarPositionStore
    @ObservedObject var displayStore: DisplayPreferenceStore
    @ObservedObject var agentMonitor: AgentMonitorService
    @ObservedObject var updateStore: AppUpdateStore
    @ObservedObject var telemetryDashboard: TelemetryDashboardService
    @ObservedObject var telemetrySettings: TelemetrySettingsStore

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            // MARK: - 1. Status Header & Quick Actions
            headerSection

            // Active Warnings Summary
            if telemetryDashboard.snapshot.hasActiveWarning, let warning = telemetryDashboard.snapshot.activeWarningSummary {
                Divider()
                Text(warning)
                    .font(.caption)
                    .foregroundStyle(.orange)
            }

            if let agentWarning = agentMonitor.activeWarning {
                Divider()
                Text(agentWarning.text)
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .lineLimit(3)
                Button("Dismiss Agent Warning") {
                    agentMonitor.acknowledgeWarning()
                }
            }

            // The warning popup's text is already shown above
            if let agentPopup = agentMonitor.activePopup, agentPopup.kind != .warning {
                Divider()
                Text(agentPopup.text)
                    .font(.caption)
                    .foregroundStyle(.blue)
            }

            Divider()

            // MARK: - 2. Dedicated Settings Entrance
            Button("Settings...") {
                openSettingsWindow()
            }
            .keyboardShortcut(",", modifiers: [.command])

            Button("Check for Updates...") {
                Task {
                    await updateStore.checkForUpdates(manual: true)
                }
            }

            Divider()

            Button("Quit Bitz") {
                NSApplication.shared.terminate(nil)
            }
            .keyboardShortcut("q")
        }
        .padding(8)
    }

    private func openSettingsWindow() {
        SettingsWindowManager.shared.showSettingsWindow(
            rootView: SettingsRootView(
                engine: engine,
                activityMonitor: activityMonitor,
                scaleStore: scaleStore,
                opacityStore: opacityStore,
                positionStore: positionStore,
                displayStore: displayStore,
                agentMonitor: agentMonitor,
                updateStore: updateStore,
                telemetryDashboard: telemetryDashboard,
                telemetrySettings: telemetrySettings
            )
        )
    }

    // MARK: - Header & Primary Actions

    @ViewBuilder
    private var headerSection: some View {
        Text("Bitz the Cyber Cat")
            .font(.headline)
        Text("State: \(engine.currentState.rawValue) (\(String(format: "%.0f", engine.currentPoints)) PTS)")
        Text(String(format: "Streak: %.0f min • Focus: %.1f / 100", engine.continuousWorkMinutes, engine.currentPoints))
            .font(.caption)
            .foregroundStyle(.secondary)

        Button("Pet Bitz (<3)") {
            engine.triggerPetInteraction()
        }
        .accessibilityLabel("Pet Bitz")
        .keyboardShortcut("p")

        Toggle(positionStore.isMascotVisible ? "Mascot Visible on Screen" : "Mascot Hidden (Click to Show)", isOn: $positionStore.isMascotVisible)

        if positionStore.isPositionUnlocked {
            Button("✓ Lock Position [⎋ Esc / Right-Click]") {
                positionStore.lockPosition()
            }
            .accessibilityLabel("Lock Position")
            .keyboardShortcut(.escape, modifiers: [])
        }

        if updateStore.isUpdateAvailable, let release = updateStore.latestRelease {
            Button("🚀 Download v\(release.semanticVersion.description)...") {
                updateStore.openDownloadPage()
            }
            .accessibilityLabel("Download Update")
            .keyboardShortcut("u", modifiers: [.command])
        }
    }

}

/// SwiftUI `App` definition providing a lightweight Menu Bar status item for inspecting
/// Bitz's live hardware telemetry, wellness points, triggering `"Pet Bitz"`, and testing behavioral states (`FR-006`).
@MainActor
public struct BitzApp: App {
    @NSApplicationDelegateAdaptor(BitzAppDelegate.self) public var appDelegate

    public init() {}

    public var body: some Scene {
        MenuBarExtra(appDelegate.menuBarTitle, systemImage: "cat.fill") {
            BitzMenuBarContentView(
                engine: appDelegate.engine,
                activityMonitor: appDelegate.activityMonitor,
                scaleStore: appDelegate.scaleStore,
                opacityStore: appDelegate.opacityStore,
                positionStore: appDelegate.positionStore,
                displayStore: appDelegate.displayStore,
                agentMonitor: appDelegate.agentMonitor,
                updateStore: appDelegate.updateStore,
                telemetryDashboard: appDelegate.telemetryDashboard,
                telemetrySettings: appDelegate.telemetrySettings
            )
        }
    }
}
