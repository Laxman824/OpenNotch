import Foundation

/// Fixed prompts with the tools a good answer uses — so changes to the router,
/// the prompt or the tools can be measured instead of judged by feel.
///
/// - `--checks` uses them offline: the router must offer every expected tool.
/// - `OpenNotch --eval <provider> [model]` runs them against a live model
///   (key from $OPENNOTCH_KEY or the one saved in Settings). Nothing real happens: tools that
///   change anything (approval tools, memory, timers, music, opening apps)
///   return a pretend success instead of running. `OPENNOTCH_EVAL=name,name`
///   runs a subset.
struct EvalCase: Sendable {
    let name: String
    let prompt: String
    var any: [String] = []        // at least one of these must be called
    var all: [String] = []        // every one of these must be called
    var noTools = false           // a plain answer, no tools

    static let cases: [EvalCase] = [
        EvalCase(name: "weather", prompt: "Will I need an umbrella in Paris tomorrow?", all: ["weather"]),
        EvalCase(name: "plan-day", prompt: "Plan my day", all: ["calendar_events", "reminders_list"]),
        EvalCase(name: "past-chat", prompt: "What did we decide about the logo colours last time we talked about it?", all: ["search_chats"]),
        EvalCase(name: "find-file", prompt: "Find the invoice PDF I downloaded recently", any: ["find_files", "run_command", "list_directory"]),
        EvalCase(name: "fetch", prompt: "Summarise https://www.swift.org/about/ in two lines", all: ["fetch_url"]),
        EvalCase(name: "web", prompt: "Who won the most recent Formula 1 race?", any: ["web_search", "fetch_url"]),
        EvalCase(name: "mail-unread", prompt: "Anything unread in my email that needs me?", all: ["mail_recent"]),
        EvalCase(name: "mail-draft", prompt: "Draft an email to sam@example.com saying I'll be 10 minutes late to our 3pm", all: ["mail_draft"]),
        EvalCase(name: "schedule", prompt: "Every weekday at 9am give me a short tech news brief", all: ["schedule_task"]),
        EvalCase(name: "disk", prompt: "How much free disk space do I have?", any: ["system_info", "run_command"]),
        EvalCase(name: "event", prompt: "Put lunch with Priya on my calendar tomorrow at 1pm", all: ["create_event"]),
        EvalCase(name: "reminder", prompt: "Add a reminder to renew my passport next Monday at 10", all: ["create_reminder"]),
        EvalCase(name: "reminders-due", prompt: "What's due on my reminders?", all: ["reminders_list"]),
        EvalCase(name: "contact", prompt: "What's Anna's phone number?", all: ["contacts_find"]),
        EvalCase(name: "screen", prompt: "What's on my screen right now?", all: ["screenshot"]),
        EvalCase(name: "list-dir", prompt: "What's in my Downloads folder?", any: ["list_directory", "run_command"]),
        EvalCase(name: "grep", prompt: "Search the code in ~/Projects for TODO comments", any: ["search_text", "run_command"]),
        EvalCase(name: "awake", prompt: "Keep my Mac awake for the next hour", all: ["keep_awake"]),
        EvalCase(name: "timer", prompt: "Start a 25 minute focus timer", all: ["timer"]),
        EvalCase(name: "remember", prompt: "Remember that my home city is Lisbon", all: ["remember"]),
        EvalCase(name: "apple-note", prompt: "Make an Apple Note called Gift ideas with: book, scarf, tea", all: ["notes_create"]),
        EvalCase(name: "math", prompt: "What's 15% of 2,340?", noTools: true),
        EvalCase(name: "translate", prompt: "How do I say 'good morning' in Spanish?", noTools: true),
        EvalCase(name: "multi", prompt: "What's the weather in Tokyo and what's on my calendar today?", all: ["weather", "calendar_events"]),
    ]

    /// Did the calls made satisfy this case?
    func judge(_ called: [String]) -> (pass: Bool, why: String) {
        let used = called.filter { $0 != "more_tools" && $0 != "todo_write" }
        if noTools { return (used.isEmpty, used.isEmpty ? "" : "expected no tools, called \(used.joined(separator: ", "))") }
        let missing = all.filter { !called.contains($0) }
        if !missing.isEmpty { return (false, "missing \(missing.joined(separator: ", "))") }
        if !any.isEmpty && !any.contains(where: called.contains) { return (false, "expected one of \(any.joined(separator: ", "))") }
        return (true, "")
    }
}

@MainActor
enum Evals {
    /// Tools that change something outside the conversation: pretend in evals.
    static let pretend: Set<String> = ["remember", "forget", "timer", "keep_awake", "open", "media_control",
                                       "clipboard", "notes", "screenshot"]

    static func run() async -> Int32 {
        let args = CommandLine.arguments
        guard let i = args.firstIndex(of: "--eval"), i + 1 < args.count, let kind = ProviderKind(rawValue: args[i + 1]) else {
            print("usage: OpenNotch --eval <\(ProviderKind.allCases.map(\.rawValue).joined(separator: "|"))> [model]")
            return 2
        }
        // $OPENNOTCH_KEY, else the key saved in Settings (Keychain) for this provider.
        let key = ProcessInfo.processInfo.environment["OPENNOTCH_KEY"] ?? ProviderStore.key(for: kind)
        var model = i + 2 < args.count ? args[i + 2] : (ProviderStore.activeKind == kind ? ProviderStore.model(for: kind) : nil)
        if model == nil, let models = try? await ProviderStore.test(kind, key: key) { model = ProviderKind.pickDefault(kind, from: models) }
        guard let provider = ProviderStore.make(kind, model: model, key: key) else {
            print("✗ couldn't build the provider (missing key or model)")
            return 1
        }
        let only = ProcessInfo.processInfo.environment["OPENNOTCH_EVAL"].map { Set($0.split(separator: ",").map(String.init)) }
        let cases = EvalCase.cases.filter { only?.contains($0.name) ?? true }
        print("eval: \(provider.name) · \(provider.model) · \(cases.count) cases\n")
        var passed = 0, inTok = 0, outTok = 0
        let started = Date()
        for c in cases {
            let core = AgentCore(ephemeral: provider)
            core.pretendTools = pretend
            var called: [String] = []
            var error: String?
            let t0 = Date()
            await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
                core.emit = { ev in
                    switch ev["type"] as? String ?? "" {
                    case "tool" where ev["state"] as? String != "running":
                        called.append(ev["name"] as? String ?? "")
                    case "approval": core.approve(id: ev["id"] as? String ?? "", allow: true)    // pretend-run below
                    case "error": error = ev["text"] as? String
                    case "done":
                        inTok += ev["inTokens"] as? Int ?? 0; outTok += ev["outTokens"] as? Int ?? 0
                        done.resume()
                    default: break
                    }
                }
                core.send(c.prompt, display: nil)
            }
            let (ok, why) = error.map { (false, "error: \($0)") } ?? c.judge(called)
            if ok { passed += 1 }
            let tools = called.isEmpty ? "—" : called.joined(separator: " → ")
            print("\(ok ? "✓" : "✗") \(c.name.padding(toLength: 14, withPad: " ", startingAt: 0)) \(String(format: "%5.1fs", Date().timeIntervalSince(t0)))  \(tools)\(ok ? "" : "   ← \(why)")")
        }
        print("\n\(passed)/\(cases.count) passed · \(Int(Date().timeIntervalSince(started))) s · \(inTok) in / \(outTok) out tokens")
        return passed == cases.count ? 0 : 1
    }
}
