import Foundation

/// `OpenNotch --checks` — in-process assertions for the agent's pure logic
/// (run by Checks/run.sh). No network, no user data.
@MainActor
enum AgentChecks {
    private static var failed = 0, total = 0

    private static func check(_ name: String, _ ok: Bool) {
        total += 1
        if !ok { failed += 1; print("FAIL \(name)") }
    }

    static func run() async -> Int32 {
        // Context window
        var msgs: [ChatMessage] = [ChatMessage(role: .assistant, text: "orphan"), ChatMessage(role: .tool, text: "r", toolCallId: "x")]
        for i in 0..<10 {
            msgs.append(ChatMessage(role: .user, text: "q\(i)", images: ["/tmp/a\(i).png"]))
            msgs.append(ChatMessage(role: .assistant, text: String(repeating: "a", count: 1000)))
        }
        let w = AgentCore.window(msgs, maxChars: 5000)
        check("window starts at a user message", w.first?.role == .user)
        check("window respects the size cap", w.reduce(0) { $0 + $1.text.count } <= 5000)
        check("window keeps images on at most 2 turns", w.filter { $0.images?.isEmpty == false }.count <= 2)
        check("window keeps the latest turn", w.last?.text == msgs.last?.text)

        // Retry delay
        check("retry: body seconds", HTTP.retryDelay(header: nil, body: "Please try again in 11.0025s. Need more") == 11.0025)
        check("retry: header", HTTP.retryDelay(header: "3", body: "") == 3)
        check("retry: default", HTTP.retryDelay(header: nil, body: "overloaded") == 2)

        // Forbidden commands
        for c in ["rm -rf /", "rm -rf ~", "sudo ls", "dd if=x of=/dev/disk2", "diskutil eraseDisk APFS x disk2"] {
            check("blocked: \(c)", ToolKit.isForbidden(c))
        }
        for c in ["rm -rf build", "ls -la ~", "git status", "rm -rf ./node_modules"] {
            check("allowed: \(c)", !ToolKit.isForbidden(c))
        }

        // DuckDuckGo parsing
        let html = """
        <a rel="nofollow" class="result__a" href="//duckduckgo.com/l/?uddg=https%3A%2F%2Fswift.org%2Fdocs&amp;rut=1">Swift &amp; Docs</a>
        <a class="result__snippet" href="x">The <b>Swift</b> language.</a>
        """
        let r = ToolKit.parseDuckDuckGo(html)
        check("ddg: url decoded", r.first?.url == "https://swift.org/docs")
        check("ddg: title cleaned", r.first?.title == "Swift & Docs")
        check("ddg: snippet", r.first?.snippet == "The Swift language.")

        // MCP names
        let n = MCPManager.wireName(server: "my server", tool: "get.thing")
        check("mcp name", n == "mcp__my_server__get_thing")
        check("mcp name length", MCPManager.wireName(server: String(repeating: "s", count: 50), tool: String(repeating: "t", count: 50)).count <= 64)

        // Default models
        check("default anthropic", ProviderKind.pickDefault(.anthropic, from: []) == "claude-opus-5-5")
        check("default openai", ProviderKind.pickDefault(.openai, from: ["gpt-4o", "gpt-5"]) == "gpt-5")
        check("default openrouter", ProviderKind.pickDefault(.openrouter, from: ["x"]) == "openrouter/auto")
        check("default ollama", ProviderKind.pickDefault(.ollama, from: ["llama3.2"]) == "llama3.2")

        // Path policy
        let home = NSHomeDirectory()
        check("path: /etc blocked", PathPolicy.check("/etc/passwd", write: false) != nil)
        check("path: home write ok", PathPolicy.check(home + "/Documents/x.txt", write: true) == nil)
        check("path: ssh blocked", PathPolicy.check(home + "/.ssh/id_ed25519", write: false) != nil)
        check("path: sessions blocked", PathPolicy.check(AppPaths.root + "/sessions/current.json", write: false) != nil)
        check("path: tilde", PathPolicy.resolve("~/x").hasPrefix(home))

        // Read-before-write
        let dir = NSTemporaryDirectory() + "opennotch-checks-\(UUID().uuidString)"
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let f = PathPolicy.resolve(dir + "/a.txt")
        try? "one".write(toFile: f, atomically: true, encoding: .utf8)
        await FileState.shared.reset()
        check("rbw: unread file refused", await FileState.shared.problem(f)?.hasPrefix("read_before_write") == true)
        await FileState.shared.record(f)
        check("rbw: read file ok", await FileState.shared.problem(f) == nil)
        try? "one two".write(toFile: f, atomically: true, encoding: .utf8)
        check("rbw: changed file stale", await FileState.shared.problem(f)?.hasPrefix("stale_file") == true)
        check("rbw: new file ok", await FileState.shared.problem(dir + "/new.txt") == nil)
        let edit = await ToolKit.editFile(ToolArgs(json: #"{"path":"\#(f)","old_string":"one","new_string":"1"}"#))
        check("edit refused when stale", !edit.ok)
        _ = await ToolKit.readFile(ToolArgs(json: #"{"path":"\#(f)"}"#))
        let edit2 = await ToolKit.editFile(ToolArgs(json: #"{"path":"\#(f)","old_string":"one","new_string":"1"}"#))
        check("edit after read", edit2.ok && (try? String(contentsOfFile: f, encoding: .utf8)) == "1 two")
        try? FileManager.default.removeItem(atPath: dir)

        // HTML → text
        let t = ToolKit.htmlToText("<html><head><title>Hi &amp; bye</title><script>x()</script></head><body><p>One</p><p>Two</p></body></html>",
                                   url: URL(string: "https://e.com")!)
        check("html: title", t.hasPrefix("# Hi & bye"))
        check("html: no script", !t.contains("x()"))
        check("html: paragraphs", t.contains("One") && t.contains("Two"))

        // OpenAI wire: tool calls echo extra_content (Gemini thought signatures)
        let m = ChatMessage(role: .assistant, text: "", toolCalls: [ToolCall(id: "c1", name: "t", arguments: "{}",
                                                                           extra: #"{"google":{"thought_signature":"sig"}}"#)])
        let wired = OpenAICompatibleProvider.wire(true)(m)
        let calls = wired?["tool_calls"] as? [[String: Any]]
        check("wire: tool call id", calls?.first?["id"] as? String == "c1")
        check("wire: extra echoed", ((calls?.first?["extra_content"] as? [String: Any])?["google"] as? [String: Any])?["thought_signature"] as? String == "sig")
        let tool = OpenAICompatibleProvider.wire(true)(ChatMessage(role: .tool, text: "ok", toolCallId: "c1"))
        check("wire: tool result", tool?["tool_call_id"] as? String == "c1" && tool?["role"] as? String == "tool")

        // Chat history (temp folder + temp defaults key — never the real chats)
        let hdir = NSTemporaryDirectory() + "opennotch-history-\(UUID().uuidString)"
        try? FileManager.default.createDirectory(atPath: hdir, withIntermediateDirectories: true)
        let hkey = "checks.chat.current.\(UUID().uuidString)"
        try? JSONEncoder().encode([ChatMessage(role: .user, text: "legacy hello")])
            .write(to: URL(fileURLWithPath: hdir + "/current.json"))
        let st = SessionStore(dir: hdir, key: hkey)
        check("history: legacy migrated", st.load().first?.text == "legacy hello")
        let firstID = st.currentID
        st.startNew()
        st.save([ChatMessage(role: .user, text: "Plan my trip to Goa\n\n[OpenNotch context]\nsecret"),
                 ChatMessage(role: .assistant, text: "Sure — here's a plan.")], sync: true)
        let tripID = st.currentID
        st.startNew()
        st.save([], sync: true)
        let all = st.list()
        check("history: two chats listed (empty one skipped)", all.count == 2)
        check("history: title from first message, context hidden", all.contains { $0.title == "Plan my trip to Goa" })
        check("history: search body", st.search("here's a plan").map(\.id) == [tripID])
        check("history: search misses", st.search("zebra").isEmpty)
        st.switchTo(firstID)
        check("history: switch loads", st.load().first?.text == "legacy hello")
        st.delete(tripID)
        check("history: delete", !st.list().contains { $0.id == tripID })
        check("history: long title trimmed", SessionStore.title(String(repeating: "a", count: 90)).count == 61)
        UserDefaults.standard.removeObject(forKey: hkey)
        try? FileManager.default.removeItem(atPath: hdir)

        // Tool router
        let everyTool = ToolKit.all() + DailyTools.all() + [ToolRouter.moreTools]
        func routed(_ text: String) -> Set<String> {
            Set(ToolRouter.select(everyTool, conversation: [ChatMessage(role: .user, text: text)]).map(\.name))
        }
        check("router: core always", routed("hi").isSuperset(of: ["read_file", "web_search", "more_tools"]))
        check("router: no mail for hi", !routed("hi").contains("mail_recent"))
        check("router: email", routed("any new emails from Priya?").contains("mail_recent"))
        check("router: weather", routed("will it rain tomorrow in Pune?").contains("weather"))
        check("router: plan my day", routed("plan my day").isSuperset(of: ["calendar_events", "reminders_list", "weather"]))
        check("router: schedule", routed("every weekday at 9 brief me").contains("schedule_task"))
        check("router: this page", routed("summarise this page").contains("active_tab"))
        check("router: fewer than half", routed("hi").count * 2 < everyTool.count)
        let used = [ChatMessage(role: .user, text: "check mail"),
                    ChatMessage(role: .assistant, text: "", toolCalls: [ToolCall(id: "1", name: "mail_recent", arguments: "{}")]),
                    ChatMessage(role: .user, text: "reply to the first one")]
        check("router: sticky used tools", Set(ToolRouter.select(everyTool, conversation: used).map(\.name)).contains("mail_recent"))
        check("router: more_tools group", Set(ToolRouter.select(everyTool, conversation: [ChatMessage(role: .user, text: "hi")],
                                                               extra: ["notes_app"]).map(\.name)).contains("notes_create"))

        // Scheduler
        let spath = NSTemporaryDirectory() + "opennotch-schedule-\(UUID().uuidString).json"
        let sch = ScheduleStore(path: spath)
        let cal = Calendar.current
        let nine = cal.date(bySettingHour: 9, minute: 0, second: 0, of: Date())!
        let daily = sch.add(prompt: "brief me", hour: 9, minute: 0, repeat: .daily, date: nil)
        check("schedule: not due right after adding", sch.takeDue(Date()).isEmpty)
        let tomorrowNine = cal.date(byAdding: .day, value: 1, to: nine)!
        check("schedule: due at next slot", sch.takeDue(tomorrowNine.addingTimeInterval(60)).map(\.id) == [daily.id])
        check("schedule: only once per slot", sch.takeDue(tomorrowNine.addingTimeInterval(120)).isEmpty)
        check("schedule: stale slot skipped", sch.takeDue(tomorrowNine.addingTimeInterval(3 * 3600)).isEmpty)
        var wk = ScheduleStore.Task(id: "w", prompt: "x", hour: 9, minute: 0, repeat: .weekdays, date: nil, lastRun: nil)
        let sat = cal.nextDate(after: Date(), matching: DateComponents(hour: 10, weekday: 7), matchingPolicy: .nextTime)!
        let slot = ScheduleStore.lastSlot(wk, before: sat)
        check("schedule: weekdays skip Saturday", slot.map { cal.component(.weekday, from: $0) } == 6)
        wk.repeat = .once; wk.date = "2020-01-01"
        check("schedule: once in the past fires", ScheduleStore.lastSlot(wk, before: Date()) != nil)
        check("schedule: remove", sch.remove(daily.id) && sch.all().isEmpty)
        try? FileManager.default.removeItem(atPath: spath)

        // Weather words, AppleScript escaping
        check("weather: code 61", DailyTools.describe(NSNumber(value: 61)) == "rain")
        check("weather: code 0", DailyTools.describe(NSNumber(value: 0)) == "clear")
        check("applescript escape", DailyTools.esc(#"say "hi" \ now"#) == #"say \"hi\" \\ now"#)

        // Character brain
        let b = CharacterBrain()
        var clock = Date()
        func tick(_ sec: Double) { for _ in 0..<Int(sec * 60) { clock.addTimeInterval(1.0 / 60); b.step(clock, doneAt: nil, dragging: false) } }
        UserDefaults.standard.set(false, forKey: Prefs.characterSounds)       // silent checks
        b.poke()
        check("puff: poke annoys", b.current == .annoyed)
        b.poke(); b.poke()
        check("puff: 3 pokes = dizzy", b.current == .dizzy)
        b.celebrate(sound: false)
        tick(0.2)
        check("puff: hop goes up", b.hop > 0.05)
        tick(2.5)
        check("puff: hop lands", b.hop == 0)
        check("puff: squash settles", abs(b.squash) < 0.02)
        b.hover(true)
        for i in 0..<12 { b.pet(x: i % 2 == 0 ? 10 : 30) }
        check("puff: petting = love", b.current == .love && !b.hearts.isEmpty)
        UserDefaults.standard.removeObject(forKey: Prefs.characterSounds)
        for k in SoundFX.Kind.allCases {
            let d = SoundFX.wav(k)
            check("sound \(k): wav", d.count > 1000 && String(data: d.prefix(4), encoding: .ascii) == "RIFF")
        }

        print(failed == 0 ? "agent: \(total)/\(total) pass" : "agent: \(failed) of \(total) FAILED")
        return failed == 0 ? 0 : 1
    }
}
