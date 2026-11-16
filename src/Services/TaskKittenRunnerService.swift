import Foundation

/// Supported authenticated CLI tools used for zero-token Phase 2 Task-Kittens (#189, #190).
public enum TaskKittenCLIProvider: String, CaseIterable, Sendable, Identifiable {
    case claude
    case gemini
    case codex

    public var id: String { rawValue }

    public var agentID: String { rawValue }

    public var agentName: String {
        switch self {
        case .claude: return "Claude"
        case .gemini: return "Gemini"
        case .codex:  return "Codex"
        }
    }

    public var displayName: String {
        switch self {
        case .claude: return "Claude CLI"
        case .gemini: return "Gemini CLI"
        case .codex:  return "Codex CLI"
        }
    }

    public var executableName: String { rawValue }

    public func arguments(for prompt: String) -> [String] {
        switch self {
        case .claude: return ["-p", prompt]
        case .gemini: return ["-p", prompt]
        case .codex:  return ["exec", prompt]
        }
    }
}

/// Built-in quick-launch presets for Phase 2 CLI Task-Kittens.
public enum TaskKittenPreset: String, CaseIterable, Sendable, Identifiable {
    case prReview
    case gitBrief
    case testAudit

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .prReview:  return "PR Review"
        case .gitBrief:  return "Git Brief"
        case .testAudit: return "Test Audit"
        }
    }

    public var prompt: String {
        switch self {
        case .prReview:
            return "Review the current git branch diff for bugs, regressions, and dead code in 3 concise bullet points."
        case .gitBrief:
            return "Summarize the current git status, branch, and recent commits in 3 concise bullet points."
        case .testAudit:
            return "Check recent changes and suggest the most important missing edge-case test in 2 concise sentences."
        }
    }
}

/// Executes Phase 2 background Task-Kittens using existing authenticated CLI subscriptions
/// (`claude -p`, `gemini -p`, `codex exec`) and publishes live crewmate lifecycle events
/// to `AgentMonitorService` so they appear in the 3D Cyber-Ship Command Deck.
@MainActor
public final class TaskKittenRunnerService: ObservableObject {
    public typealias CommandRunner = @Sendable (_ executable: String, _ arguments: [String], _ workingDirectory: String?) async -> (exitCode: Int32, output: String)

    @Published public private(set) var activeSessionIDs: Set<String> = []

    public weak var agentMonitor: AgentMonitorService?
    private let commandRunner: CommandRunner
    private var runningTasks: [String: Task<Void, Never>] = [:]

    public init(
        agentMonitor: AgentMonitorService? = nil,
        commandRunner: @escaping CommandRunner = TaskKittenRunnerService.runCLISubprocess
    ) {
        self.agentMonitor = agentMonitor
        self.commandRunner = commandRunner
    }

    /// Launches a background CLI Task-Kitten and emits `.working` immediately followed by `.done` / `.failed`.
    @discardableResult
    public func launchTask(
        title: String,
        prompt: String,
        provider: TaskKittenCLIProvider,
        workingDirectory: String? = nil
    ) -> String {
        let trimmedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let cleanTitle = trimmedTitle.isEmpty ? "Task" : trimmedTitle
        let trimmedPrompt = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        let cleanPrompt = trimmedPrompt.isEmpty ? cleanTitle : trimmedPrompt

        let sessionID = "kitten-\(UUID().uuidString.prefix(6).lowercased())"
        let label = "\(provider.agentName) · 🐾 \(cleanTitle)"

        let trimmedDir = workingDirectory?.trimmingCharacters(in: .whitespacesAndNewlines)
        let resolvedWorkingDir = (trimmedDir?.isEmpty == false) ? trimmedDir : nil

        var metadata: [String: String] = [
            AgentEvent.MetadataKey.sessionID: sessionID,
            AgentEvent.MetadataKey.sessionLabel: label
        ]
        if let resolvedWorkingDir {
            metadata[AgentEvent.MetadataKey.workingDir] = resolvedWorkingDir
        }

        activeSessionIDs.insert(sessionID)
        agentMonitor?.handleEvent(AgentEvent(
            agentID: provider.agentID,
            agentName: provider.agentName,
            kind: .working,
            message: "🐾 \(cleanTitle): \(cleanPrompt)",
            metadata: metadata
        ))

        let runner = commandRunner
        let args = provider.arguments(for: cleanPrompt)
        let executable = provider.executableName

        let task = Task { @MainActor [weak self] in
            let result = await runner(executable, args, resolvedWorkingDir)
            guard let self else { return }
            self.activeSessionIDs.remove(sessionID)
            self.runningTasks.removeValue(forKey: sessionID)

            let summary = Self.summarizeOutput(result.output)
            let kind: AgentEventKind = (result.exitCode == 0) ? .done : .failed
            let statusText = (result.exitCode == 0)
                ? "🐾 \(cleanTitle): \(summary)"
                : "🐾 \(cleanTitle) (exit \(result.exitCode)): \(summary)"

            self.agentMonitor?.handleEvent(AgentEvent(
                agentID: provider.agentID,
                agentName: provider.agentName,
                kind: kind,
                message: statusText,
                metadata: metadata
            ))
        }
        runningTasks[sessionID] = task

        return sessionID
    }

    /// Compacts multi-line CLI output into a single readable HUD summary line.
    public static func summarizeOutput(_ rawOutput: String, maxLength: Int = 180) -> String {
        let collapsed = rawOutput
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        guard !collapsed.isEmpty else { return "Completed with no output" }
        guard collapsed.count > maxLength else { return collapsed }
        return String(collapsed.prefix(maxLength - 1)) + "…"
    }

    /// Resolves a CLI tool across standard macOS paths and executes it asynchronously with a 120s timeout.
    public static func runCLISubprocess(
        executable: String,
        arguments: [String],
        workingDirectory: String?
    ) async -> (exitCode: Int32, output: String) {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let home = NSHomeDirectory()
                let searchDirs = [
                    "/opt/homebrew/bin",
                    "/usr/local/bin",
                    "\(home)/.local/bin",
                    "\(home)/.npm-global/bin",
                    "/usr/bin"
                ]

                let fm = FileManager.default
                let resolvedPath = searchDirs
                    .map { "\($0)/\(executable)" }
                    .first { fm.isExecutableFile(atPath: $0) }

                let process = Process()
                if let resolvedPath {
                    process.executableURL = URL(fileURLWithPath: resolvedPath)
                    process.arguments = arguments
                } else {
                    process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
                    process.arguments = [executable] + arguments
                }

                var env = ProcessInfo.processInfo.environment
                let existingPath = env["PATH"] ?? "/usr/bin:/bin:/usr/sbin:/sbin"
                env["PATH"] = (searchDirs + [existingPath]).joined(separator: ":")
                process.environment = env

                if let workingDirectory, fm.fileExists(atPath: workingDirectory) {
                    process.currentDirectoryURL = URL(fileURLWithPath: workingDirectory)
                }

                let stdoutPipe = Pipe()
                let stderrPipe = Pipe()
                process.standardInput = FileHandle.nullDevice
                process.standardOutput = stdoutPipe
                process.standardError = stderrPipe

                do {
                    try process.run()
                } catch {
                    continuation.resume(returning: (127, error.localizedDescription))
                    return
                }

                let timeoutItem = DispatchWorkItem { [weak process] in
                    if let process, process.isRunning {
                        process.terminate()
                    }
                }
                DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 120.0, execute: timeoutItem)

                let stderrBox = LockedDataBox()
                let readGroup = DispatchGroup()

                readGroup.enter()
                DispatchQueue.global(qos: .userInitiated).async {
                    stderrBox.set(stderrPipe.fileHandleForReading.readDataToEndOfFile())
                    readGroup.leave()
                }
                let stdoutData = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
                readGroup.wait()
                process.waitUntilExit()
                timeoutItem.cancel()

                let stderrData = stderrBox.get()
                let outText = String(data: stdoutData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                let errText = String(data: stderrData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                let combined = !outText.isEmpty ? outText : errText
                continuation.resume(returning: (process.terminationStatus, combined))
            }
        }
    }
}

private final class LockedDataBox: @unchecked Sendable {
    private let lock = NSLock()
    private var data = Data()

    func set(_ newData: Data) {
        lock.lock()
        data = newData
        lock.unlock()
    }

    func get() -> Data {
        lock.lock()
        defer { lock.unlock() }
        return data
    }
}
