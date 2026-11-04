import AppKit
import SwiftUI

/// Manages a single-instance standard macOS Settings window for configuring
/// mascot appearance, wellness behaviors, telemetry, and AI coding agents.
///
/// Guaranteed Invariants:
/// - Single-instance lifecycle: bringing up settings when already open focuses the existing window.
/// - Mascot overlay panel invariant: `SettingsWindowManager` operates as a standard titled window and
///   never interferes with `MascotOverlayPanel.ignoresMouseEvents` or its non-activating behavior.
@MainActor
public final class SettingsWindowManager: NSObject, ObservableObject, NSWindowDelegate {
    public static let shared = SettingsWindowManager()
    /// Content (not frame) minimum, shared with `SettingsRootView`; `sizingOptions = []` means AppKit can't read it from SwiftUI.
    public static let minimumContentSize = NSSize(width: 660, height: 560)

    private var windowController: NSWindowController?
    @Published public private(set) var isWindowOpen: Bool = false
    /// True only while the Settings window is open, not miniaturized, and has at least one visible pixel on screen.
    @Published public private(set) var isWindowVisible: Bool = false
    public var onWindowClosed: (() -> Void)?

    public override init() {
        super.init()
    }

    /// Returns the underlying NSWindow if instantiated.
    public var window: NSWindow? {
        windowController?.window
    }

    /// Presents the Settings window hosting the provided SwiftUI content view.
    /// If the window is already created, it is activated and brought to the front.
    public func showSettingsWindow<Content: View>(rootView: Content) {
        if let windowController = windowController, let existingWindow = windowController.window {
            if !isWindowOpen || existingWindow.contentViewController == nil {
                let contentSize = existingWindow.contentRect(forFrameRect: existingWindow.frame).size
                let targetSize = NSSize(
                    width: max(contentSize.width, Self.minimumContentSize.width),
                    height: max(contentSize.height, Self.minimumContentSize.height)
                )
                existingWindow.contentViewController = makeHostingController(rootView: rootView, size: targetSize)
                existingWindow.setContentSize(targetSize)
                existingWindow.contentMinSize = Self.minimumContentSize
            }
            existingWindow.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            isWindowOpen = true
            refreshVisibility(for: existingWindow)
            return
        }

        let initialSize = NSSize(width: 680, height: 580)
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
        window.center()
        window.title = "Bitz Settings"
        window.isReleasedWhenClosed = false
        window.delegate = self

        let controller = NSWindowController(window: window)
        self.windowController = controller

        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        isWindowOpen = true
        refreshVisibility(for: window)
    }

    /// Closes the Settings window if open and detaches its SwiftUI hosting controller so background timelines stop (#70).
    public func closeSettingsWindow() {
        let wasOpen = isWindowOpen
        windowController?.close()
        tearDownHostedContent(notifyIfWasOpen: wasOpen)
    }

    // MARK: - NSWindowDelegate

    public func windowWillClose(_ notification: Notification) {
        tearDownHostedContent(notifyIfWasOpen: isWindowOpen)
    }

    public func windowDidChangeOcclusionState(_ notification: Notification) {
        refreshVisibility(for: window)
    }

    public func windowDidMiniaturize(_ notification: Notification) {
        refreshVisibility(for: window)
    }

    public func windowDidDeminiaturize(_ notification: Notification) {
        refreshVisibility(for: window)
    }

    // MARK: - Helpers

    private func makeHostingController<Content: View>(rootView: Content, size: NSSize) -> NSHostingController<Content> {
        let hostingController = NSHostingController(rootView: rootView)
        // Window bounds are managed by AppKit; disabling intrinsic/min/max sizing prevents 30 fps ScrollView layout thrash (#70)
        hostingController.sizingOptions = []
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
