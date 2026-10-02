import Foundation
#if canImport(FoundationModels)
import FoundationModels
#endif

/// Apple's on-device model (macOS 26+, Apple Intelligence Macs): free, private,
/// offline. Small context, so it gets a trimmed transcript and a few read-only
/// tools that the framework calls itself inside the session (`onDeviceTools`);
/// each run is reported as `.ranTool` so the transcript shows it.
struct AppleOnDeviceProvider: ChatProvider {
    let name = "Apple on-device"
    let model = "Apple Intelligence"
    var isConnected: Bool { Self.availability == nil }
    let supportsTools = false
    let supportsImages = false
    let contextChars = 12_000

    /// nil when usable, else why not.
    static var availability: String? {
        #if canImport(FoundationModels)
        if #available(macOS 26.0, *) {
            switch SystemLanguageModel.default.availability {
            case .available: return nil
            case .unavailable(.deviceNotEligible): return "This Mac doesn't support Apple Intelligence."
            case .unavailable(.appleIntelligenceNotEnabled):
                return "Turn on Apple Intelligence in System Settings › Apple Intelligence & Siri, then try again."
            case .unavailable(.modelNotReady): return "Apple's on-device model is still downloading — try again in a while."
            case .unavailable(let reason): return "Apple Intelligence isn't available (\(reason))."
            @unknown default: return "Apple Intelligence isn't available."
            }
        }
        return "Needs macOS 26 or later."
        #else
        return "This build doesn't include Apple's on-device model."
        #endif
    }

    /// Read-only tools small enough for a ~4k-token context. Nothing that needs approval.
    static let onDeviceTools = ["weather", "calendar_events", "reminders_list", "system_info", "recall", "search_chats"]
    static var registry: [AgentTool] { ToolKit.all() + DailyTools.all() + RecallTools.all() }

    static func describe(_ error: Error) -> String {
        #if canImport(FoundationModels)
        if #available(macOS 26.0, *), let e = error as? LanguageModelSession.GenerationError {
            switch e {
            case .exceededContextWindowSize: return "the conversation is too long for the on-device model — start a new chat (⌘N)."
            case .guardrailViolation: return "Apple's safety filter declined this request."
            default: break
            }
        }
        #endif
        return error.localizedDescription
    }

    func turn(system: String, messages: [ChatMessage], tools: [ToolSpec]) -> AsyncThrowingStream<ProviderEvent, Error> {
        AsyncThrowingStream { c in
            let task = Task {
                #if canImport(FoundationModels)
                if #available(macOS 26.0, *) {
                    do {
                        // Recent turns as plain text; the last user message is the prompt.
                        let recent = messages.filter { $0.role == .user || $0.role == .assistant }.suffix(8)
                        var history = ""
                        for m in recent.dropLast() {
                            history += (m.role == .user ? "User: " : "Assistant: ") + String(m.text.prefix(1500)) + "\n"
                        }
                        let prompt = (history.isEmpty ? "" : "Conversation so far:\n\(history)\n")
                            + (recent.last?.text ?? "")
                        let bridged = Self.onDeviceTools.compactMap { name in
                            Self.registry.first { $0.name == name }.flatMap { BridgedTool(tool: $0, events: c) }
                        }
                        let session = LanguageModelSession(tools: bridged, instructions: system)
                        var sent = ""
                        for try await snapshot in session.streamResponse(to: prompt) {
                            let full = snapshot.content
                            if full.count > sent.count, full.hasPrefix(sent) {
                                c.yield(.text(String(full.dropFirst(sent.count))))
                            }
                            sent = full
                        }
                        c.yield(.stop(reason: "end_turn"))
                        c.finish()
                    } catch {
                        c.finish(throwing: ProviderError(message: "Apple on-device model: \(Self.describe(error))"))
                    }
                    return
                }
                #endif
                c.finish(throwing: ProviderError(message: Self.availability ?? "Unavailable"))
            }
            c.onTermination = { _ in task.cancel() }
        }
    }
}


#if canImport(FoundationModels)
/// One of our tools, offered to Apple's model. Arguments arrive as generated JSON
/// and go through the same `run` as everywhere else.
@available(macOS 26.0, *)
struct BridgedTool: Tool {
    let tool: AgentTool
    let events: AsyncThrowingStream<ProviderEvent, Error>.Continuation
    let parameters: GenerationSchema

    var name: String { tool.name }
    var description: String { tool.description }

    init?(tool: AgentTool, events: AsyncThrowingStream<ProviderEvent, Error>.Continuation) {
        guard let schema = Self.schema(tool) else { return nil }
        self.tool = tool
        self.events = events
        self.parameters = schema
    }

    func call(arguments: GeneratedContent) async throws -> String {
        let json = arguments.jsonString
        let o = await tool.run(ToolArgs(json: json))
        let text = String(o.text.prefix(4000))          // the context is small
        events.yield(.ranTool(ToolCall(id: "od_" + UUID().uuidString.prefix(8), name: tool.name, arguments: json), ok: o.ok, result: text))
        return o.ok ? text : "Failed: " + text
    }

    /// Our JSON Schema (flat objects of strings/numbers/booleans/enums) → a dynamic generation schema.
    static func schema(_ tool: AgentTool) -> GenerationSchema? {
        guard let obj = HTTP.parse(tool.schema) else { return nil }
        let props = obj["properties"] as? [String: [String: Any]] ?? [:]
        let required = Set(obj["required"] as? [String] ?? [])
        var out: [DynamicGenerationSchema.Property] = []
        for (key, p) in props.sorted(by: { $0.key < $1.key }) {
            let schema: DynamicGenerationSchema
            if let values = p["enum"] as? [String] {
                schema = DynamicGenerationSchema(name: "\(tool.name)_\(key)", anyOf: values)
            } else {
                switch p["type"] as? String {
                case "integer": schema = DynamicGenerationSchema(type: Int.self)
                case "number": schema = DynamicGenerationSchema(type: Double.self)
                case "boolean": schema = DynamicGenerationSchema(type: Bool.self)
                case "string": schema = DynamicGenerationSchema(type: String.self)
                default: return nil                      // arrays/objects: not offered on-device
                }
            }
            out.append(.init(name: key, description: p["description"] as? String, schema: schema, isOptional: !required.contains(key)))
        }
        return try? GenerationSchema(root: DynamicGenerationSchema(name: tool.name + "_args", properties: out), dependencies: [])
    }
}
#endif
