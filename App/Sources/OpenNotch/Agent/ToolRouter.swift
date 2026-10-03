import Foundation

/// Which tools to send with a request. Sending all ~38 tool descriptions costs
/// ~5k tokens every round (free tiers hit their per-minute limits) and gives
/// small models too many choices. Core tools always go; the rest join when the
/// request mentions their topic, when they were used earlier in the chat, or
/// when the model asks for a group with `more_tools`.
enum ToolRouter {
    static let core: Set<String> = [
        "read_file", "list_directory", "find_files", "run_command", "fetch_url", "web_search", "open",
        "clipboard", "screenshot", "system_info", "remember", "forget", "todo_write", "notes", "timer", "more_tools",
        "recall", "search_chats",
    ]

    struct Group { let name: String; let pattern: String; let tools: [String] }

    static let groups: [Group] = [
        Group(name: "files", pattern: #"\b(edit|write|create|change|fix|rename|refactor|update|append|grep|bug|search (the|my) (code|files?)|in the file|save (it|to)|attached files)\b"#,
              tools: ["write_file", "edit_file", "search_text"]),
        Group(name: "mail", pattern: #"\b(e-?mails?|inbox|mail|reply|replies|unread|gmail|outlook|draft|send it)\b"#,
              tools: ["mail_recent", "mail_read", "mail_draft", "mail_send", "contacts_find"]),
        Group(name: "calendar", pattern: #"\b(calendar|meetings?|events?|agenda|schedule|today|tomorrow|this week|plan my day|remind(er)?s?|due)\b"#,
              tools: ["calendar_events", "create_event", "reminders_list", "create_reminder"]),
        Group(name: "notes_app", pattern: #"\b(apple notes?|notes app|my notes|an? note|note (about|on|for|called))\b"#,
              tools: ["notes_search", "notes_read", "notes_create"]),
        Group(name: "contacts", pattern: #"\b(contacts?|phone number|email address|birthday|number for|'s email)\b"#,
              tools: ["contacts_find"]),
        Group(name: "weather", pattern: #"\b(weather|rain|temperature|forecast|umbrella|hot|cold|sunny|plan my day)\b"#,
              tools: ["weather"]),
        Group(name: "browser", pattern: #"\b(this (web )?(page|tab|article|site|video)|current (page|tab)|what i'?m (reading|looking at)|browser|web page)\b"#,
              tools: ["active_tab"]),
        Group(name: "schedule", pattern: #"\b(every (day|morning|evening|weekday|week)|each (day|morning)|daily|weekdays|schedul|at \d{1,2}(:\d\d)?\s?(am|pm)?\b)"#,
              tools: ["schedule_task", "list_scheduled", "cancel_scheduled"]),
        Group(name: "music", pattern: #"\b(play|pause|song|music|spotify|track|volume|album|artist)\b"#, tools: ["media_control"]),
        Group(name: "awake", pattern: #"\b(awake|sleep|caffeinate|don'?t let (it|the mac) sleep)\b"#, tools: ["keep_awake"]),
    ]

    /// Picks the tools for this request. `extra` = groups asked for via more_tools.
    static func select(_ all: [AgentTool], conversation: [ChatMessage], extra: Set<String> = []) -> [AgentTool] {
        if UserDefaults.standard.bool(forKey: "agent.allTools") { return all }
        let users = conversation.filter { $0.role == .user && $0.toolCallId == nil }.suffix(2)
        let text = users.map { routingText($0.text) }.joined(separator: "\n").lowercased()
        var names = core
        for g in groups where extra.contains(g.name) || text.range(of: g.pattern, options: .regularExpression) != nil {
            names.formUnion(g.tools)
        }
        // Tools the model already used in this chat stay available (follow-ups like "now reply to it").
        for m in conversation.suffix(40) { for c in m.toolCalls ?? [] { names.insert(c.name) } }
        return all.filter { names.contains($0.name) || $0.name.hasPrefix("mcp__") }
    }

    /// What a message is about: what was typed, plus the start of what the app attached
    /// (page title, file names, selected text) — without the "Sent:" stamp.
    static func routingText(_ text: String) -> String {
        let parts = text.components(separatedBy: AgentCore.contextMarker)
        let typed = parts.first ?? text
        guard parts.count > 1 else { return typed }
        let ctx = parts.dropFirst().joined(separator: "\n").components(separatedBy: "\n")
            .filter { !$0.hasPrefix("Sent: ") && !$0.hasPrefix("Hands-free voice mode") }.joined(separator: "\n")
        return typed + "\n" + String(ctx.prefix(1500))
    }

    static var moreTools: AgentTool {
        AgentTool(
            name: "more_tools",
            description: "Load more tools when you need one you don't have. Groups and the tools they add: "
                + groups.map { "\($0.name) (\($0.tools.joined(separator: ", ")))" }.joined(separator: "; ")
                + ". Ask for every group you'll need in one call.",
            schema: #"{"type":"object","properties":{"groups":{"type":"array","items":{"type":"string"}}},"required":["groups"]}"#,
            risk: .read, verb: "Loading tools", detail: { a in (a.dict["groups"] as? [String] ?? []).joined(separator: ", ") },
            preview: { _ in "" },
            run: { a in
                let want = (a.dict["groups"] as? [String] ?? []).filter { g in groups.contains { $0.name == g } }
                return want.isEmpty ? .fail("Unknown group. Choose from: " + groups.map(\.name).joined(separator: ", "))
                    : ToolOutcome(ok: true, text: "Loaded: \(want.joined(separator: ", ")). They're available from your next step.")
            })
    }
}
