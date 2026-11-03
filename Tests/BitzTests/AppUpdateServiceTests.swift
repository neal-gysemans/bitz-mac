import AppKit
@testable import BitzCore
import XCTest

private final class MockUpdateCheckingService: UpdateCheckingService, @unchecked Sendable {
    var resultToReturn: Result<GitHubReleaseInfo, Error>

    init(result: Result<GitHubReleaseInfo, Error>) {
        self.resultToReturn = result
    }

    func fetchLatestRelease() async throws -> GitHubReleaseInfo {
        switch resultToReturn {
        case .success(let info):
            return info
        case .failure(let error):
            throw error
        }
    }
}

@MainActor
final class AppUpdateServiceTests: XCTestCase {

    private func createIsolatedDefaults() -> (UserDefaults, () -> Void) {
        let suiteName = "AppUpdateServiceTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        let cleanup = {
            defaults.removePersistentDomain(forName: suiteName)
        }
        return (defaults, cleanup)
    }

    // MARK: - SemanticVersion Tests

    func testSemanticVersionParsing() {
        let v1 = SemanticVersion("1.2.0")
        XCTAssertEqual(v1.major, 1)
        XCTAssertEqual(v1.minor, 2)
        XCTAssertEqual(v1.patch, 0)
        XCTAssertNil(v1.prerelease)
        XCTAssertEqual(v1.description, "1.2.0")

        let vWithPrefix = SemanticVersion("v2.5.9")
        XCTAssertEqual(vWithPrefix.major, 2)
        XCTAssertEqual(vWithPrefix.minor, 5)
        XCTAssertEqual(vWithPrefix.patch, 9)

        let vPrerelease = SemanticVersion("v1.3.0-rc.1")
        XCTAssertEqual(vPrerelease.major, 1)
        XCTAssertEqual(vPrerelease.minor, 3)
        XCTAssertEqual(vPrerelease.patch, 0)
        XCTAssertEqual(vPrerelease.prerelease, "rc.1")
        XCTAssertEqual(vPrerelease.description, "1.3.0-rc.1")

        let vPartial = SemanticVersion("3.4")
        XCTAssertEqual(vPartial.major, 3)
        XCTAssertEqual(vPartial.minor, 4)
        XCTAssertEqual(vPartial.patch, 0)
    }

    func testSemanticVersionComparisons() {
        XCTAssertTrue(SemanticVersion("1.3.0") > SemanticVersion("1.2.9"))
        XCTAssertTrue(SemanticVersion("2.0.0") > SemanticVersion("1.99.99"))
        XCTAssertTrue(SemanticVersion("1.2.1") > SemanticVersion("1.2.0"))
        XCTAssertEqual(SemanticVersion("v1.2.0"), SemanticVersion("1.2.0"))

        // Prerelease comparisons
        XCTAssertTrue(SemanticVersion("1.2.0") > SemanticVersion("1.2.0-beta.1"))
        XCTAssertTrue(SemanticVersion("1.2.0-beta.2") > SemanticVersion("1.2.0-beta.1"))
    }

    // MARK: - AppUpdateStore Tests

    func testAppUpdateStoreDetectsNewerVersion() async {
        let (defaults, cleanup) = createIsolatedDefaults()
        defer { cleanup() }

        let mockRelease = GitHubReleaseInfo(
            tagName: "v1.3.0",
            name: "Bitz v1.3.0",
            htmlUrl: URL(string: "https://github.com/AkramKs/bitz-mac/releases/tag/v1.3.0")!,
            dmgAssetUrl: URL(string: "https://github.com/AkramKs/bitz-mac/releases/download/v1.3.0/Bitz.dmg")!
        )
        let mockService = MockUpdateCheckingService(result: .success(mockRelease))

        let store = AppUpdateStore(
            currentVersionString: "1.2.0",
            updateService: mockService,
            userDefaults: defaults
        )

        XCTAssertFalse(store.isUpdateAvailable)
        XCTAssertFalse(store.isSpeechBubbleAlertActive)

        await store.checkForUpdates(manual: true)

        XCTAssertTrue(store.isUpdateAvailable)
        XCTAssertTrue(store.isSpeechBubbleAlertActive)
        XCTAssertEqual(store.latestVersionString, "1.3.0")
        XCTAssertNotNil(store.lastCheckDate)
        XCTAssertTrue(store.updateBannerText.contains("1.3.0"))
    }

    func testAppUpdateStoreRecognizesWhenAlreadyUpToDate() async {
        let (defaults, cleanup) = createIsolatedDefaults()
        defer { cleanup() }

        let mockRelease = GitHubReleaseInfo(
            tagName: "v1.2.0",
            name: "Bitz v1.2.0",
            htmlUrl: URL(string: "https://github.com/AkramKs/bitz-mac/releases/tag/v1.2.0")!
        )
        let mockService = MockUpdateCheckingService(result: .success(mockRelease))

        let store = AppUpdateStore(
            currentVersionString: "1.2.0",
            updateService: mockService,
            userDefaults: defaults
        )

        await store.checkForUpdates(manual: true)

        XCTAssertFalse(store.isUpdateAvailable)
        XCTAssertFalse(store.isSpeechBubbleAlertActive)
        XCTAssertTrue(store.statusMessage.contains("latest version"))
    }

    func testAppUpdateStoreDismissAndSkipVersion() async {
        let (defaults, cleanup) = createIsolatedDefaults()
        defer { cleanup() }

        let mockRelease = GitHubReleaseInfo(
            tagName: "v1.4.0",
            name: "Bitz v1.4.0",
            htmlUrl: URL(string: "https://github.com/AkramKs/bitz-mac/releases/tag/v1.4.0")!
        )
        let mockService = MockUpdateCheckingService(result: .success(mockRelease))

        let store = AppUpdateStore(
            currentVersionString: "1.2.0",
            updateService: mockService,
            userDefaults: defaults
        )

        await store.checkForUpdates(manual: true)
        XCTAssertTrue(store.isSpeechBubbleAlertActive)

        // Dismiss alert
        store.dismissAlert()
        XCTAssertFalse(store.isSpeechBubbleAlertActive)

        // Skip current update
        store.skipCurrentUpdate()
        XCTAssertEqual(store.skippedVersionTag, "v1.4.0")

        // Re-check for updates: update is available in menu, but mascot alert stays suppressed
        await store.checkForUpdates(manual: true)
        XCTAssertTrue(store.isUpdateAvailable)
        XCTAssertFalse(store.isSpeechBubbleAlertActive)
    }

    func testAppUpdateStoreHandlesNetworkErrorGracefully() async {
        let (defaults, cleanup) = createIsolatedDefaults()
        defer { cleanup() }

        let mockService = MockUpdateCheckingService(result: .failure(URLError(.notConnectedToInternet)))
        let store = AppUpdateStore(
            currentVersionString: "1.2.0",
            updateService: mockService,
            userDefaults: defaults
        )

        await store.checkForUpdates(manual: true)

        XCTAssertFalse(store.isChecking)
        XCTAssertFalse(store.isUpdateAvailable)
        XCTAssertEqual(store.statusMessage, "Could not check for updates")
    }

    func testAppUpdateStoreRespectsAutomaticCheckPreference() async {
        let (defaults, cleanup) = createIsolatedDefaults()
        defer { cleanup() }

        let mockRelease = GitHubReleaseInfo(
            tagName: "v1.5.0",
            name: "Bitz v1.5.0",
            htmlUrl: URL(string: "https://github.com/AkramKs/bitz-mac/releases/tag/v1.5.0")!
        )
        let mockService = MockUpdateCheckingService(result: .success(mockRelease))

        let store = AppUpdateStore(
            currentVersionString: "1.2.0",
            updateService: mockService,
            userDefaults: defaults
        )

        // Turn off auto check
        store.automaticallyCheckForUpdates = false
        XCTAssertFalse(defaults.bool(forKey: AppUpdateStore.autoCheckUserDefaultsKey))

        // Non-manual check should be bypassed
        await store.checkForUpdates(manual: false)
        XCTAssertFalse(store.isUpdateAvailable)

        // Manual check still proceeds
        await store.checkForUpdates(manual: true)
        XCTAssertTrue(store.isUpdateAvailable)
    }

    func testGitHubUpdateServiceDefaultRepositoryIsBitzReleases() {
        let service = GitHubUpdateService()
        XCTAssertEqual(service.repository, "AkramKs/bitz-releases")
    }
}
