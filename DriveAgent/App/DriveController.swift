import AVFoundation
import Speech
import UIKit
import UserNotifications

/// The drive-mode conversation loop, and the app's implementation of the agent's tools.
@MainActor
final class DriveController: ObservableObject, AgentHost {
    enum Phase: String {
        case off = "כבוי"
        case listening = "מקשיב"
        case thinking = "חושב"
        case speaking = "מדבר"
    }

    @Published private(set) var phase: Phase = .off
    @Published private(set) var isDriving = false
    @Published private(set) var heard = ""
    @Published private(set) var answer = ""
    @Published private(set) var errorText: String?
    /// Everything the microphone is recognizing right now, wake word or not.
    @Published private(set) var live = ""
    /// Set by the "open_team_dashboard" tool; the home screen shows the team page.
    @Published var showTeam = false
    /// The last requests and answers, newest first, for the "פקודות אחרונות" panel.
    @Published private(set) var log: [LogEntry] = []
    /// Speak answers out loud (on), or show them on the screen only (off). Remembered.
    @Published var speakReplies = UserDefaults.standard.object(forKey: "speakReplies") as? Bool ?? true {
        didSet { UserDefaults.standard.set(speakReplies, forKey: "speakReplies") }
    }

    struct LogEntry: Identifiable {
        let id = UUID()
        let request: String
        let answer: String
    }

    private static let maxLog = 10

    private let speaker = Speaker()
    private let speech = SpeechInput()
    private let claude = ClaudeClient()
    private let calendar = CalendarService()
    private lazy var brain = AgentBrain(claude: claude, host: self)
    private var loopTask: Task<Void, Never>?
    private var stopRequested = false
    private var talkRequested = false
    /// A request from a button or the typing box, handled instead of listening.
    private var pendingCommand: String?
    /// Set by "הפסק לדבר": the rest of this answer is shown, not spoken.
    private var silenced = false

    init() {
        speech.onPartial = { [weak self] text in self?.live = text }
        let center = NotificationCenter.default
        center.addObserver(forName: .AVAudioEngineConfigurationChange, object: speech.engine, queue: .main) { [weak self] _ in
            Task { @MainActor [weak self] in self?.recoverAudio() }
        }
        center.addObserver(forName: AVAudioSession.interruptionNotification, object: nil, queue: .main) { [weak self] note in
            let raw = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt
            guard raw == AVAudioSession.InterruptionType.ended.rawValue else { return }
            Task { @MainActor [weak self] in self?.recoverAudio() }
        }
    }

    func start() {
        guard loopTask == nil else { return }
        loopTask = Task { await begin() }
    }

    /// The "דבר" button: the next phrase is a request, no wake word needed.
    /// Turns drive mode on first if it is off.
    func talkNow() {
        guard !talkRequested else { return }
        talkRequested = true
        if !isDriving {
            start()
        } else if phase == .listening {
            speech.cancel()
        }
    }

    /// A request typed or chosen from a button, handled as if it was said after the wake word.
    /// Turns drive mode on first if it is off, so that questions back can be answered by voice.
    func send(_ text: String) {
        let request = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !request.isEmpty else { return }
        pendingCommand = request
        if !isDriving {
            start()
        } else if phase == .listening {
            speech.cancel()
        }
    }

    /// "הפסק לדבר": stops the voice; the answer still appears on the screen.
    func interrupt() {
        silenced = true
        speaker.stop()
    }

    func stop() {
        pendingCommand = nil
        talkRequested = false
        live = ""
        guard isDriving else { return }
        isDriving = false
        phase = .off
        loopTask?.cancel()
        loopTask = nil
        speaker.stop()
        speech.stopEngine()
        brain.reset()
        UIApplication.shared.isIdleTimerDisabled = false
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    private func begin() async {
        errorText = nil
        stopRequested = false
        guard !currentSettings().apiKey.isEmpty else {
            failToStart("חסר מפתח API. אפשר להזין אותו בהגדרות.")
            return
        }
        guard await requestPermissions() else {
            failToStart("צריך לאשר מיקרופון וזיהוי דיבור בהגדרות של האייפון.")
            return
        }
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(
                .playAndRecord,
                mode: .default,
                options: [.allowBluetooth, .allowBluetoothA2DP, .defaultToSpeaker, .mixWithOthers]
            )
            try session.setActive(true)
            try speech.startEngine()
        } catch {
            failToStart("לא הצלחתי להפעיל את המיקרופון.")
            return
        }
        isDriving = true
        UIApplication.shared.isIdleTimerDisabled = true
        await runLoop()
    }

    private func failToStart(_ message: String) {
        errorText = message
        pendingCommand = nil
        talkRequested = false
        loopTask = nil
    }

    private func requestPermissions() async -> Bool {
        let speechAllowed = await withCheckedContinuation { (waiter: CheckedContinuation<Bool, Never>) in
            SFSpeechRecognizer.requestAuthorization { waiter.resume(returning: $0 == .authorized) }
        }
        let micAllowed = await AVAudioApplication.requestRecordPermission()
        // Asked up front so that no permission dialog appears mid-drive. These features report
        // their own failure if refused, and the rest of the app still works.
        await calendar.requestAccess()
        await ContactFinder.requestAccess()
        _ = try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound])
        return speechAllowed && micAllowed
    }

    private func recoverAudio() {
        guard isDriving else { return }
        try? AVAudioSession.sharedInstance().setActive(true)
        try? speech.restartEngine()
    }

    private func runLoop() async {
        await say("מצב נהיגה פעיל.")
        var followUp = false
        while isDriving && !Task.isCancelled {
            let request: String
            if let command = pendingCommand {
                pendingCommand = nil
                request = command
            } else {
                guard let spoken = await nextSpokenRequest(followUp: followUp) else {
                    followUp = false
                    continue
                }
                request = spoken
            }
            heard = request
            live = ""
            answer = ""
            silenced = false
            phase = .thinking
            let reached = await brain.handle(request)
            if !reached && !Task.isCancelled {
                await say("אופס, לא הצלחתי להתחבר כרגע. אפשר לנסות שוב עוד רגע.")
            }
            log.insert(LogEntry(request: request, answer: answer), at: 0)
            if log.count > Self.maxLog { log.removeLast(log.count - Self.maxLog) }
            if stopRequested {
                await say("סוגר את מצב נהיגה.")
                stop()
                return
            }
            followUp = true
        }
    }

    /// Listens for the next request. Right after an answer, or after "דבר", no wake word is needed.
    /// Returns nil when nothing usable was said, or when a button interrupted the listening.
    private func nextSpokenRequest(followUp: Bool) async -> String? {
        var direct = followUp
        if talkRequested {
            talkRequested = false
            direct = true
            await say("כן?")
        }
        phase = .listening
        live = ""
        let started = Date()
        guard let utterance = await speech.listen(maxWait: direct ? 8 : 25) else {
            if talkRequested || pendingCommand != nil { return nil }
            if let reason = speech.unavailableReason { errorText = reason }
            // No recognizer or no network returns at once: don't spin.
            if Date().timeIntervalSince(started) < 1 { try? await Task.sleep(nanoseconds: 1_000_000_000) }
            return nil
        }
        errorText = nil
        if direct { return utterance }
        guard let afterWake = WakeWord.request(in: utterance, wake: currentSettings().assistantName) else {
            return nil
        }
        if !afterWake.isEmpty { return afterWake }
        await say("כן?")
        phase = .listening
        return await speech.listen(maxWait: 8)
    }

    // MARK: AgentHost

    func currentSettings() -> AppSettings {
        SettingsStore.load()
    }

    func say(_ text: String) async {
        answer = text
        await speakPart(text)
    }

    func show(_ text: String) {
        answer = text
    }

    func speakPart(_ text: String) async {
        guard speakReplies, !silenced else { return }
        let previous = phase
        phase = .speaking
        await speaker.speak(text)
        if isDriving { phase = previous == .speaking ? .thinking : previous }
    }

    func runTool(_ name: String, input: JSON) async -> String {
        switch name {
        case "get_calendar":
            return calendar.describe(period: input["period"] as? String ?? "today")
        case "add_calendar_event":
            return await addCalendarEvent(input)
        case "send_whatsapp":
            return await prepareWhatsApp(input)
        case "call_contact":
            return await callContact(input)
        case "ask_user":
            return await askUser(input["question"] as? String ?? "")
        case "stop_drive_mode":
            stopRequested = true
            return "Drive mode will turn off when you finish."
        case "get_team_board", "update_team_task", "save_employee", "add_team_task", "remove_team_task",
             "add_employee_record", "review_employee", "open_team_dashboard":
            return await teamTool(name, input)
        default:
            return "Unknown tool."
        }
    }

    // MARK: Team tools

    private func teamTool(_ name: String, _ input: JSON) async -> String {
        let team = TeamStore.shared
        func text(_ key: String) -> String { (input[key] as? String ?? "").trimmingCharacters(in: .whitespaces) }
        switch name {
        case "get_team_board":
            return team.describe()
        case "update_team_task":
            guard let t = team.setDone(text("task_id"), text("status") == "done") else { return "No task with that id." }
            return "Updated: \(t.title) is \(TeamStore.isDoneNow(t) ? "done" : "open")."
        case "save_employee":
            let n = text("name")
            guard !n.isEmpty else { return "Missing the employee's name." }
            let days = input["schedule"] as? JSON ?? [:]
            var schedule: [String: String] = [:]
            for d in weekDays { schedule[d] = (days[d] as? String ?? "").trimmingCharacters(in: .whitespaces) }
            let saved = team.saveEmployee(Employee(
                name: n, area: text("area"), role: text("role"), phone: text("phone"), notes: text("notes"), schedule: schedule
            ))
            return "Saved \(saved.name)'s card."
        case "add_team_task":
            let title = text("title")
            guard !title.isEmpty else { return "Missing what has to be done." }
            let t = team.saveTask(TeamTask(
                id: "", kind: text("kind"), date: text("date"), title: title, location: text("location"),
                assignee: text("assignee"), details: text("details")
            ))
            return "Added task \(t.id): \(t.title)\(t.assignee.isEmpty ? " (no one assigned)" : " for \(t.assignee)")."
        case "remove_team_task":
            return team.deleteTask(text("task_id")) ? "Removed." : "No task with that id."
        case "add_employee_record":
            return team.addRecord(name: text("name"), type: text("type"), text: text("text"))
                ? "Recorded on the card." : "No employee with that name, or the text is empty."
        case "review_employee":
            guard let r = await team.review(text("name")) else { return "Couldn't write the review now." }
            return "Review saved. Summary: \(r.summary) Improve: \(r.improvements.joined(separator: "; ")) Recommendation: \(r.recommendation)"
        default: // open_team_dashboard
            guard UIApplication.shared.applicationState == .active else {
                return "The phone is locked or the app is in the background; the team page opens from the home screen's צוות button."
            }
            showTeam = true
            return "The team page is open on the screen."
        }
    }

    // MARK: Tools

    /// Two chances to answer. Silence or anything unclear is a no.
    private func confirm(_ prompt: String) async -> Bool {
        silenced = false // a question must be heard even after "הפסק לדבר"
        for attempt in 0..<2 {
            await say(attempt == 0 ? prompt : "לא שמעתי. כן או לא?")
            phase = .listening
            if let reply = await speech.listen(maxWait: 7) { return CommandMatcher.confirm(reply) }
            if Task.isCancelled { return false }
        }
        return false
    }

    private func askUser(_ question: String) async -> String {
        silenced = false
        await say(question)
        phase = .listening
        let reply = await speech.listen(maxWait: 10)
        phase = .thinking
        return reply ?? "The user didn't answer."
    }

    private func addCalendarEvent(_ input: JSON) async -> String {
        let title = input["title"] as? String ?? ""
        let startText = input["start"] as? String ?? ""
        let minutes = input["duration_minutes"] as? Int ?? 60
        let location = input["location"] as? String ?? ""
        guard !title.isEmpty, let start = CalendarService.parse(startText) else {
            return "Missing title or a valid start date-time."
        }
        let allDay = minutes == 0 || !startText.contains("T")
        let when = AgentBrain.formatted(start, allDay ? "EEEE, d 'ב'MMMM" : "EEEE, d 'ב'MMMM, 'בשעה' HH:mm")
        guard await confirm("לרשום ביומן: \(title), \(when)?") else { return "The user cancelled. Nothing was added." }
        phase = .thinking
        return calendar.add(title: title, start: start, allDay: allDay, minutes: minutes, location: location)
    }

    private func resolve(_ query: String) -> (match: ContactMatch?, problem: String?) {
        do {
            let matches = try ContactFinder.find(query)
            if matches.isEmpty { return (nil, "No contact named '\(query)' with a phone number.") }
            if matches.count > 1, !matches.contains(where: { $0.name == query }) {
                let names = matches.prefix(5).map(\.name).joined(separator: ", ")
                return (nil, "Several contacts match: \(names). Ask the user which one with ask_user.")
            }
            return (matches.first { $0.name == query } ?? matches[0], nil)
        } catch {
            return (nil, "No access to contacts. The user can allow it in the iPhone's settings.")
        }
    }

    private func prepareWhatsApp(_ input: JSON) async -> String {
        let query = input["contact"] as? String ?? ""
        let text = input["message"] as? String ?? ""
        guard !text.isEmpty else { return "The message is empty." }
        let found = resolve(query)
        guard let contact = found.match else { return found.problem ?? "Contact not found." }
        guard let number = Opener.internationalNumber(contact.phone),
              let url = Opener.whatsAppURL(number: number, text: text) else {
            return "That contact's phone number isn't usable."
        }
        guard await confirm("הודעה ל\(contact.name): \(text). להכין בוואטסאפ?") else {
            return "The user cancelled. Nothing was prepared."
        }
        phase = .thinking
        switch await Opener.open(url, title: "הודעה ל\(contact.name) מוכנה", body: text) {
        case .opened:
            return "The chat is open with the text typed. It is NOT sent until the user taps send."
        case .notified:
            return "A notification was posted; tapping it opens the chat with the text typed. It is NOT sent until the user taps send."
        case .failed:
            return "Couldn't open WhatsApp."
        }
    }

    private func callContact(_ input: JSON) async -> String {
        let found = resolve(input["contact"] as? String ?? "")
        guard let contact = found.match else { return found.problem ?? "Contact not found." }
        let digits = contact.phone.filter { $0.isNumber || $0 == "+" }
        guard let url = URL(string: "tel:\(digits)") else { return "That contact's phone number isn't usable." }
        guard await confirm("להתקשר ל\(contact.name)?") else { return "The user cancelled. No call was made." }
        phase = .thinking
        switch await Opener.open(url, title: "שיחה ל\(contact.name)", body: "אפשר ללחוץ כדי להתקשר") {
        case .opened:
            return "iOS is showing the call prompt; the user taps once to place the call."
        case .notified:
            return "A notification was posted; tapping it starts the call."
        case .failed:
            return "Couldn't start the call."
        }
    }
}
