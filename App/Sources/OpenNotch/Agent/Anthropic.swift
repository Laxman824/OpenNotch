import Foundation

/// Claude via the Anthropic Messages API (raw HTTPS — there is no official
/// Swift SDK). Streams SSE; keeps every content block of the assistant turn
/// (thinking, fallback, tool_use …) so it can be replayed unchanged, as the
/// API requires for thinking blocks.
struct AnthropicProvider: ChatProvider {
    static let defaultModel = "claude-opus-5-5"
    static let knownModels = ["claude-opus-5-5", "claude-sonnet-5-5", "claude-haiku-4-5", "claude-fable-5-1"]
    /// Models that take `fallbacks: "default"` (server-side refusal fallback).
    private static let fallbackModels: Set<String> = ["claude-opus-5-5", "claude-fable-5-1", "claude-opus-5", "claude-sonnet-5-5"]

    let name = "Anthropic"
    let model: String
    let apiKey: String
    var isConnected: Bool { true }
    var supportsTools: Bool { true }
    var supportsImages: Bool { true }

    private var source: String { "anthropic:\(model)" }

    func turn(system: String, messages: [ChatMessage], tools: [ToolSpec]) -> AsyncThrowingStream<ProviderEvent, Error> {
        var body: [String: Any] = [
            "model": model,
            "max_tokens": 32000,
            "stream": true,
            "system": [["type": "text", "text": system]],
            "messages": wire(messages),
            // Auto-places a cache breakpoint on the last cacheable block.
            "cache_control": ["type": "ephemeral"],
        ]
        if !model.contains("haiku") {
            body["output_config"] = ["effort": "medium"]      // Opus 5.5 defaults to medium; be explicit
        }
        if !tools.isEmpty {
            body["tools"] = tools.map { t in
                ["name": t.name, "description": t.description,
                 "input_schema": HTTP.parse(t.schema) ?? ["type": "object", "properties": [:]],
                 "eager_input_streaming": true]
            }
        }
        let fallback = Self.fallbackModels.contains(model)
        if fallback { body["fallbacks"] = "default" }

        var req = URLRequest(url: URL(string: "https://api.anthropic.com/v1/messages")!)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        req.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        if fallback { req.setValue("server-side-fallback-2026-07-01", forHTTPHeaderField: "anthropic-beta") }
        req.httpBody = HTTP.json(body)
        let source = self.source

        return AsyncThrowingStream { c in
            let task = Task {
                var blocks: [Int: [String: Any]] = [:]
                var partialJSON: [Int: String] = [:]
                var stop = "end_turn"
                var inTok = 0, outTok = 0
                var sawText = false
                do {
                    for try await ev in HTTP.sse(req, provider: "Anthropic") {
                        guard let obj = HTTP.parse(ev.data) else { continue }
                        switch obj["type"] as? String ?? "" {
                        case "message_start":
                            let u = (obj["message"] as? [String: Any])?["usage"] as? [String: Any] ?? [:]
                            inTok = (u["input_tokens"] as? Int ?? 0) + (u["cache_read_input_tokens"] as? Int ?? 0)
                                + (u["cache_creation_input_tokens"] as? Int ?? 0)
                        case "content_block_start":
                            let i = obj["index"] as? Int ?? blocks.count
                            blocks[i] = obj["content_block"] as? [String: Any] ?? [:]
                        case "content_block_delta":
                            let i = obj["index"] as? Int ?? 0
                            let d = obj["delta"] as? [String: Any] ?? [:]
                            var b = blocks[i] ?? [:]
                            switch d["type"] as? String ?? "" {
                            case "text_delta":
                                let t = d["text"] as? String ?? ""
                                b["text"] = (b["text"] as? String ?? "") + t
                                if b["type"] as? String == "text", !t.isEmpty { sawText = true; c.yield(.text(t)) }
                            case "input_json_delta":
                                partialJSON[i, default: ""] += d["partial_json"] as? String ?? ""
                            case "thinking_delta":
                                b["thinking"] = (b["thinking"] as? String ?? "") + (d["thinking"] as? String ?? "")
                            case "signature_delta":
                                b["signature"] = (b["signature"] as? String ?? "") + (d["signature"] as? String ?? "")
                            case "citations_delta":
                                if let cit = d["citation"] {
                                    b["citations"] = (b["citations"] as? [Any] ?? []) + [cit]
                                }
                            default:
                                break
                            }
                            blocks[i] = b
                        case "content_block_stop":
                            let i = obj["index"] as? Int ?? 0
                            if blocks[i]?["type"] as? String == "tool_use" {
                                let text = partialJSON[i] ?? ""
                                // Eager input streaming: the API doesn't validate the input, so we do.
                                let parsed = text.isEmpty ? [:] : HTTP.parse(text)
                                blocks[i]?["input"] = parsed ?? [:]
                                if parsed == nil { blocks[i]?["_invalid_json"] = text }
                            }
                        case "message_delta":
                            if let r = (obj["delta"] as? [String: Any])?["stop_reason"] as? String { stop = r }
                            if let u = obj["usage"] as? [String: Any] { outTok = u["output_tokens"] as? Int ?? outTok }
                        case "error":
                            let e = obj["error"] as? [String: Any]
                            throw ProviderError(message: "Anthropic: \(e?["message"] as? String ?? "stream error")")
                        default:
                            break
                        }
                    }
                    if stop == "refusal" && !sawText {
                        c.yield(.text("_The model declined this request._"))
                    } else if stop == "max_tokens" {
                        c.yield(.text("\n\n_(The answer hit the length limit.)_"))
                    }
                    var ordered = blocks.keys.sorted().compactMap { blocks[$0] }
                    for b in ordered where b["type"] as? String == "tool_use" {
                        let args: String
                        if let bad = b["_invalid_json"] as? String { args = bad }         // the loop reports INVALID_JSON
                        else { args = String(data: HTTP.json(b["input"] ?? [:]), encoding: .utf8) ?? "{}" }
                        c.yield(.toolCall(ToolCall(id: b["id"] as? String ?? UUID().uuidString,
                                                   name: b["name"] as? String ?? "", arguments: args)))
                    }
                    ordered = ordered.map { var b = $0; b.removeValue(forKey: "_invalid_json"); return b }
                    if let raw = String(data: HTTP.json(ordered), encoding: .utf8) { c.yield(.raw(raw, source: source)) }
                    c.yield(.usage(input: inTok, output: outTok))
                    c.yield(.stop(reason: stop))
                    c.finish()
                } catch {
                    c.finish(throwing: error)
                }
            }
            c.onTermination = { _ in task.cancel() }
        }
    }

    /// Our transcript → Messages API turns (tool results grouped into one user
    /// turn, consecutive same-role turns merged, assistant turns replayed raw).
    private func wire(_ messages: [ChatMessage]) -> [[String: Any]] {
        var out: [[String: Any]] = []
        func push(_ role: String, _ blocks: [[String: Any]]) {
            guard !blocks.isEmpty else { return }
            if var last = out.last, last["role"] as? String == role {
                last["content"] = (last["content"] as? [[String: Any]] ?? []) + blocks
                out[out.count - 1] = last
            } else {
                out.append(["role": role, "content": blocks])
            }
        }
        for m in messages {
            switch m.role {
            case .system:
                continue
            case .user:
                var blocks: [[String: Any]] = []
                for p in m.images ?? [] {
                    if let img = HTTP.imageDataURL(p) {
                        blocks.append(["type": "image", "source": ["type": "base64", "media_type": img.mime, "data": img.base64]])
                    }
                }
                if !m.text.isEmpty { blocks.append(["type": "text", "text": m.text]) }
                push("user", blocks)
            case .assistant:
                if m.rawSource == source, let raw = m.raw,
                   let data = raw.data(using: .utf8),
                   let blocks = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]], !blocks.isEmpty {
                    push("assistant", blocks)
                    continue
                }
                var blocks: [[String: Any]] = []
                if !m.text.isEmpty { blocks.append(["type": "text", "text": m.text]) }
                for call in m.toolCalls ?? [] {
                    blocks.append(["type": "tool_use", "id": call.id, "name": call.name,
                                   "input": HTTP.parse(call.arguments) ?? [:]])
                }
                push("assistant", blocks)
            case .tool:
                var block: [String: Any] = ["type": "tool_result", "tool_use_id": m.toolCallId ?? "", "content": m.text]
                if m.isError == true { block["is_error"] = true }
                push("user", [block])
            }
        }
        return out
    }

    static func listModels(apiKey: String) async throws -> [String] {
        var req = URLRequest(url: URL(string: "https://api.anthropic.com/v1/models?limit=100")!)
        req.timeoutInterval = 15
        req.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        req.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        let (data, resp) = try await HTTP.session.data(for: req)
        let status = (resp as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200 else {
            throw ProviderError(message: HTTP.errorMessage(status: status, body: String(data: data, encoding: .utf8) ?? "", provider: "Anthropic"))
        }
        let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        return ((obj?["data"] as? [[String: Any]]) ?? []).compactMap { $0["id"] as? String }
    }
}
