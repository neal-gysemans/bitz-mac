import XCTest
@testable import BitzCore

@MainActor
final class LocalGitEventWatcherTests: XCTestCase {
    private func makeTempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("bitz-git-events-test-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    func testRemoteURLParsesSSHAndHTTPS() {
        let ssh = LocalGitEvent(
            kind: .push,
            repo: "bitz-mac",
            branch: "main",
            remoteURL: "git@github.com:AkramKs/bitz-mac.git"
        )
        XCTAssertEqual(ssh.webURL?.absoluteString, "https://github.com/AkramKs/bitz-mac")

        let https = LocalGitEvent(
            kind: .commit,
            repo: "bitz-web",
            branch: "feat/ui",
            remoteURL: "https://github.com/AkramKs/bitz-web.git"
        )
        XCTAssertEqual(https.webURL?.absoluteString, "https://github.com/AkramKs/bitz-web")
    }

    func testWatcherDetectsDroppedEventFileAndCleansUp() async throws {
        let eventsDir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: eventsDir) }

        let watcher = LocalGitEventWatcher(eventsDirectory: eventsDir, hooksDirectory: eventsDir)
        let exp = expectation(description: "Received local git event")
        var received: LocalGitEvent?

        watcher.onEvent = { event in
            received = event
            exp.fulfill()
        }
        watcher.start(installHooks: false)
        defer { watcher.stop() }

        let payload = #"{"kind":"push","repo":"bitz-mac","branch":"main","detail":"origin","remoteURL":"https://github.com/AkramKs/bitz-mac.git"}"#
        let fileURL = eventsDir.appendingPathComponent("1-test.json")
        try Data(payload.utf8).write(to: fileURL)

        await fulfillment(of: [exp], timeout: 2.0)
        XCTAssertEqual(received?.kind, .push)
        XCTAssertEqual(received?.repo, "bitz-mac")
        XCTAssertEqual(received?.branch, "main")
        XCTAssertFalse(FileManager.default.fileExists(atPath: fileURL.path))
    }

    func testGitHubNotificationServicePresentsLocalGitEventsImmediately() {
        let suite = "com.bitz.tests.localgit.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }

        let settings = GitHubSettingsStore(userDefaults: defaults)
        settings.setEnabled(true)
        let service = GitHubNotificationService(settingsStore: settings)

        let pushEvent = LocalGitEvent(
            kind: .push,
            repo: "any-repo",
            branch: "feat/instant",
            detail: "origin",
            remoteURL: "https://github.com/AkramKs/any-repo.git"
        )
        service.handleLocalGitEvent(pushEvent)
        XCTAssertEqual(service.activeAlert?.title, "🚀 Code Pushed")
        XCTAssertEqual(service.activeAlert?.message, "Pushed any-repo (feat/instant) → origin")
        XCTAssertEqual(service.activeAlert?.targetURL?.absoluteString, "https://github.com/AkramKs/any-repo")

        service.dismissAlert()
        settings.setNotifyGitActivity(false)
        service.handleLocalGitEvent(pushEvent)
        XCTAssertNil(service.activeAlert)
    }
}
