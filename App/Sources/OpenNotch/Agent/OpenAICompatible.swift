import Foundation

/// Chat Completions over SSE — OpenAI, OpenRouter, Groq, Gemini (OpenAI
/// endpoint), Ollama and LM Studio all speak it.
struct OpenAICompatibleProvider: ChatProvider {
    let name: String
    let model: String
    let baseURL: URL
    let apiKey: String?
    var extraHeaders: [String: String] = [:]
    /// `stream_options.include_usage` — not every server accepts it.
    var usageInStream = true
    var supportsImages = true

    var isConnected: Bool { true }
    var supportsTools: Bool { true }

    func turn(system: String, messages: [ChatMessage], tools: [ToolSpec]) -> AsyncThrowingStream<ProviderEvent, Error> {
        var body: [String: Any] = [
            "model": model,
            "stream": true,
            "messages": [["role": "system", "content": system]] + messages.compactMap(Self.wire(supportsImages)),
        ]
        if usageInStream { body["stream_options"] = ["include_usage": true] }
        if !tools.isEmpty {
            body["tools"] = tools.map { t in
                ["type": "function",
                 "function": ["name": t.name, "description": t.description,
                              "parameters": HTTP.parse(t.schema) ?? ["type": "object", "properties": [:]]]]
            }
        }
        var req = URLRequest(url: baseURL.appendingPathComponent("chat/completions"))
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let apiKey, !apiKey.isEmpty { req.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization") }
        for (k, v) in extraHeaders { req.setValue(v, forHTTPHeaderField: k) }
        req.httpBody = HTTP.json(body)
        let providerName = name

        return AsyncThrowingStream { c in
            let task = Task {
                // Tool-call fragments arrive keyed by index: id + name first, then argument pieces.
                var calls: [Int: ToolCall] = [:]
                var finish = "stop"
                do {
                    for try await ev in HTTP.sse(req, provider: providerName) {
                        if ev.data == "[DONE]" { break }
                        guard let obj = HTTP.parse(ev.data) else { continue }
                        if let err = obj["error"] as? [String: Any] {
                            throw ProviderError(message: "\(providerName): \(err["message"] as? String ?? "error")")
                        }
                        if let u = obj["usage"] as? [String: Any] {
                            c.yield(.usage(input: u["prompt_tokens"] as? Int ?? 0, output: u["completion_tokens"] as? Int ?? 0))
                        }
                        guard let choice = (obj["choices"] as? [[String: Any]])?.first else { continue }
                        if let f = choice["finish_reason"] as? String { finish = f }
                        guard let delta = choice["delta"] as? [String: Any] else { continue }
                        if let t = delta["content"] as? String, !t.isEmpty { c.yield(.text(t)) }
                        for tc in delta["tool_calls"] as? [[String: Any]] ?? [] {
                            let i = tc["index"] as? Int ?? 0
                            var call = calls[i] ?? ToolCall(id: "", name: "", arguments: "")
                            if let id = tc["id"] as? String, !id.isEmpty { call.id = id }
                            if let extra = tc["extra_content"] { call.extra = String(data: HTTP.json(extra), encoding: .utf8) }
                            if let fn = tc["function"] as? [String: Any] {
                                if let n = fn["name"] as? String, !n.isEmpty { call.name = n }
                                if let a = fn["arguments"] as? String { call.arguments += a }
                            }
                            calls[i] = call
                        }
                    }
                    for i in calls.keys.sorted() {
                        var call = calls[i]!
                        guard !call.name.isEmpty else { continue }
                        if call.id.isEmpty { call.id = "call_\(UUID().uuidString.prefix(8))" }
                        if call.arguments.trimmingCharacters(in: .whitespaces).isEmpty { call.arguments = "{}" }
                        c.yield(.toolCall(call))
                    }
                    c.yield(.stop(reason: finish))
                    c.finish()
                } catch {
                    c.finish(throwing: error)
                }
            }
            c.onTermination = { _ in task.cancel() }
        }
    }

    /// Our message → a Chat Completions message.
    static func wire(_ images: Bool) -> (ChatMessage) -> [String: Any]? {
        { m in
            switch m.role {
            case .system:
                return ["role": "system", "content": m.text]
            case .user:
                let imgs = images ? (m.images ?? []).compactMap(HTTP.imageDataURL) : []
                guard !imgs.isEmpty else { return ["role": "user", "content": m.text] }
                var parts: [[String: Any]] = [["type": "text", "text": m.text]]
                for i in imgs {
                    parts.append(["type": "image_url", "image_url": ["url": "data:\(i.mime);base64,\(i.base64)"]])
                }
                return ["role": "user", "content": parts]
            case .assistant:
                var out: [String: Any] = ["role": "assistant", "content": m.text]
                if let calls = m.toolCalls, !calls.isEmpty {
                    out["tool_calls"] = calls.map { c -> [String: Any] in
                        var d: [String: Any] = ["id": c.id, "type": "function",
                                                "function": ["name": c.name, "arguments": c.arguments]]
                        if let e = c.extra, let obj = try? JSONSerialization.jsonObject(with: Data(e.utf8)) {
                            d["extra_content"] = obj                 // echo back unchanged (Gemini thought signatures)
                        }
                        return d
                    }
                    if m.text.isEmpty { out["content"] = NSNull() }
                }
                return out
            case .tool:
                return ["role": "tool", "tool_call_id": m.toolCallId ?? "", "content": m.text]
            }
        }
    }

    /// Model ids the server offers (`GET /models`).
    static func listModels(baseURL: URL, apiKey: String?, extraHeaders: [String: String] = [:]) async throws -> [String] {
        var req = URLRequest(url: baseURL.appendingPathComponent("models"))
        req.timeoutInterval = 15
        if let apiKey, !apiKey.isEmpty { req.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization") }
        for (k, v) in extraHeaders { req.setValue(v, forHTTPHeaderField: k) }
        let (data, resp) = try await HTTP.session.data(for: req)
        let status = (resp as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200 else {
            throw ProviderError(message: HTTP.errorMessage(status: status, body: String(data: data, encoding: .utf8) ?? "", provider: baseURL.host ?? "server"))
        }
        let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        let list = (obj?["data"] as? [[String: Any]]) ?? (obj?["models"] as? [[String: Any]]) ?? []
        return list.compactMap { ($0["id"] as? String) ?? ($0["name"] as? String) }
            .map { $0.hasPrefix("models/") ? String($0.dropFirst(7)) : $0 }      // Gemini lists "models/…"
    }
}
