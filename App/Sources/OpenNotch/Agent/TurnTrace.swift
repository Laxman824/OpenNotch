import Foundation

// Turn traces — what the agent did, step by step, for the Developer view (⋯ › Developer…) and bug reports.
// Vocabulary follows harness event logs: a *turn* (one message → answer) holds ordered *events*: the router's choice,
// the decider, each model pass (with retries), every tool call (args, result, time, parallel, read-back check), approvals,
// questions, and how the turn ended. One JSON line per finished turn in traces/turns-YYYY-MM-DD.jsonl, kept 14 days.
// Local only. Exports go through `TraceLogic.redacted`: no content unless asked, and emails, home paths and key-like
// strings are always scrubbed (must-NOT checks in AgentChecks).

struct TraceEvent: Codable, Equatable {
    enum Kind: String, Codable { case route, decide, llm, retry, tool, approval, question, info }
    var kind: Kind
    var at: Int                    // ms after the turn started
    var ms: Int = 0                // how long it took
    var name: String               // tool / model / "router"
    var ok = true
    var detail = ""                // one short line
    var args: String?              // local only (≤ 1,500 chars)
    var result: String?            // local only (≤ 1,500 chars)
    var parallel = false
    var verified = false           // the tool read its effect back ("(checked)")
    var first: Int?                // llm: ms until the first output
}

struct TurnRecord: Codable, Equatable, Identifiable {
    var id: String
    var chat: String?
    var started: Date
    var prompt: String
    var provider: String
    var model: String
    var events: [TraceEvent] = []
    var end = "completed"          // completed · stopped · limit · error: …
    var ms = 0
    var inTokens = 0
    var outTokens = 0
    var toolCalls = 0

    var failedTools: Int { events.filter { $0.kind == .tool && !$0.ok }.count }
    var approvals: Int { events.filter { $0.kind == .approval }.count }
    var hadProblem: Bool { end != "completed" || failedTools > 0 || events.contains { $0.kind == .retry } }
}

/// Pure rules (checked in AgentChecks).
enum TraceLogic {
    static let keepDays = 14
    static let clip = 1_500

    /// What was typed (no context block, no "Sent:" stamp), ≤ 200 chars.
    static func promptPreview(_ text: String) -> String {
        let typed = text.components(separatedBy: AgentCore.contextMarker).first ?? text
        let lines = typed.components(separatedBy: "\n").filter { !$0.hasPrefix("Sent: ") }
        return String(lines.joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines).prefix(200))
    }

    static func cut(_ s: String?) -> String? {
        guard let s, !s.isEmpty else { return nil }
        return s.count > clip ? String(s.prefix(clip)) + "…" : s
    }

    /// Removes what must never leave the Mac: email addresses, the home folder (and its user name), key-like strings.
    static func scrub(_ s: String, home: String = NSHomeDirectory()) -> String {
        var t = s.replacingOccurrences(of: home, with: "~")
        t = t.replacingOccurrences(of: #"/Users/[^/\s"']+"#, with: "~", options: .regularExpression)
        t = t.replacingOccurrences(of: #"[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}"#, with: "<email>", options: .regularExpression)
        t = t.replacingOccurrences(of: #"\b(sk|pk|rk|gsk|xai|ghp|gho|github_pat|AIza|ya29)[-_A-Za-z0-9.]{12,}"#, with: "<secret>",
                                   options: .regularExpression)
        t = t.replacingOccurrences(of: #"(?i)(bearer|token|key|secret|password|pwd)([=: ]+)[^\s&"']{6,}"#, with: "$1$2<secret>",
                                   options: .regularExpression)
        t = t.replacingOccurrences(of: #"\b[A-Za-z0-9+/_-]{40,}={0,2}"#, with: "<secret>", options: .regularExpression)
        return t
    }

    /// A copy safe to share. `content` false (default): no prompt, args or results — names, timings, ok/failed only.
    /// Either way everything left is scrubbed.
    static func redacted(_ r: TurnRecord, content: Bool, home: String = NSHomeDirectory()) -> TurnRecord {
        var o = r
        o.chat = nil
        o.prompt = content ? scrub(r.prompt, home: home) : "(\(r.prompt.count) characters)"
        if !o.end.hasPrefix("completed") { o.end = scrub(r.end, home: home) }
        o.events = r.events.map { e in
            var x = e
            x.detail = content || e.kind != .tool ? scrub(e.detail, home: home) : ""
            x.args = content ? e.args.map { scrub($0, home: home) } : nil
            x.result = content ? e.result.map { scrub($0, home: home) } : nil
            if !content && e.kind == .approval { x.detail = e.ok ? "allowed" : "not allowed" }
            if !content && (e.kind == .retry || e.kind == .info) { x.detail = scrub(e.detail, home: home) }
            return x
        }
        return o
    }

    /// "3 steps · 4 tools (1 failed) · 1 approval · 6.2 s · completed"
    static func summary(_ r: TurnRecord) -> String {
        let steps = r.events.filter { $0.kind == .llm }.count
        var bits = ["\(steps) step\(steps == 1 ? "" : "s")"]
        let tools = r.events.filter { $0.kind == .tool }.count
        if tools > 0 { bits.append("\(tools) tool\(tools == 1 ? "" : "s")" + (r.failedTools > 0 ? " (\(r.failedTools) failed)" : "")) }
        if r.approvals > 0 { bits.append("\(r.approvals) approval\(r.approvals == 1 ? "" : "s")") }
        bits.append(seconds(r.ms))
        bits.append(r.end)
        return bits.joined(separator: " · ")
    }

    static func seconds(_ ms: Int) -> String { ms < 1000 ? "\(ms) ms" : String(format: "%.1f s", Double(ms) / 1000) }

    /// Where an event's bar sits on the timeline (fractions of the turn).
    static func bar(_ e: TraceEvent, total: Int) -> (start: Double, width: Double) {
        let t = Double(max(total, 1))
        let s = min(1, max(0, Double(e.at) / t))
        return (s, min(1 - s, max(0.004, Double(e.ms) / t)))
    }

    static func verified(_ result: String) -> Bool { result.contains("(checked)") }

    /// A short text block for a bug report (already redacted, no content).
    static func reportText(_ r: TurnRecord) -> String {
        let x = redacted(r, content: false)
        var lines = ["Trace: \(x.provider) · \(x.model) · " + summary(x)]
        for e in x.events.prefix(40) {
            lines.append("+\(seconds(e.at)) \(e.kind.rawValue) \(e.name)\(e.ok ? "" : " FAILED") \(seconds(e.ms))"
                         + (e.detail.isEmpty ? "" : " — \(e.detail.prefix(120))"))
        }
        return String(lines.joined(separator: "\n").prefix(2500))
    }

    static func fileName(_ d: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        return "turns-\(f.string(from: d)).jsonl"
    }

    /// turns-YYYY-MM-DD.jsonl older than `keepDays` → delete.
    static func isExpired(_ name: String, now: Date) -> Bool {
        guard name.hasPrefix("turns-"), name.hasSuffix(".jsonl") else { return false }
        let day = String(name.dropFirst(6).dropLast(6))
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        guard let d = f.date(from: day) else { return false }
        return now.timeIntervalSince(d) > Double(keepDays + 1) * 86_400
    }
}

/// Recent turns in memory (for the Developer view) + the JSONL files.
@MainActor
final class TraceStore: ObservableObject {
    static let shared = TraceStore()
    @Published private(set) var recent: [TurnRecord] = []
    /// The turn running right now (updated as events arrive), for the Developer view's live row.
    @Published var live: TurnRecord?
    private var loaded = false
    private let dir: String
    private let q = DispatchQueue(label: "opennotch.traces", qos: .utility)

    init(dir: String = opennotchDir("traces")) { self.dir = dir }

    func append(_ r: TurnRecord) {
        live = nil
        recent.insert(r, at: 0)
        if recent.count > 500 { recent.removeLast(recent.count - 500) }
        let path = dir + "/" + TraceLogic.fileName(r.started)
        guard var data = try? JSONEncoder.traces.encode(r) else { return }
        data.append(0x0A)
        q.async {
            if let h = FileHandle(forWritingAtPath: path) { h.seekToEndOfFile(); h.write(data); try? h.close() }
            else { FileManager.default.createFile(atPath: path, contents: data, attributes: [.posixPermissions: 0o600]) }
        }
    }

    /// Loads the last few days once (off the main thread), newest first.
    func loadIfNeeded() {
        guard !loaded else { return }
        loaded = true
        let dir = self.dir
        q.async {
            let names = ((try? FileManager.default.contentsOfDirectory(atPath: dir)) ?? []).filter { $0.hasPrefix("turns-") }.sorted().suffix(8)
            var out: [TurnRecord] = []
            for n in names {
                guard let text = try? String(contentsOfFile: dir + "/" + n, encoding: .utf8) else { continue }
                for line in text.split(separator: "\n") {
                    if let r = try? JSONDecoder.traces.decode(TurnRecord.self, from: Data(line.utf8)) { out.append(r) }
                }
            }
            let sorted = Array(out.sorted { $0.started > $1.started }.prefix(500))
            DispatchQueue.main.async {
                let have = Set(self.recent.map(\.id))
                self.recent = (self.recent + sorted.filter { !have.contains($0.id) }).sorted { $0.started > $1.started }
            }
        }
    }

    func prune(now: Date = Date()) {
        let dir = self.dir
        q.async {
            for n in (try? FileManager.default.contentsOfDirectory(atPath: dir)) ?? [] where TraceLogic.isExpired(n, now: now) {
                try? FileManager.default.removeItem(atPath: dir + "/" + n)
            }
        }
    }

    func clear() {
        recent = []
        let dir = self.dir
        q.async {
            for n in (try? FileManager.default.contentsOfDirectory(atPath: dir)) ?? [] where n.hasPrefix("turns-") {
                try? FileManager.default.removeItem(atPath: dir + "/" + n)
            }
        }
    }

    var folder: String { dir }
}

extension JSONEncoder {
    static var traces: JSONEncoder { let e = JSONEncoder(); e.dateEncodingStrategy = .iso8601; return e }
}
extension JSONDecoder {
    static var traces: JSONDecoder { let d = JSONDecoder(); d.dateDecodingStrategy = .iso8601; return d }
}

/// Builds one turn's record as it runs (lives in AgentCore, main actor).
@MainActor
struct TurnRecorder {
    private(set) var record: TurnRecord?
    private var t0 = Date()

    mutating func begin(prompt: String, chat: String?, provider: String, model: String) {
        t0 = Date()
        record = TurnRecord(id: UUID().uuidString, chat: chat, started: t0, prompt: TraceLogic.promptPreview(prompt),
                            provider: provider, model: model)
    }

    func at(_ d: Date) -> Int { Int(d.timeIntervalSince(t0) * 1000) }

    /// `since`: when the thing started (its duration runs to now).
    mutating func add(_ kind: TraceEvent.Kind, _ name: String, since: Date? = nil, ok: Bool = true, detail: String = "",
                      args: String? = nil, result: String? = nil, parallel: Bool = false, first: Int? = nil) {
        guard record != nil else { return }
        let start = since ?? Date()
        var e = TraceEvent(kind: kind, at: at(start), ms: since.map { Int(Date().timeIntervalSince($0) * 1000) } ?? 0, name: name,
                           ok: ok, detail: String(detail.prefix(300)), args: TraceLogic.cut(args), result: TraceLogic.cut(result),
                           parallel: parallel)
        if kind == .tool, let r = result { e.verified = TraceLogic.verified(r) }
        e.first = first
        record?.events.append(e)
    }

    mutating func finish(end: String, inTokens: Int, outTokens: Int, toolCalls: Int) -> TurnRecord? {
        guard var r = record else { return nil }
        r.end = end
        r.ms = at(Date())
        r.inTokens = inTokens
        r.outTokens = outTokens
        r.toolCalls = toolCalls
        r.events.sort { $0.at < $1.at }
        record = nil
        return r
    }
}
