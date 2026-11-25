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

    private let speaker = Speaker()
    private let speech = SpeechInput()
    private let claude = ClaudeClient()
    private let calendar = CalendarService()
    private lazy var brain = AgentBrain(claude: claude, host: self)
    private var loopTask: Task<Void, Never>?
    private var stopRequested = false

    init() {
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
        guard !isDriving else { return }
        loopTask = Task { await begin() }
    }

    func stop() {
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
            errorText = "חסר מפתח API. אפשר להזין אותו בהגדרות."
            return
        }
        guard await requestPermissions() else {
            errorText = "צריך לאשר מיקרופון וזיהוי דיבור בהגדרות של האייפון."
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
            errorText = "לא הצלחתי להפעיל את המיקרופון."
            return
        }
        isDriving = true
        UIApplication.shared.isIdleTimerDisabled = true
        await runLoop()
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
            phase = .listening
            let started = Date()
            guard let utterance = await speech.listen(maxWait: followUp ? 6 : 25) else {
                followUp = false
                // No recognizer or no network returns at once: don't spin.
                if Date().timeIntervalSince(started) < 1 { try? await Task.sleep(nanoseconds: 1_000_000_000) }
                continue
            }
            var request = utterance
            if !followUp {
                guard let afterWake = WakeWord.request(in: utterance, wake: currentSettings().assistantName) else {
                    continue
                }
                request = afterWake
                if request.isEmpty {
                    await say("כן?")
                    phase = .listening
                    guard let next = await speech.listen(maxWait: 8) else { continue }
                    request = next
                }
            }
            heard = request
            phase = .thinking
            let reached = await brain.handle(request)
            if !reached && !Task.isCancelled {
                await say("אופס, לא הצלחתי להתחבר כרגע. אפשר לנסות שוב עוד רגע.")
            }
            if stopRequested {
                await say("סוגר את מצב נהיגה.")
                stop()
                return
            }
            followUp = true
        }
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
        default:
            return "Unknown tool."
        }
    }

    // MARK: Tools

    /// Two chances to answer. Silence or anything unclear is a no.
    private func confirm(_ prompt: String) async -> Bool {
        for attempt in 0..<2 {
            await say(attempt == 0 ? prompt : "לא שמעתי. כן או לא?")
            phase = .listening
            if let reply = await speech.listen(maxWait: 7) { return CommandMatcher.confirm(reply) }
            if Task.isCancelled { return false }
        }
        return false
    }

    private func askUser(_ question: String) async -> String {
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
