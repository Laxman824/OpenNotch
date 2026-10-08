import Foundation

/// A watcher: "tell me when X" — the assistant checks something in the background every so often, with
/// read-only tools, until a condition is met, then drops a notice from the notch. Bounded (checks, days),
/// and it can end as met, blocked (with the reason) or expired. Watchers never act — they only report.
struct Watch: Codable, Identifiable, Equatable {
    enum Phase: String, Codable { case active, paused, met, blocked, expired }

    var id: String
    var what: String                  // what to check ("the Apple Store page for the M5 MacBook Air")
    var until: String                 // when to tell the user ("it says in stock")
    var everyMinutes: Int
    var maxChecks: Int
    var created: Date
    var expires: Date
    var checks = 0
    var lastRun: Date? = nil
    var phase: Phase = .active
    /// Latest one-line status from a check (or why it stopped).
    var note: String? = nil
    /// Checks in a row that ended without a STATUS line.
    var unclear = 0
}

/// Pure rules: what a valid watcher is, when it's due, what a check is asked, how its answer is read
/// (narrow: only a STATUS line counts — rule 9), and what happens after.
enum WatchLogic {
    static let minEvery = 15, maxEvery = 1440, defaultEvery = 60
    static let maxDays = 30, defaultDays = 7
    static let maxActive = 10
    static let maxUnclear = 3

    static func make(_ args: [String: Any], now: Date = Date(), id: String = String(UUID().uuidString.prefix(8)).lowercased()) -> Result<Watch, ToolError> {
        let what = (args["what"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let until = (args["until"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !what.isEmpty else { return .failure(ToolError("what is required: the thing to check")) }
        guard !until.isEmpty else { return .failure(ToolError("until is required: when to tell the user")) }
        let every = min(maxEvery, max(minEvery, (args["every_minutes"] as? NSNumber)?.intValue ?? defaultEvery))
        let days = min(maxDays, max(1, (args["days"] as? NSNumber)?.intValue ?? defaultDays))
        let checks = min(200, max(1, days * 24 * 60 / every))
        return .success(Watch(id: id, what: String(what.prefix(300)), until: String(until.prefix(200)), everyMinutes: every,
                              maxChecks: checks, created: now, expires: now.addingTimeInterval(Double(days) * 86_400)))
    }

    /// The watcher to check now, if any (oldest first; one at a time).
    static func due(_ all: [Watch], now: Date) -> Watch? {
        all.filter { w in
            w.phase == .active && (w.lastRun.map { now.timeIntervalSince($0) >= Double(w.everyMinutes * 60) - 20 } ?? true)
        }.min { ($0.lastRun ?? .distantPast) < ($1.lastRun ?? .distantPast) }
    }

    static func prompt(_ w: Watch) -> String {
        """
        Background check for a watcher the user set up (nobody is reading this live). Check: \(w.what). \
        The user wants to know when: \(w.until). Use your read-only tools to look now. Don't take any actions.
        End with exactly one line, one of:
        STATUS: MET — <one sentence the user will see: what you found, with the key detail>
        STATUS: NOT_YET — <one short sentence on what it is now>
        STATUS: BLOCKED — <why this can't be checked with your tools>
        """
    }

    enum Verdict: Equatable { case met(String), notYet(String), blocked(String), unclear }

    /// Only the last line that starts with "STATUS:" counts; anything else is unclear.
    static func verdict(_ text: String) -> Verdict {
        guard let line = text.components(separatedBy: "\n").map({ $0.trimmingCharacters(in: .whitespaces) })
            .last(where: { $0.uppercased().hasPrefix("STATUS:") }) else { return .unclear }
        let rest = line.dropFirst("STATUS:".count).trimmingCharacters(in: .whitespaces)
        func note(_ tag: String) -> String {
            String(rest.dropFirst(tag.count)).trimmingCharacters(in: CharacterSet(charactersIn: " —–-:")).prefix(240).description
        }
        let u = rest.uppercased()
        if u.hasPrefix("NOT_YET") || u.hasPrefix("NOT YET") { return .notYet(note("NOT_YET")) }
        if u.hasPrefix("MET") { return .met(note("MET")) }
        if u.hasPrefix("BLOCKED") { return .blocked(note("BLOCKED")) }
        return .unclear
    }

    /// The watcher after one check. Expiry and the check cap end it after a non-met answer.
    static func after(_ w: Watch, _ v: Verdict, now: Date) -> Watch {
        var w = w
        w.checks += 1
        w.lastRun = now
        switch v {
        case .met(let n): w.phase = .met; w.note = n; w.unclear = 0; return w
        case .blocked(let n): w.phase = .blocked; w.note = n.isEmpty ? "It can't be checked with the tools I have." : n; return w
        case .notYet(let n): w.note = n; w.unclear = 0
        case .unclear:
            w.unclear += 1
            if w.unclear >= maxUnclear { w.phase = .blocked; w.note = "I couldn't tell from \(maxUnclear) checks in a row."; return w }
        }
        if w.checks >= w.maxChecks || now >= w.expires {
            w.phase = .expired
            w.note = "Stopped after \(w.checks) checks — it hadn't happened yet." + (w.note.map { " Last: \($0)" } ?? "")
        }
        return w
    }

    static func describe(_ w: Watch) -> String {
        let every = w.everyMinutes % 60 == 0 ? "\(w.everyMinutes / 60) h" : "\(w.everyMinutes) min"
        return "[\(w.id)] \(w.phase.rawValue) · \(w.what) → until \(w.until) · every \(every) · \(w.checks)/\(w.maxChecks) checks"
            + (w.note.map { " · \($0)" } ?? "")
    }

    /// Read-only tools a check may use (completeWithTools keeps only `.read` ones anyway).
    static let checkTools: Set<String> = [
        "web_search", "fetch_url", "mail_recent", "mail_read", "calendar_events", "reminders_list", "weather",
        "system_info", "list_directory", "find_files", "read_file", "spotlight_search", "recall",
    ]
}

/// watchers.json in Application Support (path overridable for checks).
final class WatchStore: @unchecked Sendable {
    static let shared = WatchStore()
    private let path: String
    private let lock = NSLock()

    init(path: String = opennotchDir("") + "/watchers.json") { self.path = path }

    func all() -> [Watch] {
        lock.lock(); defer { lock.unlock() }
        return load()
    }

    private func load() -> [Watch] {
        guard let d = FileManager.default.contents(atPath: path) else { return [] }
        let dec = JSONDecoder(); dec.dateDecodingStrategy = .iso8601
        return (try? dec.decode([Watch].self, from: d)) ?? []
    }

    private func write(_ ws: [Watch]) {
        let enc = JSONEncoder(); enc.dateEncodingStrategy = .iso8601; enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        try? enc.encode(ws).write(to: URL(fileURLWithPath: path), options: .atomic)
    }

    /// Adds a watcher; refuses past `maxActive` running ones. Finished ones older than 30 days are dropped.
    func add(_ w: Watch) -> String? {
        lock.lock(); defer { lock.unlock() }
        var ws = load().filter { $0.phase == .active || Date().timeIntervalSince($0.lastRun ?? $0.created) < 30 * 86_400 }
        guard ws.filter({ $0.phase == .active }).count < WatchLogic.maxActive else {
            return "You already have \(WatchLogic.maxActive) watchers running — stop one first (watch_stop)."
        }
        ws.append(w)
        write(ws)
        return nil
    }

    func update(_ w: Watch) {
        lock.lock(); defer { lock.unlock() }
        var ws = load()
        if let i = ws.firstIndex(where: { $0.id == w.id }) { ws[i] = w; write(ws) }
    }

    @discardableResult
    func remove(_ id: String) -> Bool {
        lock.lock(); defer { lock.unlock() }
        var ws = load()
        let n = ws.count
        ws.removeAll { $0.id == id }
        write(ws)
        return ws.count < n
    }
}

enum WatchTools {
    static func all(store: WatchStore = .shared) -> [AgentTool] { [
        AgentTool(
            name: "watch_start",
            description: "Keep an eye on something and tell the user when it happens (\"tell me when the price drops below $900\", "
                + "\"let me know when Priya replies\"). Checked in the background every few minutes with read-only tools "
                + "(web, mail, calendar, files) — it never acts. Not for things at a fixed time: use schedule_task for those.",
            schema: Schema.object(["what": Schema.string("What to check, specific enough to look up (a URL, a sender, a search)"),
                                   "until": Schema.string("The condition to tell the user about"),
                                   "every_minutes": Schema.integer("How often to check (15–1440, default 60)"),
                                   "days": Schema.integer("Give up after this many days (1–30, default 7)")],
                                  required: ["what", "until"]),
            risk: .confirm, verb: "Starting a watcher", detail: { $0.str("until") ?? "" },
            preview: { a in "Watch: \(a.str("what") ?? "")\nTell you when: \(a.str("until") ?? "")\nEvery \(a.int("every_minutes") ?? WatchLogic.defaultEvery) min, for \(a.int("days") ?? WatchLogic.defaultDays) days" },
            run: { a in
                if ToolKit.background { return .fail("Watchers can only be started from a chat.") }
                switch WatchLogic.make(a.dict) {
                case .failure(let e): return .fail(e.message)
                case .success(let w):
                    if let problem = store.add(w) { return .fail(problem) }
                    return ToolOutcome(ok: true, text: "Watching (id \(w.id)): \(WatchLogic.describe(w)). The first check runs within a minute; "
                                       + "the user gets a notice from the notch when it happens.")
                }
            }),
        AgentTool(
            name: "watch_list",
            description: "List the user's watchers (running and recently finished) with their latest status.",
            schema: Schema.object([:]),
            risk: .read, verb: "Listing watchers", detail: { _ in "" }, preview: { _ in "" },
            run: { _ in
                let ws = store.all()
                return ToolOutcome(ok: true, text: ws.isEmpty ? "No watchers." : ws.map(WatchLogic.describe).joined(separator: "\n"))
            }),
        AgentTool(
            name: "watch_stop",
            description: "Stop and delete a watcher by id (from watch_list).",
            schema: Schema.object(["id": Schema.string("Watcher id")], required: ["id"]),
            risk: .read, verb: "Stopping a watcher", detail: { $0.str("id") ?? "" }, preview: { _ in "" },
            run: { a in
                guard let id = a.str("id") else { return .fail("id is required") }
                return store.remove(id) ? ToolOutcome(ok: true, text: "Stopped watcher \(id).") : .fail("No watcher with id \(id).")
            }),
    ] }
}
