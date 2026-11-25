import AVFoundation
import Contacts
import EventKit
import Speech
import UserNotifications

enum LightState {
    case ok, error, unknown, offline
}

struct SystemLight: Identifiable {
    enum Kind { case microphone, speech, claude, calendar, contacts, notifications }

    let kind: Kind
    let state: LightState
    var id: Kind { kind }

    var label: String {
        switch kind {
        case .microphone: "מיקרופון"
        case .speech: "זיהוי דיבור"
        case .claude: "Claude"
        case .calendar: "יומן"
        case .contacts: "אנשי קשר"
        case .notifications: "התראות"
        }
    }
}

/// Today at a glance, from the iPhone's calendar.
struct TodaySummary {
    var nextTitle: String?
    var nextTime: String?
    var eventsToday = 0
    var eventsTomorrow = 0
    var calendarAllowed = false
}

/// The home screen's status lights and calendar tiles. Re-checked when the app comes back.
@MainActor
final class SystemsChecker: ObservableObject {
    @Published private(set) var lights: [SystemLight] = []
    @Published private(set) var today = TodaySummary()
    private let store = EKEventStore()

    func refresh() async {
        today = loadToday()
        let local: [SystemLight] = [
            SystemLight(kind: .microphone, state: microphone()),
            SystemLight(kind: .speech, state: speech()),
            SystemLight(kind: .claude, state: .unknown),
            SystemLight(kind: .calendar, state: calendar()),
            SystemLight(kind: .contacts, state: contacts()),
            SystemLight(kind: .notifications, state: await notifications()),
        ]
        lights = local
        let claude: LightState = switch await ClaudeClient.checkConnection(apiKey: SettingsStore.load().apiKey) {
        case true?: .ok
        case false?: .error
        case nil: .offline
        }
        lights = local.map { $0.kind == .claude ? SystemLight(kind: .claude, state: claude) : $0 }
    }

    // A permission not asked yet is gray: it is asked the first time drive mode starts.

    private func microphone() -> LightState {
        switch AVAudioApplication.shared.recordPermission {
        case .granted: .ok
        case .undetermined: .unknown
        default: .error
        }
    }

    private func speech() -> LightState {
        switch SFSpeechRecognizer.authorizationStatus() {
        case .authorized: .ok
        case .notDetermined: .unknown
        default: .error
        }
    }

    private func calendar() -> LightState {
        switch EKEventStore.authorizationStatus(for: .event) {
        case .fullAccess: .ok
        case .notDetermined: .unknown
        default: .error
        }
    }

    private func contacts() -> LightState {
        let status = CNContactStore.authorizationStatus(for: .contacts)
        if status == .authorized { return .ok }
        if #available(iOS 18.0, *), status == .limited { return .ok }
        return status == .notDetermined ? .unknown : .error
    }

    private func notifications() async -> LightState {
        switch await UNUserNotificationCenter.current().notificationSettings().authorizationStatus {
        case .authorized, .provisional, .ephemeral: .ok
        case .notDetermined: .unknown
        default: .error
        }
    }

    private func loadToday() -> TodaySummary {
        var summary = TodaySummary()
        guard EKEventStore.authorizationStatus(for: .event) == .fullAccess else { return summary }
        summary.calendarAllowed = true
        let cal = Calendar.current
        let now = Date()
        let startOfToday = cal.startOfDay(for: now)
        guard let startOfTomorrow = cal.date(byAdding: .day, value: 1, to: startOfToday),
              let endOfTomorrow = cal.date(byAdding: .day, value: 2, to: startOfToday) else { return summary }
        let todays = events(from: startOfToday, to: startOfTomorrow)
        summary.eventsToday = todays.count
        summary.eventsTomorrow = events(from: startOfTomorrow, to: endOfTomorrow).count
        if let next = todays.first(where: { $0.endDate > now }) {
            summary.nextTitle = next.title
            summary.nextTime = next.isAllDay ? nil : AgentBrain.formatted(next.startDate, "HH:mm")
        }
        return summary
    }

    private func events(from start: Date, to end: Date) -> [EKEvent] {
        let predicate = store.predicateForEvents(withStart: start, end: end, calendars: nil)
        return store.events(matching: predicate).sorted { $0.startDate < $1.startDate }
    }
}
