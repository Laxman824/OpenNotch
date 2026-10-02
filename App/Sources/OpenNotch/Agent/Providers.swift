import Foundation

// Provider-neutral conversation types and the provider protocol. Each
// provider converts these to its own wire format (OpenAI chat completions,
// Anthropic Messages, Apple on-device).

struct ToolCall: Codable, Equatable, Sendable {
    var id: String
    var name: String
    var arguments: String          // JSON object as text, exactly as the model produced it
    /// Opaque per-call data some servers require back (Gemini's thought_signature), as JSON.
    var extra: String? = nil
}

struct ChatMessage: Codable, Equatable, Sendable {
    enum Role: String, Codable, Sendable { case system, user, assistant, tool }
    var role: Role
    var text: String
    var at = Date()
    /// Images for this turn (user attachments, screenshots a tool took).
    var images: [String]? = nil
    /// Assistant: tools it asked for.
    var toolCalls: [ToolCall]? = nil
    /// Tool result: which call it answers, and whether it failed.
    var toolCallId: String? = nil
    var isError: Bool? = nil
    /// The provider's own content blocks for this assistant turn (JSON), replayed
    /// verbatim to the same provider + model — Anthropic requires thinking /
    /// fallback blocks back unchanged.
    var raw: String? = nil
    var rawSource: String? = nil   // "anthropic:<model>"
}

/// A tool as the model sees it.
struct ToolSpec: Sendable {
    let name: String
    let description: String
    let schema: String             // JSON Schema object, as JSON text
}

enum ProviderEvent: Sendable {
    case text(String)
    /// The model's visible reasoning (Claude's summarized thinking, `reasoning` fields).
    case thinking(String)
    case toolCall(ToolCall)
    case usage(input: Int, output: Int)
    /// Complete provider content for the assistant turn (see ChatMessage.raw).
    case raw(String, source: String)
    /// A tool the provider ran itself (Apple on-device calls tools inside its session) — shown, not re-run.
    case ranTool(ToolCall, ok: Bool, result: String)
    case stop(reason: String)
}

struct ProviderError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

protocol ChatProvider: Sendable {
    var name: String { get }            // "OpenAI", "OpenRouter", "Apple on-device" …
    var model: String { get }
    var isConnected: Bool { get }
    var supportsTools: Bool { get }
    var supportsImages: Bool { get }
    /// Roughly how much conversation (characters) to send — small for local models.
    var contextChars: Int { get }
    func turn(system: String, messages: [ChatMessage], tools: [ToolSpec]) -> AsyncThrowingStream<ProviderEvent, Error>
}

extension ChatProvider {
    var contextChars: Int { 300_000 }
}

/// Until the user connects an AI: a friendly explanation, streamed like a real answer.
struct NotConnectedProvider: ChatProvider {
    let name = "Not connected"
    let model = "Connect an AI"
    let isConnected = false
    let supportsTools = false
    let supportsImages = false

    func turn(system: String, messages: [ChatMessage], tools: [ToolSpec]) -> AsyncThrowingStream<ProviderEvent, Error> {
        let reply = """
        I'm not connected to an AI yet. Open **Settings › AI** to pick one — sign in with OpenRouter, \
        paste an API key (OpenAI, Anthropic, Gemini, Groq), use a local model with Ollama or LM Studio, \
        or Apple's on-device model. Everything stays on your Mac.
        """
        return AsyncThrowingStream { c in
            let task = Task {
                for word in reply.split(separator: " ", omittingEmptySubsequences: false) {
                    if Task.isCancelled { break }
                    c.yield(.text(String(word) + " "))
                    try? await Task.sleep(nanoseconds: 18_000_000)
                }
                c.yield(.stop(reason: "end_turn"))
                c.finish()
            }
            c.onTermination = { _ in task.cancel() }
        }
    }
}

// MARK: - Shared HTTP helpers

enum HTTP {
    static let session: URLSession = {
        let c = URLSessionConfiguration.default
        c.timeoutIntervalForRequest = 300
        c.timeoutIntervalForResource = 1800
        return URLSession(configuration: c)
    }()

    /// Any JSON value → data. Scalars ("1", true) are allowed; anything JSON can't hold gives empty data.
    /// (JSONSerialization raises an Objective-C exception for those — `try?` can't catch it, the app would crash.)
    static func json(_ obj: Any) -> Data {
        guard JSONSerialization.isValidJSONObject([obj]) else { return Data() }
        return (try? JSONSerialization.data(withJSONObject: obj, options: .fragmentsAllowed)) ?? Data()
    }

    static func parse(_ text: String) -> [String: Any]? {
        guard let d = text.data(using: .utf8) else { return nil }
        return try? JSONSerialization.jsonObject(with: d) as? [String: Any]
    }

    /// Reads an error body into one readable line.
    static func errorMessage(status: Int, body: String, provider: String) -> String {
        let obj = parse(body)
        let detail = ((obj?["error"] as? [String: Any])?["message"] as? String)
            ?? (obj?["error"] as? String) ?? (obj?["message"] as? String)
            ?? String(body.prefix(300))
        switch status {
        case 401, 403: return "\(provider) rejected the API key (\(status)). Check it in Settings › AI. \(detail)"
        case 404: return "\(provider): model or endpoint not found (404). \(detail)"
        case 429: return "\(provider) is rate-limiting or out of credit (429). \(detail)"
        default: return "\(provider) error \(status): \(detail)"
        }
    }

    /// Server-sent events: yields each `data:` payload (and the `event:` name if any).
    static func sse(_ req: URLRequest, provider: String) -> AsyncThrowingStream<(event: String?, data: String), Error> {
        AsyncThrowingStream { c in
            let task = Task {
                do {
                    // Rate limits (429) and overloads (503) before any output: wait as
                    // the server suggests (≤ 20 s) and retry, twice at most.
                    var attempt = 0
                    var bytes: URLSession.AsyncBytes
                    while true {
                        let (b, resp) = try await session.bytes(for: req)
                        let http = resp as? HTTPURLResponse
                        let status = http?.statusCode ?? 0
                        if status == 200 { bytes = b; break }
                        var body = ""
                        for try await line in b.lines { body += line; if body.count > 4000 { break } }
                        if (status == 429 || status == 503) && attempt < 2,
                           let wait = retryDelay(header: http?.value(forHTTPHeaderField: "retry-after"), body: body), wait <= 20 {
                            attempt += 1
                            try await Task.sleep(nanoseconds: UInt64((wait + 0.5) * 1e9))
                            continue
                        }
                        throw ProviderError(message: errorMessage(status: status, body: body, provider: provider))
                    }
                    var event: String?
                    for try await line in bytes.lines {
                        if Task.isCancelled { break }
                        if line.hasPrefix("event:") {
                            event = line.dropFirst(6).trimmingCharacters(in: .whitespaces)
                        } else if line.hasPrefix("data:") {
                            c.yield((event, line.dropFirst(5).trimmingCharacters(in: .whitespaces)))
                            event = nil
                        }
                    }
                    c.finish()
                } catch {
                    c.finish(throwing: error)
                }
            }
            c.onTermination = { _ in task.cancel() }
        }
    }

    /// Seconds to wait: the Retry-After header, or "try again in 11.2s" in the body.
    static func retryDelay(header: String?, body: String) -> Double? {
        if let h = header, let v = Double(h.trimmingCharacters(in: .whitespaces)) { return v }
        if let r = body.range(of: #"(?:try again in|retry in|retry after)\s*([0-9.]+)\s*s"#, options: [.regularExpression, .caseInsensitive]) {
            let digits = body[r].replacingOccurrences(of: #"[^0-9.]"#, with: "", options: .regularExpression)
            return Double(digits)
        }
        return header == nil ? 2 : nil
    }

    static func imageDataURL(_ path: String) -> (mime: String, base64: String)? {
        guard let data = FileManager.default.contents(atPath: path), data.count < 15_000_000 else { return nil }
        let ext = (path as NSString).pathExtension.lowercased()
        let mime = ext == "png" ? "image/png" : ext == "gif" ? "image/gif" : ext == "webp" ? "image/webp" : "image/jpeg"
        return (mime, data.base64EncodedString())
    }
}
