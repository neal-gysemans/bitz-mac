import AppKit
import Combine
import Foundation

/// Errors that can occur during GitHub API communication and notification parsing.
public enum GitHubServiceError: Error, Sendable, Equatable {
    case unauthenticated
    case invalidHTTPResponse
    case apiError(statusCode: Int, message: String)
    case decodingFailed(String)
    case networkError(String)
}

/// Abstract network client for deterministic unit testing without live network calls.
public protocol HTTPRequestPerforming: AnyObject, Sendable {
    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse)
}

/// Production network requester using system `URLSession`.
public final class URLSessionHTTPRequester: HTTPRequestPerforming, @unchecked Sendable {
    private let session: URLSession

    public init(session: URLSession = .shared) {
        self.session = session
    }

    public func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let (data, response) = try await session.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw GitHubServiceError.invalidHTTPResponse
        }
        return (data, httpResponse)
    }
}

/// In-memory mock HTTP requester for testing and fixtures.
public final class MockHTTPRequester: HTTPRequestPerforming, @unchecked Sendable {
    public var requestHandler: (@Sendable (URLRequest) async throws -> (Data, HTTPURLResponse))?

    public init(requestHandler: (@Sendable (URLRequest) async throws -> (Data, HTTPURLResponse))? = nil) {
        self.requestHandler = requestHandler
    }

    public func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        if let handler = requestHandler {
            return try await handler(request)
        }
        let response = HTTPURLResponse(url: request.url ?? URL(string: "https://api.github.com")!, statusCode: 200, httpVersion: nil, headerFields: nil)!
        return (Data(), response)
    }
}

/// `@MainActor` service coordinating GitHub notification monitoring, conditional polling,
/// review requests, and CI/PR status speech bubbles (#188).
@MainActor
public final class GitHubNotificationService: ObservableObject {
    nonisolated public static let notificationsURL = URL(string: "https://api.github.com/notifications")!
    nonisolated public static let userURL = URL(string: "https://api.github.com/user")!

    public let settingsStore: GitHubSettingsStore
    public let credentialsStore: GitHubCredentialsStore
    public let httpRequester: any HTTPRequestPerforming
    public let clock: @Sendable () -> Date

    @Published public private(set) var authState: GitHubAuthState = .unauthenticated
    @Published public private(set) var activeAlert: GitHubEventAlert? = nil
    @Published public private(set) var isPolling: Bool = false
    @Published public private(set) var lastPollDate: Date? = nil
    @Published public private(set) var lastStatusCode: Int? = nil

    /// Closure invoked when opening a PR or CI logs URL. Defaults to `NSWorkspace.shared.open`.
    public var onOpenURL: ((URL) -> Void)?

    /// Closure invoked when an alert arrives, allowing audio chime integration.
    public var onPlaySound: ((CyberSoundEvent) -> Void)?

    private var pollTask: Task<Void, Never>?
    private var alertDismissTask: Task<Void, Never>?
    private var settingsCancellables = Set<AnyCancellable>()

    private var cachedETag: String?
    private var cachedLastModified: String?
    private var seenNotificationIDs = Set<String>()
    private var isSeeded: Bool = false

    public init(
        settingsStore: GitHubSettingsStore = GitHubSettingsStore(),
        credentialsStore: GitHubCredentialsStore = GitHubCredentialsStore(),
        httpRequester: any HTTPRequestPerforming = URLSessionHTTPRequester(),
        clock: @escaping @Sendable () -> Date = Date.init
    ) {
        self.settingsStore = settingsStore
        self.credentialsStore = credentialsStore
        self.httpRequester = httpRequester
        self.clock = clock

        self.onOpenURL = { url in
            NSWorkspace.shared.open(url)
        }

        bindSettings()
    }

    deinit {
        pollTask?.cancel()
        alertDismissTask?.cancel()
    }

    // MARK: - Lifecycle

    public func start() {
        guard settingsStore.isEnabled else { return }

        Task {
            await checkAuthentication()
            if authState.isAuthenticated {
                startPollingLoop()
            }
        }
    }

    public func stop() {
        pollTask?.cancel()
        pollTask = nil
        isPolling = false
    }

    private func bindSettings() {
        settingsStore.$isEnabled
            .receive(on: DispatchQueue.main)
            .sink { [weak self] enabled in
                guard let self else { return }
                if enabled {
                    self.start()
                } else {
                    self.stop()
                    self.dismissAlert()
                }
            }
            .store(in: &settingsCancellables)

        settingsStore.$authMode
            .dropFirst()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                guard let self else { return }
                Task {
                    await self.checkAuthentication()
                    if self.settingsStore.isEnabled && self.authState.isAuthenticated {
                        self.restartPollingLoop()
                    }
                }
            }
            .store(in: &settingsCancellables)

        settingsStore.$pollIntervalSeconds
            .dropFirst()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                guard let self else { return }
                if self.settingsStore.isEnabled && self.authState.isAuthenticated {
                    self.restartPollingLoop()
                }
            }
            .store(in: &settingsCancellables)
    }

    // MARK: - Authentication

    @discardableResult
    public func checkAuthentication() async -> GitHubAuthState {
        authState = .validating

        guard let (token, source) = await credentialsStore.activeToken(mode: settingsStore.authMode) else {
            let state: GitHubAuthState = .unauthenticated
            self.authState = state
            return state
        }

        do {
            let user = try await validateToken(token)
            let state: GitHubAuthState = .authenticated(username: user.login, source: source)
            self.authState = state
            return state
        } catch {
            let message = (error as? GitHubServiceError).map { err in
                switch err {
                case .apiError(let code, let msg): return "HTTP \(code): \(msg)"
                default: return error.localizedDescription
                }
            } ?? error.localizedDescription
            let state: GitHubAuthState = .error(message)
            self.authState = state
            return state
        }
    }

    public func validateToken(_ token: String) async throws -> GitHubUser {
        var request = URLRequest(url: Self.userURL)
        request.httpMethod = "GET"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")
        request.setValue("Bitz-CyberCat", forHTTPHeaderField: "User-Agent")

        let (data, response) = try await httpRequester.data(for: request)

        guard response.statusCode == 200 else {
            let errorMsg = String(data: data, encoding: .utf8) ?? "Unauthorized"
            throw GitHubServiceError.apiError(statusCode: response.statusCode, message: errorMsg)
        }

        do {
            let user = try JSONDecoder().decode(GitHubUser.self, from: data)
            return user
        } catch {
            throw GitHubServiceError.decodingFailed(error.localizedDescription)
        }
    }

    // MARK: - Polling Engine

    private func restartPollingLoop() {
        stop()
        startPollingLoop()
    }

    private func startPollingLoop() {
        guard pollTask == nil else { return }

        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { break }

                await self.pollNotificationsOnce()

                let interval = TimeInterval(self.settingsStore.pollIntervalSeconds)
                try? await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))
            }
        }
    }

    public func pollNotificationsOnce() async {
        guard let (token, _) = await credentialsStore.activeToken(mode: settingsStore.authMode) else {
            authState = .unauthenticated
            return
        }

        isPolling = true
        defer { isPolling = false }

        var request = URLRequest(url: Self.notificationsURL)
        request.httpMethod = "GET"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")
        request.setValue("Bitz-CyberCat", forHTTPHeaderField: "User-Agent")

        if let etag = cachedETag {
            request.setValue(etag, forHTTPHeaderField: "If-None-Match")
        }
        if let lastModified = cachedLastModified {
            request.setValue(lastModified, forHTTPHeaderField: "If-Modified-Since")
        }

        do {
            let (data, response) = try await httpRequester.data(for: request)
            lastStatusCode = response.statusCode
            lastPollDate = clock()

            // 304 Not Modified: zero new notifications, zero rate limit impact
            if response.statusCode == 304 {
                return
            }

            guard response.statusCode == 200 else {
                if response.statusCode == 401 || response.statusCode == 403 {
                    authState = .error("Authentication expired or rate limited (HTTP \(response.statusCode))")
                }
                return
            }

            // Save caching headers for subsequent conditional requests
            if let etag = response.value(forHTTPHeaderField: "ETag") ?? response.value(forHTTPHeaderField: "Etag") {
                cachedETag = etag
            }
            if let lastModified = response.value(forHTTPHeaderField: "Last-Modified") {
                cachedLastModified = lastModified
            }

            let notifications = try decodeNotifications(from: data)
            handleIncomingNotifications(notifications)
        } catch {
            // Transient network failure: keep calm and preserve battery
        }
    }

    private func decodeNotifications(from data: Data) throws -> [GitHubNotification] {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { d in
            let container = try d.singleValueContainer()
            let dateStr = try container.decode(String.self)
            if let date = try? Date(dateStr, strategy: .iso8601) {
                return date
            }
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            if let date = formatter.date(from: dateStr) {
                return date
            }
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Invalid ISO8601 date: \(dateStr)")
        }

        return try decoder.decode([GitHubNotification].self, from: data)
    }

    public func handleIncomingNotifications(_ notifications: [GitHubNotification]) {
        // Startup seeding: record current notifications without blasting alerts for old unread items
        if !isSeeded {
            for n in notifications {
                seenNotificationIDs.insert(n.id)
            }
            isSeeded = true
            return
        }

        let newItems = notifications.filter { $0.unread && !seenNotificationIDs.contains($0.id) }
        guard !newItems.isEmpty else { return }

        for item in newItems {
            seenNotificationIDs.insert(item.id)
        }

        // Generate alert for the highest priority incoming notification
        for item in newItems {
            if let alert = makeAlert(from: item) {
                presentAlert(alert)
                break
            }
        }
    }

    public func makeAlert(from item: GitHubNotification) -> GitHubEventAlert? {
        let repoName = item.repository.name
        let title = item.subject.title
        let targetURL = GitHubURLConverter.webURL(from: item.subject.url, fallbackRepo: item.repository.htmlURL)
        let itemNum = GitHubURLConverter.itemNumber(from: item.subject.url).map { "#\($0)" } ?? ""

        switch item.reason {
        case "review_requested":
            guard settingsStore.notifyReviewRequests else { return nil }
            let msg = itemNum.isEmpty
                ? "Review requested on \(repoName): \(title)"
                : "Review requested on \(repoName): \(itemNum) (\(title))"
            return GitHubEventAlert(
                id: item.id,
                kind: .reviewRequested,
                title: "🔍 Review Requested",
                message: msg,
                repositoryName: repoName,
                targetURL: targetURL,
                actionTitle: "VIEW PR"
            )

        case "ci_activity":
            let isFailure = title.localizedCaseInsensitiveContains("fail")
                || title.localizedCaseInsensitiveContains("cancel")
                || title.localizedCaseInsensitiveContains("error")
            if isFailure {
                guard settingsStore.notifyCIFailures else { return nil }
                return GitHubEventAlert(
                    id: item.id,
                    kind: .ciFailed,
                    title: "🚨 CI Failed",
                    message: "CI failed on \(repoName): \(title)",
                    repositoryName: repoName,
                    targetURL: targetURL,
                    actionTitle: "VIEW LOGS"
                )
            } else {
                guard settingsStore.notifyCIPasses else { return nil }
                return GitHubEventAlert(
                    id: item.id,
                    kind: .ciPassed,
                    title: "✅ CI Passed",
                    message: "CI passed on \(repoName): \(title)",
                    repositoryName: repoName,
                    targetURL: targetURL,
                    actionTitle: "VIEW LOGS"
                )
            }

        case "state_change":
            guard settingsStore.notifyPRStatus else { return nil }
            let isMerged = title.localizedCaseInsensitiveContains("merge")
            let badgeTitle = isMerged ? "🎉 PR Merged" : "PR Updated"
            return GitHubEventAlert(
                id: item.id,
                kind: .prStatus,
                title: badgeTitle,
                message: "\(itemNum.isEmpty ? "" : "\(itemNum): ")\(title) (\(repoName))",
                repositoryName: repoName,
                targetURL: targetURL,
                actionTitle: "VIEW PR"
            )

        case "approval_requested":
            guard settingsStore.notifyPRStatus else { return nil }
            return GitHubEventAlert(
                id: item.id,
                kind: .prStatus,
                title: "🚀 Approval Needed",
                message: "\(title) (\(repoName))",
                repositoryName: repoName,
                targetURL: targetURL,
                actionTitle: "VIEW"
            )

        case "mention":
            return GitHubEventAlert(
                id: item.id,
                kind: .mention,
                title: "💬 Mentioned",
                message: "Mentioned in \(repoName): \(title)",
                repositoryName: repoName,
                targetURL: targetURL,
                actionTitle: "VIEW"
            )

        default:
            // Check if CheckSuite or WorkflowRun by type
            if item.subject.type == "CheckSuite" || item.subject.type == "WorkflowRun" {
                let isFailure = title.localizedCaseInsensitiveContains("fail")
                if isFailure && settingsStore.notifyCIFailures {
                    return GitHubEventAlert(
                        id: item.id,
                        kind: .ciFailed,
                        title: "🚨 CI Failed",
                        message: "CI failed on \(repoName): \(title)",
                        repositoryName: repoName,
                        targetURL: targetURL,
                        actionTitle: "VIEW LOGS"
                    )
                } else if !isFailure && settingsStore.notifyCIPasses {
                    return GitHubEventAlert(
                        id: item.id,
                        kind: .ciPassed,
                        title: "✅ CI Passed",
                        message: "CI passed on \(repoName): \(title)",
                        repositoryName: repoName,
                        targetURL: targetURL,
                        actionTitle: "VIEW LOGS"
                    )
                }
            }
            return nil
        }
    }

    // MARK: - Alert Presentation & Interaction

    public func presentAlert(_ alert: GitHubEventAlert) {
        activeAlert = alert
        onPlaySound?(.agentNeedsApproval)

        // Auto-dismiss after 60 seconds if unacknowledged
        alertDismissTask?.cancel()
        alertDismissTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 60 * 1_000_000_000)
            guard !Task.isCancelled else { return }
            self?.dismissAlert()
        }
    }

    public func dismissAlert() {
        alertDismissTask?.cancel()
        alertDismissTask = nil
        activeAlert = nil
    }

    public func openTargetURL(for alert: GitHubEventAlert) {
        if let targetURL = alert.targetURL {
            onOpenURL?(targetURL)
        }
        dismissAlert()
    }

    public func triggerTestAlert() {
        let testAlert = GitHubEventAlert(
            kind: .reviewRequested,
            title: "🔍 Review Requested",
            message: "Review requested on bitz-mac: #188 (GitHub Notifications & PR Watcher)",
            repositoryName: "bitz-mac",
            targetURL: URL(string: "https://github.com/AkramKs/bitz-mac/issues/188"),
            actionTitle: "VIEW PR"
        )
        presentAlert(testAlert)
    }

    public func setActiveAlertForTesting(_ alert: GitHubEventAlert?) {
        activeAlert = alert
    }

    public func setSeededForTesting(_ seeded: Bool) {
        isSeeded = seeded
    }
}
