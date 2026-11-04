import AppKit
import Combine
import Foundation

/// Curated screen corner anchors for positioning the Bitz overlay panel.
public enum ScreenCornerAnchor: String, CaseIterable, Sendable {
    case bottomRight = "bottomRight"
    case bottomLeft = "bottomLeft"
    case topRight = "topRight"
    case topLeft = "topLeft"

    public var menuTitle: String {
        switch self {
        case .bottomRight: return "Bottom-Right (Default)"
        case .bottomLeft: return "Bottom-Left"
        case .topRight: return "Top-Right"
        case .topLeft: return "Top-Left"
        }
    }
}

/// Mascot positioning mode: either locked to a predefined screen corner or placed freeform.
public enum MascotPositionMode: Equatable, Sendable {
    case corner(ScreenCornerAnchor)
    case freeform(x: CGFloat, y: CGFloat)
}

/// `@MainActor` observable store managing the user's selected screen corner anchor,
/// freeform drag-and-drop position coordinates, interactivity toggles, and `UserDefaults` persistence.
@MainActor
public final class AvatarPositionStore: ObservableObject {
    public static let defaultCorner: ScreenCornerAnchor = .bottomRight
    public static let userDefaultsKey: String = "avatarCornerAnchor"
    public static let isFreeformKey: String = "avatarIsFreeformMode"
    public static let customPositionXKey: String = "avatarCustomPositionX"
    public static let customPositionYKey: String = "avatarCustomPositionY"
    public static let isMascotVisibleKey: String = "avatarIsMascotVisible"

    @Published public private(set) var positionMode: MascotPositionMode
    @Published public private(set) var cornerAnchor: ScreenCornerAnchor
    @Published public private(set) var customOrigin: NSPoint?
    @Published public var isPositionUnlocked: Bool = false
    @Published public var isModifierHeld: Bool = false
    @Published public var isDragging: Bool = false
    @Published public var isMascotVisible: Bool {
        didSet {
            userDefaults.set(isMascotVisible, forKey: Self.isMascotVisibleKey)
            onVisibilityChanged?(isMascotVisible)
        }
    }

    private let userDefaults: UserDefaults

    public var onCornerChanged: ((ScreenCornerAnchor) -> Void)?
    public var onCustomPositionChanged: ((NSPoint) -> Void)?
    public var onPositionModeChanged: ((MascotPositionMode) -> Void)?
    public var onInteractivityToggled: ((Bool) -> Void)?
    public var onVisibilityChanged: ((Bool) -> Void)?

    public var isInteractivityEnabled: Bool {
        isPositionUnlocked || isModifierHeld
    }

    public var isFreeform: Bool {
        if case .freeform = positionMode { return true }
        return false
    }

    public var formattedPositionSummary: String {
        isFreeform ? "Freeform (Custom)" : cornerAnchor.menuTitle
    }

    public init(userDefaults: UserDefaults = .standard) {
        self.userDefaults = userDefaults

        let isMascotVisible = userDefaults.object(forKey: Self.isMascotVisibleKey) as? Bool ?? true
        self.isMascotVisible = isMascotVisible

        let storedCornerRaw = userDefaults.string(forKey: Self.userDefaultsKey)
        let resolvedCorner = storedCornerRaw.flatMap { ScreenCornerAnchor(rawValue: $0) } ?? Self.defaultCorner
        self.cornerAnchor = resolvedCorner

        let isFreeform = userDefaults.bool(forKey: Self.isFreeformKey)
        let storedX = userDefaults.object(forKey: Self.customPositionXKey) as? Double
        let storedY = userDefaults.object(forKey: Self.customPositionYKey) as? Double

        if isFreeform, let storedX, let storedY {
            let point = NSPoint(x: CGFloat(storedX), y: CGFloat(storedY))
            self.customOrigin = point
            self.positionMode = .freeform(x: CGFloat(storedX), y: CGFloat(storedY))
        } else {
            self.customOrigin = nil
            self.positionMode = .corner(resolvedCorner)
            userDefaults.set(resolvedCorner.rawValue, forKey: Self.userDefaultsKey)
        }
    }

    public func selectCorner(_ corner: ScreenCornerAnchor) {
        positionMode = .corner(corner)
        cornerAnchor = corner
        customOrigin = nil
        userDefaults.set(corner.rawValue, forKey: Self.userDefaultsKey)
        userDefaults.set(false, forKey: Self.isFreeformKey)
        onCornerChanged?(corner)
        onPositionModeChanged?(positionMode)
    }

    public func setCustomPosition(_ point: NSPoint) {
        positionMode = .freeform(x: point.x, y: point.y)
        customOrigin = point
        userDefaults.set(true, forKey: Self.isFreeformKey)
        userDefaults.set(Double(point.x), forKey: Self.customPositionXKey)
        userDefaults.set(Double(point.y), forKey: Self.customPositionYKey)
        onCustomPositionChanged?(point)
        onPositionModeChanged?(positionMode)
    }

    public func resetToDefaultCorner() {
        selectCorner(Self.defaultCorner)
    }

    public func isCornerSelected(_ corner: ScreenCornerAnchor) -> Bool {
        !isFreeform && cornerAnchor == corner
    }

    public func togglePositionLock() {
        isPositionUnlocked.toggle()
        onInteractivityToggled?(isInteractivityEnabled)
    }

    public func lockPosition() {
        guard isPositionUnlocked || isModifierHeld else { return }
        isPositionUnlocked = false
        isModifierHeld = false
        onInteractivityToggled?(false)
    }

    public func unlockPosition() {
        guard !isPositionUnlocked else { return }
        isPositionUnlocked = true
        onInteractivityToggled?(true)
    }

    public func setModifierHeld(_ held: Bool) {
        guard isModifierHeld != held else { return }
        isModifierHeld = held
        onInteractivityToggled?(isInteractivityEnabled)
    }

    public func setMascotVisible(_ visible: Bool) {
        guard isMascotVisible != visible else { return }
        isMascotVisible = visible
    }

    public func toggleMascotVisibility() {
        isMascotVisible.toggle()
    }
}

/// Curated manual opacity presets for the Bitz desktop companion avatar (transparency / see-through mode).
public enum AvatarOpacityPreset: Double, CaseIterable, Sendable {
    case solid = 1.00
    case translucent = 0.80
    case hologram = 0.60
    case ghost = 0.40
    case stealth = 0.25

    /// Percentage string representation (e.g., `"100%"`, `"80%"`, `"60%"`).
    public var percentageText: String {
        "\(Int((rawValue * 100.0).rounded()))%"
    }

    /// Human-readable Menu Bar label.
    public var menuTitle: String {
        switch self {
        case .solid:
            return "Solid — 100%"
        case .translucent:
            return "Translucent — 80%"
        case .hologram:
            return "Hologram — 60%"
        case .ghost:
            return "Ghost — 40%"
        case .stealth:
            return "Stealth — 25%"
        }
    }
}

/// `@MainActor` observable store managing the user's manual avatar opacity / see-through factor (`0.20...1.00`),
/// presets, `±10%` step adjustments, and `UserDefaults` persistence (`"avatarOpacityFactor"`).
@MainActor
public final class AvatarOpacityStore: ObservableObject {
    public static let defaultOpacityFactor: Double = 0.85
    public static let minOpacityFactor: Double = 0.20
    public static let maxOpacityFactor: Double = 1.00
    public static let stepDelta: Double = 0.10
    public static let userDefaultsKey: String = "avatarOpacityFactor"

    @Published public private(set) var opacityFactor: Double
    private let userDefaults: UserDefaults
    public var onOpacityChanged: ((Double) -> Void)?

    public init(userDefaults: UserDefaults = .standard) {
        self.userDefaults = userDefaults
        let storedObj = userDefaults.object(forKey: Self.userDefaultsKey)
        let initialOpacity: Double
        if let storedObj {
            let rawStored = (storedObj as? Double) ?? userDefaults.double(forKey: Self.userDefaultsKey)
            initialOpacity = Self.sanitizeOpacityFactor(rawStored)
        } else {
            initialOpacity = Self.defaultOpacityFactor
            userDefaults.set(initialOpacity, forKey: Self.userDefaultsKey)
        }
        self.opacityFactor = initialOpacity
    }

    /// Sanitizes an opacity input: non-finite or `<= 0` values fall back to default,
    /// and positive values are rounded to 2 decimal places and clamped to `0.20...1.00`.
    public static func sanitizeOpacityFactor(_ rawValue: Double) -> Double {
        guard rawValue.isFinite, rawValue > 0.0 else {
            return defaultOpacityFactor
        }
        let clamped = min(max(rawValue, minOpacityFactor), maxOpacityFactor)
        return (clamped * 100.0).rounded() / 100.0
    }

    /// Current opacity expressed as an integer percentage (e.g., `85` for `0.85`).
    public var percentageInt: Int {
        Int((opacityFactor * 100.0).rounded())
    }

    /// Formatted status summary for the Menu Bar header (e.g., `"85%"`).
    public var formattedOpacitySummary: String {
        "\(percentageInt)%"
    }

    public var canStepDown: Bool {
        opacityFactor > Self.minOpacityFactor + 0.001
    }

    public var canStepUp: Bool {
        opacityFactor < Self.maxOpacityFactor - 0.001
    }

    public func setOpacity(_ newOpacity: Double) {
        let sanitized = Self.sanitizeOpacityFactor(newOpacity)
        opacityFactor = sanitized
        userDefaults.set(sanitized, forKey: Self.userDefaultsKey)
        onOpacityChanged?(sanitized)
    }

    public func selectPreset(_ preset: AvatarOpacityPreset) {
        setOpacity(preset.rawValue)
    }

    public func isPresetSelected(_ preset: AvatarOpacityPreset) -> Bool {
        abs(opacityFactor - preset.rawValue) < 0.005
    }

    public func stepUp() {
        setOpacity(opacityFactor + Self.stepDelta)
    }

    public func stepDown() {
        setOpacity(opacityFactor - Self.stepDelta)
    }

    public func resetToDefault() {
        setOpacity(Self.defaultOpacityFactor)
    }
}

/// Curated manual size presets for the Bitz desktop companion avatar relative to the `250×250` pt base canvas.
public enum AvatarSizePreset: Double, CaseIterable, Sendable {
    case small = 0.60
    case medium = 0.80
    case defaultSize = 1.00
    case large = 1.25
    case extraLarge = 1.50

    /// Percentage string representation (e.g., `"60%"`, `"100%"`, `"125%"`).
    public var percentageText: String {
        "\(Int((rawValue * 100.0).rounded()))%"
    }

    /// Rounded square point side length for this preset (e.g., `150`, `200`, `250`, `313`, `375`).
    public var pointDimension: Int {
        Int((MascotOverlayPanel.defaultPanelSize.width * rawValue).rounded())
    }

    /// Human-readable Menu Bar label displaying preset name, percentage, and point dimensions.
    public var menuTitle: String {
        let side = pointDimension
        switch self {
        case .small:
            return "Small — 60% (\(side)×\(side) pt)"
        case .medium:
            return "Medium — 80% (\(side)×\(side) pt)"
        case .defaultSize:
            return "Default — 100% (\(side)×\(side) pt)"
        case .large:
            return "Large — 125% (\(side)×\(side) pt)"
        case .extraLarge:
            return "XL — 150% (\(side)×\(side) pt)"
        }
    }
}

/// `@MainActor` observable store managing the user's manual avatar scale factor (`0.50...1.75`),
/// preset selection, `±10%` step adjustments, and `UserDefaults` persistence (`"avatarScaleFactor"`).
@MainActor
public final class AvatarScaleStore: ObservableObject {
    public static let defaultScaleFactor: Double = 1.00
    public static let minScaleFactor: Double = 0.50
    public static let maxScaleFactor: Double = 1.75
    public static let stepDelta: Double = 0.10
    public static let userDefaultsKey: String = "avatarScaleFactor"

    @Published public private(set) var scaleFactor: Double

    private let userDefaults: UserDefaults
    public var onScaleChanged: ((CGFloat) -> Void)?

    public init(userDefaults: UserDefaults = .standard) {
        self.userDefaults = userDefaults
        let rawStored = userDefaults.double(forKey: Self.userDefaultsKey)
        let initialScale = Self.sanitizeScaleFactor(rawStored)
        self.scaleFactor = initialScale
        if userDefaults.object(forKey: Self.userDefaultsKey) == nil {
            userDefaults.set(initialScale, forKey: Self.userDefaultsKey)
        }
    }

    /// Sanitizes an arbitrary scale input: non-finite or `<= 0` values fall back to `1.00`,
    /// and positive values are rounded to 2 decimal places and clamped to `0.50...1.75`.
    public static func sanitizeScaleFactor(_ rawValue: Double) -> Double {
        guard rawValue.isFinite, rawValue > 0.0 else {
            return defaultScaleFactor
        }
        let clamped = min(max(rawValue, minScaleFactor), maxScaleFactor)
        return (clamped * 100.0).rounded() / 100.0
    }

    /// Current scale expressed as an integer percentage (e.g., `100` for `1.00`).
    public var percentageInt: Int {
        Int((scaleFactor * 100.0).rounded())
    }

    /// Current scaled square point side length (e.g., `250` at `1.00`).
    public var pointDimensionInt: Int {
        Int((MascotOverlayPanel.defaultPanelSize.width * scaleFactor).rounded())
    }

    /// Formatted status summary for the Menu Bar header (e.g., `"100% (250×250 pt)"`).
    public var formattedSizeSummary: String {
        let side = pointDimensionInt
        return "\(percentageInt)% (\(side)×\(side) pt)"
    }

    /// Whether the scale can be decreased further before hitting `minScaleFactor` (`50%`).
    public var canStepDown: Bool {
        scaleFactor > Self.minScaleFactor + 0.001
    }

    /// Whether the scale can be increased further before hitting `maxScaleFactor` (`175%`).
    public var canStepUp: Bool {
        scaleFactor < Self.maxScaleFactor - 0.001
    }

    /// Sets and persists the avatar scale factor, clamping to `0.50...1.75` and notifying observers.
    public func setScale(_ newScale: Double) {
        let sanitized = Self.sanitizeScaleFactor(newScale)
        scaleFactor = sanitized
        userDefaults.set(sanitized, forKey: Self.userDefaultsKey)
        onScaleChanged?(CGFloat(sanitized))
    }

    /// Applies one of the curated `AvatarSizePreset` options.
    public func selectPreset(_ preset: AvatarSizePreset) {
        setScale(preset.rawValue)
    }

    /// Checks whether the given preset matches the active `scaleFactor`.
    public func isPresetSelected(_ preset: AvatarSizePreset) -> Bool {
        abs(scaleFactor - preset.rawValue) < 0.005
    }

    /// Increases the avatar scale by `+10%` (`+0.10`), clamped at `175%` (`1.75`).
    public func stepUp() {
        setScale(scaleFactor + Self.stepDelta)
    }

    /// Decreases the avatar scale by `-10%` (`-0.10`), clamped at `50%` (`0.50`).
    public func stepDown() {
        setScale(scaleFactor - Self.stepDelta)
    }

    /// Resets the avatar scale back to `100%` (`1.00`, `250×250` pt).
    public func resetToDefault() {
        setScale(Self.defaultScaleFactor)
    }
}

/// Borderless, transparent, floating, click-through `NSPanel` hosting Bitz in a configured
/// corner of the active screen without stealing focus or intercepting mouse events (`FR-001`, `DIR-001`).
@MainActor
public final class MascotOverlayPanel: NSPanel {
    nonisolated public static let defaultPanelSize = NSSize(width: 250.0, height: 250.0)
    nonisolated public static let rightEdgePadding: CGFloat = 20.0
    nonisolated public static let bottomEdgePadding: CGFloat = 20.0
    public static let cornerAnchorUserDefaultsKey = "avatarCornerAnchor"

    public private(set) var currentScaleFactor: CGFloat = CGFloat(AvatarScaleStore.defaultScaleFactor)
    public private(set) var currentCornerAnchor: ScreenCornerAnchor = .bottomRight
    public private(set) var customOrigin: NSPoint?
    public var assignedScreen: NSScreen?
    public let speechBubblePanel = SpeechBubblePanel()
    /// Distance from the panel's top edge down to Bitz's ear tips (unscaled pt), reported by `MascotOverlayView`.
    /// The default matches a standing Bitz above a 2-line HUD until the first report arrives.
    public var earTopInset: CGFloat = 40 {
        didSet {
            if earTopInset != oldValue {
                layoutSpeechBubble()
            }
        }
    }
    public var debounceInterval: TimeInterval = 0.25
    private var screenReconfigTask: Task<Void, Never>?
    nonisolated(unsafe) private var screenParametersObserverToken: (any NSObjectProtocol)?

    public init(
        contentRect: NSRect = NSRect(
            origin: .zero,
            size: MascotOverlayPanel.defaultPanelSize
        )
    ) {
        super.init(
            contentRect: contentRect,
            styleMask: [.nonactivatingPanel, .borderless],
            backing: .buffered,
            defer: false
        )

        let isFreeform = UserDefaults.standard.bool(forKey: AvatarPositionStore.isFreeformKey)
        let storedX = UserDefaults.standard.object(forKey: AvatarPositionStore.customPositionXKey) as? Double
        let storedY = UserDefaults.standard.object(forKey: AvatarPositionStore.customPositionYKey) as? Double
        if isFreeform, let storedX, let storedY {
            self.customOrigin = NSPoint(x: CGFloat(storedX), y: CGFloat(storedY))
        } else {
            self.customOrigin = nil
        }

        if let rawCorner = UserDefaults.standard.string(forKey: Self.cornerAnchorUserDefaultsKey),
           let anchor = ScreenCornerAnchor(rawValue: rawCorner) {
            self.currentCornerAnchor = anchor
        } else {
            self.currentCornerAnchor = .bottomRight
        }

        self.isFloatingPanel = true
        self.level = .floating
        self.isOpaque = false
        self.backgroundColor = .clear
        self.hasShadow = false
        self.isMovableByWindowBackground = false
        self.ignoresMouseEvents = true
        self.collectionBehavior = [
            .canJoinAllSpaces,
            .fullScreenAuxiliary,
            .stationary
        ]

        // Child windows follow the parent's ordering and visibility (hide mascot hides the bubble too)
        addChildWindow(speechBubblePanel, ordered: .above)
        speechBubblePanel.onSizeChanged = { [weak self] in
            self?.layoutSpeechBubble()
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
    }

    deinit {
        screenReconfigTask?.cancel()
        if let token = screenParametersObserverToken {
            NotificationCenter.default.removeObserver(token)
        }
    }

    /// Debounces display change notifications to avoid layout flashes during display handshakes.
    public func handleScreenParametersChangedDebounced() {
        screenReconfigTask?.cancel()
        screenReconfigTask = Task { @MainActor [weak self] in
            guard let self else { return }
            if self.debounceInterval > 0 {
                let nanoseconds = UInt64(self.debounceInterval * 1_000_000_000)
                try? await Task.sleep(nanoseconds: nanoseconds)
            }
            guard !Task.isCancelled else { return }
            self.repositionOnScreen()
        }
    }

    /// Computes the scaled square panel dimensions (`250 * scaleFactor` × `250 * scaleFactor`),
    /// optionally bounded to fit inside a constrained `visibleFrame` with `20 pt` margins.
    public static func calculatePanelSize(
        for scaleFactor: CGFloat = CGFloat(AvatarScaleStore.defaultScaleFactor),
        visibleFrame: NSRect? = nil
    ) -> NSSize {
        let sanitized = CGFloat(AvatarScaleStore.sanitizeScaleFactor(Double(scaleFactor)))
        var side = defaultPanelSize.width * sanitized
        if let visibleFrame {
            let maxAvailableWidth = max(defaultPanelSize.width * CGFloat(AvatarScaleStore.minScaleFactor), visibleFrame.width - (rightEdgePadding * 2.0))
            let maxAvailableHeight = max(defaultPanelSize.height * CGFloat(AvatarScaleStore.minScaleFactor), visibleFrame.height - (bottomEdgePadding * 2.0))
            side = min(side, min(maxAvailableWidth, maxAvailableHeight))
        }
        return NSSize(width: side, height: side)
    }

    /// Constrains `origin` so the panel stays strictly inside `visibleFrame`,
    /// with magnetic edge snapping within `snapThreshold` of screen edges and standard margins.
    public static func clampOriginToVisibleFrame(
        _ origin: NSPoint,
        panelSize: NSSize,
        visibleFrame: NSRect,
        snapThreshold: CGFloat = 20.0,
        margin: CGFloat = 20.0
    ) -> NSPoint {
        let minX = visibleFrame.minX
        let maxX = max(minX, visibleFrame.maxX - panelSize.width)
        let minY = visibleFrame.minY
        let maxY = max(minY, visibleFrame.maxY - panelSize.height)

        var clampedX = min(max(origin.x, minX), maxX)
        var clampedY = min(max(origin.y, minY), maxY)

        // Magnetic edge snapping for horizontal axis (with margin or directly against edge)
        if abs(clampedX - (minX + margin)) <= snapThreshold {
            clampedX = minX + margin
        } else if abs(clampedX - (maxX - margin)) <= snapThreshold {
            clampedX = maxX - margin
        } else if abs(clampedX - minX) <= snapThreshold {
            clampedX = minX
        } else if abs(clampedX - maxX) <= snapThreshold {
            clampedX = maxX
        }

        // Magnetic edge snapping for vertical axis (with margin or directly against edge)
        if abs(clampedY - (minY + margin)) <= snapThreshold {
            clampedY = minY + margin
        } else if abs(clampedY - (maxY - margin)) <= snapThreshold {
            clampedY = maxY - margin
        } else if abs(clampedY - minY) <= snapThreshold {
            clampedY = minY
        } else if abs(clampedY - maxY) <= snapThreshold {
            clampedY = maxY
        }

        // Guarantee final snapped point never overflows screen visibleFrame
        clampedX = min(max(clampedX, minX), maxX)
        clampedY = min(max(clampedY, minY), maxY)

        return NSPoint(x: clampedX, y: clampedY)
    }

    /// Computes the origin for the requested corner anchor within the given screen `visibleFrame`.
    public static func calculateOrigin(
        for visibleFrame: NSRect,
        panelSize: NSSize = defaultPanelSize,
        corner: ScreenCornerAnchor = .bottomRight
    ) -> NSPoint {
        switch corner {
        case .bottomRight:
            return NSPoint(
                x: visibleFrame.maxX - panelSize.width - rightEdgePadding,
                y: visibleFrame.minY + bottomEdgePadding
            )
        case .bottomLeft:
            return NSPoint(
                x: visibleFrame.minX + rightEdgePadding,
                y: visibleFrame.minY + bottomEdgePadding
            )
        case .topRight:
            return NSPoint(
                x: visibleFrame.maxX - panelSize.width - rightEdgePadding,
                y: visibleFrame.maxY - panelSize.height - bottomEdgePadding
            )
        case .topLeft:
            return NSPoint(
                x: visibleFrame.minX + rightEdgePadding,
                y: visibleFrame.maxY - panelSize.height - bottomEdgePadding
            )
        }
    }

    /// Updates `currentScaleFactor`, resizes the hosted `contentView`, and re-anchors the panel on `screen`
    /// (`nil` keeps the assigned screen; `NSScreen.main` is the focused display and would pull Bitz off a second screen).
    public func applyScaleFactor(_ scaleFactor: CGFloat, on screen: NSScreen? = nil) {
        self.currentScaleFactor = CGFloat(AvatarScaleStore.sanitizeScaleFactor(Double(scaleFactor)))
        repositionOnScreen(of: screen)
    }

    /// Updates `currentCornerAnchor`, clears custom freeform position, persists to `UserDefaults`, and re-anchors the panel on `screen`.
    public func applyCornerAnchor(_ corner: ScreenCornerAnchor, on screen: NSScreen? = nil) {
        self.customOrigin = nil
        self.currentCornerAnchor = corner
        UserDefaults.standard.set(corner.rawValue, forKey: Self.cornerAnchorUserDefaultsKey)
        UserDefaults.standard.set(false, forKey: AvatarPositionStore.isFreeformKey)
        repositionOnScreen(of: screen)
    }

    /// Sets custom freeform origin, updates assigned screen if provided, and repositions the panel.
    public func applyCustomOrigin(_ origin: NSPoint, on screen: NSScreen? = nil) {
        self.customOrigin = origin
        if let screen {
            self.assignedScreen = screen
        }
        repositionOnScreen(of: screen)
    }

    /// Repositions the panel on the specified `screen` (defaulting to assigned screen, current screen, or `NSScreen.main`)
    /// using either `customOrigin` (if freeform placement is active) or `currentCornerAnchor`.
    public func repositionOnScreen(of screen: NSScreen? = nil) {
        if let screen {
            self.assignedScreen = screen
        }
        let activeScreen = screen ?? assignedScreen ?? self.screen ?? NSScreen.main
        let targetFrame = activeScreen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let scaledSize = Self.calculatePanelSize(for: currentScaleFactor, visibleFrame: targetFrame)

        let origin: NSPoint
        if let customOrigin {
            origin = Self.clampOriginToVisibleFrame(customOrigin, panelSize: scaledSize, visibleFrame: targetFrame)
        } else {
            origin = Self.calculateOrigin(for: targetFrame, panelSize: scaledSize, corner: currentCornerAnchor)
        }

        contentView?.frame = NSRect(origin: .zero, size: scaledSize)
        contentView?.needsDisplay = true
        setFrame(NSRect(origin: origin, size: scaledSize), display: true)
        invalidateShadow()
    }

    // Corner/scale/screen changes come through setFrame, drag moves through setFrameOrigin
    public override func setFrame(_ frameRect: NSRect, display flag: Bool) {
        super.setFrame(frameRect, display: flag)
        layoutSpeechBubble()
    }

    public override func setFrameOrigin(_ point: NSPoint) {
        super.setFrameOrigin(point)
        layoutSpeechBubble()
    }

    /// Keeps `speechBubblePanel` just above Bitz's ears after the panel moves, the bubble resizes, or the ears move.
    public func layoutSpeechBubble() {
        let bubbleSize = speechBubblePanel.frame.size
        guard bubbleSize.width > 0, let visibleFrame = (screen ?? assignedScreen ?? NSScreen.main)?.visibleFrame else {
            return
        }
        speechBubblePanel.setFrameOrigin(
            SpeechBubblePanel.calculateOrigin(
                bubbleSize: bubbleSize,
                mascotFrame: frame,
                visibleFrame: visibleFrame,
                earTopInset: earTopInset,
                scaleFactor: currentScaleFactor
            )
        )
    }

    /// Legacy convenience helper backward compatible with previous bottom-right calls.
    public func positionInBottomRight(of screen: NSScreen? = NSScreen.main) {
        applyCornerAnchor(.bottomRight, on: screen)
    }

    public var onRightMouseDown: (() -> Void)?

    public override func rightMouseDown(with event: NSEvent) {
        if let onRightMouseDown {
            onRightMouseDown()
        } else {
            super.rightMouseDown(with: event)
        }
    }

    public override var canBecomeKey: Bool {
        false
    }

    public override var canBecomeMain: Bool {
        false
    }
}
