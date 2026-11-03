import AppKit
import Foundation

/// Seam for running applications to allow headless deterministic testing (NFR-004).
public protocol RunningAppActivating: AnyObject, Sendable {
    var isTerminated: Bool { get }
    func activate(options: NSApplication.ActivationOptions) -> Bool
}

extension NSRunningApplication: RunningAppActivating {}

/// Protocol abstraction for bringing external terminal or IDE applications forward (FR-004, NFR-003).
public protocol AppActivating: Sendable {
    /// Attempts to bring the application owning the given PID or bundle ID to the foreground.
    /// Returns `true` if an application was successfully found and activated.
    @discardableResult
    func activateApp(pid: pid_t?, bundleID: String?) -> Bool
}

/// Production implementation of `AppActivating` using standard macOS `NSRunningApplication`.
/// Never steals keyboard focus from the active workspace or requires Accessibility/TCC prompts (C-002).
public final class WorkspaceAppActivator: AppActivating {
    public typealias PIDResolver = @Sendable (pid_t) -> (any RunningAppActivating)?
    public typealias BundleIDResolver = @Sendable (String) -> [any RunningAppActivating]

    private let pidResolver: PIDResolver
    private let bundleIDResolver: BundleIDResolver

    public init(
        pidResolver: @escaping PIDResolver = { pid in
            NSRunningApplication(processIdentifier: pid)
        },
        bundleIDResolver: @escaping BundleIDResolver = { bundleID in
            NSRunningApplication.runningApplications(withBundleIdentifier: bundleID)
        }
    ) {
        self.pidResolver = pidResolver
        self.bundleIDResolver = bundleIDResolver
    }

    @discardableResult
    public func activateApp(pid: pid_t?, bundleID: String?) -> Bool {
        // 1. Try activating by owning PID first
        if let pid, pid > 0, let app = pidResolver(pid), !app.isTerminated {
            return app.activate(options: [])
        }

        // 2. Try activating by bundle identifier
        if let bundleID, !bundleID.isEmpty {
            let runningApps = bundleIDResolver(bundleID)
            if let target = runningApps.first(where: { !$0.isTerminated }) {
                return target.activate(options: [])
            }
        }

        return false
    }
}
