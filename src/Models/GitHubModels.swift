import Foundation

/// Strategy for resolving GitHub authentication credentials.
public enum GitHubAuthMode: String, CaseIterable, Identifiable, Sendable {
    case auto = "auto"
    case manualPAT = "manualPAT"

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .auto:
            return "Auto (GitHub CLI 'gh' or Keychain)"
        case .manualPAT:
            return "Personal Access Token (PAT)"
        }
    }
}

/// Identifies where the active GitHub token originated.
public enum GitHubAuthSource: String, Sendable, Equatable {
    case ghCLI = "gh CLI"
    case personalAccessToken = "Personal Access Token"
}

/// High-level authorization state for GitHub integration.
public enum GitHubAuthState: Equatable, Sendable {
    case unauthenticated
    case validating
    case authenticated(username: String, source: GitHubAuthSource)
    case error(String)

    public var isAuthenticated: Bool {
        if case .authenticated = self { return true }
        return false
    }

    public var displayTitle: String {
        switch self {
        case .unauthenticated:
            return "Not Connected"
        case .validating:
            return "Validating..."
        case .authenticated(let username, let source):
            return "Connected as @\(username) (\(source.rawValue))"
        case .error(let message):
            return "Error: \(message)"
        }
    }

    public var username: String? {
        if case .authenticated(let username, _) = self {
            return username
        }
        return nil
    }
}

/// Decoded GitHub user profile from `GET /user`.
public struct GitHubUser: Codable, Equatable, Sendable {
    public let login: String
    public let id: Int
    public let name: String?
    public let avatarUrl: String?

    enum CodingKeys: String, CodingKey {
        case login
        case id
        case name
        case avatarUrl = "avatar_url"
    }

    public init(login: String, id: Int, name: String? = nil, avatarUrl: String? = nil) {
        self.login = login
        self.id = id
        self.name = name
        self.avatarUrl = avatarUrl
    }
}

/// Decoded notification thread item from `GET /notifications`.
public struct GitHubNotification: Codable, Equatable, Identifiable, Sendable {
    public struct Subject: Codable, Equatable, Sendable {
        public let title: String
        public let url: URL?
        public let latestCommentUrl: URL?
        public let type: String

        enum CodingKeys: String, CodingKey {
            case title
            case url
            case latestCommentUrl = "latest_comment_url"
            case type
        }

        public init(
            title: String,
            url: URL? = nil,
            latestCommentUrl: URL? = nil,
            type: String = "PullRequest"
        ) {
            self.title = title
            self.url = url
            self.latestCommentUrl = latestCommentUrl
            self.type = type
        }
    }

    public struct Repository: Codable, Equatable, Identifiable, Sendable {
        public let id: Int
        public let name: String
        public let fullName: String
        public let htmlURL: URL?

        enum CodingKeys: String, CodingKey {
            case id
            case name
            case fullName = "full_name"
            case htmlURL = "html_url"
        }

        public init(
            id: Int,
            name: String,
            fullName: String,
            htmlURL: URL? = nil
        ) {
            self.id = id
            self.name = name
            self.fullName = fullName
            self.htmlURL = htmlURL
        }
    }

    public let id: String
    public let unread: Bool
    public let reason: String
    public let updatedAt: Date
    public let subject: Subject
    public let repository: Repository
    public let url: URL?

    enum CodingKeys: String, CodingKey {
        case id
        case unread
        case reason
        case updatedAt = "updated_at"
        case subject
        case repository
        case url
    }

    public init(
        id: String,
        unread: Bool = true,
        reason: String,
        updatedAt: Date = Date(),
        subject: Subject,
        repository: Repository,
        url: URL? = nil
    ) {
        self.id = id
        self.unread = unread
        self.reason = reason
        self.updatedAt = updatedAt
        self.subject = subject
        self.repository = repository
        self.url = url
    }
}

/// User activity event from `GET /users/{username}/events` (e.g. `PushEvent`, `CreateEvent`, `PullRequestEvent`).
public struct GitHubUserActivityEvent: Decodable, Equatable, Identifiable, Sendable {
    public struct EventRepo: Decodable, Equatable, Sendable {
        public let name: String

        public var shortName: String {
            name.split(separator: "/").last.map(String.init) ?? name
        }

        public init(name: String) {
            self.name = name
        }
    }

    public struct PullRequestRef: Decodable, Equatable, Sendable {
        public let number: Int?
        public let title: String?
        public let htmlURL: URL?

        enum CodingKeys: String, CodingKey {
            case number
            case title
            case htmlURL = "html_url"
        }

        public init(number: Int? = nil, title: String? = nil, htmlURL: URL? = nil) {
            self.number = number
            self.title = title
            self.htmlURL = htmlURL
        }
    }

    public struct ReleaseRef: Decodable, Equatable, Sendable {
        public let tagName: String?
        public let htmlURL: URL?

        enum CodingKeys: String, CodingKey {
            case tagName = "tag_name"
            case htmlURL = "html_url"
        }

        public init(tagName: String? = nil, htmlURL: URL? = nil) {
            self.tagName = tagName
            self.htmlURL = htmlURL
        }
    }

    public struct Payload: Decodable, Equatable, Sendable {
        public let ref: String?
        public let refType: String?
        public let size: Int?
        public let action: String?
        public let head: String?
        public let pullRequest: PullRequestRef?
        public let release: ReleaseRef?

        enum CodingKeys: String, CodingKey {
            case ref
            case refType = "ref_type"
            case size
            case action
            case head
            case pullRequest = "pull_request"
            case release
        }

        public init(
            ref: String? = nil,
            refType: String? = nil,
            size: Int? = nil,
            action: String? = nil,
            head: String? = nil,
            pullRequest: PullRequestRef? = nil,
            release: ReleaseRef? = nil
        ) {
            self.ref = ref
            self.refType = refType
            self.size = size
            self.action = action
            self.head = head
            self.pullRequest = pullRequest
            self.release = release
        }
    }

    public let id: String
    public let type: String
    public let repo: EventRepo
    public let payload: Payload?

    public init(id: String, type: String, repo: EventRepo, payload: Payload? = nil) {
        self.id = id
        self.type = type
        self.repo = repo
        self.payload = payload
    }
}

/// Response wrapper from `GET /repos/{owner}/{repo}/actions/runs`.
public struct GitHubWorkflowRunsResponse: Decodable, Sendable {
    public let workflowRuns: [GitHubWorkflowRun]

    enum CodingKeys: String, CodingKey {
        case workflowRuns = "workflow_runs"
    }
}

/// GitHub Actions workflow run summary.
public struct GitHubWorkflowRun: Decodable, Equatable, Identifiable, Sendable {
    public let id: Int
    public let name: String?
    public let status: String?
    public let conclusion: String?
    public let headBranch: String?
    public let htmlURL: URL?

    enum CodingKeys: String, CodingKey {
        case id
        case name
        case status
        case conclusion
        case headBranch = "head_branch"
        case htmlURL = "html_url"
    }

    public init(
        id: Int,
        name: String? = nil,
        status: String? = nil,
        conclusion: String? = nil,
        headBranch: String? = nil,
        htmlURL: URL? = nil
    ) {
        self.id = id
        self.name = name
        self.status = status
        self.conclusion = conclusion
        self.headBranch = headBranch
        self.htmlURL = htmlURL
    }
}

/// Alert model surfaced to Bitz's floating speech bubble when key GitHub developer events occur.
public struct GitHubEventAlert: Equatable, Hashable, Identifiable, Sendable {
    public enum Kind: String, Equatable, Hashable, Sendable {
        case reviewRequested
        case ciFailed
        case ciPassed
        case prStatus
        case mention
        case general
    }

    public let id: String
    public let kind: Kind
    public let title: String
    public let message: String
    public let repositoryName: String
    public let targetURL: URL?
    public let actionTitle: String

    public var isInteractive: Bool {
        // Any GitHub alert has action button(s) and a dismiss button
        true
    }

    public init(
        id: String = UUID().uuidString,
        kind: Kind,
        title: String,
        message: String,
        repositoryName: String,
        targetURL: URL? = nil,
        actionTitle: String = "VIEW PR"
    ) {
        self.id = id
        self.kind = kind
        self.title = title
        self.message = message
        self.repositoryName = repositoryName
        self.targetURL = targetURL
        self.actionTitle = actionTitle
    }
}

/// Utility for translating GitHub API resource URLs (e.g. `api.github.com/repos/.../pulls/142`)
/// into user-accessible browser URLs (`github.com/.../pull/142`).
public enum GitHubURLConverter: Sendable {
    public static func webURL(from apiURL: URL?, fallbackRepo: URL? = nil) -> URL? {
        guard let apiURL else { return fallbackRepo }
        let urlString = apiURL.absoluteString
        guard urlString.contains("api.github.com/repos/") else {
            return apiURL
        }

        var webString = urlString.replacingOccurrences(of: "https://api.github.com/repos/", with: "https://github.com/")
        if webString.contains("/pulls/") {
            webString = webString.replacingOccurrences(of: "/pulls/", with: "/pull/")
        } else if webString.contains("/check-suites/") {
            if let regex = try? NSRegularExpression(pattern: #"/check-suites/\d+"#) {
                let range = NSRange(webString.startIndex..., in: webString)
                webString = regex.stringByReplacingMatches(in: webString, options: [], range: range, withTemplate: "/actions")
            }
        }

        return URL(string: webString) ?? fallbackRepo
    }

    /// Extracts an item number (PR or Issue ID) from the trailing path component if numeric.
    public static func itemNumber(from apiURL: URL?) -> String? {
        guard let path = apiURL?.path else { return nil }
        let components = path.split(separator: "/")
        if let last = components.last, last.allSatisfy({ $0.isNumber }) {
            return String(last)
        }
        return nil
    }
}
