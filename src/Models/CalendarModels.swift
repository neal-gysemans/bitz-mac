import Foundation

/// macOS Calendar authorization state abstracted for deterministic testability and UI status badges.
public enum CalendarAuthorizationStatus: String, Sendable, CaseIterable, Equatable {
    case notDetermined
    case restricted
    case denied
    case fullAccess
    case writeOnly

    public var displayTitle: String {
        switch self {
        case .notDetermined:
            return "Not Connected"
        case .restricted:
            return "Restricted"
        case .denied:
            return "Access Denied"
        case .fullAccess:
            return "Connected"
        case .writeOnly:
            return "Write Only"
        }
    }

    public var isAuthorized: Bool {
        self == .fullAccess
    }
}

/// Immutable snapshot of a calendar event, decoupled from EventKit.
public struct CalendarEventSnapshot: Equatable, Hashable, Identifiable, Sendable {
    public let id: String
    public let title: String
    public let startDate: Date
    public let endDate: Date
    public let isAllDay: Bool
    public let location: String?
    public let meetingURL: URL?
    public let notes: String?

    public init(
        id: String,
        title: String,
        startDate: Date,
        endDate: Date,
        isAllDay: Bool = false,
        location: String? = nil,
        meetingURL: URL? = nil,
        notes: String? = nil
    ) {
        self.id = id
        self.title = title.isEmpty ? "Untitled Event" : title
        self.startDate = startDate
        self.endDate = endDate
        self.isAllDay = isAllDay
        self.location = location
        self.meetingURL = meetingURL
        self.notes = notes
    }
}

/// Notification/alert model surfaced through Bitz's floating speech bubble.
public struct CalendarAgendaAlert: Equatable, Hashable, Identifiable, Sendable {
    public enum Kind: String, Equatable, Hashable, Sendable {
        case upcomingMeeting
        case morningBrief
        case eveningPreview
    }

    public let id: String
    public let kind: Kind
    public let message: String
    public let event: CalendarEventSnapshot?
    public let meetingURL: URL?

    public var isInteractive: Bool {
        // Any calendar alert has at least a dismiss / "GOT IT" or "JOIN" button
        true
    }

    public init(
        id: String = UUID().uuidString,
        kind: Kind,
        message: String,
        event: CalendarEventSnapshot? = nil,
        meetingURL: URL? = nil
    ) {
        self.id = id
        self.kind = kind
        self.message = message
        self.event = event
        self.meetingURL = meetingURL ?? event?.meetingURL
    }
}

/// Video call & meeting URL parser detecting Zoom, Google Meet, Microsoft Teams, and Webex links.
public enum MeetingURLParser {
    // Standard meeting host patterns
    private static let meetingURLRegexPattern = #"(https?://(?:[a-zA-Z0-9_\-.]+\.)?(?:zoom\.us/(?:j|my)/[a-zA-Z0-9_?&=#\-]+|meet\.google\.com/[a-zA-Z0-9_\-]+|teams\.(?:microsoft|live)\.com/(?:l/meetup-join|meet)/[^\s<>"']+|webex\.com/(?:meet|join|[a-zA-Z0-9_\-]+/[^\s<>"']+)|chime\.aws/[a-zA-Z0-9_\-]+))"#

    private static let regex: NSRegularExpression? = {
        try? NSRegularExpression(pattern: meetingURLRegexPattern, options: [.caseInsensitive])
    }()

    /// Checks if a given URL is directly a recognized video meeting link.
    public static func isMeetingURL(_ url: URL) -> Bool {
        guard let host = url.host?.lowercased() else { return false }
        if host.contains("meet.google.com") { return true }
        if host.contains("zoom.us") {
            let path = url.path.lowercased()
            return path.contains("/j/") || path.contains("/my/")
        }
        if host.contains("teams.microsoft.com") || host.contains("teams.live.com") {
            let path = url.path.lowercased()
            return path.contains("meetup-join") || path.contains("meet")
        }
        if host.contains("webex.com") { return true }
        if host.contains("chime.aws") { return true }
        return false
    }

    /// Extracts a meeting URL from `url`, `notes`, or `location` fields.
    public static func extractMeetingURL(from url: URL?, notes: String?, location: String?) -> URL? {
        if let url, isMeetingURL(url) {
            return url
        }

        // Search text content (notes then location)
        for text in [notes, location].compactMap({ $0 }) where !text.isEmpty {
            if let matched = findFirstMeetingURL(in: text) {
                return matched
            }
        }

        return nil
    }

    private static func findFirstMeetingURL(in text: String) -> URL? {
        guard let regex else { return nil }
        let nsRange = NSRange(text.startIndex..<text.endIndex, in: text)
        guard let match = regex.firstMatch(in: text, options: [], range: nsRange),
              let range = Range(match.range, in: text) else {
            return nil
        }
        let urlString = String(text[range])
        return URL(string: urlString)
    }
}
