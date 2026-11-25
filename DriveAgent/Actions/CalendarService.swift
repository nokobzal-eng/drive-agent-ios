import EventKit
import Foundation

@MainActor
final class CalendarService {
    private static let maxEvents = 40
    private let store = EKEventStore()

    func requestAccess() async {
        _ = try? await store.requestFullAccessToEvents()
    }

    private var hasAccess: Bool {
        EKEventStore.authorizationStatus(for: .event) == .fullAccess
    }

    func describe(period: String) -> String {
        guard hasAccess else { return "No access to the calendar. The user can allow it in the iPhone's settings." }
        let cal = Calendar.current
        let today = cal.startOfDay(for: Date())
        let range: (start: Int, days: Int)
        switch period {
        case "tomorrow": range = (1, 1)
        case "week": range = (0, 7)
        case "month": range = (0, 30)
        default: range = (0, 1)
        }
        guard let start = cal.date(byAdding: .day, value: range.start, to: today),
              let end = cal.date(byAdding: .day, value: range.days, to: start) else {
            return "Couldn't work out the dates."
        }
        let predicate = store.predicateForEvents(withStart: start, end: end, calendars: nil)
        let events = store.events(matching: predicate).sorted { $0.startDate < $1.startDate }
        if events.isEmpty { return "No events in this period." }
        return events.prefix(Self.maxEvents).map { event in
            let when = AgentBrain.formatted(event.startDate, event.isAllDay ? "EEEE d/M" : "EEEE d/M HH:mm")
            let place = event.location.map { $0.isEmpty ? "" : " (\($0))" } ?? ""
            return "\(when): \(event.title ?? "")\(place)"
        }.joined(separator: "\n")
    }

    func add(title: String, start: Date, allDay: Bool, minutes: Int, location: String) -> String {
        guard hasAccess else { return "No access to the calendar. The user can allow it in the iPhone's settings." }
        guard let target = store.defaultCalendarForNewEvents else { return "There is no calendar to add to." }
        let event = EKEvent(eventStore: store)
        event.calendar = target
        event.title = title
        event.startDate = start
        event.isAllDay = allDay
        event.endDate = start.addingTimeInterval(TimeInterval((allDay ? 60 : max(minutes, 1)) * 60))
        if !location.isEmpty { event.location = location }
        do {
            try store.save(event, span: .thisEvent)
            return "Added to the calendar."
        } catch {
            return "Couldn't save the event."
        }
    }

    static func parse(_ text: String) -> Date? {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = text.contains("T") ? "yyyy-MM-dd'T'HH:mm" : "yyyy-MM-dd"
        return formatter.date(from: text)
    }
}
