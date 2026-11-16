import AppKit
import SwiftUI

/// Manages a single-instance standard macOS window for the 3D Cyber-Ship Agent Command Deck.
///
/// Guaranteed Invariants (AGENTS.md §2.3, §2.4):
/// - Single-instance lifecycle: bringing up the Command Deck when already open focuses the existing window.
/// - Zero idle resource footprint when closed: detaches `window.contentViewController = nil` on close
///   (`tearDownHostedContent`) so 3D SceneKit viewport, render loops, and SwiftUI graphs consume 0.0% CPU and 0 MB RAM.
/// - Disabled intrinsic content size sizing: hosting controller sets `sizingOptions = []` to prevent AppKit
///   from running per-frame intrinsic content size measurement passes.
/// - Occlusion & miniaturization awareness: tracks `isWindowVisible` via `NSWindowDelegate` (`windowDidChangeOcclusionState`,
///   `windowDidMiniaturize`, `windowDidDeminiaturize`) so SCNView automatically pauses rendering when occluded.
@MainActor
public final class AgentCommandDeckWindowManager: NSObject, ObservableObject, NSWindowDelegate {
    public static let shared = AgentCommandDeckWindowManager()

    /// Content (not frame) minimum, shared with AgentCommandDeckView; `sizingOptions = []` means AppKit can't read it from SwiftUI.
    public static let minimumContentSize = NSSize(width: 900, height: 600)
    public static let defaultInitialSize = NSSize(width: 1080, height: 720)

    private var windowController: NSWindowController?
    @Published public private(set) var isWindowOpen: Bool = false
    /// True only while the Command Deck window is open, not miniaturized, and has at least one visible pixel on screen.
    @Published public private(set) var isWindowVisible: Bool = false
    public var onWindowClosed: (() -> Void)?

    public override init() {
        super.init()
    }

    /// Returns the underlying NSWindow if instantiated.
    public var window: NSWindow? {
        windowController?.window
    }

    /// Presents the Command Deck window hosting the provided SwiftUI content view.
    /// If the window is already created, it is activated and brought to the front.
    public func showCommandDeckWindow<Content: View>(rootView: Content) {
        if let windowController = windowController, let existingWindow = windowController.window {
            if !isWindowOpen || existingWindow.contentViewController == nil {
                let contentSize = existingWindow.contentRect(forFrameRect: existingWindow.frame).size
                let targetSize = NSSize(
                    width: max(contentSize.width, Self.minimumContentSize.width),
                    height: max(contentSize.height, Self.minimumContentSize.height)
                )
                existingWindow.contentViewController = makeHostingController(rootView: rootView, size: targetSize)
                existingWindow.setContentSize(targetSize)
                // After contentViewController: assigning it resets contentMinSize on macOS 14
                existingWindow.contentMinSize = Self.minimumContentSize
                existingWindow.minSize = existingWindow.frameRect(forContentRect: NSRect(origin: .zero, size: Self.minimumContentSize)).size
            }
            existingWindow.makeKeyAndOrderFront(nil)
            isWindowOpen = true
            AppActivationPolicyCoordinator.refreshActivationPolicy()
            NSApp.activate(ignoringOtherApps: true)
            refreshVisibility(for: existingWindow)
            return
        }

        let initialSize = Self.defaultInitialSize
        let hostingController = makeHostingController(rootView: rootView, size: initialSize)
        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: initialSize),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.contentViewController = hostingController
        window.setContentSize(initialSize)
        // After contentViewController: assigning it resets contentMinSize on macOS 14
        window.contentMinSize = Self.minimumContentSize
        window.minSize = window.frameRect(forContentRect: NSRect(origin: .zero, size: Self.minimumContentSize)).size
        window.center()
        window.title = "Bitz — Agent Command Deck"
        window.isReleasedWhenClosed = false
        window.delegate = self

        let controller = NSWindowController(window: window)
        self.windowController = controller

        window.makeKeyAndOrderFront(nil)
        isWindowOpen = true
        AppActivationPolicyCoordinator.refreshActivationPolicy()
        NSApp.activate(ignoringOtherApps: true)
        refreshVisibility(for: window)
    }

    /// Closes the Command Deck window if open and detaches its SwiftUI hosting controller
    /// so SceneKit render loops and background timelines stop immediately.
    public func closeCommandDeckWindow() {
        let wasOpen = isWindowOpen
        windowController?.close()
        tearDownHostedContent(notifyIfWasOpen: wasOpen)
    }

    // MARK: - NSWindowDelegate

    public func windowWillResize(_ sender: NSWindow, to frameSize: NSSize) -> NSSize {
        let minFrame = sender.frameRect(forContentRect: NSRect(origin: .zero, size: Self.minimumContentSize)).size
        return NSSize(
            width: max(frameSize.width, minFrame.width),
            height: max(frameSize.height, minFrame.height)
        )
    }

    public func windowWillClose(_ notification: Notification) {
        tearDownHostedContent(notifyIfWasOpen: isWindowOpen)
    }

    public func windowDidChangeOcclusionState(_ notification: Notification) {
        refreshVisibility(for: (notification.object as? NSWindow) ?? window)
    }

    public func windowDidMiniaturize(_ notification: Notification) {
        refreshVisibility(for: (notification.object as? NSWindow) ?? window)
    }

    public func windowDidDeminiaturize(_ notification: Notification) {
        refreshVisibility(for: (notification.object as? NSWindow) ?? window)
    }

    // MARK: - Helpers

    private func makeHostingController<Content: View>(rootView: Content, size: NSSize) -> NSHostingController<Content> {
        let hostingController = NSHostingController(rootView: rootView)
        // Window bounds are managed by AppKit; disabling intrinsic/min/max sizing prevents 30 fps ScrollView layout thrash (#70)
        hostingController.sizingOptions = []
        hostingController.view.autoresizingMask = [.width, .height]
        hostingController.view.frame = NSRect(origin: .zero, size: size)
        return hostingController
    }

    private func tearDownHostedContent(notifyIfWasOpen: Bool) {
        windowController?.window?.contentViewController = nil
        if isWindowVisible {
            isWindowVisible = false
        }
        let shouldNotify = notifyIfWasOpen && isWindowOpen
        isWindowOpen = false
        AppActivationPolicyCoordinator.refreshActivationPolicy()
        if shouldNotify {
            onWindowClosed?()
        }
    }

    private func refreshVisibility(for window: NSWindow?) {
        let visible: Bool
        if isWindowOpen, let window {
            visible = !window.isMiniaturized && window.occlusionState.contains(.visible)
        } else {
            visible = false
        }
        if isWindowVisible != visible {
            isWindowVisible = visible
        }
    }
}
