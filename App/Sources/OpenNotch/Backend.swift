import AppKit
import Foundation
import SwiftUI

/// One row in the notch transcript.
struct Item: Identifiable, Equatable {
    enum Kind: Equatable {
        case user
        case assistant
        case tool(state: String, icon: String, verb: String, detail: String, error: String?)
        case info
        case error
        /// The model's reasoning, streamed live, then folded away.
        case thinking
        /// The agent's current plan (todo_write), updated in place.
        case plan([PlanStep])
    }
    let id: String
    var kind: Kind
    var text: String
    var streaming = false
    var meta: String? = nil          // "3.2s" under an answer
    var details: String? = nil       // tool rows: what was sent / what came back
    var started: Date? = nil         // thinking rows: when it began
}

extension Item {
    var isPlan: Bool { if case .plan(_) = kind { return true } else { return false } }
}

struct PlanStep: Equatable {
    let content: String
    let status: String               // pending | in_progress | completed
}

struct NowPlaying: Equatable {
    var app: String? = nil
    var state = "stopped"
    var track = ""
    var artist = ""
    var album = ""
    var position: Double = 0          // seconds, as of `at`
    var duration: Double = 0          // seconds (0 = unknown)
    var artworkURL: String? = nil     // Spotify
    var artworkPath: String? = nil    // Apple Music (file written by media_control)
    var at = Date()
    var playing: Bool { state == "playing" }
    var artKey: String? { artworkURL ?? artworkPath.map { "\($0)#\(track)|\(artist)" } }

    /// Playback position now, interpolated between polls.
    func livePosition(_ now: Date = Date()) -> Double {
        let p = position + (playing ? now.timeIntervalSince(at) : 0)
        return duration > 0 ? min(duration, max(0, p)) : max(0, p)
    }
    var progress: Double { duration > 0 ? livePosition() / duration : 0 }

    static func == (a: NowPlaying, b: NowPlaying) -> Bool {
        // Position drifts every poll; only a jump (seek) counts as a change.
        a.app == b.app && a.state == b.state && a.track == b.track && a.artist == b.artist
            && a.album == b.album && a.duration == b.duration && a.artKey == b.artKey
            && abs(a.livePosition() - b.livePosition()) < 1.5
    }

    init() {}
    init(_ d: [String: Any]) {
        app = d["app"] as? String
        state = d["state"] as? String ?? (d["success"] as? Bool == true && d["action"] as? String != "pause" ? "playing" : "paused")
        track = d["track"] as? String ?? ""
        artist = d["artist"] as? String ?? ""
        album = d["album"] as? String ?? ""
        position = d["position"] as? Double ?? 0
        duration = d["duration"] as? Double ?? 0
        artworkURL = (d["artwork_url"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        artworkPath = (d["artwork_path"] as? String).flatMap { $0.isEmpty ? nil : $0 }
    }
}

/// Something the user attached to the next prompt.
struct Attachment: Identifiable, Equatable {
    enum Kind: Equatable { case file, screenshot, clipboard, selection, web }
    let id = UUID()
    let kind: Kind
    let value: String                // path, or the clipboard text

    var label: String {
        switch kind {
        case .file, .screenshot: return (value as NSString).lastPathComponent
        case .clipboard: return "Clipboard · \(value.count) chars"
        case .selection: return "Selected text · \(value.count) chars"
        case .web: return value.components(separatedBy: "\n").first.map { String($0.prefix(40)) } ?? "Web page"
        }
    }
    var icon: String {
        switch kind {
        case .file: return "doc"
        case .screenshot: return "camera.viewfinder"
        case .clipboard: return "doc.on.clipboard"
        case .selection: return "text.cursor"
        case .web: return "safari"
        }
    }
}

struct Approval: Identifiable, Equatable {
    let id: String
    let tool: String
    let preview: String
    /// What hands-free says out loud ("I need your OK to run a command: …").
    var spoken: String = ""
    /// "Allow git in this chat" — nil when this call can't be pre-approved.
    var allowLabel: String? = nil
}

/// The UI's view of the assistant: transcript, busy state, approvals,
/// attachments and now-playing. The agent itself runs in-process
/// (`AgentCore`); its events arrive through `handle(_:)`.
@MainActor
final class Backend: ObservableObject {
    @Published var items: [Item] = []
    @Published var approvals: [Approval] = []
    @Published var busy = false
    @Published var provider = ""
    @Published var model = ""
    @Published var connected = true             // the agent is in-process: always reachable
    @Published var lastTool: String = ""
    @Published var lastAnswer: String = ""
    @Published var attachments: [Attachment] = []
    /// An answer finished while the notch was closed and hasn't been looked at:
    /// the ears say "Ready" until the notch opens.
    @Published var unseenAnswer = false
    /// Suggested next prompts after the last answer (chips under it).
    @Published var followUps: [String] = []
    @Published var turnStarted: Date? = nil
    /// (done, total) of the current plan while a turn runs — the closed notch shows "Step 2/5".
    @Published var planProgress: (done: Int, total: Int)? = nil
    /// True while the model is reasoning (before it answers or calls a tool).
    @Published var thinkingNow = false
    // For the avatar's moods.
    var lastTextAt: Date? = nil
    var lastDoneAt: Date? = nil
    var lastErrorAt: Date? = nil
    @Published var listening = false
    @Published var micLevel: CGFloat = 0
    @Published var handsFree = false
    // Mirrored from HandsFree for the avatar (plain vars: read every frame, no re-render storm).
    var voicePhase: HandsFree.Phase = .off
    var speechLevel: CGFloat = 0
    @Published var nowPlaying = NowPlaying() {
        didSet { if nowPlaying.artKey != oldValue.artKey { loadArtwork(nowPlaying) } }
    }
    /// Album art of the current track and a vivid colour pulled from it
    /// (tints the closed notch's music ears, like the Dynamic Island).
    @Published var artwork: NSImage? = nil
    @Published var artworkTint: Color? = nil
    private var artworkTask: Task<Void, Never>?

    /// Streamed answer text (hands-free speaks it as it arrives).
    var onTextDelta: ((String) -> Void)?
    /// (final text, whether any of it was streamed first)
    var onTurnFinished: ((String, Bool) -> Void)?
    /// A tool began running (verb = tool label) — hands-free narrates it.
    var onToolStarted: ((String) -> Void)?

    private(set) var sentHistory: [String] = []
    /// Fired when a turn finishes, so the notch can "peek" the answer.
    var onDone: ((String) -> Void)?
    /// Fired when the agent needs a yes/no, so the notch can open itself.
    var onApproval: (() -> Void)?

    /// True once an AI is connected (Settings › AI).
    var aiConnected: Bool { core.provider.isConnected }

    let core = AgentCore()
    private var counter = 0
    private var turnHadText = false

    func start() {
        core.emit = { [weak self] ev in self?.handle(ev) }
        applyStatus(core.statusEvent())
        for h in core.history {
            add(h.role == "user" ? .user : .assistant, h.text)
        }
    }

    func shutdown() {
        core.stop()
    }

    /// Settings › AI changed the provider or model.
    func reloadAI() {
        core.reloadProvider()
    }

    /// Send a prompt plus whatever is attached. The model gets the context
    /// under the marker; the bubble shows only what you typed.
    func send(_ text: String, voice: Bool = false) {
        var t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty || !attachments.isEmpty else { return }
        // Quick capture ("remind me…", "note: …") is handled locally, instantly.
        if attachments.isEmpty, !t.hasPrefix("/"), !busy, let reply = interceptor?(t) {
            sentHistory.append(t)
            showLocalExchange(user: voice ? "🎙 " + t : t, reply: reply, remember: t)
            return
        }
        if t.isEmpty { t = "Take a look at this." }
        if !t.hasPrefix("/") { sentHistory.append(t) }

        var context: [String] = []
        let files = attachments.filter { $0.kind == .file }.map(\.value)
        if !files.isEmpty {
            context.append("Attached files (read each with read_file — it handles text, code, PDF, Word and images):\n"
                           + files.map { "- \($0)" }.joined(separator: "\n"))
        }
        for shot in attachments where shot.kind == .screenshot {
            context.append("A screenshot of my screen right now is at \(shot.value) — it's attached to this message (or open it with read_file).")
        }
        for sel in attachments where sel.kind == .selection {
            context.append("Text I have selected\(selectionSource.map { " in \($0)" } ?? ""):\n```\n\(sel.value.prefix(20000))\n```")
        }
        for page in attachments where page.kind == .web {
            let lines = page.value.components(separatedBy: "\n")
            context.append("I'm looking at this web page: “\(lines.first ?? "")” — \(lines.dropFirst().first ?? "")\n"
                           + "Fetch it with fetch_url if you need its content.")
        }
        for clip in attachments where clip.kind == .clipboard {
            context.append("My clipboard:\n```\n\(clip.value.prefix(20000))\n```")
        }
        if voice {
            context.append("Hands-free voice mode: your reply is spoken aloud. Answer in one to three short, "
                           + "natural sentences. No markdown, lists, tables or code unless I ask for them. "
                           + "For actions, just do them and confirm in one sentence.")
        }
        var body: [String: Any] = ["text": t]
        if !context.isEmpty {
            body["text"] = t + "\n\n[OpenNotch context]\n" + context.joined(separator: "\n\n")
            let chips = attachments.map { "📎 " + $0.label }.joined(separator: "  ")
            body["display"] = chips.isEmpty ? (voice ? "🎙 " + t : t) : t + "\n" + chips
        }
        attachments = []
        core.send(body["text"] as? String ?? t, display: body["display"] as? String)
    }

    func attach(_ a: Attachment) {
        if !attachments.contains(where: { $0.value == a.value }) { attachments.append(a) }
    }

    /// Files and links dropped on the notch: files as files, links as web pages.
    func attachDropped(_ urls: [URL]) {
        for u in urls {
            if u.isFileURL { attach(Attachment(kind: .file, value: u.path)) }
            else if let scheme = u.scheme?.lowercased(), scheme == "http" || scheme == "https" {
                attach(Attachment(kind: .web, value: "\(u.host ?? "Link")\n\(u.absoluteString)"))
            }
        }
    }

    func attachClipboard() {
        guard let s = NSPasteboard.general.string(forType: .string), !s.isEmpty else {
            add(.info, "Clipboard is empty")
            return
        }
        attach(Attachment(kind: .clipboard, value: s))
    }

    // MARK: local exchanges, writing tools, proactive

    /// Returns a confirmation if the text was handled locally (quick capture).
    var interceptor: ((String) -> String?)?
    /// App name the current `.selection` attachment came from.
    var selectionSource: String?

    /// Show an exchange that didn't go through the agent, tell the agent about
    /// it (so follow-ups work), and let hands-free speak it.
    func showLocalExchange(user: String, reply: String, remember original: String? = nil) {
        followUps = []
        add(.user, user)
        add(.assistant, reply)
        lastAnswer = reply
        lastDoneAt = Date()
        onTurnFinished?(reply, false)
        core.remember(user: original ?? user, assistant: reply)
    }

    enum CallResult { case success(String), failure(String) }

    /// Writing tools: rewrite `text` per `instruction`, returning only the result.
    func transform(_ text: String, instruction: String, _ done: @escaping (CallResult) -> Void) {
        let prompt = "\(instruction)\n\nReturn only the rewritten text — no preamble, no quotes.\n\n\(text)"
        Task {
            do { done(.success(try await core.complete(prompt, system: "You rewrite text exactly as asked."))) }
            catch { done(.failure(error.localizedDescription)) }
        }
    }

    /// A one-off prompt outside the chat (proactive morning brief).
    func oneshot(_ prompt: String, _ done: @escaping (CallResult) -> Void) {
        Task {
            do { done(.success(try await core.complete(prompt))) }
            catch { done(.failure(error.localizedDescription)) }
        }
    }

    /// A one-off prompt that may use read-only tools (the morning brief reads calendar, mail, weather).
    func oneshotWithTools(_ prompt: String, tools: Set<String>, _ done: @escaping (CallResult) -> Void) {
        Task {
            do { done(.success(try await core.completeWithTools(prompt, toolNames: tools))) }
            catch { done(.failure(error.localizedDescription)) }
        }
    }

    struct Mail { let id: String; let from: String; let subject: String }

    /// Unread Mail.app messages from the last day that look like they're from a person.
    /// Only when Mail automation is already allowed — a background check never prompts.
    func inboxNeedingReply(_ done: @escaping ([Mail]?) -> Void) {
        guard ContextGrabber.automationStatus("com.apple.mail") == noErr,
              let tool = DailyTools.mail.first(where: { $0.name == "mail_recent" }) else { done(nil); return }
        Task {
            let o = await Task.detached { await tool.run(ToolArgs(json: #"{"days":1,"unread_only":true}"#)) }.value
            done(o.ok ? Self.parseMailRows(o.text) : nil)
        }
    }

    /// mail_recent rows ("- [id 12] ● Ann <a@x.com> — Subject (2026-10-02 09:14)") → people's mail.
    nonisolated static func parseMailRows(_ text: String) -> [Mail] {
        let rx = try? NSRegularExpression(pattern: #"^- \[id (\d+)\] (?:● )?(.+?) — (.*) \(\d{4}-\d\d-\d\d \d\d:\d\d\)$"#)
        let robots = ["noreply", "no-reply", "donotreply", "notification", "newsletter", "mailer-daemon", "updates@", "news@", "marketing"]
        return text.split(separator: "\n").compactMap { line -> Mail? in
            let s = String(line), ns = s as NSString
            guard let m = rx?.firstMatch(in: s, range: NSRange(location: 0, length: ns.length)) else { return nil }
            let from = ns.substring(with: m.range(at: 2))
            guard !robots.contains(where: { from.lowercased().contains($0) }) else { return nil }
            return Mail(id: ns.substring(with: m.range(at: 1)), from: from, subject: ns.substring(with: m.range(at: 3)))
        }
    }

    // MARK: music

    func media(_ action: String, query: String? = nil) {
        Task {
            let res = await Task.detached { MediaControl.control(action, query: query) }.value
            var ev = res
            ev["type"] = "media"
            if action != "pause" { ev["state"] = ev["state"] ?? "playing" }
            handle(ev)
            try? await Task.sleep(nanoseconds: 350_000_000)
            await refreshNowPlaying()
        }
    }

    /// Scrub bar: jump to `seconds`, updating the local clock straight away.
    func seek(_ seconds: Double) {
        var np = nowPlaying
        np.position = seconds; np.at = Date()
        nowPlaying = np
        Task {
            _ = await Task.detached { MediaControl.control("seek", position: seconds) }.value
            try? await Task.sleep(nanoseconds: 400_000_000)
            await refreshNowPlaying()
        }
    }

    func refreshNowPlaying() async {
        let obj = await Task.detached { MediaControl.nowPlaying() }.value
        let np = NowPlaying(obj)
        if np != nowPlaying { nowPlaying = np }
    }

    private func loadArtwork(_ np: NowPlaying) {
        artworkTask?.cancel()
        guard np.artKey != nil else { artwork = nil; artworkTint = nil; return }
        artworkTask = Task { [weak self] in
            var data: Data?
            if let s = np.artworkURL, let url = URL(string: s), url.scheme == "https" {
                data = try? await URLSession.shared.data(from: url).0
            } else if let path = np.artworkPath {
                data = await Task.detached { try? Data(contentsOf: URL(fileURLWithPath: path)) }.value
            }
            guard !Task.isCancelled, let self else { return }
            let image = data.flatMap { NSImage(data: $0) }
            self.artwork = image
            self.artworkTint = image.flatMap(ArtworkColor.vivid)
        }
    }

    private var lastNotice: (text: String, at: Date)?

    /// Show an error once — the same message repeated within 20s is dropped
    /// (a retried action shouldn't stack identical cards).
    func notice(_ text: String) {
        if let last = lastNotice, last.text == text, Date().timeIntervalSince(last.at) < 20 { return }
        lastNotice = (text, Date())
        add(.error, text)
    }

    func stop() { core.stop() }

    // Chat history
    func chats(matching q: String = "") -> [SessionStore.Summary] { core.chats(matching: q) }
    var currentChatID: String? { core.currentChatID }
    func openChat(_ id: String) { core.openChat(id) }
    func deleteChat(_ id: String) { core.deleteChat(id) }
    func newChat() { core.newChat() }

    func answer(_ approval: Approval, allow: Bool, forChat: Bool = false) {
        approvals.removeAll { $0.id == approval.id }
        core.approve(id: approval.id, allow: allow, forChat: forChat)
    }

    // MARK: agent events

    private func applyStatus(_ ev: [String: Any]) {
        if let b = ev["busy"] as? Bool { busy = b }
        if let p = ev["provider"] as? String { provider = p }
        if let m = ev["model"] as? String { model = m }
    }

    private func handle(_ ev: [String: Any]) {
        ValueLedger.shared.observe(ev)
        switch ev["type"] as? String ?? "" {
        case "status":
            applyStatus(ev)
        case "user":
            planProgress = nil
            followUps = []
            let injected = ev["injected"] as? Bool ?? false
            add(.user, (injected ? "↪ " : "") + (ev["text"] as? String ?? ""))
            if !injected { turnHadText = false; lastTool = ""; turnStarted = Date() }
        case "thinking":
            let delta = ev["delta"] as? String ?? ""
            thinkingNow = true
            if let i = items.indices.last, items[i].kind == .thinking, items[i].streaming {
                items[i].text += delta
            } else {
                closeStreaming()
                counter += 1
                items.append(Item(id: "i\(counter)", kind: .thinking, text: delta, streaming: true, started: Date()))
            }
        case "plan":
            let steps = (ev["items"] as? [[String: Any]] ?? []).map {
                PlanStep(content: $0["content"] as? String ?? "", status: $0["status"] as? String ?? "pending")
            }
            closeThinking()
            let turnStart = items.lastIndex { $0.kind == .user } ?? -1
            if let i = items.indices.last(where: { $0 > turnStart && items[$0].isPlan }) {
                items[i].kind = .plan(steps)
            } else {
                counter += 1
                items.append(Item(id: "i\(counter)", kind: .plan(steps), text: ""))
            }
            planProgress = steps.isEmpty ? nil : (steps.filter { $0.status == "completed" }.count, steps.count)
        case "text":
            closeThinking()
            let delta = ev["delta"] as? String ?? ""
            turnHadText = true
            lastTextAt = Date()
            onTextDelta?(delta)
            if let i = items.indices.last, items[i].kind == .assistant, items[i].streaming {
                items[i].text += delta
            } else {
                add(.assistant, delta, streaming: true)
            }
        case "tool":
            // Loading more tools is plumbing, not a step the user cares about.
            if ev["name"] as? String == "more_tools" { break }
            let id = ev["id"] as? String ?? UUID().uuidString
            let state = ev["state"] as? String ?? "running"
            let verb = ev["verb"] as? String ?? ""
            let kind = Item.Kind.tool(state: state, icon: ev["icon"] as? String ?? "◆", verb: verb,
                                      detail: ev["detail"] as? String ?? "", error: ev["error"] as? String)
            closeThinking()
            closeStreaming()
            var details = ""
            if let a = ev["args"] as? String, !a.isEmpty { details += a }
            if let r = ev["result"] as? String, !r.isEmpty { details += (details.isEmpty ? "" : "\n───\n") + r }
            if let i = items.firstIndex(where: { $0.id == id }) {
                items[i].kind = kind
                if !details.isEmpty { items[i].details = details }
            } else {
                items.append(Item(id: id, kind: kind, text: "", details: details.isEmpty ? nil : details))
            }
            lastTool = state == "running" ? verb : ""
            if state == "running" { onToolStarted?(verb.isEmpty ? (ev["detail"] as? String ?? "") : verb) }
        case "approval":
            approvals.append(Approval(id: ev["id"] as? String ?? "", tool: ev["tool"] as? String ?? "",
                                      preview: ev["preview"] as? String ?? "", spoken: ev["spoken"] as? String ?? "",
                                      allowLabel: ev["allowLabel"] as? String))
            onApproval?()
        case "approval_done":
            approvals.removeAll { $0.id == ev["id"] as? String }
        case "done":
            closeThinking()
            planProgress = nil
            closeStreaming()
            let text = ev["text"] as? String ?? ""
            // The loop returns provider failures as the answer text, e.g.
            // "[Groq error: Error code: 404 …]" — show those as errors.
            let isProviderError = text.hasPrefix("[") && text.range(of: #"^\[\w+ error:"#,
                                                                    options: [.regularExpression, .caseInsensitive]) != nil
            lastDoneAt = Date()
            if isProviderError {
                lastErrorAt = Date()
                if let i = items.indices.last, items[i].kind == .assistant, items[i].text == text {
                    items.remove(at: i)
                }
                add(.error, String(text.dropFirst().dropLast()))
            } else if !turnHadText && !text.isEmpty && text != "[No text response]" {
                add(.assistant, text)
            }
            lastAnswer = text
            followUps = isProviderError ? [] : (ev["followUps"] as? [String] ?? [])
            onTurnFinished?(isProviderError ? "Sorry, the model failed. Try again." : text, turnHadText && !isProviderError)
            lastTool = ""
            turnStarted = nil
            if let i = items.lastIndex(where: { $0.kind == .assistant }) {
                items[i].meta = Self.stats(ev)
            }
            onDone?(text)
        case "info":
            add(.info, ev["text"] as? String ?? "")
        case "error":
            closeStreaming()
            lastErrorAt = Date()
            let text = ev["text"] as? String ?? "error"
            // OpenRouter with no credit left: move to the free models instead of failing every time.
            if text.contains("requires more credits"), ProviderStore.activeKind == .openrouter,
               ProviderStore.model(for: .openrouter) != ProviderStore.openRouterFree {
                ProviderStore.setModel(ProviderStore.openRouterFree, for: .openrouter)
                core.reloadProvider()
                add(.info, "Your OpenRouter balance ran out, so I switched to the free models (openrouter/free). Ask again — or add credit and pick a model in Settings › AI.")
            } else {
                add(.error, text)
            }
        case "media":
            // Action results ("pause", "next") carry no track details — keep
            // what we know and let the refresh that follows fill it in.
            var np = NowPlaying(ev)
            if np.track.isEmpty {
                np = nowPlaying
                np.position = nowPlaying.livePosition(); np.at = Date()
                np.state = NowPlaying(ev).state
            }
            nowPlaying = np
        case "cleared":
            followUps = []
            items = []
            approvals = []
            planProgress = nil
        case "reload":                                    // another chat was opened
            followUps = []
            items = []
            approvals = []
            planProgress = nil
            for h in core.history { add(h.role == "user" ? .user : .assistant, h.text) }
        default:
            break
        }
    }

    private static func stats(_ ev: [String: Any]) -> String {
        var parts: [String] = []
        if let ms = ev["ms"] as? Int { parts.append(String(format: "%.1fs", Double(ms) / 1000)) }
        // Steps are shown by the steps row above; token counts live in the AI usage tab.
        return parts.joined(separator: " · ")
    }

    /// The model moved on from reasoning: fold the thinking row into "Thought for 6s".
    private func closeThinking() {
        thinkingNow = false
        guard let i = items.indices.last, items[i].kind == .thinking, items[i].streaming else { return }
        items[i].streaming = false
        let secs = max(1, Int(Date().timeIntervalSince(items[i].started ?? Date()).rounded()))
        items[i].meta = "Thought for \(secs)s"
    }

    private func closeStreaming() {
        if let i = items.indices.last, items[i].streaming { items[i].streaming = false }
    }

    private func add(_ kind: Item.Kind, _ text: String, streaming: Bool = false) {
        counter += 1
        items.append(Item(id: "i\(counter)", kind: kind, text: text, streaming: streaming))
        if items.count > 300 { items.removeFirst(items.count - 300) }
    }
}
