import Foundation

// Remembering across chats: search earlier conversations (search_chats), look
// facts up in memory (recall), notice new facts worth keeping (MemoryLearner →
// a "Save" proposal, never saved silently), and summarise the part of a long
// chat that no longer fits the context window (ChatSummary).

// MARK: - Search earlier chats

enum ChatSearch {
    struct Hit: Equatable {
        let id: String
        let title: String
        let updated: Date
        let snippets: [String]
        let score: Int
    }

    private static let stop: Set<String> = ["the", "and", "for", "with", "that", "this", "what", "about", "did", "was",
                                            "we", "you", "me", "my", "a", "an", "of", "to", "in", "on", "it", "is", "do"]

    static func terms(_ q: String) -> [String] {
        let words = q.lowercased().components(separatedBy: CharacterSet.alphanumerics.inverted).filter { $0.count >= 2 }
        let kept = words.filter { !stop.contains($0) }
        return Array(Set(kept.isEmpty ? words : kept)).sorted()
    }

    /// What a message says, as the user saw it (context blocks and tool traffic left out).
    static func said(_ m: ChatMessage) -> String? {
        guard (m.role == .user || m.role == .assistant), m.toolCallId == nil, !m.text.isEmpty else { return nil }
        return m.role == .user ? (m.text.components(separatedBy: AgentCore.contextMarker).first ?? m.text) : m.text
    }

    /// Chats in `dir` that mention most of the query's words, best first, with a
    /// few snippets each. Off the main thread: it reads every chat file.
    static func search(_ query: String, dir: String, limit: Int = 5, excluding: String? = nil) -> [Hit] {
        let words = terms(query)
        guard !words.isEmpty else { return [] }
        let need = max(1, Int((Double(words.count) * 0.6).rounded(.up)))
        let names = (try? FileManager.default.contentsOfDirectory(atPath: dir)) ?? []
        var hits: [Hit] = []
        for name in names where name.hasPrefix("chat_") && name.hasSuffix(".json") {
            let id = String(name.dropFirst(5).dropLast(5))
            guard id != excluding, let data = FileManager.default.contents(atPath: dir + "/" + name),
                  let msgs = try? JSONDecoder().decode([ChatMessage].self, from: data) else { continue }
            let lines = msgs.compactMap { m in said(m).map { (m.role, $0, $0.lowercased()) } }
            let all = lines.map(\.2).joined(separator: "\n")
            let found = words.filter { all.contains($0) }
            guard found.count >= need, let first = lines.first(where: { $0.0 == .user }) else { continue }
            // Messages with the most matching words make the snippets.
            let ranked = lines.map { l in (l, found.filter { l.2.contains($0) }.count) }
                .filter { $0.1 > 0 }.sorted { $0.1 > $1.1 }.prefix(3)
            let snippets = ranked.map { (l, _) -> String in
                (l.0 == .user ? "You: " : "Assistant: ") + excerpt(l.1, around: found.first { l.2.contains($0) } ?? "")
            }
            let occurrences = found.reduce(0) { $0 + all.components(separatedBy: $1).count - 1 }
            let updated = ((try? FileManager.default.attributesOfItem(atPath: dir + "/" + name))?[.modificationDate] as? Date)
                ?? msgs.last?.at ?? .distantPast
            hits.append(Hit(id: id, title: SessionStore.title(first.1), updated: updated, snippets: snippets,
                            score: found.count * 100 + min(occurrences, 99)))
        }
        return Array(hits.sorted { $0.score != $1.score ? $0.score > $1.score : $0.updated > $1.updated }.prefix(limit))
    }

    /// ~240 characters of `text` around the first `word`, on one line.
    static func excerpt(_ text: String, around word: String) -> String {
        let flat = text.replacingOccurrences(of: "\n", with: " ")
        guard !word.isEmpty, let r = flat.range(of: word, options: .caseInsensitive) else { return String(flat.prefix(240)) }
        let start = flat.index(r.lowerBound, offsetBy: -100, limitedBy: flat.startIndex) ?? flat.startIndex
        let end = flat.index(r.upperBound, offsetBy: 140, limitedBy: flat.endIndex) ?? flat.endIndex
        return (start > flat.startIndex ? "…" : "") + flat[start..<end] + (end < flat.endIndex ? "…" : "")
    }

    static func render(_ hits: [Hit]) -> String {
        let f = DateFormatter()
        f.dateFormat = "EEE d MMM yyyy"
        return hits.map { h in
            "## \(h.title) — \(f.string(from: h.updated))\n" + h.snippets.map { "- " + $0 }.joined(separator: "\n")
        }.joined(separator: "\n\n")
    }
}

// MARK: - Tools

enum RecallTools {
    static func all() -> [AgentTool] { [searchChats, recall] }

    static let searchChats = AgentTool(
        name: "search_chats",
        description: "Search the user's earlier chats with you (saved on this Mac) — for \"what did we decide about…\", \"last time we…\", "
            + "\"that recipe you gave me\". Returns the best matching chats with dates and snippets.",
        schema: Schema.object(["query": Schema.string("Words to look for"),
                               "limit": Schema.integer("How many chats (default 5, max 10)")], required: ["query"]),
        risk: .read, verb: "Searching earlier chats", detail: { $0.str("query") ?? "" }, preview: { $0.str("query") ?? "" },
        run: { a in
            guard let q = a.str("query") else { return .fail("query is required") }
            let current = UserDefaults.standard.string(forKey: "chat.current")
            let hits = ChatSearch.search(q, dir: opennotchDir("sessions"), limit: min(10, max(1, a.int("limit") ?? 5)),
                                         excluding: current)
            return hits.isEmpty ? ToolOutcome(ok: true, text: "No earlier chat mentions “\(q)”.")
                : ToolOutcome(ok: true, text: ChatSearch.render(hits))
        })

    static let recall = AgentTool(
        name: "recall",
        description: "Look up facts saved with remember (preferences, people, places). Use when the prompt's memory list "
            + "doesn't have it. Empty query lists every key.",
        schema: Schema.object(["query": Schema.string("What to look for, e.g. 'sister birthday'")]),
        risk: .read, verb: "Recalling", detail: { $0.str("query") ?? "everything" }, preview: { $0.str("query") ?? "" },
        run: { a in
            let facts = MemoryStore.shared.search(a.str("query") ?? "")
            if facts.isEmpty { return ToolOutcome(ok: true, text: "Nothing saved about that.") }
            return ToolOutcome(ok: true, text: facts.prefix(40).map { "- \($0.key): \($0.value)" }.joined(separator: "\n"))
        })
}

// MARK: - Learning facts

/// After a chat, ask the model what's worth remembering. The answer becomes a
/// proposal; nothing is saved until the user clicks Save.
enum MemoryLearner {
    static let pref = "memory.learn"
    static var enabled: Bool { UserDefaults.standard.object(forKey: pref) as? Bool ?? true }

    /// The chat as plain lines (what was typed and answered), newest last, capped.
    static func transcript(_ msgs: [ChatMessage], maxChars: Int = 12_000) -> String {
        let lines = msgs.compactMap { m in ChatSearch.said(m).map { (m.role == .user ? "User: " : "Assistant: ") + $0 } }
        var out = lines.joined(separator: "\n")
        if out.count > maxChars { out = "…" + out.suffix(maxChars) }
        return out
    }

    /// Worth a look: at least two things the user typed, with some substance.
    static func worthLearning(_ msgs: [ChatMessage]) -> Bool {
        let typed = msgs.filter { $0.role == .user && $0.toolCallId == nil }.compactMap(ChatSearch.said)
        return typed.count >= 2 && typed.joined().count >= 60
    }

    static func prompt(transcript: String, known: [(key: String, value: String)]) -> String {
        """
        Below is a chat between a user and their assistant. List lasting facts about the USER worth remembering \
        for future chats: preferences, home city, work, routines, people they mention (with relation), recurring \
        projects. Only what the user stated or clearly confirmed. Skip one-off tasks, anything about the \
        assistant, guesses, secrets (passwords, keys, card numbers) and health or money details. Skip facts \
        already known unless they changed.

        Known facts:
        \(known.isEmpty ? "(none)" : known.prefix(60).map { "- \($0.key): \($0.value)" }.joined(separator: "\n"))

        Chat:
        \(transcript)

        Answer with only a JSON array, at most 5 items, like [{"key":"home-city","fact":"Lives in Pune"}]. \
        Keys are short kebab-case. Answer [] if nothing qualifies.
        """
    }

    /// The model's JSON → new or changed facts (secrets and repeats dropped).
    static func parse(_ reply: String, known: [(key: String, value: String)]) -> [(key: String, fact: String)] {
        guard let a = reply.firstIndex(of: "["), let b = reply.lastIndex(of: "]"), a < b,
              let arr = try? JSONSerialization.jsonObject(with: Data(reply[a...b].utf8)) as? [[String: Any]] else { return [] }
        let knownMap = Dictionary(known.map { ($0.key, $0.value.lowercased()) }, uniquingKeysWith: { a, _ in a })
        var out: [(String, String)] = []
        for item in arr.prefix(5) {
            guard var key = item["key"] as? String, let fact = (item["fact"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !fact.isEmpty, fact.count <= 300, !looksSecret(fact) else { continue }
            key = key.lowercased().replacingOccurrences(of: "[^a-z0-9]+", with: "-", options: .regularExpression)
                .trimmingCharacters(in: CharacterSet(charactersIn: "-"))
            guard !key.isEmpty, knownMap[key] != fact.lowercased(), !out.contains(where: { $0.0 == key }) else { continue }
            out.append((String(key.prefix(40)), fact))
        }
        return out
    }

    static func looksSecret(_ s: String) -> Bool {
        s.range(of: #"(sk-[A-Za-z0-9]{10,}|password\s*[:=]|api[_-]?key\s*[:=]|\b\d{4}[ -]?\d{4}[ -]?\d{4}[ -]?\d{4}\b)"#,
                options: [.regularExpression, .caseInsensitive]) != nil
    }

    // Which chats were looked at, and how far (user-message count), so each is read once per new part.
    private static let doneKey = "memory.learned"
    static func learnedCount(_ id: String) -> Int {
        (UserDefaults.standard.dictionary(forKey: doneKey) as? [String: Int])?[id] ?? 0
    }
    static func markLearned(_ id: String, count: Int) {
        var d = UserDefaults.standard.dictionary(forKey: doneKey) as? [String: Int] ?? [:]
        d[id] = count
        if d.count > 300 { d = Dictionary(uniqueKeysWithValues: d.sorted { $0.key > $1.key }.prefix(200).map { ($0.key, $0.value) }) }
        UserDefaults.standard.set(d, forKey: doneKey)
    }
}

// MARK: - Summaries of long chats

/// The part of a chat that slid out of the context window, in a few paragraphs.
/// Kept next to the chat (sessions/summary_<id>.json); `upTo` = how many of the
/// chat's messages it covers.
struct ChatSummary: Codable, Equatable {
    var upTo: Int
    var text: String

    static let header = "[Summary of the earlier part of this chat]"

    /// Lines for the summariser: what was said, plus which tools ran (results shortened).
    static func render(_ msgs: ArraySlice<ChatMessage>, maxChars: Int = 60_000) -> String {
        var lines: [String] = []
        for m in msgs {
            switch m.role {
            case .user where m.toolCallId == nil:
                if let s = ChatSearch.said(m), !s.isEmpty { lines.append("User: " + s) }
            case .assistant:
                if !m.text.isEmpty { lines.append("Assistant: " + m.text) }
                for c in m.toolCalls ?? [] { lines.append("  (tool \(c.name) \(c.arguments.prefix(160)))") }
            case .tool:
                lines.append("  (result: \(m.text.replacingOccurrences(of: "\n", with: " ").prefix(200)))")
            default: break
            }
        }
        let out = lines.joined(separator: "\n")
        return out.count > maxChars ? "…" + String(out.suffix(maxChars)) : out
    }

    static func prompt(previous: String?, newPart: String) -> String {
        """
        Update the running summary of a conversation between a user and their assistant so the assistant can \
        continue it without the original messages. Keep: what the user wants, decisions made, facts learned, \
        names, file paths, numbers, what was done (and what failed), open questions and next steps. \
        Plain prose or short bullets, at most 350 words. Answer with the summary only.

        Summary so far:
        \(previous ?? "(none — this is the start of the chat)")

        New messages to fold in:
        \(newPart)
        """
    }
}
