import AppKit
import EventKit
import Foundation
import IOKit.ps
import PDFKit

/// The built-in tools. Every tool reports failure as failure (`ok: false`) —
/// the model repeats whatever we return, so never claim something happened.
enum ToolKit {
    static func all() -> [AgentTool] {
        files + shell + web + mac + calendar + memory + plan
    }

    // MARK: Files

    static let textLimit = 2_000_000

    static let files: [AgentTool] = [
        AgentTool(
            name: "read_file",
            description: "Read a file: text, code, PDF, Word (.docx) or an image (the image is shown to you). Paths may start with ~. Use start_line/end_line for long files.",
            schema: Schema.object(["path": Schema.string("File path"),
                                   "start_line": Schema.integer("First line (1-based), optional"),
                                   "end_line": Schema.integer("Last line, optional")], required: ["path"]),
            risk: .read, verb: "Reading", detail: { short($0.str("path")) }, preview: { $0.str("path") ?? "" },
            run: { a in await readFile(a) }),
        AgentTool(
            name: "list_directory",
            description: "List a folder's contents (folders first, with sizes).",
            schema: Schema.object(["path": Schema.string("Folder path, e.g. ~/Downloads"),
                                   "show_hidden": Schema.boolean("Include dotfiles")], required: ["path"]),
            risk: .read, verb: "Listing", detail: { short($0.str("path")) }, preview: { $0.str("path") ?? "" },
            run: { a in listDirectory(a) }),
        AgentTool(
            name: "search_text",
            description: "Search file contents under a folder for a regular expression (like grep -rn). Skips .git, node_modules and build folders.",
            schema: Schema.object(["pattern": Schema.string("Regular expression"),
                                   "path": Schema.string("Folder or file to search"),
                                   "ignore_case": Schema.boolean("Case-insensitive")], required: ["pattern", "path"]),
            risk: .read, verb: "Searching", detail: { "“\($0.str("pattern") ?? "")” in \(short($0.str("path")))" },
            preview: { $0.str("pattern") ?? "" }, run: { a in await searchText(a) }),
        AgentTool(
            name: "find_files",
            description: "Find files in the home folder by name using Spotlight (fast). Returns newest matches first.",
            schema: Schema.object(["name": Schema.string("Part of the file name")], required: ["name"]),
            risk: .read, verb: "Finding files", detail: { $0.str("name") ?? "" }, preview: { $0.str("name") ?? "" },
            run: { a in await findFiles(a) }),
        AgentTool(
            name: "write_file",
            description: "Create a file, or replace an existing one you have read first. Creates parent folders.",
            schema: Schema.object(["path": Schema.string("File path"), "content": Schema.string("Full file content")],
                                  required: ["path", "content"]),
            risk: .confirm, verb: "Writing", detail: { short($0.str("path")) },
            preview: { a in
                let c = a.str("content") ?? ""
                return "Write \(c.split(separator: "\n", omittingEmptySubsequences: false).count) lines to \(a.str("path") ?? "?")\n\n" + String(c.prefix(600))
            },
            run: { a in await writeFile(a) }),
        AgentTool(
            name: "edit_file",
            description: "Replace exact text in a file you have read. old_string must match exactly once unless replace_all is true.",
            schema: Schema.object(["path": Schema.string("File path"),
                                   "old_string": Schema.string("Exact text to replace"),
                                   "new_string": Schema.string("Replacement text"),
                                   "replace_all": Schema.boolean("Replace every occurrence")],
                                  required: ["path", "old_string", "new_string"]),
            risk: .confirm, verb: "Editing", detail: { short($0.str("path")) },
            preview: { a in
                "Edit \(a.str("path") ?? "?")\n\n− " + String((a.str("old_string") ?? "").prefix(300))
                    + "\n+ " + String((a.str("new_string") ?? "").prefix(300))
            },
            run: { a in await editFile(a) }),
    ]

    static func readFile(_ a: ToolArgs) async -> ToolOutcome {
        guard let raw = a.str("path") else { return .fail("path is required") }
        let path = PathPolicy.resolve(raw)
        if let p = PathPolicy.check(path, write: false) { return .fail(p) }
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDir) else { return .fail("No such file: \(path)") }
        if isDir.boolValue { return .fail("\(path) is a folder — use list_directory.") }
        let ext = (path as NSString).pathExtension.lowercased()
        await FileState.shared.record(path)

        if ["png", "jpg", "jpeg", "gif", "webp", "heic", "tiff", "bmp"].contains(ext) {
            guard let img = pngForModel(path) else { return .fail("Couldn't read the image \(path).") }
            return ToolOutcome(ok: true, text: "Image \(path) — shown below.", images: [img])
        }
        var text: String
        if ext == "pdf" {
            guard let doc = PDFDocument(url: URL(fileURLWithPath: path)) else { return .fail("Couldn't open the PDF.") }
            text = doc.string ?? ""
            if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return .fail("The PDF has no text layer (it's probably scanned). Try read_file on a screenshot of it.")
            }
            text = "[PDF, \(doc.pageCount) pages]\n" + text
        } else if ext == "docx" {
            let r = Proc.run("/usr/bin/unzip", ["-p", path, "word/document.xml"])
            guard r.status == 0 else { return .fail("Couldn't read the Word file.") }
            text = r.out.replacingOccurrences(of: "</w:p>", with: "\n")
                .replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
            text = decodeEntities(text)
        } else {
            guard let data = FileManager.default.contents(atPath: path) else { return .fail("Couldn't read \(path).") }
            if data.count > textLimit { return .fail("\(path) is \(data.count / 1_000_000) MB — too big to read whole. Use search_text on it.") }
            if data.prefix(8000).contains(0) { return .fail("\(path) looks like a binary file.") }
            text = String(data: data, encoding: .utf8) ?? String(decoding: data, as: UTF8.self)
        }
        if a.int("start_line") != nil || a.int("end_line") != nil {
            let lines = text.components(separatedBy: "\n")
            let s = max(1, a.int("start_line") ?? 1), e = min(lines.count, a.int("end_line") ?? lines.count)
            guard s <= e else { return .fail("start_line is past the end (\(lines.count) lines).") }
            text = "[lines \(s)–\(e) of \(lines.count)]\n" + lines[(s - 1)..<e].joined(separator: "\n")
        }
        return ToolOutcome(ok: true, text: text)
    }

    /// Images go to the model as PNG/JPEG; convert anything else (HEIC, TIFF…) and shrink big ones.
    static func pngForModel(_ path: String) -> String? {
        let ext = (path as NSString).pathExtension.lowercased()
        if ["png", "jpg", "jpeg"].contains(ext),
           let a = try? FileManager.default.attributesOfItem(atPath: path), (a[.size] as? Int ?? 0) < 4_000_000 {
            return path
        }
        guard let img = NSImage(contentsOfFile: path), let tiff = img.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff) else { return nil }
        let maxSide = 1600.0
        let w = Double(rep.pixelsWide), h = Double(rep.pixelsHigh)
        var out = rep
        if max(w, h) > maxSide {
            let s = maxSide / max(w, h)
            let size = NSSize(width: w * s, height: h * s)
            let small = NSImage(size: size)
            small.lockFocus()
            img.draw(in: NSRect(origin: .zero, size: size))
            small.unlockFocus()
            if let t = small.tiffRepresentation, let r = NSBitmapImageRep(data: t) { out = r }
        }
        guard let png = out.representation(using: .jpeg, properties: [.compressionFactor: 0.85]) else { return nil }
        let dest = opennotchDir("tmp") + "/img_\(UUID().uuidString.prefix(8)).jpg"
        return (try? png.write(to: URL(fileURLWithPath: dest))) != nil ? dest : nil
    }

    static func listDirectory(_ a: ToolArgs) -> ToolOutcome {
        guard let raw = a.str("path") else { return .fail("path is required") }
        let path = PathPolicy.resolve(raw)
        if let p = PathPolicy.check(path, write: false) { return .fail(p) }
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: path) else {
            return .fail("Couldn't list \(path) — does it exist, and does OpenNotch have access (Settings › Permissions)?")
        }
        let hidden = a.bool("show_hidden")
        var rows: [(dir: Bool, line: String)] = []
        for n in names where hidden || !n.hasPrefix(".") {
            let full = path + "/" + n
            var d: ObjCBool = false
            FileManager.default.fileExists(atPath: full, isDirectory: &d)
            let size = (try? FileManager.default.attributesOfItem(atPath: full)[.size] as? Int) ?? 0
            rows.append((d.boolValue, d.boolValue ? n + "/" : "\(n)  (\(ByteCountFormatter.string(fromByteCount: Int64(size), countStyle: .file)))"))
        }
        rows.sort { $0.dir != $1.dir ? $0.dir : $0.line.localizedStandardCompare($1.line) == .orderedAscending }
        let shown = rows.prefix(500).map(\.line)
        return ToolOutcome(ok: true, text: "\(path) — \(rows.count) items\n" + shown.joined(separator: "\n")
                           + (rows.count > 500 ? "\n… \(rows.count - 500) more" : ""))
    }

    static func searchText(_ a: ToolArgs) async -> ToolOutcome {
        guard let pattern = a.str("pattern"), let raw = a.str("path") else { return .fail("pattern and path are required") }
        let path = PathPolicy.resolve(raw)
        if let p = PathPolicy.check(path, write: false) { return .fail(p) }
        if path == PathPolicy.home { return .fail("Searching your whole home folder is too slow — pick a folder.") }
        var args = ["-rInE", "--exclude-dir=.git", "--exclude-dir=node_modules", "--exclude-dir=.build",
                    "--exclude-dir=build", "--exclude-dir=Library", "-m", "20"]
        if a.bool("ignore_case") { args.append("-i") }
        args += ["--", pattern, path]
        let r = Proc.run("/usr/bin/grep", args, timeout: 25)
        if r.status == 1 { return ToolOutcome(ok: true, text: "No matches.") }
        guard r.status == 0 else { return .fail("grep failed: \(r.err.isEmpty ? "exit \(r.status)" : r.err)") }
        let lines = r.out.split(separator: "\n")
        return ToolOutcome(ok: true, text: lines.prefix(200).joined(separator: "\n")
                           + (lines.count > 200 ? "\n… \(lines.count - 200) more matches" : ""))
    }

    static func findFiles(_ a: ToolArgs) async -> ToolOutcome {
        guard let name = a.str("name") else { return .fail("name is required") }
        let r = Proc.run("/usr/bin/mdfind", ["-onlyin", PathPolicy.home, "-name", name], timeout: 15)
        let hits = r.out.split(separator: "\n").map(String.init)
            .filter { !$0.contains("/Library/") && !$0.contains("/.") && !$0.contains("/node_modules/") }
        let dated = hits.prefix(300).map { p -> (String, Date) in
            (p, ((try? FileManager.default.attributesOfItem(atPath: p))?[.modificationDate] as? Date) ?? .distantPast)
        }.sorted { $0.1 > $1.1 }.prefix(30)
        if dated.isEmpty { return ToolOutcome(ok: true, text: "No files named like “\(name)”.") }
        let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd"
        return ToolOutcome(ok: true, text: dated.map { "\($0.0)  (\(f.string(from: $0.1)))" }.joined(separator: "\n"))
    }

    static func writeFile(_ a: ToolArgs) async -> ToolOutcome {
        guard let raw = a.str("path") else { return .fail("path is required") }
        let content = a.dict["content"] as? String ?? ""
        let path = PathPolicy.resolve(raw)
        if let p = PathPolicy.check(path, write: true) { return .fail(p) }
        if let p = await FileState.shared.problem(path) { return .fail(p) }
        do {
            try FileManager.default.createDirectory(atPath: (path as NSString).deletingLastPathComponent,
                                                    withIntermediateDirectories: true)
            try content.write(toFile: path, atomically: true, encoding: .utf8)
        } catch { return .fail("Couldn't write \(path): \(error.localizedDescription)") }
        await FileState.shared.record(path)
        return ToolOutcome(ok: true, text: "Wrote \(content.count) characters to \(path).")
    }

    static func editFile(_ a: ToolArgs) async -> ToolOutcome {
        guard let raw = a.str("path"), let old = a.dict["old_string"] as? String, let new = a.dict["new_string"] as? String,
              !old.isEmpty else { return .fail("path, old_string and new_string are required") }
        let path = PathPolicy.resolve(raw)
        if let p = PathPolicy.check(path, write: true) { return .fail(p) }
        guard FileManager.default.fileExists(atPath: path) else { return .fail("No such file: \(path) — use write_file to create it.") }
        if let p = await FileState.shared.problem(path) { return .fail(p) }
        guard let text = try? String(contentsOfFile: path, encoding: .utf8) else { return .fail("Couldn't read \(path) as text.") }
        let count = text.components(separatedBy: old).count - 1
        if count == 0 { return .fail("old_string wasn't found in \(path). Read the file again and copy the text exactly.") }
        if count > 1 && !a.bool("replace_all") {
            return .fail("old_string appears \(count) times — add surrounding lines to make it unique, or set replace_all.")
        }
        let out = a.bool("replace_all") ? text.replacingOccurrences(of: old, with: new)
            : text.replacingCharacters(in: text.range(of: old)!, with: new)
        do { try out.write(toFile: path, atomically: true, encoding: .utf8) }
        catch { return .fail("Couldn't write \(path): \(error.localizedDescription)") }
        await FileState.shared.record(path)
        return ToolOutcome(ok: true, text: "Edited \(path) (\(a.bool("replace_all") ? count : 1) replacement\(count == 1 ? "" : "s")).")
    }

    // MARK: Shell

    /// Commands that are never run, approval or not.
    static let forbidden: [String] = [
        #"rm\s+-[a-zA-Z]*r[a-zA-Z]*f?\s+(/|~|\$HOME)\s*($|;|&)"#, #"rm\s+-[a-zA-Z]*f[a-zA-Z]*r\s+(/|~|\$HOME)\s*($|;|&)"#,
        #"\bmkfs\b"#, #"\bdd\b.*of=/dev/"#, #":\(\)\s*\{\s*:\|:&\s*\};:"#, #"\bdiskutil\s+(erase|zero)"#,
        #"\bsudo\b"#, #">\s*/dev/disk"#,
    ]

    static func isForbidden(_ cmd: String) -> Bool {
        forbidden.contains { cmd.range(of: $0, options: .regularExpression) != nil }
    }

    static let shell: [AgentTool] = [
        AgentTool(
            name: "run_command",
            description: "Run a shell command (zsh) and return its output. Asks the user first. Use for git, builds, scripts, file operations. No sudo. Default timeout 60 s (max 600).",
            schema: Schema.object(["command": Schema.string("The command"),
                                   "cwd": Schema.string("Working folder (default: home)"),
                                   "timeout_seconds": Schema.integer("Seconds before it's stopped")], required: ["command"]),
            risk: .confirm, verb: "Running command", detail: { String(($0.str("command") ?? "").prefix(60)) },
            preview: { a in "$ \(a.str("command") ?? "")" + (a.str("cwd").map { "\n(in \($0))" } ?? "") },
            run: { a in await runCommand(a) }),
    ]

    static func runCommand(_ a: ToolArgs) async -> ToolOutcome {
        guard let cmd = a.str("command") else { return .fail("command is required") }
        if isForbidden(cmd) { return .fail("That command is blocked for safety (destructive or needs sudo).") }
        let cwd = PathPolicy.resolve(a.str("cwd") ?? "~")
        if let p = PathPolicy.check(cwd, write: false) { return .fail(p) }
        let timeout = TimeInterval(min(600, max(1, a.int("timeout_seconds") ?? 60)))
        let r = Proc.run("/bin/zsh", ["-c", cmd], cwd: cwd, timeout: timeout,
                         env: ["PATH": "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"])
        var out = r.out
        if !r.err.isEmpty { out += (out.isEmpty ? "" : "\n") + "[stderr]\n" + r.err }
        if out.count > 20_000 { out = String(out.prefix(12_000)) + "\n… [output trimmed] …\n" + String(out.suffix(6_000)) }
        let note = r.timedOut ? "Stopped after \(Int(timeout)) s (timeout)." : "Exit code \(r.status)."
        return ToolOutcome(ok: r.status == 0 && !r.timedOut, text: note + (out.isEmpty ? " (no output)" : "\n" + out))
    }

    // MARK: Web

    static let web: [AgentTool] = [
        AgentTool(
            name: "fetch_url",
            description: "Fetch a web page and return its readable text (title + main text). http/https only.",
            schema: Schema.object(["url": Schema.string("The URL")], required: ["url"]),
            risk: .read, verb: "Fetching", detail: { URL(string: $0.str("url") ?? "")?.host ?? "" }, preview: { $0.str("url") ?? "" },
            run: { a in await fetchURL(a) }),
        AgentTool(
            name: "web_search",
            description: "Search the web (DuckDuckGo). Returns titles, links and snippets — then fetch_url the best ones.",
            schema: Schema.object(["query": Schema.string("Search query")], required: ["query"]),
            risk: .read, verb: "Searching the web", detail: { $0.str("query") ?? "" }, preview: { $0.str("query") ?? "" },
            run: { a in await webSearch(a) }),
    ]

    static let browserUA = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Safari/605.1.15"

    static func fetchURL(_ a: ToolArgs) async -> ToolOutcome {
        guard let s = a.str("url"), let url = URL(string: s), ["http", "https"].contains(url.scheme?.lowercased() ?? "") else {
            return .fail("Give a full http(s) URL.")
        }
        var req = URLRequest(url: url)
        req.timeoutInterval = 30
        req.setValue(browserUA, forHTTPHeaderField: "User-Agent")
        do {
            let (data, resp) = try await HTTP.session.data(for: req)
            let status = (resp as? HTTPURLResponse)?.statusCode ?? 0
            guard status < 400 else { return .fail("The site answered \(status).") }
            let type = (resp as? HTTPURLResponse)?.value(forHTTPHeaderField: "Content-Type")?.lowercased() ?? ""
            let body = String(data: data.prefix(5_000_000), encoding: .utf8) ?? String(decoding: data.prefix(5_000_000), as: UTF8.self)
            if type.contains("html") || body.lowercased().hasPrefix("<!doctype html") || body.contains("<html") {
                return ToolOutcome(ok: true, text: htmlToText(body, url: url))
            }
            if type.hasPrefix("text/") || type.contains("json") || type.contains("xml") {
                return ToolOutcome(ok: true, text: body)
            }
            return .fail("That URL is \(type.isEmpty ? "not text" : type) — can't read it as text.")
        } catch {
            return .fail("Couldn't fetch \(url.host ?? s): \(error.localizedDescription)")
        }
    }

    static func htmlToText(_ html: String, url: URL) -> String {
        var s = html
        let title = s.range(of: #"<title[^>]*>([\s\S]*?)</title>"#, options: [.regularExpression, .caseInsensitive])
            .map { String(s[$0]).replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression) } ?? ""
        for tag in ["script", "style", "noscript", "svg", "nav", "footer", "header", "form"] {
            s = s.replacingOccurrences(of: "<\(tag)[\\s\\S]*?</\(tag)>", with: " ", options: [.regularExpression, .caseInsensitive])
        }
        s = s.replacingOccurrences(of: #"<(br|/p|/div|/li|/h[1-6]|/tr)[^>]*>"#, with: "\n", options: [.regularExpression, .caseInsensitive])
        s = s.replacingOccurrences(of: "<[^>]+>", with: " ", options: .regularExpression)
        s = decodeEntities(s)
        s = s.replacingOccurrences(of: "[ \t]+", with: " ", options: .regularExpression)
            .replacingOccurrences(of: #"\n\s*\n+"#, with: "\n\n", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return "# \(decodeEntities(title).trimmingCharacters(in: .whitespacesAndNewlines))\n\(url.absoluteString)\n\n\(s)"
    }

    static func decodeEntities(_ s: String) -> String {
        var t = s
        for (k, v) in ["&nbsp;": " ", "&amp;": "&", "&lt;": "<", "&gt;": ">", "&quot;": "\"", "&#39;": "'", "&#x27;": "'",
                       "&apos;": "'", "&mdash;": "—", "&ndash;": "–", "&hellip;": "…", "&rsquo;": "’", "&lsquo;": "‘",
                       "&ldquo;": "“", "&rdquo;": "”"] {
            t = t.replacingOccurrences(of: k, with: v)
        }
        return t
    }

    static func webSearch(_ a: ToolArgs) async -> ToolOutcome {
        guard let q = a.str("query") else { return .fail("query is required") }
        var c = URLComponents(string: "https://html.duckduckgo.com/html/")!
        c.queryItems = [URLQueryItem(name: "q", value: q)]
        var req = URLRequest(url: c.url!)
        req.timeoutInterval = 20
        req.setValue(browserUA, forHTTPHeaderField: "User-Agent")
        guard let (data, _) = try? await HTTP.session.data(for: req), let html = String(data: data, encoding: .utf8) else {
            return .fail("Web search failed (no connection?).")
        }
        let results = parseDuckDuckGo(html)
        if results.isEmpty { return .fail("Web search returned nothing usable — try a different query, or fetch_url a site directly.") }
        return ToolOutcome(ok: true, text: results.prefix(8).enumerated().map { i, r in
            "\(i + 1). \(r.title)\n   \(r.url)\n   \(r.snippet)"
        }.joined(separator: "\n"))
    }

    static func parseDuckDuckGo(_ html: String) -> [(title: String, url: String, snippet: String)] {
        guard let link = try? NSRegularExpression(pattern: #"<a[^>]*class="result__a"[^>]*href="([^"]+)"[^>]*>([\s\S]*?)</a>"#),
              let snip = try? NSRegularExpression(pattern: #"class="result__snippet"[^>]*>([\s\S]*?)</a>"#) else { return [] }
        let ns = html as NSString
        let links = link.matches(in: html, range: NSRange(location: 0, length: ns.length))
        let snips = snip.matches(in: html, range: NSRange(location: 0, length: ns.length))
        func clean(_ s: String) -> String {
            decodeEntities(s.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression))
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }
        var out: [(String, String, String)] = []
        for (i, m) in links.enumerated() {
            var href = ns.substring(with: m.range(at: 1))
            if let r = href.range(of: "uddg=") {
                let enc = href[r.upperBound...].split(separator: "&").first.map(String.init) ?? ""
                href = enc.removingPercentEncoding ?? enc
            }
            if href.hasPrefix("//") { href = "https:" + href }
            guard !href.contains("duckduckgo.com/y.js") else { continue }            // ads
            let snippet = i < snips.count ? clean(ns.substring(with: snips[i].range(at: 1))) : ""
            out.append((clean(ns.substring(with: m.range(at: 2))), href, snippet))
        }
        return out
    }

    // MARK: Mac

    static let mac: [AgentTool] = [
        AgentTool(
            name: "open",
            description: "Open an app, a URL, or a web search in the default browser. Give exactly one of app, url, search.",
            schema: Schema.object(["app": Schema.string("App name, e.g. Safari, Notes"),
                                   "url": Schema.string("http(s), mailto:, spotify:, music: … URL"),
                                   "search": Schema.string("Search the web for this")]),
            risk: .read, verb: "Opening", detail: { $0.str("app") ?? $0.str("url") ?? $0.str("search") ?? "" },
            preview: { $0.str("app") ?? $0.str("url") ?? $0.str("search") ?? "" },
            run: { a in await openOnMac(a) }),
        AgentTool(
            name: "media_control",
            description: "Control Spotify or Apple Music: play, pause, toggle, next, previous, now_playing, volume (level 0-100), play_query (query).",
            schema: Schema.object(["action": Schema.enumeration("What to do", ["play", "pause", "toggle", "next", "previous",
                                                                               "now_playing", "volume", "play_query"]),
                                   "query": Schema.string("For play_query: song, artist or album"),
                                   "level": Schema.integer("For volume: 0-100")], required: ["action"]),
            risk: .read, verb: "Music", detail: { $0.str("action") ?? "" }, preview: { $0.str("action") ?? "" },
            run: { a in
                let r = MediaControl.control(a.str("action") ?? "", query: a.str("query"), level: a.int("level"))
                let text = String(data: HTTP.json(r), encoding: .utf8) ?? "{}"
                return ToolOutcome(ok: r["success"] as? Bool == true, text: text)
            }),
        AgentTool(
            name: "clipboard",
            description: "Read the clipboard (action read) or put text on it (action write, with text).",
            schema: Schema.object(["action": Schema.enumeration("read or write", ["read", "write"]),
                                   "text": Schema.string("Text to copy (write)")], required: ["action"]),
            risk: .read, verb: "Clipboard", detail: { $0.str("action") ?? "" }, preview: { $0.str("text") ?? "" },
            run: { a in
                await MainActor.run {
                    let pb = NSPasteboard.general
                    if a.str("action") == "write" {
                        pb.clearContents()
                        pb.setString(a.dict["text"] as? String ?? "", forType: .string)
                        return ToolOutcome(ok: true, text: "Copied to the clipboard.")
                    }
                    guard let s = pb.string(forType: .string), !s.isEmpty else { return ToolOutcome(ok: true, text: "The clipboard has no text.") }
                    return ToolOutcome(ok: true, text: s)
                }
            }),
        AgentTool(
            name: "screenshot",
            description: "Take a screenshot of the screen (the notch hides itself) and look at it. Needs Screen Recording permission.",
            schema: Schema.object([:]),
            risk: .read, verb: "Looking at the screen", detail: { _ in "" }, preview: { _ in "" },
            run: { _ in
                let path = await screenshotHidingNotch()
                guard let path, let img = pngForModel(path) else {
                    return .fail("Screenshot failed — allow OpenNotch in System Settings › Privacy & Security › Screen Recording.")
                }
                return ToolOutcome(ok: true, text: "Screenshot taken — shown below.", images: [img])
            }),
        AgentTool(
            name: "system_info",
            description: "Battery, power, disk space, memory, macOS version, uptime and the frontmost app.",
            schema: Schema.object([:]),
            risk: .read, verb: "Checking the Mac", detail: { _ in "" }, preview: { _ in "" },
            run: { _ in await systemInfo() }),
        AgentTool(
            name: "timer",
            description: "Start a countdown timer in the notch (minutes), a focus session, or stop the current timer.",
            schema: Schema.object(["action": Schema.enumeration("start, focus or stop", ["start", "focus", "stop"]),
                                   "minutes": Schema.number("For start: length in minutes")], required: ["action"]),
            risk: .read, verb: "Timer", detail: { $0.str("action") ?? "" }, preview: { $0.str("action") ?? "" },
            run: { a in
                await MainActor.run {
                    guard let t = ToolHost.hub?.timers else { return ToolOutcome.fail("Timers aren't available.") }
                    switch a.str("action") {
                    case "stop": t.reset(); return ToolOutcome(ok: true, text: "Timer stopped.")
                    case "focus": t.startPomodoro(); return ToolOutcome(ok: true, text: "Focus session started (\(t.focusMinutes) min).")
                    default:
                        guard let m = a.double("minutes"), m > 0, m <= 24 * 60 else { return ToolOutcome.fail("minutes must be 1–1440.") }
                        t.startCountdown(seconds: m * 60)
                        return ToolOutcome(ok: true, text: "Timer set for \(m) minutes — it's in the notch.")
                    }
                }
            }),
        AgentTool(
            name: "keep_awake",
            description: "Keep the Mac awake (minutes, or 0 for until turned off), or stop keeping it awake.",
            schema: Schema.object(["action": Schema.enumeration("start or stop", ["start", "stop"]),
                                   "minutes": Schema.integer("0 = until turned off")], required: ["action"]),
            risk: .read, verb: "Keep awake", detail: { $0.str("action") ?? "" }, preview: { $0.str("action") ?? "" },
            run: { a in
                await MainActor.run {
                    if a.str("action") == "stop" { KeepAwake.shared.stop(); return ToolOutcome(ok: true, text: "The Mac will sleep as usual.") }
                    let m = a.int("minutes") ?? 0
                    KeepAwake.shared.start(minutes: m > 0 ? m : nil)
                    return KeepAwake.shared.isOn ? ToolOutcome(ok: true, text: m > 0 ? "Keeping awake for \(m) minutes." : "Keeping awake until turned off.")
                        : ToolOutcome.fail("macOS refused the keep-awake request.")
                }
            }),
        AgentTool(
            name: "notes",
            description: "The user's scratchpad in the notch: read it, or append text to it.",
            schema: Schema.object(["action": Schema.enumeration("read or append", ["read", "append"]),
                                   "text": Schema.string("Text to append")], required: ["action"]),
            risk: .read, verb: "Notes", detail: { $0.str("action") ?? "" }, preview: { $0.str("text") ?? "" },
            run: { a in
                await MainActor.run {
                    guard let n = ToolHost.hub?.notes else { return ToolOutcome.fail("Notes aren't available.") }
                    if a.str("action") == "append" {
                        let t = a.dict["text"] as? String ?? ""
                        n.text += (n.text.isEmpty || n.text.hasSuffix("\n") ? "" : "\n") + t
                        return ToolOutcome(ok: true, text: "Added to your notes.")
                    }
                    return ToolOutcome(ok: true, text: n.text.isEmpty ? "(Notes are empty.)" : n.text)
                }
            }),
    ]

    @MainActor
    static func screenshotHidingNotch() async -> String? {
        guard let panel = ToolHost.notch?.panel else { return nil }
        return await ScreenGrab.capture(hiding: panel)
    }

    static func openOnMac(_ a: ToolArgs) async -> ToolOutcome {
        if let app = a.str("app") {
            let r = Proc.run("/usr/bin/open", ["-a", app])
            return r.status == 0 ? ToolOutcome(ok: true, text: "Opened \(app).") : .fail("Couldn't open “\(app)” — is it installed?")
        }
        if let s = a.str("url") {
            guard let url = URL(string: s), let scheme = url.scheme?.lowercased(),
                  ["http", "https", "mailto", "spotify", "music", "maps", "facetime", "x-apple.systempreferences"].contains(scheme) else {
                return .fail("That kind of link isn't allowed.")
            }
            let ok = await MainActor.run { NSWorkspace.shared.open(url) }
            return ok ? ToolOutcome(ok: true, text: "Opened \(s).") : .fail("macOS couldn't open \(s).")
        }
        if let q = a.str("search") {
            var c = URLComponents(string: "https://www.google.com/search")!
            c.queryItems = [URLQueryItem(name: "q", value: q)]
            guard let url = c.url else { return .fail("Couldn't build the search link.") }
            let ok = await MainActor.run { NSWorkspace.shared.open(url) }
            return ok ? ToolOutcome(ok: true, text: "Opened a search for “\(q)”.") : .fail("Couldn't open the browser.")
        }
        return .fail("Give app, url or search.")
    }

    static func systemInfo() async -> ToolOutcome {
        var lines: [String] = []
        let pi = ProcessInfo.processInfo
        lines.append("macOS \(pi.operatingSystemVersionString)")
        let up = Int(pi.systemUptime)
        lines.append("Uptime: \(up / 86400)d \(up / 3600 % 24)h \(up / 60 % 60)m")
        lines.append("Memory: \(pi.physicalMemory / 1_073_741_824) GB installed")
        if let v = try? URL(fileURLWithPath: "/").resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey, .volumeTotalCapacityKey]),
           let free = v.volumeAvailableCapacityForImportantUsage, let total = v.volumeTotalCapacity {
            lines.append(String(format: "Disk: %.0f GB free of %.0f GB", Double(free) / 1e9, Double(total) / 1e9))
        }
        if let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
           let list = IOPSCopyPowerSourcesList(info)?.takeRetainedValue() as? [CFTypeRef] {
            for ps in list {
                guard let d = IOPSGetPowerSourceDescription(info, ps)?.takeUnretainedValue() as? [String: Any],
                      d[kIOPSTypeKey] as? String == kIOPSInternalBatteryType else { continue }
                let cur = d[kIOPSCurrentCapacityKey] as? Int ?? 0, mx = d[kIOPSMaxCapacityKey] as? Int ?? 100
                let plugged = d[kIOPSPowerSourceStateKey] as? String == kIOPSACPowerValue
                lines.append("Battery: \(mx > 0 ? cur * 100 / mx : cur)%, \(plugged ? "on power" : "on battery")\(d[kIOPSIsChargingKey] as? Bool == true ? ", charging" : "")")
            }
        }
        let front = await MainActor.run { NSWorkspace.shared.frontmostApplication?.localizedName }
        if let front { lines.append("Frontmost app: \(front)") }
        lines.append("Thermal state: \(["nominal", "fair", "serious", "critical"][min(3, pi.thermalState.rawValue)])")
        return ToolOutcome(ok: true, text: lines.joined(separator: "\n"))
    }

    // MARK: Calendar & reminders

    static let calendar: [AgentTool] = [
        AgentTool(
            name: "calendar_events",
            description: "List calendar events from today for the next N days (default 1, max 14).",
            schema: Schema.object(["days": Schema.integer("How many days, starting today")]),
            risk: .read, verb: "Checking the calendar", detail: { "\($0.int("days") ?? 1) day(s)" }, preview: { _ in "" },
            run: { a in calendarEvents(days: min(14, max(1, a.int("days") ?? 1))) }),
        AgentTool(
            name: "create_event",
            description: "Add a calendar event. Times as ISO 8601 local time, e.g. 2026-10-02T15:00.",
            schema: Schema.object(["title": Schema.string("Title"), "start": Schema.string("Start (ISO 8601)"),
                                   "end": Schema.string("End (optional, default 1 hour later)"),
                                   "notes": Schema.string("Notes (optional)")], required: ["title", "start"]),
            risk: .confirm, verb: "Adding an event", detail: { $0.str("title") ?? "" },
            preview: { "“\($0.str("title") ?? "")” at \($0.str("start") ?? "?")" }, run: { a in createEvent(a) }),
        AgentTool(
            name: "create_reminder",
            description: "Add a reminder, optionally due at an ISO 8601 local time.",
            schema: Schema.object(["title": Schema.string("What to remember"), "due": Schema.string("Due (optional, ISO 8601)")],
                                  required: ["title"]),
            risk: .confirm, verb: "Adding a reminder", detail: { $0.str("title") ?? "" },
            preview: { "“\($0.str("title") ?? "")”" + ($0.str("due").map { " due \($0)" } ?? "") }, run: { a in createReminder(a) }),
    ]

    static let eventStore = EKEventStore()

    static func parseDate(_ s: String?) -> Date? {
        guard let s else { return nil }
        for f in ["yyyy-MM-dd'T'HH:mm:ss", "yyyy-MM-dd'T'HH:mm", "yyyy-MM-dd HH:mm", "yyyy-MM-dd"] {
            let df = DateFormatter()
            df.locale = Locale(identifier: "en_US_POSIX")
            df.dateFormat = f
            if let d = df.date(from: s) { return d }
        }
        return ISO8601DateFormatter().date(from: s)
    }

    static func calendarEvents(days: Int) -> ToolOutcome {
        guard EKEventStore.authorizationStatus(for: .event) == .fullAccess else {
            return .fail("Calendar access isn't allowed — turn it on in Settings › Permissions.")
        }
        let start = Calendar.current.startOfDay(for: Date())
        let end = Calendar.current.date(byAdding: .day, value: days, to: start)!
        let events = eventStore.events(matching: eventStore.predicateForEvents(withStart: start, end: end, calendars: nil))
            .sorted { $0.startDate < $1.startDate }
        if events.isEmpty { return ToolOutcome(ok: true, text: "No events.") }
        let f = DateFormatter(); f.dateFormat = "EEE d MMM HH:mm"
        return ToolOutcome(ok: true, text: events.prefix(60).map { e in
            let when = e.isAllDay ? "all day \(DateFormatter.localizedString(from: e.startDate, dateStyle: .short, timeStyle: .none))" : f.string(from: e.startDate)
            return "- \(when): \(e.title ?? "(no title)")" + (e.location.map { " @ \($0)" } ?? "")
        }.joined(separator: "\n"))
    }

    static func createEvent(_ a: ToolArgs) -> ToolOutcome {
        guard EKEventStore.authorizationStatus(for: .event) == .fullAccess else {
            return .fail("Calendar access isn't allowed — turn it on in Settings › Permissions.")
        }
        guard let title = a.str("title"), let start = parseDate(a.str("start")) else { return .fail("title and a valid start time are required.") }
        let e = EKEvent(eventStore: eventStore)
        e.title = title
        e.startDate = start
        e.endDate = parseDate(a.str("end")) ?? start.addingTimeInterval(3600)
        e.notes = a.str("notes")
        e.calendar = eventStore.defaultCalendarForNewEvents
        do { try eventStore.save(e, span: .thisEvent) } catch { return .fail("Couldn't save the event: \(error.localizedDescription)") }
        return ToolOutcome(ok: true, text: "Added “\(title)” on \(DateFormatter.localizedString(from: start, dateStyle: .medium, timeStyle: .short)).")
    }

    static func createReminder(_ a: ToolArgs) -> ToolOutcome {
        guard EKEventStore.authorizationStatus(for: .reminder) == .fullAccess else {
            return .fail("Reminders access isn't allowed — turn it on in Settings › Permissions.")
        }
        guard let title = a.str("title") else { return .fail("title is required.") }
        let r = EKReminder(eventStore: eventStore)
        r.title = title
        r.calendar = eventStore.defaultCalendarForNewReminders()
        if let due = parseDate(a.str("due")) {
            r.dueDateComponents = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute], from: due)
            r.addAlarm(EKAlarm(absoluteDate: due))
        }
        do { try eventStore.save(r, commit: true) } catch { return .fail("Couldn't save the reminder: \(error.localizedDescription)") }
        return ToolOutcome(ok: true, text: "Reminder added: “\(title)”.")
    }

    // MARK: Memory

    static let memory: [AgentTool] = [
        AgentTool(
            name: "remember",
            description: "Save a lasting fact about the user or their preferences (e.g. key 'coffee', fact 'oat flat white'). Saved on this Mac.",
            schema: Schema.object(["key": Schema.string("Short kebab-case key"), "fact": Schema.string("The fact")], required: ["key", "fact"]),
            risk: .read, verb: "Remembering", detail: { $0.str("key") ?? "" }, preview: { $0.str("fact") ?? "" },
            run: { a in
                guard let k = a.str("key"), let f = a.str("fact") else { return .fail("key and fact are required") }
                if f.range(of: #"(sk-[A-Za-z0-9]{10,}|password\s*[:=]|api[_-]?key\s*[:=])"#, options: [.regularExpression, .caseInsensitive]) != nil {
                    return .fail("That looks like a secret — not saving it to memory.")
                }
                MemoryStore.shared.remember(k, f)
                return ToolOutcome(ok: true, text: "Remembered \(k).")
            }),
        AgentTool(
            name: "forget",
            description: "Delete a remembered fact by key.",
            schema: Schema.object(["key": Schema.string("The key")], required: ["key"]),
            risk: .read, verb: "Forgetting", detail: { $0.str("key") ?? "" }, preview: { $0.str("key") ?? "" },
            run: { a in
                MemoryStore.shared.forget(a.str("key") ?? "") ? ToolOutcome(ok: true, text: "Forgotten.") : .fail("No fact with that key.")
            }),
    ]

    // MARK: Plan

    static let plan: [AgentTool] = [
        AgentTool(
            name: "todo_write",
            description: "Keep a plan for multi-step tasks. Send the whole list each time; exactly one item in_progress.",
            schema: #"{"type":"object","properties":{"items":{"type":"array","items":{"type":"object","properties":{"content":{"type":"string"},"status":{"type":"string","enum":["pending","in_progress","completed"]}},"required":["content","status"]}}},"required":["items"]}"#,
            risk: .read, verb: "Planning", detail: { "\($0.array("items").count) steps" }, preview: { _ in "" },
            run: { a in
                var items = a.array("items").compactMap { i -> (String, String)? in
                    guard let c = i["content"] as? String else { return nil }
                    return (c, i["status"] as? String ?? "pending")
                }
                let active = items.filter { $0.1 == "in_progress" }.count
                if active > 1 { return .fail("Only one item can be in_progress (found \(active)).") }
                // None in progress yet: the first pending step is the one being worked on.
                if active == 0, let i = items.firstIndex(where: { $0.1 == "pending" }) { items[i].1 = "in_progress" }
                PlanStore.shared.set(items)
                return ToolOutcome(ok: true, text: PlanStore.shared.render())
            }),
    ]

    // MARK: helpers

    static func short(_ path: String?) -> String {
        guard let p = path else { return "" }
        return p.replacingOccurrences(of: NSHomeDirectory(), with: "~")
    }
}

/// Runs a process, capturing output, with a timeout. Blocking — call off the main thread.
enum Proc {
    struct Result { var status: Int32; var out: String; var err: String; var timedOut = false }

    static func run(_ path: String, _ args: [String], cwd: String? = nil, timeout: TimeInterval = 10,
                    env: [String: String]? = nil) -> Result {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: path)
        p.arguments = args
        if let cwd { p.currentDirectoryURL = URL(fileURLWithPath: cwd) }
        if let env { p.environment = ProcessInfo.processInfo.environment.merging(env) { _, n in n } }
        let out = Pipe(), err = Pipe()
        p.standardOutput = out
        p.standardError = err
        p.standardInput = FileHandle.nullDevice
        do { try p.run() } catch { return Result(status: -1, out: "", err: "couldn't start \(path): \(error.localizedDescription)") }
        let timedOut = TimedFlag()
        DispatchQueue.global().asyncAfter(deadline: .now() + timeout) {
            if p.isRunning { timedOut.set(); p.terminate() }
        }
        // Read both pipes concurrently so a full stderr can't block stdout.
        var errData = Data()
        let g = DispatchGroup()
        g.enter()
        DispatchQueue.global().async { errData = err.fileHandleForReading.readDataToEndOfFile(); g.leave() }
        let outData = out.fileHandleForReading.readDataToEndOfFile()
        g.wait()
        p.waitUntilExit()
        return Result(status: p.terminationStatus,
                      out: String(decoding: outData, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines),
                      err: String(decoding: errData, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines),
                      timedOut: timedOut.value)
    }
}

final class TimedFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var v = false
    func set() { lock.lock(); v = true; lock.unlock() }
    var value: Bool { lock.lock(); defer { lock.unlock() }; return v }
}
