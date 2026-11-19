import Foundation

// photos_search — Photos' own search (what Spotlight-in-Photos uses: things and scenes it recognised on the Mac,
// people you named, places, dates, captions, text in photos) through Photos' AppleScript `search for`. Read-only:
// returns names, dates and ids, and can export up to 3 small previews so the model can look at them.
// Never from background jobs (it would launch Photos); asks for Automation once, like Mail and Notes.

/// Pure rules (checked in AgentChecks).
enum PhotosLogic {
    /// The search text Photos gets: trimmed, quotes and backslashes removed, ≤ 80 chars.
    static func query(_ raw: String?) -> String? {
        let q = (raw ?? "").replacingOccurrences(of: "[\"\\\\]", with: "", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return q.isEmpty ? nil : String(q.prefix(80))
    }

    /// One row per item from the script: id \t filename \t date \t name \t keywords.
    static func rows(_ out: String, limit: Int = 20) -> [String] {
        out.split(separator: "\n").prefix(limit).map { line in
            let f = line.components(separatedBy: "\t")
            func at(_ i: Int) -> String { i < f.count ? f[i].trimmingCharacters(in: .whitespaces) : "" }
            var s = "- \(at(1))"
            if !at(2).isEmpty { s += " · \(at(2))" }
            if !at(3).isEmpty, at(3) != "missing value" { s += " · “\(at(3))”" }
            if !at(4).isEmpty, at(4) != "missing value" { s += " · tags: \(at(4))" }
            return s + " [id \(at(0))]"
        }
    }
}

enum PhotosTools {
    static func all() -> [AgentTool] { [search] }

    static let search = AgentTool(
        name: "photos_search",
        description: "Search the user's Photos library the way Photos' own search does — things and scenes (\"dog\", \"beach\", "
            + "\"receipt\"), people they've named, places, dates, captions and text in photos. Returns matches newest first; "
            + "set preview true to look at the top 3.",
        schema: Schema.object(["query": Schema.string("What to look for, e.g. 'dog beach', 'Priya', 'Paris 2025', 'receipt'"),
                               "preview": Schema.boolean("Also show the top 3 photos to you (optional)")],
                              required: ["query"]),
        risk: .read, verb: "Searching Photos", detail: { $0.str("query") ?? "" }, preview: { _ in "" },
        run: { a in
            guard let q = PhotosLogic.query(a.str("query")) else { return .fail("Say what to look for.") }
            if ToolKit.background { return .fail("Photos isn't searched from background jobs (it would open Photos).") }
            if let p = await DailyTools.ensureAutomation("com.apple.Photos", "Photos") { return .fail(p) }
            let r = DailyTools.script("""
            tell application "Photos"
              set found to search for "\(q)"
              set n to count of found
              set out to (n as string) & linefeed
              set i to 0
              repeat with m in found
                set i to i + 1
                if i > 20 then exit repeat
                set d to ""
                try
                  set d to ((date of m) as «class isot» as string)
                end try
                set out to out & (id of m) & tab & (filename of m) & tab & d & tab & (name of m as string) & tab & ((keywords of m) as string) & linefeed
              end repeat
              return out
            end tell
            """, timeout: 40)
            guard r.ok else { return .fail("Photos didn't answer: \(r.out)") }
            var lines = r.out.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
            let total = Int(lines.first?.trimmingCharacters(in: .whitespaces) ?? "") ?? 0
            lines.removeFirst()
            guard total > 0 else { return ToolOutcome(ok: true, text: "Photos found nothing for “\(q)”.") }
            let list = PhotosLogic.rows(lines.joined(separator: "\n"))
            var images: [String] = []
            if a.bool("preview") == true { images = await previews(ids: lines.prefix(3).compactMap { $0.components(separatedBy: "\t").first }) }
            return ToolOutcome(ok: true, text: "\(total) photo\(total == 1 ? "" : "s") match “\(q)”" + (total > 20 ? " (newest 20)" : "") + ":\n"
                               + list.joined(separator: "\n") + (images.isEmpty ? "" : "\nThe top \(images.count) are shown below."),
                               images: images)
        })

    /// Exports the given items (by id) as small JPEG previews into our tmp folder (deleted with it).
    static func previews(ids: [String]) async -> [String] {
        guard !ids.isEmpty else { return [] }
        let dir = opennotchDir("tmp") + "/photos-" + UUID().uuidString.prefix(8)
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let list = ids.map { "media item id \"\(PhotosLogic.query($0) ?? "")\"" }.joined(separator: ", ")
        let r = DailyTools.script("tell application \"Photos\" to export {\(list)} to POSIX file \"\(dir)\"", timeout: 40)
        guard r.ok, let names = try? FileManager.default.contentsOfDirectory(atPath: dir) else { return [] }
        return names.sorted().prefix(3).compactMap { ToolKit.pngForModel(dir + "/" + $0) }
    }
}
