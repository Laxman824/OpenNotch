import Foundation

// The agent, in-process. It speaks the event vocabulary the UI understands
// (status · user · text · tool · approval · approval_done · done · error ·
// info · cleared · media), delivered as dictionaries on the main actor.
//
// A turn: stream the model's answer; if it asked for tools, run them (asking
// first for risky ones), append the results and go round again — until it
// answers without tools, the user stops it, or a safety limit trips.

@MainActor
final class AgentCore {
    /// Events for the UI (Backend.handle).
    var emit: (([String: Any]) -> Void)?

    private(set) var provider: ChatProvider = NotConnectedProvider()
    private(set) var conversation: [ChatMessage] = []
    private(set) var busy = false
    private var turn: Task<Void, Never>?
    private let store: SessionStore?
    private var approvals: [String: CheckedContinuation<Bool, Never>] = [:]

    static let maxToolCalls = 40
    static let approvalTimeout: TimeInterval = 300

    /// App-attached context goes after this marker; the transcript shows only
    /// what was typed.
    nonisolated static let contextMarker = "\n\n[OpenNotch context]"

    init() {
        store = SessionStore()
        conversation = store?.load() ?? []
        provider = ProviderStore.make()
    }

    /// A throwaway agent (self-test): given provider, nothing loaded or saved.
    init(ephemeral p: ChatProvider) {
        store = nil
        provider = p
    }

    func reloadProvider() {
        provider = ProviderStore.make()
        emitStatus()
    }

    var tools: [AgentTool] { ToolKit.all() + DailyTools.all() + [ToolRouter.moreTools] + MCPManager.shared.tools }

    /// History for the transcript on launch (context stripped, tool traffic hidden).
    var history: [(role: String, text: String)] {
        conversation.filter { ($0.role == .user || $0.role == .assistant) && !$0.text.isEmpty && $0.toolCallId == nil }
            .suffix(40).map { m in
                (m.role == .user ? "user" : "assistant", m.text.components(separatedBy: Self.contextMarker).first ?? m.text)
            }
    }

    func statusEvent() -> [String: Any] {
        ["type": "status", "busy": busy, "provider": provider.name,
         "model": provider.isConnected ? provider.model : ""]
    }

    private func emitStatus() { emit?(statusEvent()) }

    // MARK: turns

    func send(_ text: String, display: String?) {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return }
        guard !busy else {
            emit?(["type": "info", "text": "Still working on the last message — press Stop first."])
            return
        }
        let typed = t.components(separatedBy: Self.contextMarker).first ?? t
        // "pause", "next song", "volume 40": instant, no model needed.
        if let cmd = MediaIntent.parse(typed, assistantName: UserDefaults.standard.string(forKey: "assistantName") ?? "Ledge") {
            runMedia(cmd, typed: typed, display: display)
            return
        }
        conversation.append(ChatMessage(role: .user, text: t, images: Self.imageAttachments(in: t)))
        emit?(["type": "user", "text": display ?? typed])
        busy = true
        emitStatus()
        PlanStore.shared.clear()
        turn = Task { [weak self] in await self?.runTurn() }
    }

    private func runTurn() async {
        let started = Date()
        let provider = self.provider
        let allTools = provider.supportsTools && provider.isConnected ? self.tools : []
        var extraGroups: Set<String> = []
        var tools = ToolRouter.select(allTools, conversation: conversation)
        var specs = tools.map(\.spec)
        var toolCalls = 0
        var repeats: [String: Int] = [:]
        var inTok = 0, outTok = 0
        var answer = ""
        var failure: String?
        var stoppedBy: String?

        var retried = false
        loop: while !Task.isCancelled {
            var text = ""
            var calls: [ToolCall] = []
            var raw: (String, String)?
            let requestStart = Date()
            var passIn = 0, passOut = 0
            do {
                for try await ev in provider.turn(system: systemPrompt(), messages: Self.window(conversation), tools: specs) {
                    if Task.isCancelled { break }
                    switch ev {
                    case .text(let d): text += d; emit?(["type": "text", "delta": d])
                    case .thinking(let d): emit?(["type": "thinking", "delta": d])
                    case .toolCall(let c): calls.append(c)
                    case .usage(let i, let o): passIn = i; passOut = o
                    case .raw(let r, let src): raw = (r, src)
                    case .stop: break
                    }
                }
            } catch {
                failure = error.localizedDescription
            }
            inTok += passIn; outTok += passOut
            Trace.llm(provider: provider.name, model: provider.model, start: requestStart, input: passIn, output: passOut)
            if Task.isCancelled { stoppedBy = "stopped"; break }
            if failure != nil && text.isEmpty && calls.isEmpty {
                // A glitch before anything streamed (malformed tool call, dropped connection):
                // try this pass once more before giving up.
                if !retried && !Self.isPermanent(failure!) {
                    retried = true
                    failure = nil
                    emit?(["type": "info", "text": "Hiccup from the model — retrying…"])
                    continue
                }
                break
            }

            conversation.append(ChatMessage(role: .assistant, text: text, toolCalls: calls.isEmpty ? nil : calls,
                                            raw: raw?.0, rawSource: raw?.1))
            answer = text
            if calls.isEmpty || failure != nil { break }

            var images: [String] = []
            for call in calls {
                if Task.isCancelled { stoppedBy = "stopped"; break loop }
                toolCalls += 1
                let outcome: ToolOutcome
                let sig = call.name + "|" + call.arguments
                repeats[sig, default: 0] += 1
                if toolCalls > Self.maxToolCalls {
                    stoppedBy = "the \(Self.maxToolCalls)-tool limit for one message"
                    appendToolResult(call, ToolOutcome.fail("Tool budget for this turn is used up. Stop and summarise what you've done."))
                    continue
                }
                if repeats[sig]! >= 3 {
                    outcome = .fail("You are repeating the same call with the same arguments. It won't give a different result — change approach or answer with what you have.")
                } else if let tool = tools.first(where: { $0.name == call.name })
                            ?? allTools.first(where: { $0.name == call.name }) {   // routed out but the model knew it
                    outcome = await execute(tool, call)
                    if call.name == "more_tools" && outcome.ok {
                        extraGroups.formUnion(ToolArgs(json: call.arguments).dict["groups"] as? [String] ?? [])
                        tools = ToolRouter.select(allTools, conversation: conversation, extra: extraGroups)
                        specs = tools.map(\.spec)
                    }
                } else {
                    outcome = .fail("There is no tool called \(call.name).")
                }
                appendToolResult(call, outcome)
                images += outcome.images
            }
            if !images.isEmpty {
                conversation.append(ChatMessage(role: .user, text: "(Images from the tools above.)", images: images))
            }
            if stoppedBy != nil { break }
        }

        busy = false
        turn = nil
        if let failure { emit?(["type": "error", "text": failure]) }
        if let stoppedBy { emit?(["type": "info", "text": "Stopped (\(stoppedBy))."]) }
        store?.save(conversation)
        emit?(["type": "done", "text": answer, "ms": Int(Date().timeIntervalSince(started) * 1000),
               "toolCalls": toolCalls, "inTokens": inTok, "outTokens": outTok])
        emitStatus()
    }

    private func appendToolResult(_ call: ToolCall, _ o: ToolOutcome) {
        conversation.append(ChatMessage(role: .tool, text: o.text.isEmpty ? (o.ok ? "(done)" : "(failed)") : o.text,
                                        toolCallId: call.id, isError: o.ok ? nil : true))
    }

    /// Runs one tool: validates its JSON, asks for approval if needed, shows it in the transcript.
    private func execute(_ tool: AgentTool, _ call: ToolCall) async -> ToolOutcome {
        guard HTTP.parse(call.arguments) != nil else {
            return .fail("INVALID_JSON: your arguments for \(call.name) weren't valid JSON. Send the call again with a complete JSON object.")
        }
        let args = ToolArgs(json: call.arguments)
        let rowID = "tool_" + call.id
        var event: [String: Any] = ["type": "tool", "id": rowID, "state": "running", "icon": "◆",
                                    "verb": tool.verb, "detail": tool.detail(args),
                                    "args": Self.prettyArgs(call.arguments)]
        if tool.risk == .confirm {
            let allowed = await askApproval(tool: tool, args: args)
            guard allowed else {
                event["state"] = "error"; event["error"] = "Not allowed"
                emit?(event)
                return .fail("The user declined this \(tool.name) call. Don't retry it; ask what they'd like instead.")
            }
        }
        emit?(event)
        let raw = await Task.detached { await tool.run(args) }.value
        let o = ResultBudget.apply(raw, tool: tool.name)
        event["state"] = o.ok ? "done" : "error"
        if !o.ok { event["error"] = String(o.text.prefix(160)) }
        event["result"] = String(o.text.prefix(700)) + (o.text.count > 700 ? "…" : "")
        emit?(event)
        if tool.name == "todo_write" && o.ok {
            emit?(["type": "plan", "items": PlanStore.shared.items.map { ["content": $0.content, "status": $0.status] }])
        }
        return o
    }

    /// Errors a retry won't fix (bad key, no credit, unknown model).
    static func isPermanent(_ message: String) -> Bool {
        ["rejected the API key", "out of credit", "not found (404)", "quota", "Connect an AI"].contains { message.contains($0) }
    }

    /// Tool arguments for the expandable row: compact, readable, bounded.
    static func prettyArgs(_ json: String) -> String {
        guard let obj = HTTP.parse(json), !obj.isEmpty else { return "" }
        return obj.keys.sorted().map { k in
            let v = obj[k]
            let text = (v as? String) ?? (String(data: HTTP.json(v ?? ""), encoding: .utf8) ?? "\(v ?? "")")
            return "\(k): " + (text.count > 300 ? String(text.prefix(300)) + "…" : text)
        }.joined(separator: "\n")
    }

    private func askApproval(tool: AgentTool, args: ToolArgs) async -> Bool {
        let id = UUID().uuidString
        let timeout = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(Self.approvalTimeout * 1e9))
            self?.approve(id: id, allow: false)
        }
        // Register the waiter before announcing it: an answer can arrive synchronously.
        let ok = await withCheckedContinuation { c in
            approvals[id] = c
            let flat = args.dict.compactMapValues { ($0 as? String) ?? ($0 as? NSNumber)?.stringValue }
            emit?(["type": "approval", "id": id, "tool": tool.name, "preview": tool.preview(args),
                   "spoken": VoiceTurn.approvalPhrase(tool: tool.name, args: flat)])
        }
        timeout.cancel()
        emit?(["type": "approval_done", "id": id])
        return ok
    }

    func approve(id: String, allow: Bool) {
        approvals.removeValue(forKey: id)?.resume(returning: allow)
    }

    private func runMedia(_ cmd: MediaIntent.Command, typed: String, display: String?) {
        emit?(["type": "user", "text": display ?? typed])
        let started = Date()
        Task.detached {
            let res = MediaControl.control(cmd.action, query: cmd.query, level: cmd.level)
            await MainActor.run { [weak self] in
                guard let self else { return }
                let reply = MediaIntent.describe(cmd, res)
                self.remember(user: typed, assistant: reply)
                self.emit?(["type": "text", "delta": reply])
                self.emit?(["type": "done", "text": reply, "toolCalls": 1,
                            "ms": Int(Date().timeIntervalSince(started) * 1000)])
                var ev = res
                ev["type"] = "media"
                self.emit?(ev)
            }
        }
    }

    func stop() {
        turn?.cancel()
        for id in Array(approvals.keys) { approve(id: id, allow: false) }
    }

    func newChat() {
        stop()
        store?.save(conversation)
        store?.startNew()
        conversation = []
        PlanStore.shared.clear()
        Task { await FileState.shared.reset() }
        emit?(["type": "cleared"])
        emitStatus()
    }

    // MARK: chat history

    func chats(matching q: String = "") -> [SessionStore.Summary] { store?.search(q) ?? [] }
    var currentChatID: String? { store?.currentID }

    /// Reopen an earlier chat: the current one is saved, the chosen one becomes current.
    func openChat(_ id: String) {
        guard let store, id != store.currentID else { return }
        stop()
        store.save(conversation)
        store.switchTo(id)
        conversation = store.load(id)
        PlanStore.shared.clear()
        Task { await FileState.shared.reset() }
        emit?(["type": "reload"])
        emitStatus()
    }

    func deleteChat(_ id: String) {
        guard let store else { return }
        if id == store.currentID {
            // Don't save the chat being deleted (a late background write would bring it back).
            stop()
            conversation = []
            store.startNew()
            PlanStore.shared.clear()
            emit?(["type": "cleared"])
            emitStatus()
        }
        store.delete(id)
    }

    /// An exchange handled outside the model (quick capture, music), so follow-ups make sense.
    func remember(user: String, assistant: String) {
        conversation.append(ChatMessage(role: .user, text: user))
        conversation.append(ChatMessage(role: .assistant, text: assistant))
        store?.save(conversation)
    }

    /// What gets sent: the recent part of the chat, starting at a real user
    /// message (so no tool result is orphaned), under ~300k characters, with
    /// images kept only on the latest two image-bearing turns.
    static func window(_ all: [ChatMessage], maxMessages: Int = 120, maxChars: Int = 300_000) -> [ChatMessage] {
        var msgs = Array(all.suffix(maxMessages))
        func size(_ m: [ChatMessage]) -> Int { m.reduce(0) { $0 + $1.text.count + ($1.raw?.count ?? 0) / 4 } }
        func startAtUser() { while let f = msgs.first, f.role != .user { msgs.removeFirst() } }
        startAtUser()
        while msgs.count > 1 && size(msgs) > maxChars {
            msgs.removeFirst()
            startAtUser()
        }
        if msgs.isEmpty, let last = all.last(where: { $0.role == .user }) { msgs = [last] }
        var kept = 0
        for i in msgs.indices.reversed() where msgs[i].images?.isEmpty == false {
            kept += 1
            if kept > 2 { msgs[i].images = nil }
        }
        return msgs
    }

    // MARK: one-off calls (writing tools, proactive brief)

    enum OneShotError: LocalizedError {
        case notConnected
        var errorDescription: String? { "Connect an AI in Settings › AI first." }
    }

    /// A single prompt outside the chat, no tools, collected into one string.
    func complete(_ prompt: String, system: String? = nil) async throws -> String {
        guard provider.isConnected else { throw OneShotError.notConnected }
        var out = ""
        for try await ev in provider.turn(system: system ?? systemPrompt(),
                                          messages: [ChatMessage(role: .user, text: prompt)], tools: []) {
            if case .text(let d) = ev { out += d }
        }
        return out.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: prompt

    /// Stable first (so providers can cache it), changing bits last.
    func systemPrompt() -> String {
        let name = UserDefaults.standard.string(forKey: "assistantName") ?? "Ledge"
        let f = DateFormatter()
        f.dateFormat = "EEEE d MMMM yyyy"
        var s = """
        You are \(name), an AI assistant that lives in the MacBook notch (OpenNotch) and helps with everyday \
        work. With tools you can: read and edit files, run shell commands (the user approves), search and \
        read the web and the page the user is looking at, read their Mail.app inbox and draft replies (never \
        send), search and create Apple Notes, look up contacts, check the calendar, reminders and weather, \
        schedule prompts to run later (e.g. a weekday morning brief), control music, take a screenshot, set \
        timers, keep notes and remember facts. If a tool you need isn't loaded, call more_tools.

        How to work:
        - Answers appear in a small panel: be brief and direct. Markdown is fine; prefer short paragraphs and lists.
        - Use tools instead of guessing. Read a file before editing it. For multi-step work keep a plan with todo_write.
        - Never claim you did something a tool didn't confirm. If a tool fails, say so plainly and suggest the fix.
        - Just call tools — don't ask permission in text first. For risky ones (commands, file writes, calendar \
        changes) the app shows the user an Approve button automatically; if they decline, don't retry.
        - To see the screen use screenshot; to read an image or screenshot path use read_file.
        - Save lasting preferences with remember when the user tells you something about themselves (home city, \
        work hours, people they mention often).
        - "Plan my day": calendar_events + reminders_list + weather for their remembered city, then a short plan.

        Today is \(f.string(from: Date())). The user's home folder is \(NSHomeDirectory()).
        """
        let mem = MemoryStore.shared.promptBlock()
        if !mem.isEmpty { s += "\n\nWhat you remember about the user:\n" + mem }
        let plan = PlanStore.shared.render()
        if !plan.isEmpty { s += "\n\nCurrent plan:\n" + plan }
        return s
    }

    /// Screenshots / image files attached by the app appear in the context block as paths.
    static func imageAttachments(in text: String) -> [String]? {
        guard let ctx = text.components(separatedBy: contextMarker).dropFirst().first else { return nil }
        let rx = try? NSRegularExpression(pattern: #"(/[^\s"'`]+\.(?:png|jpe?g|gif|webp|heic))"#, options: .caseInsensitive)
        let ns = ctx as NSString
        let paths = rx?.matches(in: ctx, range: NSRange(location: 0, length: ns.length))
            .map { ns.substring(with: $0.range(at: 1)) }
            .filter { FileManager.default.fileExists(atPath: $0) }
            .compactMap(ToolKit.pngForModel) ?? []
        return paths.isEmpty ? nil : Array(paths.prefix(4))
    }
}

/// Chats live on this Mac only: Application Support/OpenNotch/sessions/chat_<id>.json,
/// one file per conversation; the open one's id is remembered across launches.
final class SessionStore {
    private let dir: String
    private let key: String
    private(set) var currentID: String

    struct Summary: Identifiable, Equatable {
        let id: String
        let title: String
        let updated: Date
        let messages: Int
        let preview: String
    }

    /// `dir`/`key` are overridable so checks never touch real chats.
    init(dir: String = opennotchDir("sessions"), key: String = "chat.current") {
        self.dir = dir
        self.key = key
        // Migrate the single-file layout (current.json) to one file per chat.
        let legacy = dir + "/current.json"
        if FileManager.default.fileExists(atPath: legacy) {
            let id = Self.newID()
            try? FileManager.default.moveItem(atPath: legacy, toPath: dir + "/chat_\(id).json")
            UserDefaults.standard.set(id, forKey: key)
        }
        currentID = UserDefaults.standard.string(forKey: key) ?? Self.newID()
        UserDefaults.standard.set(currentID, forKey: key)
    }

    static func newID() -> String {
        let f = DateFormatter(); f.dateFormat = "yyyyMMdd_HHmmss"
        return f.string(from: Date()) + "_" + String(UUID().uuidString.prefix(4))
    }

    private func path(_ id: String) -> String { dir + "/chat_\(id).json" }

    func load() -> [ChatMessage] { load(currentID) }

    func load(_ id: String) -> [ChatMessage] {
        guard let data = FileManager.default.contents(atPath: path(id)),
              let msgs = try? JSONDecoder().decode([ChatMessage].self, from: data) else { return [] }
        return msgs
    }

    func save(_ msgs: [ChatMessage], sync: Bool = false) {
        let snapshot = msgs
        let p = path(currentID)
        let write = {
            if snapshot.isEmpty { try? FileManager.default.removeItem(atPath: p); return }   // no empty chats in history
            guard let data = try? JSONEncoder().encode(snapshot) else { return }
            try? data.write(to: URL(fileURLWithPath: p), options: .atomic)
        }
        if sync { write() } else { DispatchQueue.global(qos: .utility).async(execute: write) }
    }

    /// Start a fresh chat (the old one stays in history).
    func startNew() {
        currentID = Self.newID()
        UserDefaults.standard.set(currentID, forKey: key)
    }

    func switchTo(_ id: String) {
        currentID = id
        UserDefaults.standard.set(id, forKey: key)
    }

    func delete(_ id: String) { try? FileManager.default.removeItem(atPath: path(id)) }

    /// Every saved chat, newest first.
    func list() -> [Summary] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: dir)) ?? []
        return names.filter { $0.hasPrefix("chat_") && $0.hasSuffix(".json") }.compactMap { name -> Summary? in
            let id = String(name.dropFirst(5).dropLast(5))
            let msgs = load(id)
            let said = msgs.filter { ($0.role == .user || $0.role == .assistant) && !$0.text.isEmpty && $0.toolCallId == nil }
            guard let first = said.first(where: { $0.role == .user }) else { return nil }
            let firstText = first.text.components(separatedBy: AgentCore.contextMarker).first ?? first.text
            let updated = ((try? FileManager.default.attributesOfItem(atPath: path(id)))?[.modificationDate] as? Date)
                ?? said.last?.at ?? Date.distantPast
            let last = said.last(where: { $0.role == .assistant })?.text ?? ""
            return Summary(id: id, title: Self.title(firstText), updated: updated, messages: said.count,
                           preview: String(last.replacingOccurrences(of: "\n", with: " ").prefix(120)))
        }.sorted { $0.updated > $1.updated }
    }

    /// Full-text search across chats (title and every message).
    func search(_ q: String) -> [Summary] {
        let query = q.lowercased().trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty else { return list() }
        return list().filter { s in
            s.title.lowercased().contains(query) || load(s.id).contains { $0.text.lowercased().contains(query) }
        }
    }

    static func title(_ text: String) -> String {
        let one = text.replacingOccurrences(of: "\n", with: " ").trimmingCharacters(in: .whitespaces)
        return one.count > 60 ? String(one.prefix(60)) + "…" : (one.isEmpty ? "Untitled chat" : one)
    }
}

/// One JSONL line per model request — feeds the AI-usage heatmap.
enum Trace {
    static func llm(provider: String, model: String, start: Date, input: Int, output: Int) {
        let line: [String: Any] = [
            "name": "llm.request", "start": start.timeIntervalSince1970,
            "duration_ms": Int(Date().timeIntervalSince(start) * 1000),
            "attrs": ["gen_ai.system": provider, "gen_ai.request.model": model,
                      "gen_ai.usage.input_tokens": input, "gen_ai.usage.output_tokens": output],
        ]
        let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd"
        let path = opennotchDir("traces") + "/\(f.string(from: Date())).jsonl"
        var d = HTTP.json(line); d.append(0x0A)
        DispatchQueue.global(qos: .utility).async {
            if let h = FileHandle(forWritingAtPath: path) {
                h.seekToEndOfFile(); h.write(d); try? h.close()
            } else {
                FileManager.default.createFile(atPath: path, contents: d)
            }
        }
    }
}
