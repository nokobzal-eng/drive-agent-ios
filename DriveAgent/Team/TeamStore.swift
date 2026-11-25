import Foundation
import os

private let log = Logger(subsystem: "com.driveagent.ios", category: "team")

/// Days of the week as stored in a schedule, Sunday first (the Israeli week).
let weekDays = ["sun", "mon", "tue", "wed", "thu", "fri", "sat"]
private let dayNames = ["ראשון", "שני", "שלישי", "רביעי", "חמישי", "שישי", "שבת"]

struct EmpRecord: Codable {
    var id: String
    var date: String
    var type: String
    var text: String
}

struct Review: Codable {
    var date: String
    var summary: String
    var strengths: [String]
    var improvements: [String]
    var recommendation: String
}

struct Employee: Codable {
    var name: String
    var area = ""
    var role = ""
    var phone = ""
    var notes = ""
    /// Day key -> hours ("07:00-16:00"), "חופש", or "" when unknown.
    var schedule: [String: String] = [:]
    /// Bonuses, upgrades (raise, promotion, training) and notes, newest first.
    var records: [EmpRecord] = []
    var review: Review?
}

struct TeamTask: Codable {
    var id: String
    /// "once" (a dated job), "daily" (every working day) or "weekly" (once a week).
    var kind: String
    var date: String
    var title: String
    var location: String
    var assignee: String
    var recommended = ""
    var reason = ""
    /// For one-off tasks: "open" | "done".
    var status = "open"
    var details = ""
    /// "manual" (entered by the user) or "whatsapp" (from an imported group).
    var source = "manual"
    /// Recurring tasks: the days (daily) or week starts (weekly) they were done.
    var doneOn: [String] = []
    var formName = ""
    var startedAt = ""
    var endedAt = ""
    var log: [String] = []
}

struct Board: Codable {
    var group = ""
    var updated: Double = 0
    var employees: [Employee] = []
    var tasks: [TeamTask] = []
}

/// The owner's team: employee cards (details and work schedule), daily / weekly / one-off tasks
/// and what was done. Entered on the team page or by voice, or built from an exported WhatsApp
/// work group. Kept on the phone only.
@MainActor
final class TeamStore: ObservableObject {
    static let shared = TeamStore()
    static let allEmployees = "*"

    /// Bumped on every change, so an open team page redraws.
    @Published private(set) var version = 0
    /// Names whose review is being written right now.
    @Published private(set) var reviewing: Set<String> = []
    @Published private(set) var importing = false

    private(set) var board: Board

    private static var fileURL: URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("team", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("board.json")
    }

    private init() {
        if let data = try? Data(contentsOf: Self.fileURL),
           let saved = try? JSONDecoder().decode(Board.self, from: data) {
            board = saved
        } else {
            board = Board()
        }
    }

    private func save(_ new: Board) {
        var b = new
        b.updated = Date().timeIntervalSince1970 * 1000
        board = b
        if let data = try? JSONEncoder().encode(b) {
            try? data.write(to: Self.fileURL, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        }
        version += 1
    }

    // MARK: Dates

    private static let dayFormat: DateFormatter = {
        let f = DateFormatter()
        f.calendar = Calendar(identifier: .gregorian)
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()

    static func todayKey() -> String { dayFormat.string(from: Date()) }

    /// The Sunday that starts this week.
    static func weekKey() -> String {
        var cal = Calendar(identifier: .gregorian)
        cal.firstWeekday = 1
        let now = Date()
        let weekday = cal.component(.weekday, from: now) // 1 = Sunday
        let sunday = cal.date(byAdding: .day, value: -(weekday - 1), to: now) ?? now
        return dayFormat.string(from: sunday)
    }

    static func todayDayKey() -> String {
        weekDays[Calendar(identifier: .gregorian).component(.weekday, from: Date()) - 1]
    }

    static func isDoneNow(_ t: TeamTask) -> Bool {
        switch t.kind {
        case "daily": t.doneOn.contains(todayKey())
        case "weekly": t.doneOn.contains(weekKey())
        default: t.status == "done"
        }
    }

    static func isTodays(_ t: TeamTask) -> Bool {
        switch t.kind {
        case "daily": return true
        case "weekly": return !isDoneNow(t)
        default:
            let today = todayKey()
            return t.date == today || (t.date < today && !t.date.isEmpty && !isDoneNow(t))
        }
    }

    static func worksToday(_ e: Employee) -> Bool {
        let v = e.schedule[todayDayKey()] ?? ""
        return !v.isEmpty && !v.contains("חופש") && !v.contains("לא עובד")
    }

    private static func newId() -> String {
        "t" + String(UInt64.random(in: 0..<UInt64(1) << 40), radix: 36)
    }

    // MARK: For the page

    /// The board as the team page expects it.
    func pageJSON() -> String {
        guard let data = try? JSONEncoder().encode(board),
              var root = try? JSONSerialization.jsonObject(with: data) as? JSON else { return "{}" }
        root["today"] = Self.todayKey()
        root["week"] = Self.weekKey()
        guard let out = try? JSONSerialization.data(withJSONObject: root) else { return "{}" }
        return String(decoding: out, as: UTF8.self)
    }

    // MARK: Editing (page and voice)

    /// Adds or updates an employee. With `replace` the whole card comes from the page's form;
    /// otherwise blank fields keep what was there, so "דני עובד גם בשישי" changes only Friday.
    @discardableResult
    func saveEmployee(_ e: Employee, originalName: String? = nil, replace: Bool = false) -> Employee {
        var b = board
        let original = originalName.flatMap { $0.isEmpty ? nil : $0 } ?? e.name
        let index = b.employees.firstIndex { $0.name == original || $0.name == e.name }
        var merged = e
        if let i = index {
            let old = b.employees[i]
            if replace {
                merged.records = old.records
                merged.review = old.review
            } else {
                merged = old
                if !e.name.isEmpty { merged.name = e.name }
                if !e.area.isEmpty { merged.area = e.area }
                if !e.role.isEmpty { merged.role = e.role }
                if !e.phone.isEmpty { merged.phone = e.phone }
                if !e.notes.isEmpty { merged.notes = e.notes }
                for d in weekDays where !(e.schedule[d] ?? "").isEmpty { merged.schedule[d] = e.schedule[d] }
            }
            b.employees[i] = merged
            // A rename carries the person's tasks along.
            if old.name != merged.name {
                for j in b.tasks.indices where b.tasks[j].assignee == old.name { b.tasks[j].assignee = merged.name }
            }
        } else {
            b.employees.append(merged)
        }
        save(b)
        return merged
    }

    @discardableResult
    func deleteEmployee(_ name: String) -> Bool {
        guard board.employees.contains(where: { $0.name == name }) else { return false }
        var b = board
        b.employees.removeAll { $0.name == name }
        save(b)
        return true
    }

    /// Adds a task (blank id) or edits one. "*" as assignee gives everyone their own copy.
    @discardableResult
    func saveTask(_ t: TeamTask) -> TeamTask {
        if t.assignee == Self.allEmployees && t.id.isEmpty {
            var last = t
            if board.employees.isEmpty {
                var solo = t
                solo.assignee = ""
                return saveTask(solo)
            }
            for e in board.employees {
                var copy = t
                copy.assignee = e.name
                last = saveTask(copy)
            }
            return last
        }
        var b = board
        let kind = ["daily", "weekly"].contains(t.kind) ? t.kind : "once"
        let saved: TeamTask
        if !t.id.isEmpty, let i = b.tasks.firstIndex(where: { $0.id == t.id }) {
            var edited = b.tasks[i]
            edited.kind = kind
            if !t.title.isEmpty { edited.title = t.title }
            edited.assignee = t.assignee
            edited.date = t.date
            edited.location = t.location
            edited.details = t.details
            edited.formName = t.formName
            b.tasks[i] = edited
            saved = edited
        } else {
            var created = t
            created.id = Self.newId()
            created.kind = kind
            created.source = "manual"
            created.status = "open"
            if created.date.isEmpty && kind == "once" { created.date = Self.todayKey() }
            b.tasks.insert(created, at: 0)
            saved = created
        }
        save(b)
        return saved
    }

    @discardableResult
    func deleteTask(_ id: String) -> Bool {
        guard board.tasks.contains(where: { $0.id == id }) else { return false }
        var b = board
        b.tasks.removeAll { $0.id == id }
        save(b)
        return true
    }

    /// Ticks a task: one-off tasks done/open; daily ones for today; weekly ones for this week.
    @discardableResult
    func setDone(_ id: String, _ done: Bool) -> TeamTask? {
        guard let i = board.tasks.firstIndex(where: { $0.id == id }) else { return nil }
        var b = board
        var t = b.tasks[i]
        if t.kind == "daily" || t.kind == "weekly" {
            let key = t.kind == "daily" ? Self.todayKey() : Self.weekKey()
            t.doneOn.removeAll { $0 == key }
            if done { t.doneOn.append(key) }
            if t.doneOn.count > 400 { t.doneOn.removeFirst(t.doneOn.count - 400) }
        } else {
            t.status = done ? "done" : "open"
            if t.date.isEmpty { t.date = Self.todayKey() }
        }
        b.tasks[i] = t
        save(b)
        return t
    }

    /// Adds a bonus / upgrade / note to an employee's card.
    @discardableResult
    func addRecord(name: String, type: String, text: String) -> Bool {
        let clean = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty, let i = board.employees.firstIndex(where: { $0.name == name }) else { return false }
        var b = board
        let kind = ["bonus", "upgrade", "suggestion"].contains(type) ? type : "note"
        b.employees[i].records.insert(EmpRecord(id: Self.newId(), date: Self.todayKey(), type: kind, text: clean), at: 0)
        save(b)
        return true
    }

    func deleteRecord(name: String, id: String) {
        guard let i = board.employees.firstIndex(where: { $0.name == name }) else { return }
        var b = board
        b.employees[i].records.removeAll { $0.id == id }
        save(b)
    }

    // MARK: Employee review (Claude)

    /// Writes a fair, data-based review of one employee and saves it on their card.
    @discardableResult
    func review(_ name: String) async -> Review? {
        guard let e = board.employees.first(where: { $0.name == name }), !reviewing.contains(name) else { return nil }
        reviewing.insert(name)
        version += 1
        defer {
            reviewing.remove(name)
            version += 1
        }
        var withoutReview = e
        withoutReview.review = nil
        let tasks = board.tasks.filter { $0.assignee == name || $0.recommended == name }
        let input: JSON = [
            "today": Self.todayKey(),
            "employee": Self.jsonObject(withoutReview),
            "tasks": tasks.map { Self.jsonObject($0) },
            "team_size": board.employees.count,
            "team_open_tasks": board.tasks.filter { !Self.isDoneNow($0) }.count,
        ]
        let schema = Self.object([
            ("summary", Self.string),
            ("strengths", Self.array(Self.string)),
            ("improvements", Self.array(Self.string)),
            ("recommendation", Self.string),
        ])
        do {
            let text = String(decoding: try JSONSerialization.data(withJSONObject: input), as: UTF8.self)
            let r = try await ClaudeClient().structured(
                settings: SettingsStore.load(), system: Self.prompt("prompt_review"), text: text, schema: schema
            )
            let review = Review(
                date: Self.todayKey(),
                summary: (r["summary"] as? String ?? "").trimmingCharacters(in: .whitespaces),
                strengths: r["strengths"] as? [String] ?? [],
                improvements: r["improvements"] as? [String] ?? [],
                recommendation: (r["recommendation"] as? String ?? "").trimmingCharacters(in: .whitespaces)
            )
            guard let i = board.employees.firstIndex(where: { $0.name == name }) else { return nil }
            var b = board
            b.employees[i].review = review
            save(b)
            return review
        } catch {
            log.warning("Review failed")
            return nil
        }
    }

    // MARK: Importing a WhatsApp work group

    private static let maxChatChars = 150_000

    /// Builds the board from an exported WhatsApp group. Returns a short spoken summary, or nil.
    func importChat(_ chat: String, group: String) async -> String? {
        guard !importing else { return nil }
        importing = true
        version += 1
        defer {
            importing = false
            version += 1
        }
        let known = board.employees.map { "- \($0.name) | \($0.area) | \($0.role)" }.joined(separator: "\n")
        var intro = "קבוצה: \(group)\n"
        if !known.isEmpty { intro += "עובדים שהמשתמש כבר הזין (שם | אזור | תחום):\n\(known)\n" }
        let schema = Self.object([
            ("summary_spoken", Self.string),
            ("employees", Self.array(Self.object([("name", Self.string), ("area", Self.string), ("role", Self.string)]))),
            ("tasks", Self.array(Self.object([
                ("date", Self.string), ("title", Self.string), ("location", Self.string), ("assignee", Self.string),
                ("status", ["type": "string", "enum": ["open", "done"]] as JSON),
                ("details", Self.string), ("recommended", Self.string), ("reason", Self.string),
            ]))),
        ])
        do {
            let r = try await ClaudeClient().structured(
                settings: SettingsStore.load(), system: Self.prompt("prompt_team"),
                text: intro + "\n" + Self.trimChat(chat), schema: schema, maxTokens: 32000
            )
            var b = board
            if !group.isEmpty { b.group = group }
            // Keep what the user entered; fill blanks from the import; add new people.
            for item in r["employees"] as? [JSON] ?? [] {
                let name = (item["name"] as? String ?? "").trimmingCharacters(in: .whitespaces)
                guard !name.isEmpty else { continue }
                let area = (item["area"] as? String ?? "").trimmingCharacters(in: .whitespaces)
                let role = (item["role"] as? String ?? "").trimmingCharacters(in: .whitespaces)
                if let i = b.employees.firstIndex(where: { $0.name == name }) {
                    if b.employees[i].area.isEmpty { b.employees[i].area = area }
                    if b.employees[i].role.isEmpty { b.employees[i].role = role }
                } else {
                    b.employees.append(Employee(name: name, area: area, role: role))
                }
            }
            let previous = b.tasks
            var tasks = previous.filter { $0.source == "manual" }
            for item in r["tasks"] as? [JSON] ?? [] {
                func field(_ key: String) -> String { (item[key] as? String ?? "").trimmingCharacters(in: .whitespaces) }
                let title = field("title")
                guard !title.isEmpty else { continue }
                let date = field("date")
                // A task ticked done on the page stays done after a new import.
                let wasDone = previous.contains {
                    $0.source == "whatsapp" && $0.status == "done" && $0.title == title && $0.date == date
                }
                tasks.append(TeamTask(
                    id: Self.newId(), kind: "once", date: date, title: title, location: field("location"),
                    assignee: field("assignee"), recommended: field("recommended"), reason: field("reason"),
                    status: wasDone || field("status") == "done" ? "done" : "open",
                    details: field("details"), source: "whatsapp"
                ))
            }
            b.tasks = tasks
            save(b)
            return (r["summary_spoken"] as? String ?? "").trimmingCharacters(in: .whitespaces)
        } catch {
            log.warning("Import failed")
            return nil
        }
    }

    /// Drops lines that carry no information, and keeps the most recent part of a long chat.
    private static func trimChat(_ chat: String) -> String {
        let noise = ["<Media omitted>", "<המדיה הושמטה>", "<מדיה הושמטה>", "This message was deleted", "ההודעה נמחקה",
                     "image omitted", "התמונה הושמטה", "video omitted", "הסרטון הושמט"]
        let lines = chat.split(separator: "\n", omittingEmptySubsequences: true).filter { line in
            let t = line.trimmingCharacters(in: .whitespaces)
            return !t.isEmpty && !noise.contains { t.hasSuffix($0) }
        }
        let text = lines.joined(separator: "\n")
        return text.count > maxChatChars ? String(text.suffix(maxChatChars)) : text
    }

    /// The group's name from WhatsApp's export file name ("WhatsApp Chat - צוות צפון.zip").
    static func groupName(fromFile name: String) -> String {
        var n = (name as NSString).deletingPathExtension
        for marker in ["WhatsApp Chat - ", "WhatsApp Chat with ", "צ'אט WhatsApp עם ", "צ׳אט WhatsApp עם "] {
            if let r = n.range(of: marker) { n = String(n[r.upperBound...]) }
        }
        return n == "_chat" ? "" : n.trimmingCharacters(in: .whitespaces)
    }

    // MARK: For the assistant

    /// The board as short text for Claude (ids, so it can tick or remove tasks).
    func describe() -> String {
        let b = board
        if b.employees.isEmpty && b.tasks.isEmpty { return "The team board is empty: no employees or tasks yet." }
        let short = ["א", "ב", "ג", "ד", "ה", "ו", "ש"]
        var s = "Today: \(Self.todayKey()) (week starts \(Self.weekKey())). Group: \(b.group.isEmpty ? "-" : b.group).\nEmployees:\n"
        for e in b.employees {
            let sched = weekDays.enumerated().compactMap { i, d -> String? in
                guard let v = e.schedule[d], !v.isEmpty else { return nil }
                return "\(short[i]) \(v)"
            }
            s += "- \(e.name) | area: \(e.area.isEmpty ? "?" : e.area) | role: \(e.role.isEmpty ? "?" : e.role)"
            if !e.phone.isEmpty { s += " | phone: \(e.phone)" }
            if !sched.isEmpty { s += " | schedule: \(sched.joined(separator: ", "))" }
            if !e.notes.isEmpty { s += " | notes: \(e.notes)" }
            if !e.records.isEmpty {
                s += " | history: " + e.records.prefix(6).map { "\($0.date) \($0.type): \($0.text)" }.joined(separator: "; ")
            }
            if let r = e.review { s += " | last review \(r.date): \(r.summary) Improve: \(r.improvements.joined(separator: "; "))" }
            s += "\n"
        }
        s += "Tasks (id | kind | date | done now? | task | location | assignee | recommended — reason | details):\n"
        for t in b.tasks {
            s += "\(t.id) | \(t.kind) | \(t.date.isEmpty ? "-" : t.date) | \(Self.isDoneNow(t) ? "done" : "open") | \(t.title) | "
            s += "\(t.location) | \(t.assignee.isEmpty ? "-" : t.assignee) | \(t.recommended) — \(t.reason) | \(t.details)\n"
        }
        return s
    }

    /// The text sent to an employee on WhatsApp: their week and their open tasks.
    func scheduleMessage(for name: String) -> String? {
        guard let e = board.employees.first(where: { $0.name == name }) else { return nil }
        var s = "שלום \(e.name), הסידור שלך השבוע:\n"
        for (i, d) in weekDays.enumerated() {
            let v = e.schedule[d] ?? ""
            s += "\(dayNames[i]): \(v.isEmpty ? "—" : v)\n"
        }
        let open = board.tasks.filter { $0.assignee == name && !Self.isDoneNow($0) }
        if !open.isEmpty {
            s += "\nמשימות פתוחות:\n"
            for t in open.prefix(15) {
                var line = "• \(t.title)"
                if !t.location.isEmpty { line += " — \(t.location)" }
                if t.kind == "once" && !t.date.isEmpty { line += " (\(t.date))" }
                s += line + "\n"
            }
        }
        return s
    }

    // MARK: Export (opens in Excel)

    /// Two CSV files (UTF-8 with BOM, so Excel shows Hebrew): the week's schedule and the tasks.
    func exportCSV() -> [URL] {
        let b = board
        let kind = ["daily": "יומית", "weekly": "שבועית"]
        var schedule = [["עובד"] + dayNames + ["תפקיד", "אזור", "טלפון"]]
        for e in b.employees {
            schedule.append([e.name] + weekDays.map { e.schedule[$0] ?? "" } + [e.role, e.area, e.phone])
        }
        var tasks = [["סוג", "תאריך", "משימה", "מיקום", "אחראי", "סטטוס", "מומלץ לביצוע", "סיבה", "פרטים"]]
        for t in b.tasks {
            tasks.append([
                kind[t.kind] ?? "חד-פעמית", t.date, t.title, t.location, t.assignee,
                Self.isDoneNow(t) ? "בוצע" : "פתוח", t.recommended, t.reason, t.details,
            ])
        }
        let dir = FileManager.default.temporaryDirectory
        var files: [URL] = []
        for (name, rows) in [("סידור עבודה", schedule), ("משימות", tasks)] {
            let csv = "\u{FEFF}" + rows.map { $0.map(Self.csvField).joined(separator: ",") }.joined(separator: "\r\n")
            let url = dir.appendingPathComponent("\(name).csv")
            do {
                try csv.write(to: url, atomically: true, encoding: .utf8)
                files.append(url)
            } catch {
                continue
            }
        }
        return files
    }

    private static func csvField(_ s: String) -> String {
        "\"" + s.replacingOccurrences(of: "\"", with: "\"\"") + "\""
    }

    // MARK: Helpers

    static func prompt(_ name: String) -> String {
        guard let url = Bundle.main.url(forResource: name, withExtension: "txt") else { return "" }
        return (try? String(contentsOf: url, encoding: .utf8)) ?? ""
    }

    private static func jsonObject<T: Encodable>(_ value: T) -> Any {
        guard let data = try? JSONEncoder().encode(value) else { return [:] as JSON }
        return (try? JSONSerialization.jsonObject(with: data)) ?? ([:] as JSON)
    }

    private static let string: JSON = ["type": "string"]

    private static func array(_ items: JSON) -> JSON { ["type": "array", "items": items] }

    private static func object(_ fields: [(String, JSON)]) -> JSON {
        var properties: JSON = [:]
        for (k, v) in fields { properties[k] = v }
        return ["type": "object", "properties": properties, "required": fields.map(\.0), "additionalProperties": false]
    }
}
