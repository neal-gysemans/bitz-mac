import AppKit
import Combine
import SwiftUI
import XCTest
@testable import BitzCore

@MainActor
final class CalendarAgendaServiceTests: XCTestCase {
    private var defaults: UserDefaults!
    private var suiteName: String!

    override func setUp() async throws {
        suiteName = "CalendarAgendaServiceTests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)!
    }

    override func tearDown() async throws {
        defaults.removePersistentDomain(forName: suiteName)
    }

    // MARK: - WP2: Meeting URL Parser Tests

    func testMeetingURLParser_DetectsGoogleMeet() {
        let url = URL(string: "https://meet.google.com/abc-defg-hij")!
        XCTAssertTrue(MeetingURLParser.isMeetingURL(url))

        let parsedFromURL = MeetingURLParser.extractMeetingURL(from: url, notes: nil, location: nil)
        XCTAssertEqual(parsedFromURL, url)

        let notes = "Join the call here: https://meet.google.com/xyz-uvwx-rst and review PR"
        let parsedFromNotes = MeetingURLParser.extractMeetingURL(from: nil, notes: notes, location: nil)
        XCTAssertEqual(parsedFromNotes?.absoluteString, "https://meet.google.com/xyz-uvwx-rst")

        let location = "Room 3, https://meet.google.com/foo-bar-baz"
        let parsedFromLocation = MeetingURLParser.extractMeetingURL(from: nil, notes: nil, location: location)
        XCTAssertEqual(parsedFromLocation?.absoluteString, "https://meet.google.com/foo-bar-baz")
    }

    func testMeetingURLParser_DetectsZoom() {
        let zoomURL = URL(string: "https://us02web.zoom.us/j/1234567890?pwd=secretPassword123")!
        XCTAssertTrue(MeetingURLParser.isMeetingURL(zoomURL))

        let parsedDirect = MeetingURLParser.extractMeetingURL(from: zoomURL, notes: nil, location: nil)
        XCTAssertEqual(parsedDirect, zoomURL)

        let notes = "Team sync!\nhttps://zoom.us/j/9876543210\nPasscode: 42"
        let parsedNotes = MeetingURLParser.extractMeetingURL(from: nil, notes: notes, location: nil)
        XCTAssertEqual(parsedNotes?.absoluteString, "https://zoom.us/j/9876543210")

        let vanityNotes = "Personal meeting: https://myteam.zoom.us/my/johnsmith"
        let parsedVanity = MeetingURLParser.extractMeetingURL(from: nil, notes: vanityNotes, location: nil)
        XCTAssertEqual(parsedVanity?.absoluteString, "https://myteam.zoom.us/my/johnsmith")
    }

    func testMeetingURLParser_DetectsMicrosoftTeams() {
        let teamsURL = URL(string: "https://teams.microsoft.com/l/meetup-join/19%3ameeting_xyz%40thread.v2/0?context=%7b%22Tid%22%3a%22abc%22%7d")!
        XCTAssertTrue(MeetingURLParser.isMeetingURL(teamsURL))

        let parsedDirect = MeetingURLParser.extractMeetingURL(from: teamsURL, notes: nil, location: nil)
        XCTAssertEqual(parsedDirect, teamsURL)

        let liveURL = URL(string: "https://teams.live.com/meet/987654321")!
        XCTAssertTrue(MeetingURLParser.isMeetingURL(liveURL))
    }

    func testMeetingURLParser_DetectsWebexAndChime() {
        let webexURL = URL(string: "https://company.webex.com/meet/akram")!
        XCTAssertTrue(MeetingURLParser.isMeetingURL(webexURL))
        XCTAssertEqual(MeetingURLParser.extractMeetingURL(from: webexURL, notes: nil, location: nil), webexURL)

        let chimeURL = URL(string: "https://app.chime.aws/meet/123456789")!
        XCTAssertTrue(MeetingURLParser.isMeetingURL(chimeURL))
        XCTAssertEqual(MeetingURLParser.extractMeetingURL(from: chimeURL, notes: nil, location: nil), chimeURL)
    }

    func testMeetingURLParser_RejectsNonMeetingURLs() {
        let gitHubURL = URL(string: "https://github.com/AkramKs/bitz-mac")!
        XCTAssertFalse(MeetingURLParser.isMeetingURL(gitHubURL))
        XCTAssertNil(MeetingURLParser.extractMeetingURL(from: gitHubURL, notes: "Code review", location: "GitHub"))

        let genericWeb = "Check https://apple.com and https://google.com/search?q=bitz"
        XCTAssertNil(MeetingURLParser.extractMeetingURL(from: nil, notes: genericWeb, location: nil))
        XCTAssertNil(MeetingURLParser.extractMeetingURL(from: nil, notes: nil, location: nil))
    }

    // MARK: - WP1: Settings Store Tests

    func testCalendarSettingsStore_DefaultsAndPersistence() {
        let store = CalendarSettingsStore(userDefaults: defaults)

        // Strict default: OFF to guarantee zero unexpected battery/resource usage
        XCTAssertFalse(store.isEnabled)
        XCTAssertEqual(store.reminderOffsetMinutes, 10)
        XCTAssertTrue(store.isMorningBriefEnabled)
        XCTAssertTrue(store.isEveningPreviewEnabled)
        XCTAssertTrue(store.showMeetingURLQuickJoin)

        // Mutators and persistence
        store.setEnabled(true)
        XCTAssertTrue(store.isEnabled)

        store.setReminderOffsetMinutes(15)
        XCTAssertEqual(store.reminderOffsetMinutes, 15)

        store.setMorningBriefEnabled(false)
        XCTAssertFalse(store.isMorningBriefEnabled)

        store.setEveningPreviewEnabled(false)
        XCTAssertFalse(store.isEveningPreviewEnabled)

        store.setShowMeetingURLQuickJoin(false)
        XCTAssertFalse(store.showMeetingURLQuickJoin)

        // Reinstantiate to test persistence
        let reloaded = CalendarSettingsStore(userDefaults: defaults)
        XCTAssertTrue(reloaded.isEnabled)
        XCTAssertEqual(reloaded.reminderOffsetMinutes, 15)
        XCTAssertFalse(reloaded.isMorningBriefEnabled)
        XCTAssertFalse(reloaded.isEveningPreviewEnabled)
        XCTAssertFalse(reloaded.showMeetingURLQuickJoin)
    }

    // MARK: - WP1: Service Authorization & Refresh Tests

    func testCalendarAgendaService_InitialStatusAndAuthorizationRequest() async {
        let mockStore = MockCalendarEventStore(status: .notDetermined, requestAccessResult: true)
        let settings = CalendarSettingsStore(userDefaults: defaults)
        let service = CalendarAgendaService(storeProvider: mockStore, settingsStore: settings)

        XCTAssertEqual(service.authorizationStatus, .notDetermined)
        XCTAssertFalse(service.authorizationStatus.isAuthorized)

        let granted = await service.requestAuthorization()
        XCTAssertTrue(granted)
        XCTAssertTrue(mockStore.requestAccessCalled)
        XCTAssertEqual(service.authorizationStatus, .fullAccess)
        XCTAssertTrue(service.authorizationStatus.isAuthorized)
        XCTAssertTrue(settings.isEnabled)
    }

    func testCalendarAgendaService_AuthorizationDenied() async {
        let mockStore = MockCalendarEventStore(status: .notDetermined, requestAccessResult: false)
        let settings = CalendarSettingsStore(userDefaults: defaults)
        let service = CalendarAgendaService(storeProvider: mockStore, settingsStore: settings)

        let granted = await service.requestAuthorization()
        XCTAssertFalse(granted)
        XCTAssertFalse(settings.isEnabled)
    }

    func testCalendarAgendaService_RefreshEventsFiltersAndSorts() async {
        let now = Date(timeIntervalSince1970: 1700000000) // Deterministic reference date
        let cal = Calendar.current
        let startOfToday = cal.startOfDay(for: now)

        let event1 = CalendarEventSnapshot(
            id: "ev1",
            title: "Sprint Planning",
            startDate: startOfToday.addingTimeInterval(3600 * 10), // 10:00 AM
            endDate: startOfToday.addingTimeInterval(3600 * 11),
            isAllDay: false,
            meetingURL: URL(string: "https://meet.google.com/abc-defg-hij")
        )
        let event2 = CalendarEventSnapshot(
            id: "ev2",
            title: "Daily Standup",
            startDate: startOfToday.addingTimeInterval(3600 * 9), // 09:00 AM (earlier)
            endDate: startOfToday.addingTimeInterval(3600 * 9.5),
            isAllDay: false
        )
        let eventTomorrow = CalendarEventSnapshot(
            id: "ev3",
            title: "Design Review",
            startDate: startOfToday.addingTimeInterval(3600 * 34), // Tomorrow 10:00 AM
            endDate: startOfToday.addingTimeInterval(3600 * 35),
            isAllDay: false
        )

        let mockStore = MockCalendarEventStore(
            status: .fullAccess,
            stubbedEvents: [event1, event2, eventTomorrow]
        )
        let settings = CalendarSettingsStore(userDefaults: defaults)
        settings.setEnabled(true)

        let service = CalendarAgendaService(storeProvider: mockStore, settingsStore: settings, calendar: cal)
        service.dateProvider = { now }

        await service.refreshEvents(at: now)

        // Today's events should be sorted chronologically: ev2 (09:00) before ev1 (10:00)
        XCTAssertEqual(service.todayEvents.count, 2)
        XCTAssertEqual(service.todayEvents[0].id, "ev2")
        XCTAssertEqual(service.todayEvents[1].id, "ev1")

        // Tomorrow's events should include ev3
        XCTAssertEqual(service.tomorrowEvents.count, 1)
        XCTAssertEqual(service.tomorrowEvents[0].id, "ev3")
    }

    // MARK: - WP3 & WP4: Upcoming Meeting Alerts & 1-Click Join

    func testCalendarAgendaService_UpcomingMeetingAlertCountdown() async {
        let now = Date(timeIntervalSince1970: 1700000000)
        let cal = Calendar.current

        // Meeting starts in exactly 10 minutes
        let meetingStart = now.addingTimeInterval(600)
        let event = CalendarEventSnapshot(
            id: "meet-1",
            title: "Sprint Planning",
            startDate: meetingStart,
            endDate: meetingStart.addingTimeInterval(1800),
            isAllDay: false,
            meetingURL: URL(string: "https://meet.google.com/abc-defg-hij")
        )

        let mockStore = MockCalendarEventStore(status: .fullAccess, stubbedEvents: [event])
        let settings = CalendarSettingsStore(userDefaults: defaults)
        settings.setEnabled(true)
        settings.setReminderOffsetMinutes(10)

        let service = CalendarAgendaService(storeProvider: mockStore, settingsStore: settings, calendar: cal)
        service.dateProvider = { now }

        await service.refreshEvents(at: now)

        XCTAssertNotNil(service.activeAlert)
        XCTAssertEqual(service.activeAlert?.kind, .upcomingMeeting)
        XCTAssertEqual(service.activeAlert?.message, "Meeting in 10m: Sprint Planning 📅")
        XCTAssertEqual(service.activeAlert?.meetingURL, URL(string: "https://meet.google.com/abc-defg-hij"))
        XCTAssertEqual(service.upcomingMeetingAlert?.id, "meet-1")

        // Deduplication: re-evaluating should not duplicate or clear
        service.evaluateUpcomingMeetings(at: now)
        XCTAssertEqual(service.activeAlert?.event?.id, "meet-1")
    }

    func testCalendarAgendaService_1ClickJoinMeeting() async {
        let now = Date(timeIntervalSince1970: 1700000000)
        let meetingURL = URL(string: "https://zoom.us/j/1234567890")!
        let event = CalendarEventSnapshot(
            id: "meet-zoom",
            title: "Client Sync",
            startDate: now.addingTimeInterval(300),
            endDate: now.addingTimeInterval(1800),
            isAllDay: false,
            meetingURL: meetingURL
        )

        let mockStore = MockCalendarEventStore(status: .fullAccess, stubbedEvents: [event])
        let settings = CalendarSettingsStore(userDefaults: defaults)
        settings.setEnabled(true)

        let service = CalendarAgendaService(storeProvider: mockStore, settingsStore: settings)
        service.dateProvider = { now }

        var openedURL: URL?
        service.onJoinMeeting = { url in
            openedURL = url
        }

        await service.refreshEvents(at: now)
        XCTAssertNotNil(service.activeAlert)

        // User clicks JOIN
        service.joinMeeting(for: event)

        XCTAssertEqual(openedURL, meetingURL)
        XCTAssertNil(service.activeAlert)
        XCTAssertNil(service.upcomingMeetingAlert)
    }

    // MARK: - WP4: Morning Brief & Evening Preview Tests

    func testCalendarAgendaService_MorningBriefGeneration() async {
        let cal = Calendar.current
        // Construct a morning time: 06:15 AM (new 6:00 AM cutoff threshold)
        var components = cal.dateComponents([.year, .month, .day], from: Date())
        components.hour = 6
        components.minute = 15
        let morningDate = cal.date(from: components)!

        let event1 = CalendarEventSnapshot(
            id: "m1",
            title: "Standup",
            startDate: morningDate.addingTimeInterval(3600),
            endDate: morningDate.addingTimeInterval(4500),
            isAllDay: false
        )
        let event2 = CalendarEventSnapshot(
            id: "m2",
            title: "Sync",
            startDate: morningDate.addingTimeInterval(7200),
            endDate: morningDate.addingTimeInterval(8100),
            isAllDay: false
        )

        let mockStore = MockCalendarEventStore(status: .fullAccess, stubbedEvents: [event1, event2])
        let settings = CalendarSettingsStore(userDefaults: defaults)
        settings.setEnabled(true)
        settings.setMorningBriefEnabled(true)

        let service = CalendarAgendaService(storeProvider: mockStore, settingsStore: settings, calendar: cal)

        // 1. Before 6:00 AM (05:45 AM) must NOT trigger morning brief
        var earlyComponents = components
        earlyComponents.hour = 5
        earlyComponents.minute = 45
        let earlyDate = cal.date(from: earlyComponents)!
        service.triggerMorningBriefIfEligible(at: earlyDate)
        XCTAssertNil(service.activeAlert)

        // 2. At or after 6:00 AM (06:15 AM) triggers morning brief
        service.dateProvider = { morningDate }
        await service.refreshEvents(at: morningDate)
        service.triggerMorningBriefIfEligible(at: morningDate)

        XCTAssertNotNil(service.activeAlert)
        XCTAssertEqual(service.activeAlert?.kind, .morningBrief)
        XCTAssertEqual(service.activeAlert?.message, "Good morning! 2 meetings scheduled today 📅")

        // Firing again on the same day must not duplicate
        service.dismissAlert()
        service.triggerMorningBriefIfEligible(at: morningDate.addingTimeInterval(60))
        XCTAssertNil(service.activeAlert)
    }

    func testCalendarAgendaService_EveningPreviewGeneration() async {
        let cal = Calendar.current
        var components = cal.dateComponents([.year, .month, .day], from: Date())
        components.hour = 15
        components.minute = 0
        let eveningDate = cal.date(from: components)!

        let startOfTomorrow = cal.date(byAdding: .day, value: 1, to: cal.startOfDay(for: eveningDate))!
        var tomorrowMeetingComps = cal.dateComponents([.year, .month, .day], from: startOfTomorrow)
        tomorrowMeetingComps.hour = 9
        tomorrowMeetingComps.minute = 30
        let tomorrowMeetingDate = cal.date(from: tomorrowMeetingComps)!

        let tomorrowEvent = CalendarEventSnapshot(
            id: "t1",
            title: "Design Sync",
            startDate: tomorrowMeetingDate,
            endDate: tomorrowMeetingDate.addingTimeInterval(3600),
            isAllDay: false
        )

        let mockStore = MockCalendarEventStore(status: .fullAccess, stubbedEvents: [tomorrowEvent])
        let settings = CalendarSettingsStore(userDefaults: defaults)
        settings.setEnabled(true)
        settings.setEveningPreviewEnabled(true)

        let service = CalendarAgendaService(storeProvider: mockStore, settingsStore: settings, calendar: cal)

        // 1. Before 3:00 PM (14:30) with 0 work minutes must NOT trigger
        var earlyComponents = components
        earlyComponents.hour = 14
        earlyComponents.minute = 30
        let earlyDate = cal.date(from: earlyComponents)!
        service.triggerEveningPreviewIfEligible(at: earlyDate, continuousWorkMinutes: 0)
        XCTAssertNil(service.activeAlert)

        // 2. Before 3:00 PM (14:30) with 480 work minutes DOES trigger (full workday)
        service.triggerEveningPreviewIfEligible(at: earlyDate, continuousWorkMinutes: 480)
        XCTAssertNotNil(service.activeAlert)

        // 3. At 3:00 PM (15:00) triggers regardless of continuous work minutes (fresh service on that day)
        let afternoonService = CalendarAgendaService(storeProvider: mockStore, settingsStore: settings, calendar: cal)
        afternoonService.dateProvider = { eveningDate }
        await afternoonService.refreshEvents(at: eveningDate)
        afternoonService.triggerEveningPreviewIfEligible(at: eveningDate)

        XCTAssertNotNil(afternoonService.activeAlert)
        XCTAssertEqual(afternoonService.activeAlert?.kind, .eveningPreview)
        XCTAssertTrue(afternoonService.activeAlert?.message.contains("Tomorrow's radar:") ?? false)
        XCTAssertTrue(afternoonService.activeAlert?.message.contains("Design Sync") ?? false)
    }

    // MARK: - WP3: Speech Bubble Prioritization & Interactivity

    func testSpeechBubbleContent_AgendaPrioritizationAndInteractivity() {
        let alert = CalendarAgendaAlert(
            kind: .upcomingMeeting,
            message: "Meeting in 10m: Sprint Planning 📅",
            meetingURL: URL(string: "https://meet.google.com/abc-defg-hij")
        )

        let agendaContent = SpeechBubbleContent.agenda(alert)
        XCTAssertTrue(agendaContent.isInteractive)
        XCTAssertTrue(SpeechBubblePanel.isInteractiveContent(agendaContent))

        let briefAlert = CalendarAgendaAlert(
            kind: .morningBrief,
            message: "Good morning! 2 meetings scheduled today 📅"
        )
        let briefContent = SpeechBubbleContent.agenda(briefAlert)
        XCTAssertTrue(briefContent.isInteractive)
        XCTAssertTrue(SpeechBubblePanel.isInteractiveContent(briefContent))
    }

    func testSpeechBubbleContent_CurrentPriorityHierarchy() {
        let engine = WellnessPointEngine(riveController: ProductionRiveController(), userDefaults: defaults)
        let agentMonitor = AgentMonitorService(adapters: [], userDefaults: defaults)
        let updateStore = AppUpdateStore(currentVersionString: "1.3.0", userDefaults: defaults)
        let telemetrySettings = TelemetrySettingsStore(userDefaults: defaults)
        let telemetryDashboard = TelemetryDashboardService(settingsStore: telemetrySettings)

        let settings = CalendarSettingsStore(userDefaults: defaults)
        settings.setEnabled(true)
        let calendarService = CalendarAgendaService(settingsStore: settings)

        // Baseline: no alerts -> nil (or wellness if set)
        XCTAssertNil(SpeechBubbleContent.current(
            engine: engine,
            agentMonitor: agentMonitor,
            calendarService: calendarService,
            updateStore: updateStore,
            telemetryDashboard: telemetryDashboard,
            telemetrySettings: telemetrySettings
        ))

        // When calendar alert is active -> surfaces .agenda
        let alertEvent = CalendarEventSnapshot(id: "e1", title: "Standup", startDate: Date(), endDate: Date().addingTimeInterval(1800))
        let mockStore = MockCalendarEventStore(status: .fullAccess, stubbedEvents: [alertEvent])
        let activeCalService = CalendarAgendaService(storeProvider: mockStore, settingsStore: settings)
        activeCalService.dateProvider = { Date() }

        // Trigger an alert manually
        let contentWithAgenda = SpeechBubbleContent.current(
            engine: engine,
            agentMonitor: agentMonitor,
            calendarService: activeCalService,
            updateStore: updateStore,
            telemetryDashboard: telemetryDashboard,
            telemetrySettings: telemetrySettings
        )
        // With no active alert yet, it's nil
        XCTAssertNil(contentWithAgenda)

        // When agent popup arrives -> agent popup takes highest priority over agenda
        agentMonitor.handleEvent(AgentEvent(agentID: "claude", agentName: "Claude", kind: .warning, message: "⚠️ Claude stuck"))
        let contentWithAgent = SpeechBubbleContent.current(
            engine: engine,
            agentMonitor: agentMonitor,
            calendarService: activeCalService,
            updateStore: updateStore,
            telemetryDashboard: telemetryDashboard,
            telemetrySettings: telemetrySettings
        )
        if case .agentPopup(let popup) = contentWithAgent {
            XCTAssertEqual(popup.text, "⚠️ Claude stuck")
        } else {
            XCTFail("Expected agent popup to take priority")
        }
    }
}
