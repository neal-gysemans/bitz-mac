import Foundation
import XCTest

/// Packaging scripts can't be run in tests (they build, sign and launch Bitz), so check what can be checked without that:
/// syntax, and the shared Info.plist template both scripts render.
final class BuildScriptsTests: XCTestCase {
    private let scriptsDir = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("Scripts", isDirectory: true)

    @discardableResult
    private func run(_ executable: String, _ arguments: [String]) throws -> Int32 {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        return process.terminationStatus
    }

    func testScriptsParse() throws {
        for script in ["package_and_run.sh", "create_dmg.sh", "render_info_plist.sh"] {
            XCTAssertEqual(try run("/bin/bash", ["-n", scriptsDir.appendingPathComponent(script).path]), 0, script)
        }
    }

    func testInfoPlistTemplateRendersDevAndReleaseBundleIDs() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("bitz-plist-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let renderer = scriptsDir.appendingPathComponent("render_info_plist.sh").path

        for bundleID in ["com.bitz.cybercat.dev", "com.bitz.cybercat"] {
            let output = dir.appendingPathComponent("\(bundleID).plist")
            XCTAssertEqual(try run("/bin/bash", [renderer, "Bitz", bundleID, output.path]), 0, bundleID)
            XCTAssertEqual(try run("/usr/bin/plutil", ["-lint", output.path]), 0, bundleID)

            let plist = try XCTUnwrap(NSDictionary(contentsOf: output) as? [String: Any])
            XCTAssertEqual(plist["CFBundleIdentifier"] as? String, bundleID)
            XCTAssertEqual(plist["CFBundleExecutable"] as? String, "Bitz")
            XCTAssertEqual(plist["CFBundleName"] as? String, "Bitz")
            for key in ["NSMicrophoneUsageDescription", "NSSpeechRecognitionUsageDescription",
                        "NSScreenCaptureUsageDescription", "NSDocumentsFolderUsageDescription"] {
                XCTAssertFalse((plist[key] as? String ?? "").isEmpty, "\(bundleID): \(key)")
            }
        }

        // A bundle ID that would break the sed substitution or the XML is refused
        let bad = dir.appendingPathComponent("bad.plist")
        XCTAssertNotEqual(try run("/bin/bash", [renderer, "Bitz", "com.bitz/<x>", bad.path]), 0)
    }

    func testPackagingScriptsDoNotInjectLocalDevLicenseToken() throws {
        for script in ["package_and_run.sh", "create_dmg.sh", "Info.plist.template"] {
            let contents = try String(contentsOf: scriptsDir.appendingPathComponent(script), encoding: .utf8)
            XCTAssertFalse(contents.contains("BitzLocalDevLicenseToken"), "\(script) must not embed BitzLocalDevLicenseToken")
            XCTAssertFalse(contents.contains("BTZ-LOCAL-DEV-PRO"), "\(script) must not embed BTZ-LOCAL-DEV-PRO")
        }
    }
}
