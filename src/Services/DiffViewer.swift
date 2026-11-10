import Foundation
import AppKit

/// Errors that can occur during diff inspection or execution.
public enum DiffViewerError: Error, Equatable, Sendable {
    case invalidDirectory
    case executionFailed(Int32, String)
    case gitNotFound
}

/// Protocol abstraction for retrieving and displaying working git diffs (FR-005).
public protocol DiffViewing: Sendable {
    /// Executes `/usr/bin/git diff` asynchronously for the specified working directory off the main thread.
    func getDiff(workingDirectory: String?) async -> Result<String, DiffViewerError>

    /// Opens the diff or working repository in the user's default viewer or editor.
    @discardableResult
    func openDiff(workingDirectory: String?) async -> Bool
}

/// Production implementation of `DiffViewing` executing `/usr/bin/git diff` off the main thread (FR-005).
public final class SystemDiffViewer: DiffViewing {
    public let gitPath: String

    public init(gitPath: String = "/usr/bin/git") {
        self.gitPath = gitPath
    }

    public func getDiff(workingDirectory: String?) async -> Result<String, DiffViewerError> {
        let dir = workingDirectory ?? FileManager.default.currentDirectoryPath
        guard FileManager.default.fileExists(atPath: dir) else {
            return .failure(.invalidDirectory)
        }
        guard FileManager.default.fileExists(atPath: gitPath) else {
            return .failure(.gitNotFound)
        }

        return await Task.detached(priority: .userInitiated) { [gitPath = self.gitPath] in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: gitPath)
            process.arguments = ["diff"]
            process.currentDirectoryURL = URL(fileURLWithPath: dir)

            do {
                let (stdoutData, stderrData) = try process.runCollectingOutput()
                let stdoutString = String(data: stdoutData, encoding: .utf8) ?? ""
                let stderrString = String(data: stderrData, encoding: .utf8) ?? ""

                if process.terminationStatus == 0 {
                    return .success(stdoutString)
                } else {
                    return .failure(.executionFailed(process.terminationStatus, stderrString))
                }
            } catch {
                return .failure(.executionFailed(-1, error.localizedDescription))
            }
        }.value
    }

    @discardableResult
    public func openDiff(workingDirectory: String?) async -> Bool {
        let diffResult = await getDiff(workingDirectory: workingDirectory)
        switch diffResult {
        case .success(let diffText):
            if diffText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                // If diff is empty, reveal the working directory in Finder
                if let dir = workingDirectory {
                    let url = URL(fileURLWithPath: dir)
                    return await MainActor.run {
                        NSWorkspace.shared.open(url)
                    }
                }
                return false
            }

            // Write diff to a temporary file and open in default diff viewer
            let tempDir = FileManager.default.temporaryDirectory
            let tempFile = tempDir.appendingPathComponent("bitz-diff-\(UUID().uuidString.prefix(8)).diff")
            do {
                try diffText.write(to: tempFile, atomically: true, encoding: .utf8)
                return await MainActor.run {
                    NSWorkspace.shared.open(tempFile)
                }
            } catch {
                return false
            }

        case .failure:
            // Fallback: reveal the directory in Finder
            if let dir = workingDirectory {
                let url = URL(fileURLWithPath: dir)
                return await MainActor.run {
                    NSWorkspace.shared.open(url)
                }
            }
            return false
        }
    }
}

extension Process {
    /// Runs the process and reads stdout and stderr to EOF before waiting for exit.
    /// Waiting first deadlocks once the child fills a pipe's ~64 KB buffer.
    func runCollectingOutput() throws -> (stdout: Data, stderr: Data) {
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        standardOutput = stdoutPipe
        standardError = stderrPipe
        try run()

        let stderrHandle = stderrPipe.fileHandleForReading
        let stderrBox = ProcessOutputBox()
        let group = DispatchGroup()
        DispatchQueue.global(qos: .utility).async(group: group) {
            stderrBox.data = stderrHandle.readDataToEndOfFile()
        }
        let stdoutData = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
        group.wait()
        waitUntilExit()
        return (stdoutData, stderrBox.data)
    }
}

/// Written once on a background queue and read after `group.wait()`, which orders the accesses.
private final class ProcessOutputBox: @unchecked Sendable {
    var data = Data()
}
