import AppKit
import Foundation

// The agent's tools: how they're described to the model, how risky they are,
// and the safety net shared by all of them (read-before-write, result budget,
// path policy). Implementations are in ToolKit.swift; MCP tools join at runtime.

enum ToolRisk: Sendable {
    case read       // runs without asking
    case confirm    // needs an Approve click (shell, writes, calendar changes, MCP by default)
}

struct ToolOutcome: Sendable {
    var ok: Bool
    var text: String
    var images: [String] = []

    static func fail(_ msg: String) -> ToolOutcome { ToolOutcome(ok: false, text: msg) }
}

/// Parsed tool arguments (from the model's JSON).
struct ToolArgs: @unchecked Sendable {
    let dict: [String: Any]
    init(json: String) { dict = HTTP.parse(json) ?? [:] }
    func str(_ k: String) -> String? {
        if let s = dict[k] as? String { return s.isEmpty ? nil : s }
        if let n = dict[k] as? NSNumber { return n.stringValue }
        return nil
    }
    func int(_ k: String) -> Int? { (dict[k] as? NSNumber)?.intValue ?? str(k).flatMap(Int.init) }
    func double(_ k: String) -> Double? { (dict[k] as? NSNumber)?.doubleValue ?? str(k).flatMap(Double.init) }
    func bool(_ k: String) -> Bool { (dict[k] as? Bool) ?? (str(k) == "true") }
    func array(_ k: String) -> [[String: Any]] { dict[k] as? [[String: Any]] ?? [] }
}

struct AgentTool: Sendable {
    let name: String
    let description: String
    let schema: String
    let risk: ToolRisk
    let verb: String                                   // "Reading file" — shown in the transcript
    let detail: @Sendable (ToolArgs) -> String         // short argument summary for the tool row
    let preview: @Sendable (ToolArgs) -> String        // what the Approve card shows
    let run: @Sendable (ToolArgs) async -> ToolOutcome

    var spec: ToolSpec { ToolSpec(name: name, description: description, schema: schema) }
}

/// JSON Schema helpers so tool definitions stay one line each.
enum Schema {
    static func object(_ props: [String: [String: Any]], required: [String] = []) -> String {
        let o: [String: Any] = ["type": "object", "properties": props, "required": required]
        return String(data: HTTP.json(o), encoding: .utf8) ?? "{}"
    }
    static func string(_ d: String) -> [String: Any] { ["type": "string", "description": d] }
    static func integer(_ d: String) -> [String: Any] { ["type": "integer", "description": d] }
    static func number(_ d: String) -> [String: Any] { ["type": "number", "description": d] }
    static func boolean(_ d: String) -> [String: Any] { ["type": "boolean", "description": d] }
    static func enumeration(_ d: String, _ values: [String]) -> [String: Any] { ["type": "string", "description": d, "enum": values] }
}

// MARK: - Main-actor bridge

/// The parts of the app tools can reach (set by AppDelegate).
@MainActor
enum ToolHost {
    static weak var hub: Hub?
    static weak var notch: NotchController?
}

// MARK: - Safety net

enum PathPolicy {
    static let home = NSHomeDirectory()

    /// `~/x`, absolute, or relative to home → absolute, symlinks resolved.
    static func resolve(_ raw: String) -> String {
        var p = (raw as NSString).expandingTildeInPath
        if !p.hasPrefix("/") { p = home + "/" + p }
        return URL(fileURLWithPath: p).standardizedFileURL.resolvingSymlinksInPath().path
    }

    private static let blocked = ["/Library/Keychains", "/Library/Cookies", "/.ssh", "/.gnupg",
                                  "/Library/Application Support/OpenNotch/sessions"]

    /// Reads: anywhere under home or /tmp, minus secrets. Writes: under home only.
    static func check(_ path: String, write: Bool) -> String? {
        let tmp = URL(fileURLWithPath: NSTemporaryDirectory()).resolvingSymlinksInPath().path
        let inHome = path == home || path.hasPrefix(home + "/")
        let inTmp = path.hasPrefix("/tmp/") || path.hasPrefix("/private/tmp/") || path.hasPrefix(tmp)
        if !(inHome || (!write && inTmp) || (write && inTmp)) {
            return "\(path) is outside your home folder — OpenNotch only \(write ? "writes" : "reads") there."
        }
        if let b = blocked.first(where: { path.contains($0) }) {
            return "\(path) is private (\(b)) — not accessible to the assistant."
        }
        return nil
    }
}

/// Read-before-write: a file may only be changed if this conversation read it
/// (or wrote it) and it hasn't changed on disk since. Stops blind overwrites.
actor FileState {
    static let shared = FileState()
    private var seen: [String: (mtime: Date, size: Int)] = [:]

    func record(_ path: String) {
        if let a = try? FileManager.default.attributesOfItem(atPath: path) {
            seen[path] = ((a[.modificationDate] as? Date) ?? .distantPast, (a[.size] as? Int) ?? 0)
        }
    }

    /// nil = OK to modify.
    func problem(_ path: String) -> String? {
        guard let a = try? FileManager.default.attributesOfItem(atPath: path) else { return nil }   // new file
        guard let s = seen[path] else {
            return "read_before_write: read \(path) with read_file first, then edit it."
        }
        if (a[.modificationDate] as? Date) != s.mtime || (a[.size] as? Int) != s.size {
            return "stale_file: \(path) changed since you read it — read it again before editing."
        }
        return nil
    }

    func reset() { seen = [:] }
}

enum ResultBudget {
    static let maxChars = 40_000

    /// Long results keep their head and tail; the full text is saved to a file
    /// the model is told about — nothing is cut silently.
    static func apply(_ o: ToolOutcome, tool: String) -> ToolOutcome {
        guard o.text.count > maxChars else { return o }
        let dir = opennotchDir("spill")
        let f = dir + "/\(tool)_\(Int(Date().timeIntervalSince1970)).txt"
        try? o.text.write(toFile: f, atomically: true, encoding: .utf8)
        var r = o
        r.text = String(o.text.prefix(maxChars * 3 / 4)) + "\n\n… [\(o.text.count - maxChars) characters omitted — full output saved to \(f); read it with read_file start_line/end_line] …\n\n"
            + String(o.text.suffix(maxChars / 4))
        return r
    }
}

// MARK: - Memory and plan (both injected into the system prompt)

/// Long-term facts the user asked to remember. Local JSON, bounded.
final class MemoryStore: @unchecked Sendable {
    static let shared = MemoryStore()
    private let path: String
    private let lock = NSLock()
    private var facts: [String: [String: String]] = [:]     // key → {value, updated}

    /// `path` is overridable so checks never touch real memory.
    init(path: String = opennotchDir("") + "/memory.json") {
        self.path = path
        if let d = FileManager.default.contents(atPath: path),
           let f = try? JSONSerialization.jsonObject(with: d) as? [String: [String: String]] { facts = f }
    }

    func remember(_ key: String, _ value: String) {
        lock.lock(); defer { lock.unlock() }
        facts[key] = ["value": String(value.prefix(500)), "updated": ISO8601DateFormatter().string(from: Date())]
        save()
    }

    func forget(_ key: String) -> Bool {
        lock.lock(); defer { lock.unlock() }
        let had = facts.removeValue(forKey: key) != nil
        save()
        return had
    }

    func all() -> [(key: String, value: String)] {
        lock.lock(); defer { lock.unlock() }
        return facts.sorted { ($0.value["updated"] ?? "") > ($1.value["updated"] ?? "") }
            .map { ($0.key, $0.value["value"] ?? "") }
    }

    /// For the system prompt: newest first, capped; the rest are a `recall` away.
    func promptBlock(maxChars: Int = 2500) -> String {
        var out = ""
        let facts = all()
        var shown = 0
        for f in facts {
            let line = "- \(f.key): \(f.value)\n"
            if out.count + line.count > maxChars { break }
            out += line
            shown += 1
        }
        if shown < facts.count { out += "(\(facts.count - shown) older facts not shown — use recall to search them)\n" }
        return out
    }

    /// Facts whose key or text mention any of the query's words, best match first. Empty query = all.
    func search(_ query: String) -> [(key: String, value: String)] {
        let words = ChatSearch.terms(query)
        let facts = all()
        guard !words.isEmpty else { return facts }
        return facts.map { f -> ((key: String, value: String), Int) in
            let hay = (f.key.replacingOccurrences(of: "-", with: " ") + " " + f.value).lowercased()
            return (f, words.filter { hay.contains($0) }.count)
        }.filter { $0.1 > 0 }.sorted { $0.1 > $1.1 }.map(\.0)
    }

    private func save() {
        if let d = try? JSONSerialization.data(withJSONObject: facts, options: [.prettyPrinted, .sortedKeys]) {
            try? d.write(to: URL(fileURLWithPath: path), options: .atomic)
        }
    }
}

/// The current task plan (todo_write) — held outside the conversation.
final class PlanStore: @unchecked Sendable {
    static let shared = PlanStore()
    private let lock = NSLock()
    private var items_: [(content: String, status: String)] = []

    func set(_ new: [(String, String)]) {
        lock.lock(); items_ = new.map { ($0.0, $0.1) }; lock.unlock()
    }

    func clear() { set([]) }

    var items: [(content: String, status: String)] {
        lock.lock(); defer { lock.unlock() }
        return items_
    }

    func render() -> String {
        lock.lock(); defer { lock.unlock() }
        return items_.map { i in
            let box = i.status == "completed" ? "[x]" : i.status == "in_progress" ? "[→]" : "[ ]"
            return "\(box) \(i.content)"
        }.joined(separator: "\n")
    }
}
