import Foundation

/// Safe, reversible installer for configuring agent hooks into the drop-box directory.
public struct AgentHookInstaller {

    public enum HookType: String, CaseIterable, Sendable {
        case claudeCode
        case codex
    }

    public static func dropEventScript(agentID: String, agentName: String, kind: String, message: String) -> String {
        let dir = DropboxAgentAdapter.defaultDirectoryURL.path
        let cleanID = agentID.replacingOccurrences(of: "'", with: "")
        let cleanName = agentName.replacingOccurrences(of: "'", with: "")
        let cleanKind = kind.replacingOccurrences(of: "'", with: "")
        let cleanMessage = message.replacingOccurrences(of: "'", with: "")
        return """
        mkdir -p '\(dir)' && id=$(uuidgen | tr '[:upper:]' '[:lower:]') && ts=$(date -u +%Y-%m-%dT%H:%M:%SZ) && printf '{"id":"%s","agentID":"%s","agentName":"%s","kind":"%s","message":"%s","timestamp":"%s"}\\n' "$id" '\(cleanID)' '\(cleanName)' '\(cleanKind)' '\(cleanMessage)' "$ts" > '\(dir)/'$id.json
        """
    }

    public static func failureCommand(agentID: String = "claude", agentName: String = "Claude", message: String = "Claude encountered a failure!") -> String {
        dropEventScript(agentID: agentID, agentName: agentName, kind: AgentEventKind.failed.rawValue, message: message)
    }

    /// Generates Claude Code notification/stop hooks snippet for ~/.claude/settings.json
    public static func claudeSettingsSnippet() -> [String: Any] {
        let dir = DropboxAgentAdapter.defaultDirectoryURL.path
        let doneCommand = "mkdir -p '\(dir)' && id=$(uuidgen | tr '[:upper:]' '[:lower:]') && ts=$(date -u +%Y-%m-%dT%H:%M:%SZ) && printf '{\"id\":\"%s\",\"agentID\":\"%s\",\"agentName\":\"%s\",\"kind\":\"%s\",\"message\":\"%s\",\"timestamp\":\"%s\"}\\n' \"$id\" \"claude\" \"Claude\" \"done\" \"Claude is done!\" \"$ts\" > '\(dir)/'$id.json"

        let approvalCommand = "mkdir -p '\(dir)' && id=$(uuidgen | tr '[:upper:]' '[:lower:]') && ts=$(date -u +%Y-%m-%dT%H:%M:%SZ) && printf '{\"id\":\"%s\",\"agentID\":\"%s\",\"agentName\":\"%s\",\"kind\":\"%s\",\"message\":\"%s\",\"timestamp\":\"%s\"}\\n' \"$id\" \"claude\" \"Claude\" \"needsApproval\" \"Claude needs approval!\" \"$ts\" > '\(dir)/'$id.json"

        let stopHook: [String: Any] = [
            "matcher": "",
            "hooks": [
                ["type": "command", "command": doneCommand]
            ]
        ]

        let approvalHook: [String: Any] = [
            "matcher": "",
            "hooks": [
                ["type": "command", "command": approvalCommand]
            ]
        ]

        return [
            "hooks": [
                "Stop": [stopHook],
                "PermissionRequest": [approvalHook],
                "Notification": [approvalHook]
            ]
        ]
    }

    public struct SettingsFormatError: LocalizedError {
        public let errorDescription: String?
    }

    /// Appends Bitz's entry to each Claude hook event, keeping the user's entries. Events already holding a Bitz command are left alone.
    public static func installClaudeHooks(in settings: [String: Any]) throws -> [String: Any] {
        var settings = settings
        var hooks = try hooksDictionary(in: settings) ?? [:]
        for (event, bitzEntries) in bitzHooks {
            let entries = try hookEntries(hooks[event], event: event)
            if !entries.contains(where: groupHasBitzCommand) {
                hooks[event] = entries + (bitzEntries as? [Any] ?? [])
            }
        }
        settings["hooks"] = hooks
        return settings
    }

    /// Removes only Bitz's own hook commands from Bitz's events, dropping a group or event only when that leaves it empty.
    public static func uninstallClaudeHooks(from settings: [String: Any]) throws -> [String: Any] {
        guard var hooks = try hooksDictionary(in: settings) else { return settings }
        for event in bitzHooks.keys {
            let entries = try hookEntries(hooks[event], event: event)
            guard entries.contains(where: groupHasBitzCommand) else { continue }
            let kept: [Any] = entries.compactMap { entry in
                guard var group = entry as? [String: Any],
                      let commands = group["hooks"] as? [Any],
                      commands.contains(where: isBitzCommand) else { return entry }
                let rest = commands.filter { !isBitzCommand($0) }
                if rest.isEmpty { return nil }
                group["hooks"] = rest
                return group
            }
            hooks[event] = kept.isEmpty ? nil : kept
        }
        var settings = settings
        settings["hooks"] = hooks
        return settings
    }

    /// Applies `transform` to the JSON settings file at `url` (a missing file counts as empty).
    /// Throws without writing if the file isn't a JSON object, is read-only or a dangling symlink, the transform fails, or the backup fails;
    /// skips the write when nothing changes.
    public static func updateSettingsFile(at url: URL, _ transform: ([String: Any]) throws -> [String: Any]) throws {
        let fileExists = FileManager.default.fileExists(atPath: url.path)
        var settings: [String: Any] = [:]
        if fileExists {
            let data = try Data(contentsOf: url)
            guard let parsed = try? JSONSerialization.jsonObject(with: data) else {
                throw SettingsFormatError(errorDescription: "\(url.lastPathComponent) isn't valid JSON, so nothing was changed. Fix or remove it and try again.")
            }
            guard let object = parsed as? [String: Any] else {
                throw SettingsFormatError(errorDescription: "\(url.lastPathComponent) isn't a JSON object, so nothing was changed. Fix or remove it and try again.")
            }
            if let duplicateKey = findFirstDuplicateKey(in: data) {
                throw SettingsFormatError(errorDescription: "\(url.lastPathComponent) contains duplicate key \"\(duplicateKey)\", so nothing was changed. Fix or remove it and try again.")
            }
            settings = object
        }
        let updated = try transform(settings)
        guard !NSDictionary(dictionary: updated).isEqual(to: settings) else { return }
        // The atomic write would replace a dangling link with a file and ignore the file's own write protection.
        if fileExists, !FileManager.default.isWritableFile(atPath: url.path) {
            throw SettingsFormatError(errorDescription: "\(url.lastPathComponent) is read-only, so nothing was changed. Make it writable and try again.")
        }
        if !fileExists, (try? FileManager.default.destinationOfSymbolicLink(atPath: url.path)) != nil {
            throw SettingsFormatError(errorDescription: "\(url.lastPathComponent) is a symlink to a missing file, so nothing was changed. Fix the link and try again.")
        }
        _ = try backupFile(at: url)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let data = try JSONSerialization.data(withJSONObject: updated, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        // Atomic so a failed write can't truncate the file; to the resolved target so a symlink stays a symlink.
        try data.write(to: url.resolvingSymlinksInPath(), options: .atomic)
    }

    private static func hooksDictionary(in settings: [String: Any]) throws -> [String: Any]? {
        guard let value = settings["hooks"] else { return nil }
        guard let hooks = value as? [String: Any] else {
            throw SettingsFormatError(errorDescription: "\"hooks\" in settings.json isn't a JSON object, so nothing was changed. Fix it and try again.")
        }
        return hooks
    }

    private static func hookEntries(_ value: Any?, event: String) throws -> [Any] {
        guard let value else { return [] }
        guard let entries = value as? [Any] else {
            throw SettingsFormatError(errorDescription: "\"hooks.\(event)\" in settings.json isn't a JSON array, so nothing was changed. Fix it and try again.")
        }
        return entries
    }

    private static var bitzHooks: [String: Any] {
        claudeSettingsSnippet()["hooks"] as? [String: Any] ?? [:]
    }

    // Match the snippet's exact commands, not the drop-box path: users may write their own drop-box hooks.
    private static let bitzCommands: Set<String> = Set(bitzHooks.values.flatMap { groups in
        (groups as? [Any] ?? []).flatMap { (($0 as? [String: Any])?["hooks"] as? [Any]) ?? [] }.compactMap(command)
    })

    private static func command(_ hook: Any) -> String? {
        (hook as? [String: Any])?["command"] as? String
    }

    private static func isBitzCommand(_ hook: Any) -> Bool {
        command(hook).map { bitzCommands.contains($0) } ?? false
    }

    private static func groupHasBitzCommand(_ entry: Any) -> Bool {
        ((entry as? [String: Any])?["hooks"] as? [Any])?.contains(where: isBitzCommand) ?? false
    }

    /// Scans raw JSON data for duplicate keys within any JSON object scope.
    /// Returns the first duplicate key found, or nil if all object keys are unique.
    public static func findFirstDuplicateKey(in data: Data) -> String? {
        enum Container {
            case object(keys: Set<String>, expectingKey: Bool)
            case array
        }

        let bytes = Array(data)
        var stack: [Container] = []
        var i = 0

        while i < bytes.count {
            let b = bytes[i]
            switch b {
            case 0x7B: // "{"
                stack.append(.object(keys: [], expectingKey: true))
                i += 1
            case 0x7D: // "}"
                if !stack.isEmpty { stack.removeLast() }
                i += 1
            case 0x5B: // "["
                stack.append(.array)
                i += 1
            case 0x5D: // "]"
                if !stack.isEmpty { stack.removeLast() }
                i += 1
            case 0x2C: // ","
                if case .object(let keys, _) = stack.last {
                    stack[stack.count - 1] = .object(keys: keys, expectingKey: true)
                }
                i += 1
            case 0x22: // "\""
                var j = i + 1
                while j < bytes.count {
                    if bytes[j] == 0x5C { // "\"
                        j += 2
                    } else if bytes[j] == 0x22 {
                        break
                    } else {
                        j += 1
                    }
                }
                guard j < bytes.count else { return nil }

                let stringData = data.subdata(in: (data.startIndex + i)..<(data.startIndex + j + 1))
                let str = (try? JSONSerialization.jsonObject(with: stringData, options: .fragmentsAllowed) as? String)
                    ?? String(decoding: bytes[(i + 1)..<j], as: UTF8.self)

                if case .object(var keys, let expectingKey) = stack.last {
                    if expectingKey {
                        if keys.contains(str) {
                            return str
                        }
                        keys.insert(str)
                        stack[stack.count - 1] = .object(keys: keys, expectingKey: false)
                    }
                }
                i = j + 1
            default:
                i += 1
            }
        }
        return nil
    }

    /// Backs up a target file before modification.
    public static func backupFile(at url: URL) throws -> URL {
        // Microseconds: two back-to-back updates can land in the same millisecond, and a name clash aborts the update.
        let backupURL = url.appendingPathExtension("bitz-backup.\(Int(Date().timeIntervalSince1970 * 1_000_000))")
        if FileManager.default.fileExists(atPath: url.path) {
            // Copy the target, not the link, so a symlinked file gets a real backup.
            try FileManager.default.copyItem(at: url.resolvingSymlinksInPath(), to: backupURL)
        }
        return backupURL
    }
}
