import Foundation

/// What the brain needs from the app: a voice, and hands (the tools).
@MainActor
protocol AgentHost: AnyObject {
    func say(_ text: String) async
    func show(_ text: String)
    func speakPart(_ text: String) async
    func runTool(_ name: String, input: JSON) async -> String
    func currentSettings() -> AppSettings
}

/// Claude with a toolbox, in a loop. The conversation is append-only with content echoed back
/// unchanged, and starts fresh after a long pause or when it gets long.
@MainActor
final class AgentBrain {
    private static let maxSteps = 8
    private static let maxHistory = 40
    private static let maxToolResult = 6000
    private static let idleReset: TimeInterval = 30 * 60
    private static let fillerDelay: UInt64 = 3_000_000_000

    private let claude: ClaudeClient
    private unowned let host: AgentHost
    private let systemTemplate: String

    private var history: [JSON] = []
    private var lastUsed = Date.distantPast
    private var system = ""
    private var fillerDue = false
    private var spokeWords = false

    init(claude: ClaudeClient, host: AgentHost) {
        self.claude = claude
        self.host = host
        let url = Bundle.main.url(forResource: "prompt_agent", withExtension: "txt")
        systemTemplate = url.flatMap { try? String(contentsOf: $0, encoding: .utf8) } ?? ""
    }

    /// Returns false if Claude couldn't be reached.
    func handle(_ utterance: String) async -> Bool {
        let now = Date()
        if now.timeIntervalSince(lastUsed) > Self.idleReset || history.count > Self.maxHistory { history = [] }
        lastUsed = now
        // The system prompt stays fixed for the conversation; the time travels with each request.
        if history.isEmpty { system = buildSystem() }
        let stamped = "[\(Self.formatted(now, "EEEE d/M/yyyy HH:mm"))] \(utterance)"
        history.append(["role": "user", "content": stamped])
        fillerDue = true
        spokeWords = false
        var retried = false

        var step = 0
        while step < Self.maxSteps {
            step += 1
            let root: JSON
            do {
                root = try await speakingTurn()
            } catch let error as ClaudeError {
                var status = 0
                if case .http(let code) = error { status = code }
                if spokeWords && status != 400 {
                    // Part of the answer was already said: finish in words, don't start over.
                    history = []
                    await host.say("אופס, לא הצלחתי להתחבר כרגע. אפשר לנסות שוב עוד רגע.")
                    return true
                }
                if status == 400 && !retried && history.count > 1 {
                    // Old conversation no longer accepted: start over with just this request.
                    retried = true
                    system = buildSystem()
                    history = [["role": "user", "content": stamped]]
                    continue
                }
                history = []
                return false
            } catch {
                history = []
                return false
            }

            let content = root["content"] as? [JSON] ?? []
            history.append(["role": "assistant", "content": content])

            switch root["stop_reason"] as? String {
            case "tool_use":
                var results: [JSON] = []
                for block in content where block["type"] as? String == "tool_use" {
                    let name = block["name"] as? String ?? ""
                    let result = await host.runTool(name, input: block["input"] as? JSON ?? [:])
                    results.append([
                        "type": "tool_result",
                        "tool_use_id": block["id"] as? String ?? "",
                        "content": String(result.prefix(Self.maxToolResult)),
                    ])
                }
                // All results of one turn go back together in a single user message.
                history.append(["role": "user", "content": results])
            case "pause_turn":
                continue
            case "refusal":
                history = []
                await host.say("את זה אני לא יכול לעשות.")
                return true
            default:
                return true
            }
        }
        await host.say("זה לקח יותר מדי צעדים, בוא ננסה שוב בפשטות.")
        return true
    }

    func reset() {
        history = []
    }

    /// One step, spoken while it's being written: each sentence goes to the voice when complete.
    private func speakingTurn() async throws -> JSON {
        let (queue, continuation) = AsyncStream.makeStream(of: String.self)
        let speaker = Task { @MainActor [host] in
            for await sentence in queue { await host.speakPart(sentence) }
        }
        // A slow answer gets a short sign of life instead of silence.
        let filler = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: Self.fillerDelay)
            guard !Task.isCancelled, let self, self.fillerDue else { return }
            self.fillerDue = false
            continuation.yield("אני על זה.")
        }
        defer { filler.cancel() }

        let splitter = SentenceSplitter()
        let markSpoken: () -> Void = { [weak self] in
            self?.spokeWords = true
            self?.fillerDue = false
        }
        do {
            let root = try await claude.agentTurn(
                settings: host.currentSettings(),
                system: system,
                messages: history,
                tools: AgentTools.definitions
            ) { piece in
                filler.cancel()
                for sentence in splitter.feed(piece) {
                    markSpoken()
                    continuation.yield(sentence)
                }
            }
            if let rest = splitter.flush() {
                markSpoken()
                continuation.yield(rest)
            }
            continuation.finish()
            await speaker.value
            let text = Self.textOf(root["content"] as? [JSON] ?? [])
            if !text.isEmpty { host.show(text) }
            return root
        } catch {
            continuation.finish()
            await speaker.value
            throw error
        }
    }

    private func buildSystem() -> String {
        let settings = host.currentSettings()
        let owner = settings.ownerName.trimmingCharacters(in: .whitespaces)
        let now = Self.formatted(Date(), "EEEE, d 'ב'MMMM yyyy, HH:mm")
        return systemTemplate
            .replacingOccurrences(of: "{{NAME}}", with: settings.assistantName)
            .replacingOccurrences(of: "{{OWNER}}", with: owner.isEmpty ? "המשתמש" : owner)
            .replacingOccurrences(of: "{{NOW}}", with: "עכשיו: \(now). המשתמש בישראל.")
    }

    private static func textOf(_ content: [JSON]) -> String {
        let text = content
            .filter { $0["type"] as? String == "text" }
            .compactMap { $0["text"] as? String }
            .joined(separator: " ")
        return SentenceSplitter.stripFormatting(text).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func formatted(_ date: Date, _ format: String) -> String {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "he_IL")
        formatter.dateFormat = format
        return formatter.string(from: date)
    }
}
