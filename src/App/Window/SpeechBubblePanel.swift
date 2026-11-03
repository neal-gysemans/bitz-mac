import AppKit

/// Borderless, transparent, click-through child panel of `MascotOverlayPanel` that carries Bitz's
/// speech bubble. It sizes itself to `SpeechBubbleView`, so bubbles are never clipped by the
/// fixed-size mascot canvas (#61). It never becomes key, so it cannot steal focus.
@MainActor
public final class SpeechBubblePanel: NSPanel {
    /// Space between Bitz's ear tips and the visible bubble (unscaled pt); covers the 4.5 pt breathing rise.
    nonisolated public static let earGap: CGFloat = 10

    /// Called after the bubble resizes itself to new content, so the owner can re-place it.
    public var onSizeChanged: (() -> Void)?

    public init() {
        super.init(
            contentRect: .zero,
            styleMask: [.nonactivatingPanel, .borderless],
            backing: .buffered,
            defer: false
        )
        self.isFloatingPanel = true
        self.level = .floating
        self.isOpaque = false
        self.backgroundColor = .clear
        self.hasShadow = false
        self.ignoresMouseEvents = true
        self.collectionBehavior = [
            .canJoinAllSpaces,
            .fullScreenAuxiliary,
            .stationary
        ]
    }

    /// Centers the bubble just above Bitz's ear tips (`earTopInset` below the mascot panel's top edge,
    /// unscaled), flips it below the panel when there is no room above, and keeps it inside `visibleFrame`.
    public static func calculateOrigin(
        bubbleSize: NSSize,
        mascotFrame: NSRect,
        visibleFrame: NSRect,
        earTopInset: CGFloat,
        scaleFactor: CGFloat = 1.0
    ) -> NSPoint {
        let centeredX = mascotFrame.midX - bubbleSize.width / 2.0
        let x = max(visibleFrame.minX, min(centeredX, visibleFrame.maxX - bubbleSize.width))

        // The window includes the bubble's glow padding, so its bottom sits that far below the visible bubble
        let aboveY = mascotFrame.maxY - (earTopInset - earGap + SpeechBubbleView.glowPadding) * scaleFactor
        let belowY = mascotFrame.minY - bubbleSize.height
        let y: CGFloat
        if aboveY + bubbleSize.height <= visibleFrame.maxY {
            y = aboveY
        } else if belowY >= visibleFrame.minY {
            y = belowY
        } else {
            y = visibleFrame.maxY - bubbleSize.height
        }
        return NSPoint(x: x, y: y)
    }

    // NSHostingView resizes the window to its content through this call
    public override func setFrame(_ frameRect: NSRect, display flag: Bool) {
        let sizeChanged = frameRect.size != frame.size
        super.setFrame(frameRect, display: flag)
        if sizeChanged {
            onSizeChanged?()
        }
    }

    public override var canBecomeKey: Bool {
        false
    }

    public override var canBecomeMain: Bool {
        false
    }

    /// Determines whether the given bubble content requires mouse interactivity (buttons clickable, FR-008).
    nonisolated public static func isInteractiveContent(_ content: SpeechBubbleContent?) -> Bool {
        guard let content else { return false }
        switch content {
        case .update:
            return true
        case .agentPopup(let popup):
            return popup.kind == .warning || popup.kind == .needsApproval
        case .wellness, .carousel:
            return false
        }
    }

    /// Whether this panel is currently configured to accept mouse events.
    public var isInteractive: Bool {
        get { !ignoresMouseEvents }
        set { ignoresMouseEvents = !newValue }
    }

    /// Updates this panel's `ignoresMouseEvents` based on whether the content has interactive buttons (FR-008).
    public func updateInteractivity(for content: SpeechBubbleContent?) {
        self.ignoresMouseEvents = !Self.isInteractiveContent(content)
    }
}

extension SpeechBubbleContent {
    /// Extended interactivity check supporting `.needsApproval` action buttons (FR-008).
    public var isQuickActionInteractive: Bool {
        SpeechBubblePanel.isInteractiveContent(self)
    }
}
