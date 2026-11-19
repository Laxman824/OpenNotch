import Foundation
#if canImport(FoundationModels)
import FoundationModels
#endif

/// Pure rules for Apple's on-device model (checked in AgentChecks).
enum AppleLogic {
    /// What macOS reports before 27 (and our fallback).
    static let baseTokens = 4096

    /// How much conversation to send. 4K tokens keeps the old 12k chars; a bigger model (macOS 27's
    /// Core Advanced, 8K) gets about 3 chars per extra token, capped — tool schemas and the answer need room too.
    static func contextChars(tokens: Int) -> Int {
        guard tokens > baseTokens else { return 12_000 }
        return min(12_000 + (tokens - baseTokens) * 3, 60_000)
    }

    /// Every read-only tool Apple's model may ever be offered (never anything that needs approval or acts on
    /// the Mac: seen live, a small model "opened" something to write a poem, so `open` is out).
    static func tools(contextTokens: Int) -> [String] {
        let base = ["weather", "calendar_events", "reminders_list", "system_info", "recall", "search_chats", "timer"]
        return contextTokens > baseTokens ? base + ["web_search", "media_control"] : base
    }

    /// Topic patterns for the tools the keyword router doesn't cover the way a small model needs.
    static let patterns: [(tools: [String], pattern: String)] = [
        (["timer"], #"\b(timers?|countdown|count down|pomodoro|focus (session|timer)|stop the timer)\b"#),
        (["system_info"], #"\b(battery|charg(e|ing)|disk|storage|free space|memory|ram|macos|os version|uptime|cpu|my mac)\b"#),
        (["web_search"], #"\b(news|latest|newest|recent(ly)?|current(ly)?|right now|this (week|year|season)|who won|score|price of|stock|search|look (it )?up|google|on the web|online)\b"#),
        (["recall", "search_chats"], #"\b(remember|recall|earlier|last time|before|we (talked|discussed|spoke)|i (told|said|mentioned)|you said|my (name|birthday|favou?rite))\b"#),
    ]

    /// The tools for this message: only what its topic needs (seen live: offered everything, it searched the
    /// web for "12% of 80"). Weather/calendar/music follow the router's groups; small talk, maths and writing get none.
    static func tools(for text: String, routerGroups: Set<String>, contextTokens: Int) -> [String] {
        let lower = text.lowercased()
        var want: Set<String> = []
        if routerGroups.contains("weather") { want.insert("weather") }
        if routerGroups.contains("calendar") { want.formUnion(["calendar_events", "reminders_list"]) }
        if routerGroups.contains("music") { want.insert("media_control") }
        for p in patterns where lower.range(of: p.pattern, options: .regularExpression) != nil { want.formUnion(p.tools) }
        return tools(contextTokens: contextTokens).filter { want.contains($0) }
    }

    /// The prompt without "Sent: …" stamps (seen live: the small model echoed them into answers);
    /// the time goes into the instructions instead. Drops a context block left empty.
    static func cleanPrompt(_ text: String) -> String {
        var lines = text.components(separatedBy: "\n").filter { !$0.hasPrefix("Sent: ") }
        while let last = lines.last, last.trimmingCharacters(in: .whitespaces).isEmpty { lines.removeLast() }
        var out = lines.joined(separator: "\n")
        let marker = AgentCore.contextMarker.trimmingCharacters(in: .whitespacesAndNewlines)
        if out.hasSuffix(marker) { out = String(out.dropLast(marker.count)).trimmingCharacters(in: .whitespacesAndNewlines) }
        return out
    }

    /// Holds back a line that might be an echoed "Sent: …" stamp and drops it (streamed text in, text to show out).
    struct StampFilter {
        private var pending = ""
        mutating func feed(_ d: String) -> String {
            pending += d
            var out = ""
            while let nl = pending.firstIndex(of: "\n") {
                let line = String(pending[..<nl])
                pending = String(pending[pending.index(after: nl)...])
                if !Self.isStamp(line) { out += line + "\n" }
            }
            // Keep a partial line back only while it could still become "Sent:".
            if !"Sent:".hasPrefix(pending.prefix(5)) || pending.count > 5 && !pending.hasPrefix("Sent:") {
                out += pending
                pending = ""
            }
            return out
        }
        mutating func finish() -> String {
            defer { pending = "" }
            return Self.isStamp(pending) ? "" : pending
        }
        static func isStamp(_ line: String) -> Bool { line.trimmingCharacters(in: .whitespaces).hasPrefix("Sent:") }
    }

    /// The most of one tool result the model sees.
    static func resultChars(contextTokens: Int) -> Int { contextTokens > baseTokens ? 6000 : 4000 }

    /// Recent turns sent as text: how many and how long each.
    static func history(contextTokens: Int) -> (messages: Int, chars: Int) {
        contextTokens > baseTokens ? (14, 2000) : (8, 1500)
    }

    enum Status: Equatable { case ready, waiting, never }

    /// Why it isn't usable → may it become usable while the app runs? (Downloading or switched off: keep
    /// checking and adopt it the moment it's ready. Old Mac/macOS: stop asking.)
    static func status(reason: String?) -> Status {
        guard let reason else { return .ready }
        return reason.contains("downloading") || reason.contains("Turn on") ? .waiting : .never
    }

    /// Adopt Apple automatically only when the user has no AI at all — never replace one they picked.
    static func shouldAdopt(activeKind: ProviderKind?, status: Status) -> Bool {
        activeKind == nil && status == .ready
    }

    /// "Core Advanced · 8K tokens" for Settings.
    static func detail(variant: String?, tokens: Int) -> String {
        let k = tokens >= 1000 ? "\(tokens / 1024)K tokens" : "\(tokens) tokens"
        return [variant, k].compactMap { $0 }.joined(separator: " · ")
    }
}

/// Apple's on-device model (macOS 26+, Apple Intelligence Macs): free, private,
/// offline. Small context, so it gets a trimmed transcript and a few read-only
/// tools that the framework calls itself inside the session (`AppleLogic.tools`);
/// each run is reported as `.ranTool` so the transcript shows it. On macOS 27, M3+ Macs get the
/// bigger Core Advanced model (8K tokens) — sizes follow `contextTokens`.
struct AppleOnDeviceProvider: ChatProvider {
    let name = "Apple on-device"
    let model = "Apple Intelligence"
    var isConnected: Bool { Self.availability == nil }
    let supportsTools = false
    let supportsImages = false
    let contextTokens: Int
    let contextChars: Int
    let compactPrompt = true

    init() {
        contextTokens = Self.contextTokens
        contextChars = AppleLogic.contextChars(tokens: contextTokens)
    }

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

    static var status: AppleLogic.Status { AppleLogic.status(reason: availability) }

    /// The model's context in tokens (macOS 27 reports the real size; earlier: 4096).
    static var contextTokens: Int {
        #if canImport(FoundationModels)
        if #available(macOS 26.0, *), availability == nil {
            let n = SystemLanguageModel.default.contextSize
            return n > 0 ? n : AppleLogic.baseTokens
        }
        #endif
        return AppleLogic.baseTokens
    }

    /// "Core Advanced", "Core" (macOS 27+), else nil.
    static var variantName: String? {
        #if canImport(FoundationModels, _version: 2.0)       // the macOS 27 SDK; older SDKs don't have `variant`
        if #available(macOS 27.0, *), availability == nil {
            let name = SystemLanguageModel.default.variant.displayName
            return name.isEmpty ? nil : name
        }
        #endif
        return nil
    }

    /// For Settings: "Ready · Core Advanced · 8K tokens".
    static var readyDetail: String { "Ready · " + AppleLogic.detail(variant: variantName, tokens: contextTokens) }

    static var registry: [AgentTool] { ToolKit.all() + DailyTools.all() + RecallTools.all() }

    static func describe(_ error: Error) -> String {
        #if canImport(FoundationModels, _version: 2.0)       // macOS 27 SDK
        if #available(macOS 27.0, *), let e = error as? LanguageModelError {
            switch e {
            case .contextSizeExceeded: return "the conversation is too long for the on-device model — start a new chat (⌘N)."
            case .guardrailViolation, .refusal: return "Apple's safety filter declined this request."
            case .unsupportedLanguageOrLocale: return "it doesn't support this language yet — try English, or connect another AI in Settings › AI."
            case .rateLimited: return "it's busy right now — try again in a moment."
            default: break
            }
        }
        #endif
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

    /// Load the model before the first message (cold, the first answer took 3–9 s).
    @MainActor private static var lastPrewarm = Date.distantPast
    @MainActor static func prewarm() {
        #if canImport(FoundationModels)
        if #available(macOS 26.0, *) {
            guard availability == nil, Date().timeIntervalSince(lastPrewarm) > 60 else { return }
            lastPrewarm = Date()
            LanguageModelSession().prewarm()
        }
        #endif
    }

    func turn(system: String, messages: [ChatMessage], tools: [ToolSpec]) -> AsyncThrowingStream<ProviderEvent, Error> {
        AsyncThrowingStream { c in
            let task = Task {
                #if canImport(FoundationModels)
                if #available(macOS 26.0, *) {
                    do {
                        // Recent turns as plain text; the last user message is the prompt.
                        let h = AppleLogic.history(contextTokens: contextTokens)
                        let recent = messages.filter { $0.role == .user || $0.role == .assistant }.suffix(h.messages)
                        var history = ""
                        for m in recent.dropLast() {
                            history += (m.role == .user ? "User: " : "Assistant: ")
                                + String(AppleLogic.cleanPrompt(m.text).prefix(h.chars)) + "\n"
                        }
                        let last = recent.last?.text ?? ""
                        let prompt = (history.isEmpty ? "" : "Conversation so far:\n\(history)\n") + AppleLogic.cleanPrompt(last)
                        let cap = AppleLogic.resultChars(contextTokens: contextTokens)
                        let wanted = AppleLogic.tools(for: ToolRouter.routingText(last),
                                                      routerGroups: ToolRouter.keywordGroups(messages), contextTokens: contextTokens)
                        let bridged = wanted.compactMap { name in
                            Self.registry.first { $0.name == name }.flatMap { BridgedTool(tool: $0, events: c, maxChars: cap) }
                        }
                        let now = "\nNow: " + TurnPolicy.timestamp(Date())
                            + ". Answer directly. Work out maths yourself — there is no calculator tool. Never write the time unless asked."
                        let session = LanguageModelSession(tools: bridged, instructions: system + now)
                        var sent = ""
                        var stamps = AppleLogic.StampFilter()
                        for try await snapshot in session.streamResponse(to: prompt) {
                            let full = snapshot.content
                            if full.count > sent.count, full.hasPrefix(sent) {
                                let shown = stamps.feed(String(full.dropFirst(sent.count)))
                                if !shown.isEmpty { c.yield(.text(shown)) }
                            }
                            sent = full
                        }
                        let rest = stamps.finish()
                        if !rest.isEmpty { c.yield(.text(rest)) }
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
    let maxChars: Int

    var name: String { tool.name }
    var description: String { tool.description }

    init?(tool: AgentTool, events: AsyncThrowingStream<ProviderEvent, Error>.Continuation, maxChars: Int = 4000) {
        guard let schema = Self.schema(tool) else { return nil }
        self.tool = tool
        self.maxChars = maxChars
        self.events = events
        self.parameters = schema
    }

    func call(arguments: GeneratedContent) async throws -> String {
        let json = arguments.jsonString
        let o = await tool.run(ToolArgs(json: json))
        let text = String(o.text.prefix(maxChars))      // the context is small
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
