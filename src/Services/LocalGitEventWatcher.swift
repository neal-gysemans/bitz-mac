import Foundation

/// Represents a local git hook event emitted by `~/.bitz/git-hooks/`.
public struct LocalGitEvent: Codable, Equatable, Sendable {
    public enum Kind: String, Codable, Sendable {
        case push
        case commit
        case merge
    }

    public let kind: Kind
    public let repo: String
    public let branch: String
    public let detail: String
    public let remoteURL: String?

    public init(
        kind: Kind,
        repo: String,
        branch: String,
        detail: String = "",
        remoteURL: String? = nil
    ) {
        self.kind = kind
        self.repo = repo
        self.branch = branch
        self.detail = detail
        self.remoteURL = remoteURL
    }

    /// Converts SSH or HTTPS git remote URLs into a browsable GitHub web URL when possible.
    public var webURL: URL? {
        guard let raw = remoteURL?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty else {
            return nil
        }
        var cleaned = raw
        if cleaned.hasSuffix(".git") {
            cleaned = String(cleaned.dropLast(4))
        }
        if cleaned.hasPrefix("git@github.com:") {
            let path = cleaned.dropFirst("git@github.com:".count)
            return URL(string: "https://github.com/\(path)")
        }
        if cleaned.hasPrefix("https://") || cleaned.hasPrefix("http://") {
            return URL(string: cleaned)
        }
        return nil
    }
}

/// Watches `~/Library/Application Support/Bitz/git-events/` using kernel `kqueue`
/// (`DispatchSourceFileSystemObject`) for instant, zero-polling local git notifications (#209),
/// and safely installs global git hooks when `core.hooksPath` is unset.
@MainActor
public final class LocalGitEventWatcher {
    nonisolated public static var defaultEventsDirectory: URL {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support")
        return appSupport.appendingPathComponent("Bitz/git-events", isDirectory: true)
    }

    nonisolated public static var defaultHooksDirectory: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".bitz/git-hooks", isDirectory: true)
    }

    public let eventsDirectory: URL
    public let hooksDirectory: URL
    public var onEvent: ((LocalGitEvent) -> Void)?

    private var fileDescriptor: Int32 = -1
    private var dispatchSource: DispatchSourceFileSystemObject?
    private let fileManager = FileManager.default

    public init(
        eventsDirectory: URL = LocalGitEventWatcher.defaultEventsDirectory,
        hooksDirectory: URL = defaultHooksDirectory
    ) {
        self.eventsDirectory = eventsDirectory
        self.hooksDirectory = hooksDirectory
    }

    /// Ensures directories exist, installs global git hooks if safe, and starts watching for events.
    public func start(installHooks: Bool = true) {
        try? fileManager.createDirectory(at: eventsDirectory, withIntermediateDirectories: true)

        if installHooks {
            let hooksDir = hooksDirectory
            let eventsDir = eventsDirectory
            Task.detached(priority: .utility) {
                Self.installGlobalHooksIfUnset(hooksDirectory: hooksDir, eventsDirectory: eventsDir)
            }
        }

        drainPendingEvents()
        startDirectoryWatcher()
    }

    public func stop() {
        dispatchSource?.cancel()
        dispatchSource = nil
        fileDescriptor = -1
    }

    /// Reads and deletes all queued `.json` event files in `eventsDirectory`.
    public func drainPendingEvents() {
        guard let files = try? fileManager.contentsOfDirectory(
            at: eventsDirectory,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ) else { return }

        let jsonFiles = files
            .filter { $0.pathExtension == "json" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }

        let decoder = JSONDecoder()
        for fileURL in jsonFiles {
            defer { try? fileManager.removeItem(at: fileURL) }
            guard let data = try? Data(contentsOf: fileURL),
                  let event = try? decoder.decode(LocalGitEvent.self, from: data) else {
                continue
            }
            onEvent?(event)
        }
    }

    private func startDirectoryWatcher() {
        stop()
        let fd = open(eventsDirectory.path, O_EVTONLY)
        guard fd >= 0 else { return }
        fileDescriptor = fd

        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd,
            eventMask: .write,
            queue: DispatchQueue.main
        )
        source.setEventHandler { [weak self] in
            MainActor.assumeIsolated {
                self?.drainPendingEvents()
            }
        }
        source.setCancelHandler { [fd] in
            close(fd)
        }
        dispatchSource = source
        source.resume()
    }

    // MARK: - Global Git Hooks Installation

    nonisolated public static func installGlobalHooksIfUnset(
        hooksDirectory: URL = defaultHooksDirectory,
        eventsDirectory: URL = defaultEventsDirectory
    ) {
        let fm = FileManager.default
        let currentHooksPath = runGit(["config", "--global", "--get", "core.hooksPath"])?
            .trimmingCharacters(in: .whitespacesAndNewlines)

        // Never overwrite a custom user hooksPath
        if let currentHooksPath, !currentHooksPath.isEmpty, currentHooksPath != hooksDirectory.path {
            return
        }

        try? fm.createDirectory(at: hooksDirectory, withIntermediateDirectories: true)
        try? fm.createDirectory(at: eventsDirectory, withIntermediateDirectories: true)

        let hooks: [(name: String, script: String)] = [
            ("pre-push", hookScript(kind: "push", eventsDir: eventsDirectory.path, hookName: "pre-push")),
            ("post-commit", hookScript(kind: "commit", eventsDir: eventsDirectory.path, hookName: "post-commit")),
            ("post-merge", hookScript(kind: "merge", eventsDir: eventsDirectory.path, hookName: "post-merge"))
        ]

        for (name, script) in hooks {
            let url = hooksDirectory.appendingPathComponent(name)
            try? script.write(to: url, atomically: true, encoding: .utf8)
            try? fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        }

        if currentHooksPath != hooksDirectory.path {
            _ = runGit(["config", "--global", "core.hooksPath", hooksDirectory.path])
        }
    }

    nonisolated private static func hookScript(kind: String, eventsDir: String, hookName: String) -> String {
        let detailSnippet: String
        switch kind {
        case "push":
            detailSnippet = #"DETAIL="${1:-origin}""#
        case "commit":
            detailSnippet = #"DETAIL=$(git log -1 --pretty=%s 2>/dev/null | tr -d '"\\\n\r' | cut -c1-60)"#
        default:
            detailSnippet = #"DETAIL="merge""#
        }

        return """
        #!/bin/sh
        # Managed by Bitz (instant git activity notifications)
        GIT_DIR_LOCAL=$(git rev-parse --git-dir 2>/dev/null)
        if [ -n "$GIT_DIR_LOCAL" ] && [ -x "$GIT_DIR_LOCAL/hooks/\(hookName)" ]; then
            "$GIT_DIR_LOCAL/hooks/\(hookName)" "$@" || exit $?
        fi

        TOP=$(git rev-parse --show-toplevel 2>/dev/null)
        REPO=$(basename "${TOP:-$PWD}" | tr -d '"\\\\\\n\\r')
        BRANCH=$(git rev-parse --abbrev-ref HEAD 2>/dev/null | tr -d '"\\\\\\n\\r')
        REMOTE_URL=$(git config --get remote.origin.url 2>/dev/null | tr -d '"\\\\\\n\\r')
        \(detailSnippet)
        mkdir -p "\(eventsDir)"
        printf '{"kind":"\(kind)","repo":"%s","branch":"%s","detail":"%s","remoteURL":"%s"}\\n' "$REPO" "${BRANCH:-HEAD}" "$DETAIL" "$REMOTE_URL" > "\(eventsDir)/$(date +%s)-$$.json"
        """
    }

    nonisolated private static func runGit(_ args: [String]) -> String? {
        let candidates = ["/usr/bin/git", "/opt/homebrew/bin/git", "/usr/local/bin/git"]
        guard let gitPath = candidates.first(where: { FileManager.default.isExecutableFile(atPath: $0) }) else {
            return nil
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: gitPath)
        process.arguments = args
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()
        do {
            try process.run()
            process.waitUntilExit()
            guard process.terminationStatus == 0 else { return nil }
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            return String(data: data, encoding: .utf8)
        } catch {
            return nil
        }
    }
}
