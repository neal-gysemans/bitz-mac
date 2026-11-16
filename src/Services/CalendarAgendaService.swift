import AppKit
import Combine
@preconcurrency import EventKit
import Foundation

/// Protocol abstracting calendar event store interactions for deterministic unit testing without requiring real EventKit permissions.
public protocol CalendarEventStoreProviding: AnyObject, Sendable {
    func authorizationStatus() -> CalendarAuthorizationStatus
    func requestAccess() async throws -> Bool
    func fetchEvents(from startDate: Date, to endDate: Date) async throws -> [CalendarEventSnapshot]
}

/// Production implementation backed by Apple's `EventKit` (`EKEventStore`).
public final class SystemCalendarEventStore: CalendarEventStoreProviding, @unchecked Sendable {
    private let eventStore = EKEventStore()

    public init() {}

    public func authorizationStatus() -> CalendarAuthorizationStatus {
        let status = EKEventStore.authorizationStatus(for: .event)
        switch status {
        case .notDetermined:
            return .notDetermined
        case .restricted:
            return .restricted
        case .denied:
            return .denied
        case .fullAccess, .authorized:
            return .fullAccess
        case .writeOnly:
            return .writeOnly
        @unknown default:
            return .notDetermined
        }
    }

    public func requestAccess() async throws -> Bool {
        if #available(macOS 14.0, *) {
            do {
                return try await eventStore.requestFullAccessToEvents()
            } catch {
                // Fallback to legacy requestAccess
            }
        }
        return try await withCheckedThrowingContinuation { continuation in
            eventStore.requestAccess(to: .event) { granted, error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume(returning: granted)
                }
            }
        }
    }

    public func fetchEvents(from startDate: Date, to endDate: Date) async throws -> [CalendarEventSnapshot] {
        return await Task.detached(priority: .userInitiated) { [eventStore] in
            let predicate = eventStore.predicateForEvents(withStart: startDate, end: endDate, calendars: nil)
            let ekEvents = eventStore.events(matching: predicate)

            return ekEvents.compactMap { ekEvent -> CalendarEventSnapshot? in
                // Filter out canceled events
                if ekEvent.status == .canceled { return nil }

                // Filter out events where the user explicitly declined
                if let attendees = ekEvent.attendees,
                   let me = attendees.first(where: { $0.isCurrentUser }),
                   me.participantStatus == .declined {
                    return nil
                }

                let meetingURL = MeetingURLParser.extractMeetingURL(
                    from: ekEvent.url,
                    notes: ekEvent.notes,
                    location: ekEvent.location
                )

                return CalendarEventSnapshot(
                    id: ekEvent.eventIdentifier ?? UUID().uuidString,
                    title: ekEvent.title ?? "Untitled Event",
                    startDate: ekEvent.startDate,
                    endDate: ekEvent.endDate,
                    isAllDay: ekEvent.isAllDay,
                    location: ekEvent.location,
                    meetingURL: meetingURL,
                    notes: ekEvent.notes
                )
            }
        }.value
    }
}

/// In-memory mock calendar event store for deterministic testing.
public final class MockCalendarEventStore: CalendarEventStoreProviding, @unchecked Sendable {
    public var status: CalendarAuthorizationStatus
    public var stubbedEvents: [CalendarEventSnapshot]
    public var requestAccessResult: Bool
    public var requestAccessCalled: Bool = false
    public var fetchEventsCallCount: Int = 0

    public init(
        status: CalendarAuthorizationStatus = .notDetermined,
        stubbedEvents: [CalendarEventSnapshot] = [],
        requestAccessResult: Bool = true
    ) {
        self.status = status
        self.stubbedEvents = stubbedEvents
        self.requestAccessResult = requestAccessResult
    }

    public func authorizationStatus() -> CalendarAuthorizationStatus {
        status
    }

    public func requestAccess() async throws -> Bool {
        requestAccessCalled = true
        if requestAccessResult {
            status = .fullAccess
        }
        return requestAccessResult
    }

    public func fetchEvents(from startDate: Date, to endDate: Date) async throws -> [CalendarEventSnapshot] {
        fetchEventsCallCount += 1
        return stubbedEvents.filter { event in
            event.startDate < endDate && event.endDate > startDate
        }
    }
}

/// `@MainActor` service coordinating macOS Calendar agenda access, meeting countdown alerts,
/// and morning/evening briefs via Bitz's floating speech bubble (#186).
@MainActor
public final class CalendarAgendaService: ObservableObject {
    public let settingsStore: CalendarSettingsStore
    public let storeProvider: any CalendarEventStoreProviding
    public let calendar: Calendar

    @Published public private(set) var authorizationStatus: CalendarAuthorizationStatus
    @Published public private(set) var todayEvents: [CalendarEventSnapshot] = []
    @Published public private(set) var tomorrowEvents: [CalendarEventSnapshot] = []
    @Published public private(set) var activeAlert: CalendarAgendaAlert? = nil
    @Published public private(set) var upcomingMeetingAlert: CalendarEventSnapshot? = nil
    @Published public private(set) var isRefreshing: Bool = false

    /// Closure invoked when the user clicks the "JOIN" video call button. Defaults to `NSWorkspace.shared.open`.
    public var onJoinMeeting: ((URL) -> Void)?

    /// Pluggable date provider for deterministic unit testing.
    public var dateProvider: () -> Date = { Date() }

    private var eventStoreChangedCancellable: AnyCancellable?
    private var dayChangedCancellable: AnyCancellable?
    private var settingsChangedCancellable: AnyCancellable?
    private var nextMeetingTask: Task<Void, Never>?
    private var alertDismissTask: Task<Void, Never>?
    private var alertedEventIDs: Set<String> = []
    private var lastMorningBriefDate: Date?
    private var lastEveningPreviewDate: Date?
    private var debounceReloadTask: Task<Void, Never>?

    public init(
        storeProvider: any CalendarEventStoreProviding = SystemCalendarEventStore(),
        settingsStore: CalendarSettingsStore = CalendarSettingsStore(),
        calendar: Calendar = .current
    ) {
        self.storeProvider = storeProvider
        self.settingsStore = settingsStore
        self.calendar = calendar
        self.authorizationStatus = storeProvider.authorizationStatus()

        self.onJoinMeeting = { url in
            NSWorkspace.shared.open(url)
        }
    }

    deinit {
        nextMeetingTask?.cancel()
        alertDismissTask?.cancel()
        debounceReloadTask?.cancel()
    }

    // MARK: - Lifecycle

    public func start() {
        authorizationStatus = storeProvider.authorizationStatus()

        // Listen for calendar modifications from macOS Calendar.app without continuous polling
        eventStoreChangedCancellable = NotificationCenter.default.publisher(for: .EKEventStoreChanged)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.handleEventStoreChanged()
            }

        // Midnight rollover resets daily brief counters and refreshes agenda
        dayChangedCancellable = NotificationCenter.default.publisher(for: .NSCalendarDayChanged)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.handleDayChanged()
            }

        // React to settings changes
        settingsChangedCancellable = settingsStore.$isEnabled
            .receive(on: DispatchQueue.main)
            .sink { [weak self] enabled in
                guard let self else { return }
                if enabled {
                    if self.authorizationStatus.isAuthorized {
                        Task { await self.refreshEvents() }
                    }
                } else {
                    self.stop()
                }
            }

        if settingsStore.isEnabled && authorizationStatus.isAuthorized {
            Task { await self.refreshEvents() }
        }
    }

    public func stop() {
        nextMeetingTask?.cancel()
        nextMeetingTask = nil
        alertDismissTask?.cancel()
        alertDismissTask = nil
        debounceReloadTask?.cancel()
        debounceReloadTask = nil
        activeAlert = nil
        upcomingMeetingAlert = nil
        todayEvents = []
        tomorrowEvents = []
    }

    // MARK: - Authorization

    public func requestAuthorization() async -> Bool {
        do {
            let granted = try await storeProvider.requestAccess()
            let status = storeProvider.authorizationStatus()
            self.authorizationStatus = granted ? .fullAccess : status
            if granted && self.authorizationStatus.isAuthorized {
                settingsStore.setEnabled(true)
                await refreshEvents()
                return true
            } else {
                return false
            }
        } catch {
            authorizationStatus = storeProvider.authorizationStatus()
            return false
        }
    }

    // MARK: - Event Fetching & Refresh

    public func refreshEvents(at currentDate: Date? = nil) async {
        guard settingsStore.isEnabled && authorizationStatus.isAuthorized else { return }
        isRefreshing = true
        defer { isRefreshing = false }

        let now = currentDate ?? dateProvider()
        let startOfToday = calendar.startOfDay(for: now)
        guard let endOfToday = calendar.date(byAdding: .day, value: 1, to: startOfToday),
              let endOfTomorrow = calendar.date(byAdding: .day, value: 2, to: startOfToday) else {
            return
        }

        do {
            async let fetchedToday = storeProvider.fetchEvents(from: startOfToday, to: endOfToday)
            async let fetchedTomorrow = storeProvider.fetchEvents(from: endOfToday, to: endOfTomorrow)

            let (today, tomorrow) = try await (fetchedToday, fetchedTomorrow)

            self.todayEvents = today.sorted { $0.startDate < $1.startDate }
            self.tomorrowEvents = tomorrow.sorted { $0.startDate < $1.startDate }

            // Clear alert state for events rescheduled to the future beyond the reminder offset
            let cutoff = now.addingTimeInterval(Double(settingsStore.reminderOffsetMinutes * 60))
            self.alertedEventIDs = self.alertedEventIDs.filter { eventID in
                guard let event = self.todayEvents.first(where: { $0.id == eventID }) else { return false }
                return event.startDate <= cutoff
            }

            self.scheduleNextMeetingAlert(at: now)
        } catch {
            // Keep existing cached events on error
        }
    }

    // MARK: - Upcoming Meeting Alert Scheduling

    public func scheduleNextMeetingAlert(at currentDate: Date? = nil) {
        nextMeetingTask?.cancel()
        nextMeetingTask = nil

        let now = currentDate ?? dateProvider()
        let offsetSeconds = Double(settingsStore.reminderOffsetMinutes * 60)

        // Find candidate non-all-day events today that haven't ended yet and haven't been alerted
        let upcoming = todayEvents.filter { event in
            !event.isAllDay && event.endDate > now && !alertedEventIDs.contains(event.id)
        }

        guard let nextEvent = upcoming.first else { return }

        let alertDate = nextEvent.startDate.addingTimeInterval(-offsetSeconds)

        if now >= alertDate {
            // Within alert window: trigger immediately
            triggerMeetingAlert(for: nextEvent, at: now)
        } else {
            // Schedule a one-shot task for the next alert
            let delay = max(0.1, alertDate.timeIntervalSince(now))
            nextMeetingTask = Task { @MainActor [weak self] in
                try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
                guard !Task.isCancelled else { return }
                self?.evaluateUpcomingMeetings()
            }
        }
    }

    public func evaluateUpcomingMeetings(at currentDate: Date? = nil) {
        let now = currentDate ?? dateProvider()
        scheduleNextMeetingAlert(at: now)
    }

    private func triggerMeetingAlert(for event: CalendarEventSnapshot, at now: Date) {
        alertedEventIDs.insert(event.id)

        let minutesRemaining = max(0, Int(round(event.startDate.timeIntervalSince(now) / 60.0)))
        let message: String
        if minutesRemaining <= 0 {
            message = "Meeting starting now: \(event.title) 📅"
        } else {
            message = "Meeting in \(minutesRemaining)m: \(event.title) 📅"
        }

        let alert = CalendarAgendaAlert(
            kind: .upcomingMeeting,
            message: message,
            event: event,
            meetingURL: settingsStore.showMeetingURLQuickJoin ? event.meetingURL : nil
        )

        self.activeAlert = alert
        self.upcomingMeetingAlert = event

        // Auto-dismiss alert after 90s or when meeting has started
        let dismissDelay = max(60.0, event.startDate.timeIntervalSince(now) + 30.0)
        alertDismissTask?.cancel()
        alertDismissTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(min(180.0, dismissDelay) * 1_000_000_000))
            guard !Task.isCancelled else { return }
            self?.dismissAlert()
        }
    }

    // MARK: - Daily Briefs

    public func checkDailyBriefs(continuousWorkMinutes: Double = 0, at currentDate: Date? = nil) {
        guard settingsStore.isEnabled && authorizationStatus.isAuthorized else { return }
        let now = currentDate ?? dateProvider()

        triggerMorningBriefIfEligible(at: now)
        triggerEveningPreviewIfEligible(at: now, continuousWorkMinutes: continuousWorkMinutes)
    }

    public func triggerMorningBriefIfEligible(at currentDate: Date? = nil) {
        guard settingsStore.isEnabled && settingsStore.isMorningBriefEnabled && authorizationStatus.isAuthorized else { return }
        let now = currentDate ?? dateProvider()

        let hour = calendar.component(.hour, from: now)
        guard hour >= 6 && hour < 12 else { return }

        if let last = lastMorningBriefDate, calendar.isDate(last, inSameDayAs: now) {
            return
        }

        // Avoid overriding an active meeting countdown alert
        guard activeAlert == nil else { return }

        let count = todayEvents.filter { !$0.isAllDay }.count
        let message: String
        if count == 0 {
            message = "Good morning! No meetings scheduled today ✨"
        } else if count == 1 {
            message = "Good morning! 1 meeting scheduled today 📅"
        } else {
            message = "Good morning! \(count) meetings scheduled today 📅"
        }

        let alert = CalendarAgendaAlert(kind: .morningBrief, message: message)
        self.activeAlert = alert
        self.lastMorningBriefDate = now

        alertDismissTask?.cancel()
        alertDismissTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 20_000_000_000)
            guard !Task.isCancelled else { return }
            if self?.activeAlert?.kind == .morningBrief {
                self?.dismissAlert()
            }
        }
    }

    public func triggerEveningPreviewIfEligible(at currentDate: Date? = nil, continuousWorkMinutes: Double = 0) {
        guard settingsStore.isEnabled && settingsStore.isEveningPreviewEnabled && authorizationStatus.isAuthorized else { return }
        let now = currentDate ?? dateProvider()

        let hour = calendar.component(.hour, from: now)
        let isAfterCutoff = hour >= 15
        let isWorkdayComplete = continuousWorkMinutes >= 480

        guard isAfterCutoff || isWorkdayComplete else { return }

        if let last = lastEveningPreviewDate, calendar.isDate(last, inSameDayAs: now) {
            return
        }

        guard activeAlert == nil else { return }

        let tomorrowMeetings = tomorrowEvents.filter { !$0.isAllDay }
        let message: String
        if tomorrowMeetings.isEmpty {
            message = "Tomorrow's radar: clear schedule ahead! ✨"
        } else {
            let first = tomorrowMeetings.first!
            let formatter = DateFormatter()
            formatter.dateFormat = "HH:mm"
            let timeStr = formatter.string(from: first.startDate)
            let count = tomorrowMeetings.count
            if count == 1 {
                message = "Tomorrow's radar: 1 meeting starting with \(first.title) at \(timeStr)"
            } else {
                message = "Tomorrow's radar: \(count) meetings starting with \(first.title) at \(timeStr)"
            }
        }

        let alert = CalendarAgendaAlert(kind: .eveningPreview, message: message)
        self.activeAlert = alert
        self.lastEveningPreviewDate = now

        alertDismissTask?.cancel()
        alertDismissTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 20_000_000_000)
            guard !Task.isCancelled else { return }
            if self?.activeAlert?.kind == .eveningPreview {
                self?.dismissAlert()
            }
        }
    }

    // MARK: - User Actions

    public func dismissAlert() {
        alertDismissTask?.cancel()
        alertDismissTask = nil
        activeAlert = nil
        upcomingMeetingAlert = nil
    }

    public func setActiveAlertForTesting(_ alert: CalendarAgendaAlert?) {
        self.activeAlert = alert
    }

    public func joinMeeting(for event: CalendarEventSnapshot) {
        if let url = event.meetingURL {
            onJoinMeeting?(url)
        }
        dismissAlert()
    }

    // MARK: - Private Notification Handlers

    private func handleEventStoreChanged() {
        // Debounce calendar change notifications by 1 second to avoid query thrashing
        debounceReloadTask?.cancel()
        debounceReloadTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            guard !Task.isCancelled else { return }
            await self?.refreshEvents()
        }
    }

    private func handleDayChanged() {
        alertedEventIDs.removeAll()
        lastMorningBriefDate = nil
        lastEveningPreviewDate = nil
        Task { await refreshEvents() }
    }
}
