import Foundation
import os

typealias JSON = [String: Any]

enum ClaudeError: Error {
    case noKey
    case network
    case http(Int)
    case badResponse
}

private let log = Logger(subsystem: "com.driveagent.ios", category: "claude")

/// Minimal streaming client for POST /v1/messages. Swift has no official Anthropic SDK.
/// Logs only status codes, never message content or the API key.
@MainActor
final class ClaudeClient {
    private static let endpoint = URL(string: "https://api.anthropic.com/v1/messages")!
    private var webSearchUnavailable = false

    /// One step of the agent loop. Text goes to `onText` as it is written; the return value is
    /// the same message a non-streaming call gives, so it can be echoed back unchanged.
    func agentTurn(
        settings: AppSettings,
        system: String,
        messages: [JSON],
        tools: [JSON],
        onText: @escaping (String) -> Void
    ) async throws -> JSON {
        guard !settings.apiKey.isEmpty else { throw ClaudeError.noKey }
        var withWeb = !webSearchUnavailable
        var outcome = try await send(
            body(settings, system, messages, tools, withWeb: withWeb), apiKey: settings.apiKey, onText: onText
        )
        if case .failure(400) = outcome, withWeb {
            webSearchUnavailable = true
            withWeb = false
            outcome = try await send(
                body(settings, system, messages, tools, withWeb: false), apiKey: settings.apiKey, onText: onText
            )
        }
        switch outcome {
        case .success(let root): return root
        case .failure(let code): throw ClaudeError.http(code)
        }
    }

    /// One request whose answer must match `schema` (structured outputs): returns the parsed JSON.
    /// For background work like a review or an import, not the live conversation.
    func structured(
        settings: AppSettings,
        system: String,
        text: String,
        schema: JSON,
        maxTokens: Int = 16000
    ) async throws -> JSON {
        guard !settings.apiKey.isEmpty else { throw ClaudeError.noKey }
        var output: JSON = ["format": ["type": "json_schema", "schema": schema] as JSON]
        if Self.isCurrentGeneration(settings.model) { output["effort"] = "medium" }
        let body: JSON = [
            "model": settings.model,
            "max_tokens": maxTokens,
            "system": system,
            "messages": [["role": "user", "content": text] as JSON],
            "output_config": output,
        ]
        var request = URLRequest(url: Self.endpoint, timeoutInterval: 300)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "content-type")
        request.setValue(settings.apiKey, forHTTPHeaderField: "x-api-key")
        request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await URLSession.shared.data(for: request)
        } catch {
            throw ClaudeError.network
        }
        guard let http = response as? HTTPURLResponse else { throw ClaudeError.badResponse }
        guard (200...299).contains(http.statusCode) else {
            log.warning("Structured HTTP \(http.statusCode)")
            throw ClaudeError.http(http.statusCode)
        }
        guard let root = try? JSONSerialization.jsonObject(with: data) as? JSON,
              root["stop_reason"] as? String != "refusal",
              let blocks = root["content"] as? [JSON],
              let answer = blocks.first(where: { $0["type"] as? String == "text" })?["text"] as? String,
              let answerData = answer.data(using: .utf8),
              let result = try? JSONSerialization.jsonObject(with: answerData) as? JSON else {
            throw ClaudeError.badResponse
        }
        return result
    }

    /// A real check against the service: true if the key works, false if it is refused,
    /// nil if there is no connection. Costs nothing: it only lists models.
    static func checkConnection(apiKey: String) async -> Bool? {
        guard !apiKey.isEmpty else { return false }
        var request = URLRequest(url: URL(string: "https://api.anthropic.com/v1/models?limit=1")!, timeoutInterval: 15)
        request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        do {
            let (_, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse else { return nil }
            if (200...299).contains(http.statusCode) { return true }
            log.warning("Check HTTP \(http.statusCode)")
            return http.statusCode >= 500 ? nil : false
        } catch {
            return nil
        }
    }

    private enum Outcome {
        case success(JSON)
        case failure(Int)
    }

    private func body(
        _ settings: AppSettings, _ system: String, _ messages: [JSON], _ tools: [JSON], withWeb: Bool
    ) -> JSON {
        var allTools = tools
        if withWeb {
            allTools.append(["type": "web_search_20260209", "name": "web_search", "max_uses": 3])
        }
        let cache: JSON = ["type": "ephemeral"]
        var result: JSON = [
            "model": settings.model,
            "max_tokens": 4096,
            "system": [["type": "text", "text": system, "cache_control": cache] as JSON],
            "cache_control": cache,
            "messages": messages,
            "tools": allTools,
            "stream": true,
        ]
        if Self.isCurrentGeneration(settings.model) { result["output_config"] = ["effort": "low"] as JSON }
        if let off = Self.thinkingOff(settings.model) { result["thinking"] = ["type": off] as JSON }
        return result
    }

    private func send(_ body: JSON, apiKey: String, onText: @escaping (String) -> Void) async throws -> Outcome {
        var request = URLRequest(url: Self.endpoint, timeoutInterval: 90)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "content-type")
        request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        // Sorted keys keep the request bytes identical from turn to turn, for the prompt cache.
        request.httpBody = try JSONSerialization.data(withJSONObject: body, options: [.sortedKeys])

        do {
            let (bytes, response) = try await URLSession.shared.bytes(for: request)
            guard let http = response as? HTTPURLResponse else { throw ClaudeError.badResponse }
            guard (200...299).contains(http.statusCode) else {
                log.warning("HTTP \(http.statusCode)")
                return .failure(http.statusCode)
            }
            let assembler = StreamAssembler()
            for try await line in bytes.lines {
                try Task.checkCancellation()
                guard line.hasPrefix("data:") else { continue }
                let payload = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
                guard let data = payload.data(using: .utf8),
                      let event = try? JSONSerialization.jsonObject(with: data) as? JSON else {
                    throw ClaudeError.badResponse
                }
                if let text = try assembler.accept(event) { onText(text) }
            }
            return .success(try assembler.result())
        } catch let error as URLError {
            if error.code == .cancelled { throw CancellationError() }
            log.warning("Network error \(error.code.rawValue)")
            throw ClaudeError.network
        }
    }

    private static func isCurrentGeneration(_ model: String) -> Bool {
        ["claude-opus-5", "claude-sonnet-5", "claude-haiku-5", "claude-fable-5"].contains { model.hasPrefix($0) }
    }

    /// Speed beats deep reasoning in a live conversation. Each model has its own "off" value.
    private static func thinkingOff(_ model: String) -> String? {
        if model.hasPrefix("claude-sonnet-5-5") { return "between_tools" }
        if model.hasPrefix("claude-haiku-5-5") { return "disabled" }
        return nil
    }
}

/// Rebuilds the full message from the stream's events, block by block.
private final class StreamAssembler {
    private var message: JSON?
    private var blocks: [Int: JSON] = [:]
    private var toolInputs: [Int: String] = [:]
    private var stopReason = ""
    private var complete = false
    private var hadText = false

    func accept(_ event: JSON) throws -> String? {
        let index = event["index"] as? Int ?? -1
        switch event["type"] as? String {
        case "message_start":
            message = event["message"] as? JSON
        case "content_block_start":
            guard let block = event["content_block"] as? JSON else { return nil }
            blocks[index] = block
            // Separate text blocks (split by a web search) mustn't run into each other.
            if block["type"] as? String == "text", hadText { return " " }
        case "content_block_delta":
            guard let delta = event["delta"] as? JSON else { return nil }
            return apply(delta, at: index)
        case "content_block_stop":
            if let raw = toolInputs.removeValue(forKey: index),
               !raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                guard let data = raw.data(using: .utf8),
                      let input = try? JSONSerialization.jsonObject(with: data) as? JSON else {
                    throw ClaudeError.badResponse
                }
                blocks[index]?["input"] = input
            }
        case "message_delta":
            stopReason = (event["delta"] as? JSON)?["stop_reason"] as? String ?? ""
        case "message_stop":
            complete = true
        case "error":
            throw ClaudeError.http(500)
        default:
            break
        }
        return nil
    }

    private func apply(_ delta: JSON, at index: Int) -> String? {
        guard var block = blocks[index] else { return nil }
        defer { blocks[index] = block }
        switch delta["type"] as? String {
        case "text_delta":
            let text = delta["text"] as? String ?? ""
            block["text"] = (block["text"] as? String ?? "") + text
            if !text.isEmpty { hadText = true }
            return text
        case "thinking_delta":
            block["thinking"] = (block["thinking"] as? String ?? "") + (delta["thinking"] as? String ?? "")
        case "signature_delta":
            block["signature"] = delta["signature"] as? String ?? ""
        case "input_json_delta":
            toolInputs[index, default: ""] += delta["partial_json"] as? String ?? ""
        case "citations_delta":
            var citations = block["citations"] as? [Any] ?? []
            citations.append(delta["citation"] ?? NSNull())
            block["citations"] = citations
        default:
            break
        }
        return nil
    }

    func result() throws -> JSON {
        guard var root = message, complete else { throw ClaudeError.network }
        // An empty text block isn't accepted when echoed back.
        root["content"] = blocks.keys.sorted().compactMap { key -> JSON? in
            guard let block = blocks[key] else { return nil }
            if block["type"] as? String == "text", (block["text"] as? String ?? "").isEmpty { return nil }
            return block
        }
        root["stop_reason"] = stopReason
        return root
    }
}
