import Foundation

// "Always allow here": approvals the user saved as standing rules (Settings › Permissions lists and removes them),
// plus the kinds of action that always ask (delete, send, share, post, pay) — recognised by a tool's leading verb or
// an MCP server's `destructiveHint`, never by what the arguments say. Idea from CopilotKit's OpenBot (approvals.md).

/// An action that never gets an "Always allow" (and is labelled on the card).
enum RiskKind: String, Equatable {
    case delete, send, share, post, pay

    var label: String {
        switch self {
        case .delete: return "Deletes something"
        case .send: return "Sends to other people"
        case .share: return "Shares with other people"
        case .post: return "Posts publicly"
        case .pay: return "Spends money"
        }
    }
}

/// The pure rules (checked by `--checks`).
enum ApprovalLogic {
    /// Built-in tools that set up standing work or send: approve them each time (or for this chat), never forever.
    static let neverAlways: Set<String> = ["mail_send", "schedule_task", "watch_start", "routine_save", "routine_delete",
                                           "routine_export_shortcut"]

    private static let verbs: [String: RiskKind] = {
        var m: [String: RiskKind] = [:]
        for v in ["delete", "remove", "trash", "destroy", "erase", "purge", "wipe", "discard", "archive"] { m[v] = .delete }
        for v in ["send", "reply", "forward", "respond", "notify", "broadcast", "invite", "comment"] { m[v] = .send }
        for v in ["share", "grant"] { m[v] = .share }
        for v in ["post", "publish", "tweet", "repost"] { m[v] = .post }
        for v in ["pay", "purchase", "buy", "transfer", "payout", "withdraw", "charge", "refund", "checkout", "subscribe"] { m[v] = .pay }
        return m
    }()

    /// The tool's own name without the `mcp__server__` prefix.
    static func bareName(_ tool: String) -> String {
        guard tool.hasPrefix("mcp__") else { return tool }
        let parts = tool.components(separatedBy: "__")
        return parts.count >= 3 ? parts.dropFirst(2).joined(separator: "__") : tool
    }

    /// The first word of a tool name: `deletePage`, `delete_page`, `DELETE-PAGE` → "delete"; a leading service name
    /// is skipped (`notion-delete-page` on the notion server → "delete").
    static func leadingVerb(_ name: String, server: String? = nil) -> String {
        let spaced = name.replacingOccurrences(of: "([a-z0-9])([A-Z])", with: "$1 $2", options: .regularExpression)
        var words = spaced.split(whereSeparator: { !$0.isLetter }).map { $0.lowercased() }
        if let server, words.count > 1, words[0] == server.lowercased() { words.removeFirst() }
        return words.first ?? ""
    }

    /// The MCP server in a wire name (`mcp__notion__…` → "notion").
    static func serverName(_ tool: String) -> String? {
        guard tool.hasPrefix("mcp__") else { return nil }
        let parts = tool.components(separatedBy: "__")
        return parts.count >= 3 ? parts[1] : nil
    }

    /// The kind of action, by the tool's leading verb (so "list_archived", "get_sent", "mark_spam" are ordinary)
    /// or because its MCP server marked it destructive.
    static func kind(tool: String, destructive: Bool) -> RiskKind? {
        if tool == "mail_send" { return .send }
        if let k = verbs[leadingVerb(bareName(tool), server: serverName(tool))] { return k }
        return destructive ? .delete : nil
    }

    /// What an "Always allow" click saves, or nil when this call can't be allowed forever.
    /// Commands: only this exact command (no chaining, pipes, redirection, substitution; never rm/curl/shells…).
    /// File edits: the folder (and its subfolders), never all of home. Shortcuts: that one. Others: the tool.
    static func alwaysKey(tool: String, args: [String: Any], kind: RiskKind?) -> String? {
        guard kind == nil, !neverAlways.contains(tool), let chatKey = TurnPolicy.allowKey(tool: tool, args: args) else { return nil }
        if tool == "run_command" {
            guard chatKey.hasPrefix("run_command:"), let cmd = (args["command"] as? String)?.trimmingCharacters(in: .whitespaces),
                  ["sudo", "ssh", "scp", "rsync", "open", "launchctl", "defaults", "security", "diskutil", "git"]
                    .contains(String(chatKey.dropFirst(12))) == false || isReadOnlyGit(cmd)
            else { return nil }
            return "cmd:" + cmd.split(separator: " ", omittingEmptySubsequences: true).joined(separator: " ")
        }
        return chatKey
    }

    /// git subcommands that only read (the useful ones to stop being asked about).
    static func isReadOnlyGit(_ cmd: String) -> Bool {
        let w = cmd.split(separator: " ").map(String.init)
        guard w.first == "git", w.count >= 2 else { return false }
        return ["status", "log", "diff", "show", "branch", "remote"].contains(w[1])
            && !w.contains { $0.hasPrefix("-D") || $0 == "-d" || $0 == "--delete" || $0 == "add" || $0 == "remove" || $0 == "rm" }
    }

    /// Does a saved rule cover this call?
    static func covers(_ keys: Set<String>, tool: String, args: [String: Any], kind: RiskKind?) -> Bool {
        guard let key = alwaysKey(tool: tool, args: args, kind: kind) else { return false }
        if keys.contains(key) { return true }
        if key.hasPrefix("files:") {              // a folder rule covers its subfolders
            let dir = String(key.dropFirst(6))
            return keys.contains { $0.hasPrefix("files:") && (dir + "/").hasPrefix(String($0.dropFirst(6)) + "/") }
        }
        return false
    }

    /// Button label: "Always allow `git status`".
    static func alwaysLabel(_ key: String) -> String {
        if key.hasPrefix("cmd:") { return "Always allow “\(key.dropFirst(4).prefix(40))”" }
        if key.hasPrefix("files:") { return "Always allow edits in \((String(key.dropFirst(6)) as NSString).lastPathComponent)/" }
        if key.hasPrefix("shortcut:") { return "Always allow this shortcut" }
        return "Always allow this"
    }

    /// One line for the Settings list.
    static func describe(_ key: String) -> String {
        if key.hasPrefix("cmd:") { return "Run “\(key.dropFirst(4))”" }
        if key.hasPrefix("files:") { return "Edit files in " + (String(key.dropFirst(6)) as NSString).abbreviatingWithTildeInPath }
        if key.hasPrefix("shortcut:") { return "Run the shortcut “\(key.dropFirst(9))”" }
        if key.hasPrefix("mcp__") {
            let p = key.components(separatedBy: "__")
            return p.count >= 3 ? "\(p[1]): \(p.dropFirst(2).joined(separator: "__"))" : key
        }
        return key.replacingOccurrences(of: "_", with: " ").capitalizedFirst
    }
}

struct ApprovalRule: Codable, Identifiable, Equatable {
    var id: String { key }
    let key: String
    let added: Date
}

/// approval_rules.json in Application Support (path overridable for checks).
final class ApprovalRuleStore: @unchecked Sendable {
    static let shared = ApprovalRuleStore()
    private let path: String
    private let lock = NSLock()

    init(path: String = opennotchDir("") + "/approval_rules.json") { self.path = path }

    func all() -> [ApprovalRule] {
        lock.lock(); defer { lock.unlock() }
        return load()
    }

    var keys: Set<String> { Set(all().map(\.key)) }

    func add(_ key: String) {
        lock.lock(); defer { lock.unlock() }
        var rs = load()
        guard !rs.contains(where: { $0.key == key }) else { return }
        rs.append(ApprovalRule(key: key, added: Date()))
        write(rs)
    }

    func remove(_ key: String) {
        lock.lock(); defer { lock.unlock() }
        write(load().filter { $0.key != key })
    }

    private func load() -> [ApprovalRule] {
        guard let d = FileManager.default.contents(atPath: path) else { return [] }
        let dec = JSONDecoder(); dec.dateDecodingStrategy = .iso8601
        return (try? dec.decode([ApprovalRule].self, from: d)) ?? []
    }

    private func write(_ rs: [ApprovalRule]) {
        let enc = JSONEncoder(); enc.dateEncodingStrategy = .iso8601; enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let d = try? enc.encode(rs) else { return }
        FileManager.default.createFile(atPath: path, contents: d, attributes: [.posixPermissions: 0o600])
    }
}
