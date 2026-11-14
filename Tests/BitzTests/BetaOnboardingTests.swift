import Foundation
import XCTest

final class BetaOnboardingTests: XCTestCase {
    private let repoRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()

    private func readRepoFile(_ relativePath: String) throws -> String {
        let url = repoRoot.appendingPathComponent(relativePath)
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path), "Missing expected file: \(relativePath)")
        return try String(contentsOf: url, encoding: .utf8)
    }

    private func run(_ executable: String, _ arguments: [String], stdin: String? = nil) throws -> Int32 {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice

        if let stdin {
            let pipe = Pipe()
            process.standardInput = pipe
            try process.run()
            if let data = stdin.data(using: .utf8) {
                pipe.fileHandleForWriting.write(data)
            }
            try pipe.fileHandleForWriting.close()
        } else {
            try process.run()
        }

        process.waitUntilExit()
        return process.terminationStatus
    }

    func testBetaTestingGuideExistsWithRequiredOnboardingSections() throws {
        let guide = try readRepoFile("docs/BETA_TESTING.md")

        // Explanation of why Gatekeeper / quarantine warnings happen during free Public Beta
        XCTAssertTrue(guide.contains("codesign --sign -"))
        XCTAssertTrue(guide.localizedCaseInsensitiveContains("ad-hoc"))
        XCTAssertTrue(guide.contains("Apple Developer ID"))
        XCTAssertTrue(guide.localizedCaseInsensitiveContains("notarization"))

        // Method A: Homebrew Tap install & upgrade
        XCTAssertTrue(guide.contains("brew tap akramks/tap"))
        XCTAssertTrue(guide.contains("brew install --cask bitz"))
        XCTAssertTrue(guide.contains("brew upgrade --cask bitz"))

        // Method B: Direct DMG install & macOS 14/15/26 Gatekeeper workarounds
        XCTAssertTrue(guide.contains("Bitz.dmg"))
        XCTAssertTrue(guide.contains("/Applications"))
        XCTAssertTrue(guide.contains("xattr -cr /Applications/Bitz.app"))
        XCTAssertTrue(guide.contains("Privacy & Security"))
        XCTAssertTrue(guide.contains("Open Anyway"))
        XCTAssertTrue(guide.contains("macOS 15 Sequoia"))
        XCTAssertTrue(guide.localizedCaseInsensitiveContains("removed"))

        // Updating during Beta, TCC permissions tip, and Beta All-Access status
        XCTAssertTrue(guide.contains("tccutil reset All com.bitz.cybercat"))
        XCTAssertTrue(guide.contains("Meeting Recorder"))
        XCTAssertTrue(guide.contains("BETA ALL-ACCESS"))
    }

    func testReadmeLinksBetaTestingAndUpdatesGatekeeperForSequoia() throws {
        let readme = try readRepoFile("README.md")

        XCTAssertTrue(readme.contains("docs/BETA_TESTING.md"))
        XCTAssertTrue(readme.contains("xattr -cr /Applications/Bitz.app"))
        XCTAssertTrue(readme.contains("Privacy & Security"))
        XCTAssertTrue(readme.contains("Open Anyway"))
        XCTAssertTrue(readme.contains("macOS 15 Sequoia"))
        XCTAssertFalse(readme.contains("Simply right-click (or Control-click) `Bitz.app`"))
    }

    func testCreateDmgScriptParsesAndStagesReadMe() throws {
        let scriptPath = repoRoot.appendingPathComponent("Scripts/create_dmg.sh").path
        XCTAssertEqual(try run("/bin/bash", ["-n", scriptPath]), 0)

        let script = try readRepoFile("Scripts/create_dmg.sh")
        let readmeStagingMarker = #"$DMG_STAGING/FIRST TIME OPENING - READ ME.txt"#
        XCTAssertTrue(script.contains(readmeStagingMarker))

        let stageRange = try XCTUnwrap(script.range(of: readmeStagingMarker))
        let hdiutilRange = try XCTUnwrap(script.range(of: "hdiutil create"))
        XCTAssertLessThan(stageRange.lowerBound, hdiutilRange.lowerBound)

        XCTAssertTrue(script.contains("Bitz.app"))
        XCTAssertTrue(script.contains("Applications"))
        XCTAssertTrue(script.contains("xattr -cr /Applications/Bitz.app"))
        XCTAssertTrue(script.contains("Privacy & Security"))
        XCTAssertTrue(script.contains("Open Anyway"))
    }

    func testReleaseWorkflowIncludesBetaReleaseNotesAndCaskCaveats() throws {
        let workflow = try readRepoFile(".github/workflows/release.yml")

        // Release notes generation and gh release create flags
        XCTAssertTrue(workflow.contains("/tmp/release-notes.md"))
        XCTAssertTrue(workflow.contains("--notes-file /tmp/release-notes.md"))
        XCTAssertTrue(workflow.contains("--generate-notes"))
        XCTAssertTrue(workflow.contains("brew tap akramks/tap"))
        XCTAssertTrue(workflow.contains("brew install --cask bitz"))
        XCTAssertTrue(workflow.contains("xattr -cr /Applications/Bitz.app"))
        XCTAssertTrue(workflow.contains("Privacy & Security"))
        XCTAssertTrue(workflow.contains("Open Anyway"))

        // Homebrew cask caveats stanza and Ruby syntax verification
        let caskStartMarker = "cat > Casks/bitz.rb <<'EOF'\n"
        let startRange = try XCTUnwrap(workflow.range(of: caskStartMarker))
        let afterStart = workflow[startRange.upperBound...]
        let endRange = try XCTUnwrap(afterStart.range(of: "\n          EOF"))
        let rawCaskTemplate = String(afterStart[..<endRange.lowerBound])
        let caskTemplate = rawCaskTemplate
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map { line -> String in
                let prefix = "          "
                return line.hasPrefix(prefix) ? String(line.dropFirst(prefix.count)) : String(line)
            }
            .joined(separator: "\n")

        XCTAssertTrue(caskTemplate.contains("caveats"))
        XCTAssertTrue(caskTemplate.contains("xattr -cr /Applications/Bitz.app"))
        XCTAssertTrue(caskTemplate.contains("Privacy & Security"))
        XCTAssertTrue(caskTemplate.contains("Open Anyway"))

        if FileManager.default.isExecutableFile(atPath: "/usr/bin/ruby") {
            XCTAssertEqual(try run("/usr/bin/ruby", ["-c", "-"], stdin: caskTemplate), 0)
        }
    }
}
