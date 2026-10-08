import Foundation

/// One file the assistant created or changed during a turn (write_file / edit_file), for the end-of-turn card.
struct ChangedFile: Equatable, Identifiable {
    let path: String
    let added: Int
    let deleted: Int
    let created: Bool
    /// Too big (or not text) to count lines.
    var uncounted = false
    var id: String { path }
    var name: String { (path as NSString).lastPathComponent }
}

/// Pure parts: line counts and how several edits to one file in a turn add up (first "before" vs last "after").
enum FileChangeLogic {
    static let maxBytes = 1_000_000
    static let maxLines = 5_000

    /// Lines added and removed between two texts (nil when too large to diff quickly).
    static func counts(old: String, new: String) -> (added: Int, deleted: Int)? {
        let a = old.isEmpty ? [] : old.components(separatedBy: "\n")
        let b = new.isEmpty ? [] : new.components(separatedBy: "\n")
        guard a.count <= maxLines, b.count <= maxLines else { return nil }
        let d = b.difference(from: a)
        return (d.insertions.count, d.removals.count)
    }

    static func change(path: String, before: String?, after: String?) -> ChangedFile {
        let created = before == nil
        guard let after else { return ChangedFile(path: path, added: 0, deleted: 0, created: created, uncounted: true) }
        guard let c = counts(old: before ?? "", new: after) else {
            return ChangedFile(path: path, added: 0, deleted: 0, created: created, uncounted: true)
        }
        return ChangedFile(path: path, added: c.added, deleted: c.deleted, created: created)
    }

    /// Text of a file if it's small UTF-8, nil if missing; "" never stands for "missing".
    static func snapshot(_ path: String) -> String?? {
        guard FileManager.default.fileExists(atPath: path) else { return .some(nil) }
        guard let a = try? FileManager.default.attributesOfItem(atPath: path), (a[.size] as? Int ?? 0) <= maxBytes,
              let t = try? String(contentsOfFile: path, encoding: .utf8) else { return nil }   // exists, not countable
        return .some(t)
    }

    static func event(_ files: [ChangedFile]) -> [String: Any] {
        ["type": "files", "files": files.map {
            ["path": $0.path, "added": $0.added, "deleted": $0.deleted, "created": $0.created, "uncounted": $0.uncounted]
        }]
    }

    static func parse(_ ev: [String: Any]) -> [ChangedFile] {
        (ev["files"] as? [[String: Any]] ?? []).compactMap { d in
            guard let p = d["path"] as? String else { return nil }
            return ChangedFile(path: p, added: d["added"] as? Int ?? 0, deleted: d["deleted"] as? Int ?? 0,
                               created: d["created"] as? Bool ?? false, uncounted: d["uncounted"] as? Bool ?? false)
        }
    }
}

/// Tracks a turn's file writes: the first snapshot of each file before the turn touched it, in order.
@MainActor
final class TurnFiles {
    private var before: [String: String?] = [:]    // path → text before (nil = didn't exist); absent = not countable
    private var uncountable: Set<String> = []
    private(set) var order: [String] = []

    static let tools: Set<String> = ["write_file", "edit_file"]

    func reset() { before = [:]; uncountable = []; order = [] }

    /// Call before a write runs.
    func willWrite(_ path: String) {
        guard !order.contains(path) else { return }
        order.append(path)
        switch FileChangeLogic.snapshot(path) {
        case .some(let text): before[path] = .some(text)
        case .none: uncountable.insert(path)
        }
    }

    /// Call after a failed write: a file nothing happened to isn't listed.
    func failed(_ path: String) {
        guard let i = order.firstIndex(of: path), case .some(let now) = FileChangeLogic.snapshot(path),
              let was = before[path], was == now else { return }
        order.remove(at: i); before[path] = nil
    }

    func summary() -> [ChangedFile] {
        order.map { p in
            if uncountable.contains(p) { return ChangedFile(path: p, added: 0, deleted: 0, created: false, uncounted: true) }
            let after: String?? = FileChangeLogic.snapshot(p)
            return FileChangeLogic.change(path: p, before: before[p] ?? nil, after: after ?? nil)
        }
    }
}
