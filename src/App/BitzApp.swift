import AppKit
import Combine
import ServiceManagement
import SwiftUI

/// Application delegate managing the transparent `MascotOverlayPanel`, `WellnessPointEngine`,
/// `ActivityMonitorService`, `AvatarScaleStore`, and `AvatarOpacityStore` lifecycle (`FR-001`, `FR-005`, `FR-006`).
@MainActor
public final class BitzAppDelegate: NSObject, NSApplicationDelegate, ObservableObject {
    public static let hasCompletedInitialLaunchKey = "Bitz.HasCompletedInitialLaunch"

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
    public let gitActivityProvider: any GitActivityProviding
    public let approvalStore: AgentApprovalStore
    public let appActivator: any AppActivating
    public let diffViewer: any DiffViewing
    public let licensingService: LicensingService
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
    private var personalityPresetCancellable: AnyCancellable?
    private var screenReconfigTask: Task<Void, Never>?
    private let userDefaults: UserDefaults

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
        gitActivityProvider: (any GitActivityProviding)? = nil,
        approvalStore: AgentApprovalStore? = nil,
        appActivator: (any AppActivating)? = nil,
        diffViewer: (any DiffViewing)? = nil,
        licensingService: LicensingService? = nil,
        userDefaults: UserDefaults = .standard
    ) {
        self.userDefaults = userDefaults
        self.licensingService = licensingService ?? LicensingService()
        let resolvedApprovalStore = approvalStore ?? AgentApprovalStore()
        self.approvalStore = resolvedApprovalStore
        self.appActivator = appActivator ?? WorkspaceAppActivator()
        self.diffViewer = diffViewer ?? SystemDiffViewer()
        self.paletteStore = paletteStore ?? AvatarPaletteStore(userDefaults: userDefaults)
        let resolvedPersonalitySettings = personalitySettings ?? PersonalitySettingsStore(userDefaults: userDefaults)
        self.personalitySettings = resolvedPersonalitySettings
        let resolvedPersonalityService = personalityService ?? PersonalityService(
            primaryGenerator: FoundationModelsCommentaryGenerator(),
            fallbackGenerator: TemplatedCommentaryGenerator(),
            settingsStore: resolvedPersonalitySettings
        )
        self.personalityService = resolvedPersonalityService
        self.gitActivityProvider = gitActivityProvider ?? GitActivityProvider(settingsStore: resolvedPersonalitySettings)
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
        self.approvalStore.bind(agentMonitor: self.agentMonitor)

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
            self?.agentMonitor.hookActionMessage = nil
            self?.agentMonitor.isHookActionError = false
        }
        // An agent popup or pending approval can cover the update alert's buttons, so re-check on all changes
        self.bubbleInteractivityCancellable = Publishers.Merge3(
            self.updateStore.$isSpeechBubbleAlertActive.map { _ in () },
            self.agentMonitor.$activePopup.map { _ in () },
            self.approvalStore.$activeRequest.map { _ in () }
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
            let commits = await self.gitActivityProvider.recentCommitCount(sinceMinutes: 60)
            let context = PersonalityContext(
                wellnessState: state,
                currentPoints: self.engine.currentPoints,
                continuousWorkMinutes: self.engine.continuousWorkMinutes,
                temperatureCelsius: self.activityMonitor.lastTemperatureCelsius,
                cpuLoadPercentage: self.activityMonitor.lastCPULoadPercentage,
                frontmostAppName: self.activityMonitor.lastFrontmostAppName,
                activeAgentNames: Array(self.agentMonitor.activeAgents),
                recentCommitCount: commits
            )
            return await self.personalityService.rephraseWarning(warning, context: context)
        }

        self.personalityTickCancellable = self.telemetryDashboard.$snapshot
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.triggerPersonalityTick(bypassRateLimit: false)
            }

        self.personalityEnabledCancellable = self.personalitySettings.$isEnabled
            .receive(on: DispatchQueue.main)
            .sink { [weak self] enabled in
                guard let self else { return }
                if !enabled {
                    self.engine.setIdleCommentaryText(nil)
                    self.personalityService.clearCommentary()
                } else {
                    self.triggerPersonalityTick(bypassRateLimit: true)
                }
            }

        self.personalityPresetCancellable = self.personalitySettings.$preset
            .dropFirst()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                guard let self, self.personalitySettings.isEnabled else { return }
                self.triggerPersonalityTick(bypassRateLimit: true)
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
        let currentContent = SpeechBubbleContent.current(
            engine: engine,
            agentMonitor: agentMonitor,
            updateStore: updateStore,
            telemetryDashboard: telemetryDashboard,
            telemetrySettings: telemetrySettings
        )
        let bubbleIsInteractive = (currentContent?.isInteractive ?? false) || approvalStore.activeRequest != nil
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
        if shouldOpenSettingsOnLaunch() {
            showSettingsWindow()
        }
        if personalitySettings.isEnabled {
            triggerPersonalityTick(bypassRateLimit: true)
        }
    }

    /// Returns true only on the very first launch, marking initial launch complete so subsequent logins stay quiet (#94 C10 / D-3).
    public func shouldOpenSettingsOnLaunch() -> Bool {
        if userDefaults.bool(forKey: Self.hasCompletedInitialLaunchKey) {
            return false
        }
        userDefaults.set(true, forKey: Self.hasCompletedInitialLaunchKey)
        return true
    }

    /// Evaluates live telemetry and triggers on-device or templated personality commentary.
    public func triggerPersonalityTick(bypassRateLimit: Bool = false) {
        guard personalitySettings.isEnabled else {
            if engine.idleCommentaryText != nil {
                engine.setIdleCommentaryText(nil)
            }
            return
        }
        let isBubbleIdle = agentMonitor.activePopup == nil
            && !updateStore.isSpeechBubbleAlertActive
            && engine.activeSpeechBubbleText == nil
        guard isBubbleIdle else { return }

        Task { @MainActor [weak self] in
            guard let self else { return }
            let commits = await self.gitActivityProvider.recentCommitCount(sinceMinutes: 60)
            let context = PersonalityContext(
                wellnessState: self.engine.currentState,
                currentPoints: self.engine.currentPoints,
                continuousWorkMinutes: self.engine.continuousWorkMinutes,
                temperatureCelsius: self.activityMonitor.lastTemperatureCelsius,
                cpuLoadPercentage: self.activityMonitor.lastCPULoadPercentage,
                frontmostAppName: self.activityMonitor.lastFrontmostAppName,
                activeAgentNames: Array(self.agentMonitor.activeAgents),
                recentCommitCount: commits
            )
            await self.personalityService.tick(context: context, isBubbleIdle: isBubbleIdle, bypassRateLimit: bypassRateLimit)
            self.engine.setIdleCommentaryText(self.personalityService.activeCommentary)
        }
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
        personalityPresetCancellable = nil
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
                paletteStore: paletteStore,
                personalitySettings: personalitySettings,
                licensingService: licensingService
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
            rootView: SpeechBubbleHostView(
                speechBubbleView: SpeechBubbleView(
                    engine: engine,
                    scaleStore: scaleStore,
                    agentMonitor: agentMonitor,
                    updateStore: updateStore,
                    telemetryDashboard: telemetryDashboard,
                    telemetrySettings: telemetrySettings,
                    paletteStore: paletteStore
                ),
                approvalStore: approvalStore,
                agentMonitor: agentMonitor,
                appActivator: appActivator,
                diffViewer: diffViewer
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

/// Host view inside `SpeechBubblePanel`, rendering `SpeechBubbleView` and the
/// interactive quick-action HUD (`AgentApprovalHUDView`) during `.needsApproval` status (FR-004, FR-005, FR-006, FR-008).
public struct SpeechBubbleHostView: View {
    public let speechBubbleView: SpeechBubbleView
    @ObservedObject public var approvalStore: AgentApprovalStore
    @ObservedObject public var agentMonitor: AgentMonitorService
    public let appActivator: any AppActivating
    public let diffViewer: any DiffViewing

    public init(
        speechBubbleView: SpeechBubbleView,
        approvalStore: AgentApprovalStore,
        agentMonitor: AgentMonitorService,
        appActivator: any AppActivating,
        diffViewer: any DiffViewing
    ) {
        self.speechBubbleView = speechBubbleView
        self.approvalStore = approvalStore
        self.agentMonitor = agentMonitor
        self.appActivator = appActivator
        self.diffViewer = diffViewer
    }

    public var body: some View {
        VStack(spacing: 4) {
            speechBubbleView

            if let request = approvalStore.activeRequest, agentMonitor.activePopup?.kind == .needsApproval {
                AgentApprovalHUDView(
                    request: request,
                    appActivator: appActivator,
                    diffViewer: diffViewer,
                    onApprove: {
                        approvalStore.submitDecision(.approve, for: request.id)
                        agentMonitor.dismissPopup()
                    }
                )
                .padding(.horizontal, 8)
                .padding(.bottom, 6)
            }
        }
    }
}

/// Leaf subview isolating the 1–10s polling `TelemetryDashboardService` observer from the root menu bar view (#94 D1 / AGENTS.md §2.5).
@MainActor
struct MenuBarTelemetrySectionView: View {
    @ObservedObject var telemetryDashboard: TelemetryDashboardService
    @ObservedObject var telemetrySettings: TelemetrySettingsStore

    var body: some View {
        if telemetrySettings.displayInMenuBarMenu {
            let stats = telemetryDashboard.snapshot.menuBarItems(enabledMetrics: telemetrySettings.enabledMetrics)
            if !stats.isEmpty {
                Text(stats.joined(separator: " | "))
            }
        }

        if telemetryDashboard.snapshot.hasActiveWarning, let warning = telemetryDashboard.snapshot.activeWarningSummary {
            Divider()
            Text(warning)
        }
    }
}

/// Observable Menu Bar content view displaying live hardware sensor telemetry,
/// wellness score, quick actions, and links to Settings for detailed controls.
@MainActor
struct BitzMenuBarContentView: View {
    @ObservedObject var engine: WellnessPointEngine
    @ObservedObject var activityMonitor: ActivityMonitorService
    @ObservedObject var positionStore: AvatarPositionStore
    @ObservedObject var agentMonitor: AgentMonitorService
    @ObservedObject var updateStore: AppUpdateStore
    let telemetryDashboard: TelemetryDashboardService
    let telemetrySettings: TelemetrySettingsStore
    @ObservedObject var audioSettings: CyberAudioSettingsStore
    @ObservedObject var paletteStore: AvatarPaletteStore
    var audioService: CyberAudioService? = nil
    @ObservedObject var flowShieldSettings: FlowShieldSettingsStore
    let flowShieldService: FlowShieldService
    var onOpenSettings: () -> Void

    public init(
        engine: WellnessPointEngine,
        activityMonitor: ActivityMonitorService,
        positionStore: AvatarPositionStore,
        agentMonitor: AgentMonitorService,
        updateStore: AppUpdateStore,
        telemetryDashboard: TelemetryDashboardService,
        telemetrySettings: TelemetrySettingsStore,
        audioSettings: CyberAudioSettingsStore = CyberAudioSettingsStore(),
        audioService: CyberAudioService? = nil,
        flowShieldSettings: FlowShieldSettingsStore? = nil,
        flowShieldService: FlowShieldService? = nil,
        paletteStore: AvatarPaletteStore = AvatarPaletteStore(),
        onOpenSettings: @escaping () -> Void = {}
    ) {
        self.paletteStore = paletteStore
        self.onOpenSettings = onOpenSettings
        self.engine = engine
        self.activityMonitor = activityMonitor
        self.positionStore = positionStore
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
            // MARK: - 1. Status Header & Telemetry / Warnings
            Text(String(
                format: "Bitz — %@ · %.0f PTS · %.0f min streak",
                engine.currentState.displayName,
                engine.currentPoints,
                engine.continuousWorkMinutes
            ))

            MenuBarTelemetrySectionView(
                telemetryDashboard: telemetryDashboard,
                telemetrySettings: telemetrySettings
            )

            if let agentWarning = agentMonitor.activeWarning {
                Divider()
                Text(agentWarning.text)
                Button("Dismiss Agent Warning") {
                    agentMonitor.acknowledgeWarning()
                }
            }

            // The warning popup's text is already shown above
            if let agentPopup = agentMonitor.activePopup, agentPopup.kind != .warning {
                Divider()
                Text(agentPopup.text)
            }

            if activityMonitor.isManualOverrideActive {
                Divider()
                Button("Resume Live Sensors") {
                    activityMonitor.clearManualOverride()
                }
            }

            Divider()

            // MARK: - 2. Primary Quick Actions
            Button("Pet Bitz") {
                engine.triggerPetInteraction()
            }
            .keyboardShortcut("p", modifiers: [.command])

            Toggle("Show Mascot", isOn: $positionStore.isMascotVisible)

            if positionStore.isPositionUnlocked {
                Button("Lock Position") {
                    positionStore.lockPosition()
                }
            }

            if flowShieldSettings.isEnabled {
                Button(
                    flowShieldSettings.isBreakShieldOverrideActive
                        ? "Resume Auto Flow Shield"
                        : "Break Shield (Disable Focus)"
                ) {
                    flowShieldService.toggleBreakShieldOverride()
                }
            }

            Toggle("Sound", isOn: Binding(
                get: { audioSettings.isEnabled },
                set: { audioSettings.setEnabled($0) }
            ))
            if let audioService {
                AudioSuppressionNotice(audioService: audioService)
            }

            Menu("Theme") {
                ForEach(AvatarThemePreset.allCases) { preset in
                    Toggle(preset.title, isOn: Binding(
                        get: { paletteStore.selectedPreset == preset },
                        set: { if $0 { paletteStore.selectPreset(preset) } }
                    ))
                }
            }

            Divider()

            // MARK: - 3. Settings, Updates & Quit
            Button("Settings...") {
                onOpenSettings()
            }
            .keyboardShortcut(",", modifiers: [.command])

            Button("Check for Updates...") {
                Task {
                    await updateStore.checkForUpdates(manual: true)
                    // The menu is closed by now; an unskipped available update already shows its own bubble
                    if !updateStore.isSpeechBubbleAlertActive {
                        engine.showTransientBubble(updateStore.statusMessage)
                    }
                }
            }
            Text(updateStore.statusMessage)

            if updateStore.isUpdateAvailable, let release = updateStore.latestRelease {
                Button("Download v\(release.semanticVersion.description)...") {
                    updateStore.openDownloadPage()
                }
                .keyboardShortcut("u", modifiers: [.command])
            }

            Divider()

            Button("Quit Bitz") {
                NSApplication.shared.terminate(nil)
            }
            .keyboardShortcut("q", modifiers: [.command])
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
        MenuBarExtra {
            BitzMenuBarContentView(
                engine: appDelegate.engine,
                activityMonitor: appDelegate.activityMonitor,
                positionStore: appDelegate.positionStore,
                agentMonitor: appDelegate.agentMonitor,
                updateStore: appDelegate.updateStore,
                telemetryDashboard: appDelegate.telemetryDashboard,
                telemetrySettings: appDelegate.telemetrySettings,
                audioSettings: appDelegate.audioSettings,
                audioService: appDelegate.audioService,
                flowShieldSettings: appDelegate.flowShieldSettings,
                flowShieldService: appDelegate.flowShieldService,
                paletteStore: appDelegate.paletteStore,
                onOpenSettings: appDelegate.showSettingsWindow
            )
        } label: {
            BitzMenuBarLabel(appDelegate: appDelegate)
        }
    }
}

/// Status item label. Observes only the delegate, which publishes on title changes, not on every telemetry tick.
struct BitzMenuBarLabel: View {
    @ObservedObject var appDelegate: BitzAppDelegate

    var body: some View {
        if appDelegate.menuBarTitle == "Bitz" {
            Image(systemName: "cat.fill")
                .accessibilityLabel("Bitz")
        } else {
            HStack {
                Image(systemName: "cat.fill")
                Text(appDelegate.menuBarTitle)
            }
        }
    }
}
