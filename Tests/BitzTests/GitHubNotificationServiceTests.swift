import AppKit
import Combine
import XCTest
@testable import BitzCore

@MainActor
final class GitHubNotificationServiceTests: XCTestCase {
    private var suiteName: String!
    private var defaults: UserDefaults!

    override func setUp() async throws {
        suiteName = "GitHubNotificationServiceTests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)!
    }

    override func tearDown() async throws {
        if let suiteName {
            defaults.removePersistentDomain(forName: suiteName)
        }
        defaults = nil
        suiteName = nil
    }

    // MARK: - WP1: Credentials Store & Token Storage Tests

    private final class Box<T>: @unchecked Sendable {
        var value: T
        init(_ value: T) { self.value = value }
    }

    func testManualTokenStorageSaveLoadDelete() throws {
        let storage = InMemoryGitHubTokenStorage()
        let credentials = GitHubCredentialsStore(tokenStorage: storage)

        XCTAssertFalse(credentials.hasManualPAT())
        XCTAssertNil(storage.loadToken())

        try credentials.saveManualPAT("ghp_testToken123456789")
        XCTAssertTrue(credentials.hasManualPAT())
        XCTAssertEqual(storage.loadToken(), "ghp_testToken123456789")

        // Whitespace trimming
        try credentials.saveManualPAT("   ghp_trimmed987   \n")
        XCTAssertEqual(storage.loadToken(), "ghp_trimmed987")

        // Rejection of empty string
        XCTAssertThrowsError(try credentials.saveManualPAT("   \n\t  ")) { error in
            XCTAssertEqual(error as? GitHubCredentialsError, .emptyToken)
        }

        // Delete
        try credentials.deleteManualPAT()
        XCTAssertFalse(credentials.hasManualPAT())
        XCTAssertNil(storage.loadToken())

        // Idempotent delete
        XCTAssertNoThrow(try credentials.deleteManualPAT())
    }

    func testCLITokenResolutionAndTTLCaching() async throws {
        let runCount = Box(0)
        let fixedDate = Date()
        let credentials = GitHubCredentialsStore(
            tokenStorage: InMemoryGitHubTokenStorage(),
            ghRunner: {
                runCount.value += 1
                return "gho_mockTokenABC"
            },
            clock: { fixedDate },
            ttlSeconds: 60.0
        )

        let token1 = await credentials.resolveCLIToken()
        XCTAssertEqual(token1, "gho_mockTokenABC")
        XCTAssertEqual(runCount.value, 1)

        // Second call within TTL should return cached value without executing runner
        let token2 = await credentials.resolveCLIToken()
        XCTAssertEqual(token2, "gho_mockTokenABC")
        XCTAssertEqual(runCount.value, 1)

        // Clear cache
        credentials.clearCLICache()
        let token3 = await credentials.resolveCLIToken()
        XCTAssertEqual(token3, "gho_mockTokenABC")
        XCTAssertEqual(runCount.value, 2)
    }

    func testActiveTokenResolutionModes() async throws {
        let storage = InMemoryGitHubTokenStorage(initialToken: "ghp_manualPAT")
        let credentials = GitHubCredentialsStore(
            tokenStorage: storage,
            ghRunner: { "gho_cliToken" }
        )

        // In Auto mode: CLI takes precedence
        let autoAuth = await credentials.activeToken(mode: .auto)
        XCTAssertNotNil(autoAuth)
        XCTAssertEqual(autoAuth?.token, "gho_cliToken")
        XCTAssertEqual(autoAuth?.source, .ghCLI)

        // In Manual PAT mode: ignores CLI and returns PAT
        let manualAuth = await credentials.activeToken(mode: .manualPAT)
        XCTAssertNotNil(manualAuth)
        XCTAssertEqual(manualAuth?.token, "ghp_manualPAT")
        XCTAssertEqual(manualAuth?.source, .personalAccessToken)

        // When CLI runner fails in Auto mode: falls back to PAT
        let failingCredentials = GitHubCredentialsStore(
            tokenStorage: storage,
            ghRunner: { throw GitHubCredentialsError.ghCliNotFound }
        )
        let fallbackAuth = await failingCredentials.activeToken(mode: .auto)
        XCTAssertNotNil(fallbackAuth)
        XCTAssertEqual(fallbackAuth?.token, "ghp_manualPAT")
        XCTAssertEqual(fallbackAuth?.source, .personalAccessToken)
    }

    // MARK: - WP2: Settings Store Tests

    func testGitHubSettingsStoreDefaultsAndMutators() {
        let settings = GitHubSettingsStore(userDefaults: defaults)

        XCTAssertFalse(settings.isEnabled)
        XCTAssertEqual(settings.authMode, .auto)
        XCTAssertEqual(settings.pollIntervalSeconds, 60)
        XCTAssertTrue(settings.notifyReviewRequests)
        XCTAssertTrue(settings.notifyCIFailures)
        XCTAssertTrue(settings.notifyCIPasses)
        XCTAssertTrue(settings.notifyPRStatus)

        var changed = false
        settings.onSettingsChanged = { changed = true }

        settings.setEnabled(true)
        XCTAssertTrue(settings.isEnabled)
        XCTAssertTrue(changed)

        settings.setAuthMode(.manualPAT)
        XCTAssertEqual(settings.authMode, .manualPAT)

        settings.setPollIntervalSeconds(30)
        XCTAssertEqual(settings.pollIntervalSeconds, 30)

        // Invalid interval falls back to 60
        settings.setPollIntervalSeconds(999)
        XCTAssertEqual(settings.pollIntervalSeconds, 60)

        settings.setNotifyReviewRequests(false)
        XCTAssertFalse(settings.notifyReviewRequests)

        settings.setNotifyCIFailures(false)
        XCTAssertFalse(settings.notifyCIFailures)
    }

    // MARK: - WP3: Notification Service & API Tests

    func testUserAuthenticationValidationSuccess() async throws {
        let mockHTTP = MockHTTPRequester { request in
            XCTAssertEqual(request.url, GitHubNotificationService.userURL)
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer gho_validToken")

            let json = """
            {
                "login": "octocat",
                "id": 1,
                "name": "The Octocat",
                "avatar_url": "https://avatars.githubusercontent.com/u/1"
            }
            """
            let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            return (Data(json.utf8), response)
        }

        let credentials = GitHubCredentialsStore(
            tokenStorage: InMemoryGitHubTokenStorage(),
            ghRunner: { "gho_validToken" }
        )
        let settings = GitHubSettingsStore(userDefaults: defaults)
        let service = GitHubNotificationService(
            settingsStore: settings,
            credentialsStore: credentials,
            httpRequester: mockHTTP
        )

        let state = await service.checkAuthentication()
        XCTAssertTrue(state.isAuthenticated)
        XCTAssertEqual(state.username, "octocat")
        if case .authenticated(let username, let source) = state {
            XCTAssertEqual(username, "octocat")
            XCTAssertEqual(source, .ghCLI)
        } else {
            XCTFail("Expected .authenticated state")
        }
    }

    func testUserAuthenticationFailureUpdatesStateToError() async throws {
        let mockHTTP = MockHTTPRequester { request in
            let response = HTTPURLResponse(url: request.url!, statusCode: 401, httpVersion: nil, headerFields: nil)!
            return (Data("Bad credentials".utf8), response)
        }

        let credentials = GitHubCredentialsStore(
            tokenStorage: InMemoryGitHubTokenStorage(),
            ghRunner: { "gho_expiredToken" }
        )
        let settings = GitHubSettingsStore(userDefaults: defaults)
        let service = GitHubNotificationService(
            settingsStore: settings,
            credentialsStore: credentials,
            httpRequester: mockHTTP
        )

        let state = await service.checkAuthentication()
        XCTAssertFalse(state.isAuthenticated)
        if case .error(let msg) = state {
            XCTAssertTrue(msg.contains("401"))
        } else {
            XCTFail("Expected .error state")
        }
    }

    func testConditionalPollingWith304NotModified() async throws {
        let requestedETag = Box<String?>(nil)
        let mockHTTP = MockHTTPRequester { request in
            requestedETag.value = request.value(forHTTPHeaderField: "If-None-Match")
            let response = HTTPURLResponse(url: request.url!, statusCode: 304, httpVersion: nil, headerFields: nil)!
            return (Data(), response)
        }

        let credentials = GitHubCredentialsStore(
            tokenStorage: InMemoryGitHubTokenStorage(),
            ghRunner: { "gho_token" }
        )
        let settings = GitHubSettingsStore(userDefaults: defaults)
        let service = GitHubNotificationService(
            settingsStore: settings,
            credentialsStore: credentials,
            httpRequester: mockHTTP
        )

        // Seed an initial poll
        service.setSeededForTesting(true)
        await service.pollNotificationsOnce()

        XCTAssertEqual(service.lastStatusCode, 304)
        XCTAssertNil(service.activeAlert)
    }

    func testIncomingReviewRequestProducesAlert() async throws {
        let sampleJSON = """
        [
            {
                "id": "notif-101",
                "unread": true,
                "reason": "review_requested",
                "updated_at": "2026-11-16T12:00:00Z",
                "subject": {
                    "title": "Fix thermal throttling on Apple Silicon",
                    "url": "https://api.github.com/repos/AkramKs/bitz-mac/pulls/142",
                    "type": "PullRequest"
                },
                "repository": {
                    "id": 999,
                    "name": "bitz-mac",
                    "full_name": "AkramKs/bitz-mac",
                    "html_url": "https://github.com/AkramKs/bitz-mac"
                }
            }
        ]
        """

        let mockHTTP = MockHTTPRequester { request in
            let headers = ["ETag": "\"etag-test-1\""]
            let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: headers)!
            return (Data(sampleJSON.utf8), response)
        }

        let credentials = GitHubCredentialsStore(
            tokenStorage: InMemoryGitHubTokenStorage(),
            ghRunner: { "gho_token" }
        )
        let settings = GitHubSettingsStore(userDefaults: defaults)
        settings.setEnabled(true)

        let service = GitHubNotificationService(
            settingsStore: settings,
            credentialsStore: credentials,
            httpRequester: mockHTTP
        )

        // When seeded, subsequent unread notifications generate an alert
        service.setSeededForTesting(true)
        await service.pollNotificationsOnce()

        XCTAssertNotNil(service.activeAlert)
        let alert = try XCTUnwrap(service.activeAlert)
        XCTAssertEqual(alert.kind, .reviewRequested)
        XCTAssertEqual(alert.repositoryName, "bitz-mac")
        XCTAssertEqual(alert.actionTitle, "VIEW PR")
        XCTAssertEqual(alert.targetURL?.absoluteString, "https://github.com/AkramKs/bitz-mac/pull/142")
        XCTAssertTrue(alert.message.contains("#142"))
        XCTAssertTrue(alert.isInteractive)
    }

    func testStartupSeedingSilentlyIgnoresHistoricalNotifications() async throws {
        let sampleJSON = """
        [
            {
                "id": "old-notif-1",
                "unread": true,
                "reason": "review_requested",
                "updated_at": "2026-11-16T12:00:00Z",
                "subject": {
                    "title": "Old PR",
                    "url": "https://api.github.com/repos/AkramKs/bitz-mac/pulls/10",
                    "type": "PullRequest"
                },
                "repository": {
                    "id": 999,
                    "name": "bitz-mac",
                    "full_name": "AkramKs/bitz-mac"
                }
            }
        ]
        """

        let mockHTTP = MockHTTPRequester { request in
            let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            return (Data(sampleJSON.utf8), response)
        }

        let credentials = GitHubCredentialsStore(
            tokenStorage: InMemoryGitHubTokenStorage(),
            ghRunner: { "gho_token" }
        )
        let settings = GitHubSettingsStore(userDefaults: defaults)
        let service = GitHubNotificationService(
            settingsStore: settings,
            credentialsStore: credentials,
            httpRequester: mockHTTP
        )

        // First poll (isSeeded = false)
        await service.pollNotificationsOnce()
        XCTAssertNil(service.activeAlert, "Initial startup poll must seed silently without triggering alerts")
    }

    func testCIFailureProducesAlertWithViewLogsButton() async throws {
        let sampleJSON = """
        [
            {
                "id": "ci-fail-202",
                "unread": true,
                "reason": "ci_activity",
                "updated_at": "2026-11-16T12:00:00Z",
                "subject": {
                    "title": "Build & Unit Tests failed on feature/auth",
                    "url": "https://api.github.com/repos/AkramKs/bitz-mac/actions/runs/8888",
                    "type": "WorkflowRun"
                },
                "repository": {
                    "id": 999,
                    "name": "bitz-mac",
                    "full_name": "AkramKs/bitz-mac"
                }
            }
        ]
        """

        let mockHTTP = MockHTTPRequester { request in
            let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            return (Data(sampleJSON.utf8), response)
        }

        let credentials = GitHubCredentialsStore(
            tokenStorage: InMemoryGitHubTokenStorage(),
            ghRunner: { "gho_token" }
        )
        let settings = GitHubSettingsStore(userDefaults: defaults)
        let service = GitHubNotificationService(
            settingsStore: settings,
            credentialsStore: credentials,
            httpRequester: mockHTTP
        )

        service.setSeededForTesting(true)
        await service.pollNotificationsOnce()

        XCTAssertNotNil(service.activeAlert)
        let alert = try XCTUnwrap(service.activeAlert)
        XCTAssertEqual(alert.kind, .ciFailed)
        XCTAssertEqual(alert.actionTitle, "VIEW LOGS")
        XCTAssertEqual(alert.targetURL?.absoluteString, "https://github.com/AkramKs/bitz-mac/actions/runs/8888")
    }

    func testOpenTargetURLAndDismiss() {
        let settings = GitHubSettingsStore(userDefaults: defaults)
        let service = GitHubNotificationService(settingsStore: settings)

        var openedURL: URL?
        service.onOpenURL = { url in openedURL = url }

        let alert = GitHubEventAlert(
            kind: .reviewRequested,
            title: "🔍 Review Requested",
            message: "Review requested on bitz-mac",
            repositoryName: "bitz-mac",
            targetURL: URL(string: "https://github.com/AkramKs/bitz-mac/pull/188"),
            actionTitle: "VIEW PR"
        )
        service.setActiveAlertForTesting(alert)
        XCTAssertNotNil(service.activeAlert)

        service.openTargetURL(for: alert)
        XCTAssertEqual(openedURL?.absoluteString, "https://github.com/AkramKs/bitz-mac/pull/188")
        XCTAssertNil(service.activeAlert, "Opening target URL must dismiss active alert")
    }

    func testSpeechBubbleContentPriority() {
        let engine = WellnessPointEngine(riveController: ProductionRiveController(), userDefaults: defaults)
        let agentMonitor = AgentMonitorService(adapters: [], userDefaults: defaults)
        let updateStore = AppUpdateStore(userDefaults: defaults)
        let telemetrySettings = TelemetrySettingsStore(userDefaults: defaults)
        let telemetryDashboard = TelemetryDashboardService(settingsStore: telemetrySettings, provider: MockTelemetryDataProvider())
        let meetingRecorder = MeetingRecorderService.stub(defaults: defaults)

        let ghSettings = GitHubSettingsStore(userDefaults: defaults)
        let ghService = GitHubNotificationService(settingsStore: ghSettings)

        // When no alerts are active:
        let emptyContent = SpeechBubbleContent.current(
            engine: engine,
            agentMonitor: agentMonitor,
            githubService: ghService,
            updateStore: updateStore,
            telemetryDashboard: telemetryDashboard,
            telemetrySettings: telemetrySettings,
            meetingRecorder: meetingRecorder
        )
        XCTAssertNil(emptyContent)

        // When GitHub alert is active:
        let alert = GitHubEventAlert(
            kind: .reviewRequested,
            title: "🔍 Review Requested",
            message: "Review requested",
            repositoryName: "bitz-mac",
            targetURL: URL(string: "https://github.com/AkramKs/bitz-mac/pull/1"),
            actionTitle: "VIEW PR"
        )
        ghService.setActiveAlertForTesting(alert)

        let ghContent = SpeechBubbleContent.current(
            engine: engine,
            agentMonitor: agentMonitor,
            githubService: ghService,
            updateStore: updateStore,
            telemetryDashboard: telemetryDashboard,
            telemetrySettings: telemetrySettings,
            meetingRecorder: meetingRecorder
        )
        XCTAssertEqual(ghContent, .github(alert))
        XCTAssertTrue(ghContent?.isInteractive == true)

        // Agent popup outranks GitHub alert
        agentMonitor.handleEvent(AgentEvent(agentID: "claude", agentName: "Claude", kind: .needsApproval, message: "Run bash?"))
        let agentContent = SpeechBubbleContent.current(
            engine: engine,
            agentMonitor: agentMonitor,
            githubService: ghService,
            updateStore: updateStore,
            telemetryDashboard: telemetryDashboard,
            telemetrySettings: telemetrySettings,
            meetingRecorder: meetingRecorder
        )
        if case .agentPopup = agentContent {
            // Success: agent popup outranks github alert
        } else {
            XCTFail("Agent popup must outrank GitHub alert")
        }
    }

    // MARK: - WP4: URL Converter Tests

    func testGitHubURLConverter() {
        let pullAPI = URL(string: "https://api.github.com/repos/AkramKs/bitz-mac/pulls/142")!
        let pullWeb = GitHubURLConverter.webURL(from: pullAPI)
        XCTAssertEqual(pullWeb?.absoluteString, "https://github.com/AkramKs/bitz-mac/pull/142")

        let issueAPI = URL(string: "https://api.github.com/repos/AkramKs/bitz-mac/issues/188")!
        let issueWeb = GitHubURLConverter.webURL(from: issueAPI)
        XCTAssertEqual(issueWeb?.absoluteString, "https://github.com/AkramKs/bitz-mac/issues/188")

        let checkSuiteAPI = URL(string: "https://api.github.com/repos/AkramKs/bitz-mac/check-suites/12345")!
        let checkSuiteWeb = GitHubURLConverter.webURL(from: checkSuiteAPI)
        XCTAssertEqual(checkSuiteWeb?.absoluteString, "https://github.com/AkramKs/bitz-mac/actions")

        let nonAPIURL = URL(string: "https://github.com/AkramKs/bitz-mac")!
        XCTAssertEqual(GitHubURLConverter.webURL(from: nonAPIURL)?.absoluteString, "https://github.com/AkramKs/bitz-mac")

        XCTAssertEqual(GitHubURLConverter.itemNumber(from: pullAPI), "142")
        XCTAssertEqual(GitHubURLConverter.itemNumber(from: issueAPI), "188")
        XCTAssertNil(GitHubURLConverter.itemNumber(from: nonAPIURL))
    }
}
