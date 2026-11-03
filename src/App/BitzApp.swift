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
    public let audioSettings: CyberAudioSettingsStore
    public let audioService: CyberAudioService
    public let flowShieldSettings: FlowShieldSettingsStore
    public let flowShieldService: FlowShieldService
    public let interactionSettings: MascotInteractionSettingsStore
    public let fileDropService: FileDropInboxService
    public let paletteStore: AvatarPaletteStore
    public let personalitySettings: PersonalitySettingsStore
    public let personalityService: PersonalityService
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
    private var personalityTickCancellable: AnyCancellable?
    private var personalityEnabledCancellable: AnyCancellable?
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
        audioSettings: CyberAudioSettingsStore? = nil,
        audioService: CyberAudioService? = nil,
        flowShieldSettings: FlowShieldSettingsStore? = nil,
        flowShieldService: FlowShieldService? = nil,
        interactionSettings: MascotInteractionSettingsStore? = nil,
        fileDropService: FileDropInboxService? = nil,
        paletteStore: AvatarPaletteStore? = nil,
        personalitySettings: PersonalitySettingsStore? = nil,
        personalityService: PersonalityService? = nil,
        userDefaults: UserDefaults = .standard
    ) {
        self.paletteStore = paletteStore ?? AvatarPaletteStore(userDefaults: userDefaults)
        let resolvedPersonalitySettings = personalitySettings ?? PersonalitySettingsStore(userDefaults: userDefaults)
        self.personalitySettings = resolvedPersonalitySettings
        let resolvedPersonalityService = personalityService ?? PersonalityService(
            primaryGenerator: FoundationModelsCommentaryGenerator(),
            fallbackGenerator: TemplatedCommentaryGenerator(),
            settingsStore: resolvedPersonalitySettings
        )
        self.personalityService = resolvedPersonalityService
        self.interactionSettings = interactionSettings ?? MascotInteractionSettingsStore(userDefaults: userDefaults)
        self.fileDropService = fileDropService ?? FileDropInboxService()
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

        let resolvedAudioSettings = audioSettings ?? CyberAudioSettingsStore(userDefaults: userDefaults)
        self.audioSettings = resolvedAudioSettings
        let resolvedAudioService = audioService ?? CyberAudioService(settingsStore: resolvedAudioSettings)
        self.audioService = resolvedAudioService

        let resolvedFlowShieldSettings = flowShieldSettings ?? FlowShieldSettingsStore(userDefaults: userDefaults)
        self.flowShieldSettings = resolvedFlowShieldSettings
        let resolvedFlowShieldService = flowShieldService ?? FlowShieldService(settingsStore: resolvedFlowShieldSettings)
        self.flowShieldService = resolvedFlowShieldService

        // Wire agent detection adapters
        let processAdapter = ProcessAgentAdapter()
        let dropboxAdapter = DropboxAgentAdapter()
        let antigravityAdapter = AntigravityTranscriptAdapter()
        let claudeAdapter = ClaudeCodeTranscriptAdapter()
        self.agentMonitor = AgentMonitorService(
            adapters: [processAdapter, dropboxAdapter, antigravityAdapter, claudeAdapter],
            userDefaults: userDefaults
        )

        self.audioService.observe(wellnessEngine: self.engine)
        self.audioService.observe(agentMonitor: self.agentMonitor)
        self.flowShieldService.observe(wellnessEngine: self.engine)

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
            self?.activityMonitor.clearManualOverride()
            self?.paletteStore.cancelPreview()
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

        self.engine.warningRephraser = { [weak self] warning, state in
            guard let self else { return warning }
            let context = PersonalityContext(
                wellnessState: state,
                currentPoints: self.engine.currentPoints,
                continuousWorkMinutes: self.engine.continuousWorkMinutes,
                temperatureCelsius: self.activityMonitor.lastTemperatureCelsius,
                cpuLoadPercentage: self.activityMonitor.lastCPULoadPercentage,
                frontmostAppName: self.activityMonitor.lastFrontmostAppName,
                activeAgentNames: Array(self.agentMonitor.activeAgents),
                recentCommitCount: nil
            )
            return await self.personalityService.rephraseWarning(warning, context: context)
        }

        self.personalityTickCancellable = self.telemetryDashboard.$snapshot
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                guard let self else { return }
                guard self.personalitySettings.isEnabled else {
                    if self.engine.idleCommentaryText != nil {
                        self.engine.setIdleCommentaryText(nil)
                    }
                    return
                }
                let isBubbleIdle = self.agentMonitor.activePopup == nil
                    && !self.updateStore.isSpeechBubbleAlertActive
                    && self.engine.activeSpeechBubbleText == nil
                let context = PersonalityContext(
                    wellnessState: self.engine.currentState,
                    currentPoints: self.engine.currentPoints,
                    continuousWorkMinutes: self.engine.continuousWorkMinutes,
                    temperatureCelsius: self.activityMonitor.lastTemperatureCelsius,
                    cpuLoadPercentage: self.activityMonitor.lastCPULoadPercentage,
                    frontmostAppName: self.activityMonitor.lastFrontmostAppName,
                    activeAgentNames: Array(self.agentMonitor.activeAgents),
                    recentCommitCount: nil
                )
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    await self.personalityService.tick(context: context, isBubbleIdle: isBubbleIdle)
                    self.engine.setIdleCommentaryText(self.personalityService.activeCommentary)
                }
            }

        self.personalityEnabledCancellable = self.personalitySettings.$isEnabled
            .filter { !$0 }
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.engine.setIdleCommentaryText(nil)
                self?.personalityService.clearCommentary()
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
            let held = self?.interactionSettings.isHoldActive(for: event.modifierFlags) ?? false
            self?.positionStore.setModifierHeld(held)
            return event
        }

        self.globalFlagsMonitor = NSEvent.addGlobalMonitorForEvents(matching: .flagsChanged) { [weak self] event in
            let flags = event.modifierFlags
            Task { @MainActor [weak self] in
                let held = self?.interactionSettings.isHoldActive(for: flags) ?? false
                self?.positionStore.setModifierHeld(held)
            }
        }

        self.localKeyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self else { return event }
            if self.handleKeyEvent(event) {
                return nil
            }
            return event
        }

        self.globalKeyMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self else { return }
            Task { @MainActor [weak self] in
                self?.handleKeyEvent(event, isGlobal: true)
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
        audioService.preloadBuffers()
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
        audioService.stopAll()
        personalityTickCancellable = nil
        personalityEnabledCancellable = nil
        Task { [personalityService] in
            await personalityService.unloadBackend()
        }
        engine.persistState()
    }

    /// Configures standard application menu shortcuts (`⌘Q` to Quit, `⌘W` to Close, `⌘,` for Settings, `⌘P` to Pet, `⌘=`/`⌘-` to Scale, `⌘]`/`⌘[` for Opacity)
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

        let petItem = NSMenuItem(
            title: "Pet Bitz",
            action: #selector(petBitzAction),
            keyEquivalent: "p"
        )
        petItem.target = self
        appMenu.addItem(petItem)

        let scaleUpItem = NSMenuItem(
            title: "Scale Mascot Larger",
            action: #selector(scaleUpAction),
            keyEquivalent: "="
        )
        scaleUpItem.target = self
        appMenu.addItem(scaleUpItem)

        let scaleDownItem = NSMenuItem(
            title: "Scale Mascot Smaller",
            action: #selector(scaleDownAction),
            keyEquivalent: "-"
        )
        scaleDownItem.target = self
        appMenu.addItem(scaleDownItem)

        let opacityUpItem = NSMenuItem(
            title: "Increase Mascot Opacity",
            action: #selector(increaseOpacityAction),
            keyEquivalent: "]"
        )
        opacityUpItem.target = self
        appMenu.addItem(opacityUpItem)

        let opacityDownItem = NSMenuItem(
            title: "Decrease Mascot Opacity",
            action: #selector(decreaseOpacityAction),
            keyEquivalent: "["
        )
        opacityDownItem.target = self
        appMenu.addItem(opacityDownItem)
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

    // MARK: - Menu & Shortcut Actions

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
                telemetrySettings: telemetrySettings,
                audioSettings: audioSettings,
                audioPlayer: audioService,
                flowShieldSettings: flowShieldSettings,
                flowShieldService: flowShieldService,
                interactionSettings: interactionSettings,
                inboxDirectoryURL: fileDropService.inboxDirectoryURL,
                paletteStore: paletteStore
            )
        )
    }

    @objc public func toggleSettingsWindow() {
        if SettingsWindowManager.shared.isWindowOpen {
            SettingsWindowManager.shared.closeSettingsWindow()
        } else {
            showSettingsWindow()
        }
    }

    @objc public func petBitzAction() {
        engine.triggerPetInteraction()
    }

    @objc public func scaleUpAction() {
        scaleStore.stepUp()
    }

    @objc public func scaleDownAction() {
        scaleStore.stepDown()
    }

    @objc public func increaseOpacityAction() {
        opacityStore.stepUp()
    }

    @objc public func decreaseOpacityAction() {
        opacityStore.stepDown()
    }

    @objc public func lockPositionAction() {
        positionStore.lockPosition()
    }

    /// Handles keyboard shortcuts locally or globally without stealing key focus.
    /// `isGlobal` marks keystrokes typed in other apps: only ⌥⌘B and the Esc/Return lock apply there.
    @MainActor
    @discardableResult
    public func handleKeyEvent(_ event: NSEvent, isGlobal: Bool = false) -> Bool {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        let cmd = flags.contains(.command)
        let opt = flags.contains(.option)
        let ctrl = flags.contains(.control)
        let chars = event.charactersIgnoringModifiers?.lowercased() ?? ""
        let keyCode = event.keyCode

        // 1. Toggle / Open Settings Window: ⌥⌘B (works from any app)
        if cmd && opt && !ctrl && (keyCode == 11 || chars == "b") {
            toggleSettingsWindow()
            return true
        }

        // 2. Lock position when dragging or unlocked: ⎋ Esc (53), ⏎ Return (36), or Enter (76)
        if positionStore.isInteractivityEnabled && (keyCode == 53 || keyCode == 36 || keyCode == 76) {
            positionStore.lockPosition()
            return true
        }

        // Shortcuts below belong to the frontmost app when Bitz isn't active (⌘Q must not quit Bitz, #93)
        if isGlobal { return false }

        // Toggle / Open Settings Window: ⌘,
        if cmd && !opt && !ctrl && (keyCode == 43 || chars == ",") {
            toggleSettingsWindow()
            return true
        }

        // 3. Scale Mascot: ⌘- to step down, ⌘= / ⌘+ to step up
        if cmd && !opt && !ctrl {
            if keyCode == 27 || chars == "-" || chars == "_" {
                scaleStore.stepDown()
                return true
            }
            if keyCode == 24 || chars == "=" || chars == "+" {
                scaleStore.stepUp()
                return true
            }
        }

        // 4. Opacity: ⌘[ to step down, ⌘] to step up
        if cmd && !opt && !ctrl {
            if keyCode == 33 || chars == "[" || chars == "{" {
                opacityStore.stepDown()
                return true
            }
            if keyCode == 30 || chars == "]" || chars == "}" {
                opacityStore.stepUp()
                return true
            }
        }

        // 5. Pet Bitz: ⌘P, or bare 'P' when no text input is focused
        if cmd && !opt && !ctrl && (keyCode == 35 || chars == "p") {
            engine.triggerPetInteraction()
            return true
        }
        if !cmd && !opt && !ctrl && (keyCode == 35 || chars == "p") {
            if !isFirstResponderTextInput() {
                engine.triggerPetInteraction()
                return true
            }
        }

        // 6. Quit: ⌘Q
        if cmd && !opt && !ctrl && (keyCode == 12 || chars == "q") {
            NSApplication.shared.terminate(nil)
            return true
        }

        return false
    }

    private func isFirstResponderTextInput() -> Bool {
        guard let keyWindow = NSApp?.keyWindow,
              let firstResponder = keyWindow.firstResponder else {
            return false
        }
        return firstResponder is NSText || firstResponder is NSTextView || firstResponder is NSTextField
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
                telemetrySettings: telemetrySettings,
                paletteStore: paletteStore
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
            interactionSettings: interactionSettings,
            paletteStore: paletteStore,
            onFilesDropped: { [weak self] urls in
                guard let self else { return }
                do {
                    let result = try self.fileDropService.handleDrop(
                        urls: urls,
                        writeInbox: self.interactionSettings.isInboxHandoffEnabled
                    )
                    self.engine.showTransientBubble(result.message)
                } catch {
                    self.engine.showTransientBubble("⚠️ Couldn't copy that file path")
                }
            },
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
        // MascotOverlayPanel uses an explicit fixed canvas frame; disable intrinsic sizing queries per tick (#70)
        hostingView.sizingOptions = []
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
    @ObservedObject var audioSettings: CyberAudioSettingsStore
    @ObservedObject var paletteStore: AvatarPaletteStore
    var audioService: CyberAudioService? = nil
    @ObservedObject var flowShieldSettings: FlowShieldSettingsStore
    @ObservedObject var flowShieldService: FlowShieldService

    public init(
        engine: WellnessPointEngine,
        activityMonitor: ActivityMonitorService,
        scaleStore: AvatarScaleStore,
        opacityStore: AvatarOpacityStore,
        positionStore: AvatarPositionStore,
        displayStore: DisplayPreferenceStore,
        agentMonitor: AgentMonitorService,
        updateStore: AppUpdateStore,
        telemetryDashboard: TelemetryDashboardService,
        telemetrySettings: TelemetrySettingsStore,
        audioSettings: CyberAudioSettingsStore = CyberAudioSettingsStore(),
        audioService: CyberAudioService? = nil,
        flowShieldSettings: FlowShieldSettingsStore? = nil,
        flowShieldService: FlowShieldService? = nil,
        paletteStore: AvatarPaletteStore = AvatarPaletteStore()
    ) {
        self.paletteStore = paletteStore
        self.engine = engine
        self.activityMonitor = activityMonitor
        self.scaleStore = scaleStore
        self.opacityStore = opacityStore
        self.positionStore = positionStore
        self.displayStore = displayStore
        self.agentMonitor = agentMonitor
        self.updateStore = updateStore
        self.telemetryDashboard = telemetryDashboard
        self.telemetrySettings = telemetrySettings
        self.audioSettings = audioSettings
        self.audioService = audioService
        let resolvedFlowShieldSettings = flowShieldSettings ?? FlowShieldSettingsStore()
        self.flowShieldSettings = resolvedFlowShieldSettings
        self.flowShieldService = flowShieldService ?? FlowShieldService(settingsStore: resolvedFlowShieldSettings)
    }

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

            // MARK: - 1b. Theme Preset Submenu
            Menu {
                ForEach(AvatarThemePreset.allCases) { preset in
                    Toggle(preset.title, isOn: Binding(
                        get: { paletteStore.selectedPreset == preset },
                        set: { if $0 { paletteStore.selectPreset(preset) } }
                    ))
                }
            } label: {
                Label("Theme Preset", systemImage: "paintpalette.fill")
            }

            // MARK: - 2. Flow Shield Quick Controls
            if flowShieldService.isFlowShieldActive {
                Button("🛡 Break Shield (Disable Focus)") {
                    flowShieldService.activateBreakShieldOverride()
                }
            }

            Menu {
                Text("Status: \(flowShieldService.currentStatus.displayTitle)")
                Toggle("Enable Auto Flow Shield", isOn: Binding(
                    get: { flowShieldSettings.isEnabled },
                    set: { flowShieldSettings.setEnabled($0) }
                ))
                Divider()
                Button(
                    flowShieldSettings.isBreakShieldOverrideActive
                        ? "Resume Auto Flow Shield"
                        : "Break Shield (Disable Focus)"
                ) {
                    flowShieldService.toggleBreakShieldOverride()
                }
                .disabled(!flowShieldSettings.isEnabled)
                Divider()
                Text("Streak Threshold: \(flowShieldSettings.formattedStreakSummary)")
                Button("Streak: 15 min") { flowShieldSettings.setStreakMinutesThreshold(15.0) }
                    .disabled(!flowShieldSettings.isEnabled)
                Button("Streak: 20 min") { flowShieldSettings.setStreakMinutesThreshold(20.0) }
                    .disabled(!flowShieldSettings.isEnabled)
                Button("Streak: 30 min") { flowShieldSettings.setStreakMinutesThreshold(30.0) }
                    .disabled(!flowShieldSettings.isEnabled)
                Button("Streak: 45 min") { flowShieldSettings.setStreakMinutesThreshold(45.0) }
                    .disabled(!flowShieldSettings.isEnabled)
            } label: {
                Label("Flow Shield", systemImage: flowShieldService.currentStatus.systemImage)
            }
            Menu {
                Toggle("Enable Cyber Audio", isOn: Binding(
                    get: { audioSettings.isEnabled },
                    set: { audioSettings.setEnabled($0) }
                ))
                if let audioService {
                    AudioSuppressionNotice(audioService: audioService)
                }
                Divider()
                Toggle("Soothing Purr (Petting & High Wellness)", isOn: Binding(
                    get: { audioSettings.isPurrEnabled },
                    set: { audioSettings.setPurrEnabled($0) }
                ))
                .disabled(!audioSettings.isEnabled)
                Toggle("Burnout Power-Down", isOn: Binding(
                    get: { audioSettings.isBurnoutEnabled },
                    set: { audioSettings.setBurnoutEnabled($0) }
                ))
                .disabled(!audioSettings.isEnabled)
                Toggle("Overheating Thermal Alarm", isOn: Binding(
                    get: { audioSettings.isOverheatEnabled },
                    set: { audioSettings.setOverheatEnabled($0) }
                ))
                .disabled(!audioSettings.isEnabled)
                Toggle("Agent Needs Approval Chime", isOn: Binding(
                    get: { audioSettings.isAgentChimeEnabled },
                    set: { audioSettings.setAgentChimeEnabled($0) }
                ))
                .disabled(!audioSettings.isEnabled)
                Toggle("All Agents Done Fanfare", isOn: Binding(
                    get: { audioSettings.isAllDoneFanfareEnabled },
                    set: { audioSettings.setAllDoneFanfareEnabled($0) }
                ))
                .disabled(!audioSettings.isEnabled)
                Toggle("Charging Blip", isOn: Binding(
                    get: { audioSettings.isChargingEnabled },
                    set: { audioSettings.setChargingEnabled($0) }
                ))
                .disabled(!audioSettings.isEnabled)
                Divider()
                Text("Volume: \(audioSettings.formattedVolumeSummary)")
                Button("Volume: 25%") { audioSettings.setVolume(0.25) }
                    .disabled(!audioSettings.isEnabled)
                Button("Volume: 50%") { audioSettings.setVolume(0.50) }
                    .disabled(!audioSettings.isEnabled)
                Button("Volume: 75%") { audioSettings.setVolume(0.75) }
                    .disabled(!audioSettings.isEnabled)
                Button("Volume: 100%") { audioSettings.setVolume(1.00) }
                    .disabled(!audioSettings.isEnabled)
                Divider()
                Button("Test Chime") {
                    audioService?.play(.agentNeedsApproval, bypassCooldown: true)
                }
                .disabled(!audioSettings.isEnabled)
            } label: {
                Label("Sound", systemImage: audioSettings.isEnabled ? "speaker.wave.2.fill" : "speaker.slash.fill")
            }

            Divider()

            // MARK: - 3. Appearance Quick Adjustments
            Menu {
                Button("Scale Mascot Larger (⌘=)") {
                    scaleStore.stepUp()
                }
                .keyboardShortcut("=", modifiers: [.command])
                .disabled(!scaleStore.canStepUp)

                Button("Scale Mascot Smaller (⌘-)") {
                    scaleStore.stepDown()
                }
                .keyboardShortcut("-", modifiers: [.command])
                .disabled(!scaleStore.canStepDown)

                Divider()

                Button("Increase Opacity (⌘])") {
                    opacityStore.stepUp()
                }
                .keyboardShortcut("]", modifiers: [.command])
                .disabled(!opacityStore.canStepUp)

                Button("Decrease Opacity (⌘[)") {
                    opacityStore.stepDown()
                }
                .keyboardShortcut("[", modifiers: [.command])
                .disabled(!opacityStore.canStepDown)
            } label: {
                Label("Size & Opacity", systemImage: "arrow.up.left.and.arrow.down.right")
            }

            Divider()

            // MARK: - 4. Dedicated Settings Entrance
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
            .keyboardShortcut("q", modifiers: [.command])
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
                telemetrySettings: telemetrySettings,
                audioSettings: audioSettings,
                audioPlayer: audioService,
                flowShieldSettings: flowShieldSettings,
                flowShieldService: flowShieldService
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

        if activityMonitor.isManualOverrideActive {
            HStack(spacing: 6) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                    .font(.caption)
                Text("Simulation Override Active")
                    .font(.caption.bold())
                    .foregroundStyle(.orange)
                Spacer()
                Button("Resume") {
                    activityMonitor.clearManualOverride()
                }
                .controlSize(.small)
            }
        }

        Button("Pet Bitz (<3)") {
            engine.triggerPetInteraction()
        }
        .accessibilityLabel("Pet Bitz")
        .keyboardShortcut("p", modifiers: [.command])

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
                telemetrySettings: appDelegate.telemetrySettings,
                audioSettings: appDelegate.audioSettings,
                audioService: appDelegate.audioService,
                flowShieldSettings: appDelegate.flowShieldSettings,
                flowShieldService: appDelegate.flowShieldService,
                paletteStore: appDelegate.paletteStore
            )
        }
    }
}
