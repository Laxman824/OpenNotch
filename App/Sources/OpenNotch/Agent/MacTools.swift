import AppKit
import ApplicationServices
import Vision

// Mac-native tools for things people have long wanted from Siri:
//  • shortcuts_list / shortcuts_run — the user's own Shortcuts, which reach any app's App Intents actions.
//  • screen_text — what's in the window in front ("summarise this", "reply to this").
//  • spotlight_search — "the PDF Sarah sent last week": content, kind, person and date via Spotlight.
// Pure parts (query building, name matching, window choice rules) live in MacToolLogic and are checked.

enum MacToolLogic {
    // MARK: Shortcuts

    /// The exact shortcut the model named, matched case-insensitively against the user's list — or nil.
    /// Only shortcuts that exist can run (must-NOT: no made-up names, no paths or flags).
    static func shortcut(named raw: String, in list: [String]) -> String? {
        let name = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, !name.hasPrefix("-") else { return nil }
        return list.first { $0 == name } ?? list.first { $0.caseInsensitiveCompare(name) == .orderedSame }
    }

    // MARK: Spotlight

    enum Kind: String, CaseIterable {
        case any, pdf, document, spreadsheet, presentation, image, video, audio, email, folder
        var types: [String] {
            switch self {
            case .any: return []
            case .pdf: return ["com.adobe.pdf"]
            case .document: return ["org.openxmlformats.wordprocessingml.document", "com.microsoft.word.doc", "com.apple.iwork.pages.sffpages",
                                    "com.apple.iwork.pages.pages", "public.rtf", "public.plain-text", "net.daringfireball.markdown"]
            case .spreadsheet: return ["public.spreadsheet"]
            case .presentation: return ["public.presentation"]
            case .image: return ["public.image"]
            case .video: return ["public.movie"]
            case .audio: return ["public.audio"]
            case .email: return ["com.apple.mail.emlx"]
            case .folder: return ["public.folder"]
            }
        }
    }

    /// Text that's safe inside a quoted Spotlight value: no quotes, backslashes, wildcards or control characters.
    static func clean(_ s: String) -> String {
        String(s.unicodeScalars.filter { !"\"\\*?".unicodeScalars.contains($0) && !CharacterSet.controlCharacters.contains($0) })
            .trimmingCharacters(in: .whitespaces).prefix(80).description
    }

    /// A Spotlight query from the pieces (nil when there's nothing to search for).
    static func spotlightQuery(text: String?, kind: Kind, person: String?, days: Int?) -> String? {
        var parts: [String] = []
        if let t = text.map(clean), !t.isEmpty {
            parts.append("(kMDItemDisplayName == \"*\(t)*\"cdw || kMDItemTextContent == \"\(t)\"cdw || kMDItemKeywords == \"*\(t)*\"cdw)")
        }
        if let p = person.map(clean), !p.isEmpty {
            parts.append("(kMDItemAuthors == \"*\(p)*\"cd || kMDItemAuthorEmailAddresses == \"*\(p)*\"cd || "
                         + "kMDItemWhereFroms == \"*\(p)*\"cd || kMDItemRecipients == \"*\(p)*\"cd)")
        }
        if !kind.types.isEmpty {
            parts.append("(" + kind.types.map { "kMDItemContentTypeTree == \"\($0)\"" }.joined(separator: " || ") + ")")
        }
        if let d = days, d > 0 { parts.append("kMDItemContentModificationDate >= $time.today(-\(min(d, 3650)))") }
        // A filter alone (kind/date with no text or person) is fine; nothing at all isn't.
        guard !parts.isEmpty, text.map(clean)?.isEmpty == false || person.map(clean)?.isEmpty == false || !kind.types.isEmpty || days != nil
        else { return nil }
        return parts.joined(separator: " && ")
    }

    /// Paths not worth showing: app internals, caches, hidden folders, mail's own storage for non-email searches.
    static func keep(_ path: String, kind: Kind) -> Bool {
        if path.contains("/.") || path.contains("/node_modules/") || path.contains("/Caches/") { return false }
        if path.contains("/Library/") { return kind == .email && path.contains("/Library/Mail/") }
        return true
    }

    // MARK: Screen

    /// Apps whose windows are never read (passwords). Must-NOT checked.
    static let privateApps: Set<String> = [
        "com.1password.1password", "com.agilebits.onepassword7", "com.agilebits.onepassword-osx", "com.bitwarden.desktop",
        "com.apple.keychainaccess", "com.apple.Passwords", "com.lastpass.LastPass", "com.dashlane.dashlanephonefinal",
        "in.sinew.Enpass-Desktop", "com.apple.systempreferences",
    ]

    /// AX roles whose text is worth reading; secure fields never.
    static func readable(role: String) -> Bool {
        ["AXStaticText", "AXTextArea", "AXTextField", "AXHeading", "AXLink", "AXCell", "AXButton", "AXMenuButton"].contains(role)
    }
    static func secret(role: String, subrole: String?) -> Bool { role == "AXSecureTextField" || subrole == "AXSecureTextField" }

    /// Joins collected lines: no blanks, no immediate repeats, capped.
    static func joinLines(_ lines: [String], cap: Int = 12_000) -> String {
        var out: [String] = []
        var total = 0
        for l in lines {
            let t = l.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !t.isEmpty, t != out.last else { continue }
            if total + t.count > cap { break }
            out.append(t); total += t.count + 1
        }
        return out.joined(separator: "\n")
    }
}

// MARK: - Tracking the app the user is in (the notch takes focus when you type in it)

@MainActor
enum FrontApp {
    private(set) static var last: NSRunningApplication?
    private static var token: NSObjectProtocol?

    static func startTracking() {
        guard token == nil else { return }
        last = NSWorkspace.shared.frontmostApplication.flatMap { $0.bundleIdentifier == Bundle.main.bundleIdentifier ? nil : $0 }
        token = NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didActivateApplicationNotification,
                                                                  object: nil, queue: .main) { n in
            let app = n.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            MainActor.assumeIsolated {
                if let app, app.bundleIdentifier != Bundle.main.bundleIdentifier { last = app }
            }
        }
    }

    /// The app the user was last working in (not OpenNotch).
    static var current: NSRunningApplication? {
        if let f = NSWorkspace.shared.frontmostApplication, f.bundleIdentifier != Bundle.main.bundleIdentifier { return f }
        return last?.isTerminated == false ? last : nil
    }
}

// MARK: - Tools

enum MacTools {
    static func all() -> [AgentTool] { [shortcutsList, shortcutsRun, screenText, spotlight] }

    // MARK: Shortcuts

    private static let shortcutsBin = "/usr/bin/shortcuts"

    static func listShortcuts() -> [String] {
        let r = Proc.run(shortcutsBin, ["list"], timeout: 20)
        guard r.status == 0 else { return [] }
        return r.out.split(separator: "\n").map { String($0).trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }

    static let shortcutsList = AgentTool(
        name: "shortcuts_list",
        description: "List the user's Shortcuts (the Shortcuts app). Shortcuts can do things inside other apps (Focus, Home, messages, "
            + "app actions). Check this list before saying something can't be done, then use shortcuts_run.",
        schema: Schema.object(["filter": Schema.string("Optional: only names containing this")]),
        risk: .read, verb: "Checking your Shortcuts", detail: { $0.str("filter") ?? "" }, preview: { _ in "" },
        run: { a in
            var names = listShortcuts()
            if names.isEmpty { return ToolOutcome(ok: true, text: "The user has no Shortcuts (or the Shortcuts app isn't set up).") }
            if let f = a.str("filter") { names = names.filter { $0.localizedCaseInsensitiveContains(f) } }
            let shown = names.prefix(300)
            return ToolOutcome(ok: true, text: "\(names.count) shortcut\(names.count == 1 ? "" : "s"):\n" + shown.joined(separator: "\n"))
        })

    static let shortcutsRun = AgentTool(
        name: "shortcuts_run",
        description: "Run one of the user's Shortcuts by its exact name (from shortcuts_list), optionally with text input. "
            + "Asks the user first. Returns the shortcut's output, if any.",
        schema: Schema.object(["name": Schema.string("Exact shortcut name"),
                               "input": Schema.string("Optional text passed to the shortcut as its input")], required: ["name"]),
        risk: .confirm, verb: "Running a shortcut", detail: { $0.str("name") ?? "" },
        preview: { a in "Run shortcut “\(a.str("name") ?? "")”" + (a.str("input").map { "\nwith input: " + String($0.prefix(300)) } ?? "") },
        run: { a in
            if ToolKit.background { return .fail("Shortcuts don't run from background jobs — ask the user in the chat.") }
            guard let raw = a.str("name") else { return .fail("name is required") }
            let names = listShortcuts()
            guard let name = MacToolLogic.shortcut(named: raw, in: names) else {
                let near = names.filter { $0.localizedCaseInsensitiveContains(raw) || raw.localizedCaseInsensitiveContains($0) }.prefix(5)
                return .fail("There's no shortcut called “\(raw)”." + (near.isEmpty ? " Use shortcuts_list to see them." : " Did you mean: \(near.joined(separator: ", "))?"))
            }
            let dir = opennotchDir("tmp")
            let id = UUID().uuidString.prefix(8)
            let outPath = "\(dir)/shortcut_out_\(id).txt"
            var args = ["run", name, "--output-path", outPath, "--output-type", "public.plain-text"]
            var inPath: String?
            if let input = a.str("input") {
                let p = "\(dir)/shortcut_in_\(id).txt"
                if (try? input.write(toFile: p, atomically: true, encoding: .utf8)) != nil { inPath = p; args += ["--input-path", p] }
            }
            defer {
                try? FileManager.default.removeItem(atPath: outPath)
                if let inPath { try? FileManager.default.removeItem(atPath: inPath) }
            }
            let r = Proc.run(shortcutsBin, args, timeout: 120)
            if r.timedOut { return .fail("“\(name)” didn't finish within 2 minutes.") }
            guard r.status == 0 else {
                let why = r.err.trimmingCharacters(in: .whitespacesAndNewlines)
                return .fail("“\(name)” failed" + (why.isEmpty ? "." : ": " + String(why.prefix(400))))
            }
            let out = (try? String(contentsOfFile: outPath, encoding: .utf8)) ?? r.out
            let text = out.trimmingCharacters(in: .whitespacesAndNewlines)
            return ToolOutcome(ok: true, text: text.isEmpty ? "Ran “\(name)”." : "Ran “\(name)”. Output:\n" + String(text.prefix(8000)))
        })

    // MARK: Screen

    static let screenText = AgentTool(
        name: "screen_text",
        description: "Read the text in the window the user is looking at (the app in front, not this notch) — for \"this\", "
            + "\"what's on my screen\", \"summarise/reply to this\". Uses Accessibility; falls back to reading the window's pixels "
            + "if Screen Recording is already allowed. Never reads password apps or password fields.",
        schema: Schema.object([:]),
        risk: .read, verb: "Reading your screen", detail: { _ in "" }, preview: { _ in "" },
        run: { _ in await readFrontWindow() })

    static func readFrontWindow() async -> ToolOutcome {
        guard let app = await MainActor.run(body: { FrontApp.current }) else { return .fail("No app is in front.") }
        let bundle = app.bundleIdentifier ?? ""
        let appName = app.localizedName ?? "the app"
        if MacToolLogic.privateApps.contains(bundle) {
            return .fail("\(appName) holds passwords or settings — I don't read it.")
        }
        var title = ""
        var text = ""
        if AXIsProcessTrusted() {
            (title, text) = axText(pid: app.processIdentifier)
        }
        var how = "Accessibility"
        if text.count < 40 {
            if CGPreflightScreenCaptureAccess(), let ocr = await ocrWindow(pid: app.processIdentifier), ocr.count > text.count {
                text = ocr; how = "on-screen text recognition"
            } else if !AXIsProcessTrusted() {
                return .fail("I need Accessibility permission to read other apps' windows — System Settings › Privacy & Security › "
                             + "Accessibility (or use the screenshot tool).")
            }
        }
        guard !text.isEmpty else {
            return .fail("I couldn't read any text in \(appName)'s window. Try the screenshot tool instead.")
        }
        return ToolOutcome(ok: true, text: "\(appName)" + (title.isEmpty ? "" : " — “\(title)”") + " (read via \(how)):\n" + text)
    }

    /// Text in the focused window, depth-first in reading order, with a node and time budget (a hung app can't hang us).
    static func axText(pid: pid_t) -> (title: String, text: String) {
        let appEl = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(appEl, 0.4)
        func attr<T>(_ el: AXUIElement, _ name: String) -> T? {
            var v: CFTypeRef?
            guard AXUIElementCopyAttributeValue(el, name as CFString, &v) == .success else { return nil }
            return v as? T
        }
        var winRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(appEl, kAXFocusedWindowAttribute as CFString, &winRef) == .success,
              let wr = winRef, CFGetTypeID(wr) == AXUIElementGetTypeID() else { return ("", "") }
        let win = wr as! AXUIElement                      // checked by the type id above
        let title: String = attr(win, kAXTitleAttribute) ?? ""
        var lines: [String] = []
        var stack: [(AXUIElement, Int)] = [(win, 0)]
        var visited = 0
        let deadline = Date().addingTimeInterval(1.5)
        while let (el, depth) = stack.popLast(), visited < 4000, Date() < deadline {
            visited += 1
            let role: String = attr(el, kAXRoleAttribute) ?? ""
            let sub: String? = attr(el, kAXSubroleAttribute)
            if MacToolLogic.secret(role: role, subrole: sub) { continue }
            if MacToolLogic.readable(role: role) {
                if let v: String = attr(el, kAXValueAttribute) { lines.append(v) }
                else if let t: String = attr(el, kAXTitleAttribute) { lines.append(t) }
                else if let d: String = attr(el, kAXDescriptionAttribute), role != "AXButton" { lines.append(d) }
            }
            guard depth < 30, let kids: [AXUIElement] = attr(el, kAXChildrenAttribute) else { continue }
            for k in kids.reversed() { stack.append((k, depth + 1)) }
        }
        return (title, MacToolLogic.joinLines(lines))
    }

    /// The front window of `pid` as text via Vision — only called when Screen Recording is already granted.
    static func ocrWindow(pid: pid_t) async -> String? {
        guard let info = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]],
              let win = info.first(where: { ($0[kCGWindowOwnerPID as String] as? pid_t) == pid && ($0[kCGWindowLayer as String] as? Int) == 0 }),
              let id = win[kCGWindowNumber as String] as? CGWindowID else { return nil }
        let path = opennotchDir("tmp") + "/window_\(id).png"
        defer { try? FileManager.default.removeItem(atPath: path) }
        let r = Proc.run("/usr/sbin/screencapture", ["-x", "-o", "-l", String(id), path], timeout: 10)
        guard r.status == 0, let img = NSImage(contentsOfFile: path)?.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }
        let req = VNRecognizeTextRequest()
        req.recognitionLevel = .accurate
        req.usesLanguageCorrection = true
        try? VNImageRequestHandler(cgImage: img).perform([req])
        let lines = (req.results ?? []).compactMap { $0.topCandidates(1).first?.string }
        return lines.isEmpty ? nil : MacToolLogic.joinLines(lines)
    }

    // MARK: Spotlight

    static let spotlight = AgentTool(
        name: "spotlight_search",
        description: "Search the user's Mac with Spotlight by content, kind, person and date — e.g. \"the PDF Sarah sent last week\" → "
            + "text: (topic, if any), kind: pdf, person: Sarah, days: 7. Searches inside documents and emails, not just names. "
            + "Newest first.",
        schema: Schema.object(["text": Schema.string("Words in the name or contents (optional)"),
                               "kind": ["type": "string", "enum": MacToolLogic.Kind.allCases.map(\.rawValue),
                                        "description": "What kind of item (default any)"],
                               "person": Schema.string("Author, sender or recipient name/email (optional)"),
                               "days": Schema.integer("Only items changed in the last N days (optional)"),
                               "folder": Schema.string("Only inside this folder (optional, default: home)")]),
        risk: .read, verb: "Searching your Mac",
        detail: { a in [a.str("text"), a.str("kind"), a.str("person")].compactMap { $0 }.joined(separator: " · ") },
        preview: { _ in "" },
        run: { a in
            let kind = MacToolLogic.Kind(rawValue: a.str("kind")?.lowercased() ?? "any") ?? .any
            guard let q = MacToolLogic.spotlightQuery(text: a.str("text"), kind: kind, person: a.str("person"), days: a.int("days")) else {
                return .fail("Say what to look for: some text, a kind of file, a person or a date range.")
            }
            var dir = PathPolicy.home
            if let f = a.str("folder") {
                let p = PathPolicy.resolve(f)
                if let problem = PathPolicy.check(p, write: false) { return .fail(problem) }
                dir = p
            }
            let r = Proc.run("/usr/bin/mdfind", ["-onlyin", dir, q], timeout: 20)
            if r.status != 0 && r.out.isEmpty { return .fail("Spotlight search failed: " + String(r.err.prefix(200))) }
            let hits = r.out.split(separator: "\n").map(String.init).filter { MacToolLogic.keep($0, kind: kind) }
            let fm = FileManager.default
            let dated = hits.prefix(400).map { p -> (String, Date, Int) in
                let at = try? fm.attributesOfItem(atPath: p)
                return (p, at?[.modificationDate] as? Date ?? .distantPast, (at?[.size] as? NSNumber)?.intValue ?? 0)
            }.sorted { $0.1 > $1.1 }.prefix(25)
            if dated.isEmpty { return ToolOutcome(ok: true, text: "Nothing on this Mac matches.") }
            let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd HH:mm"
            let bc = ByteCountFormatter()
            return ToolOutcome(ok: true, text: "\(hits.count) match\(hits.count == 1 ? "" : "es")" + (hits.count > 25 ? ", newest 25" : "") + ":\n"
                + dated.map { "\($0.0)  (\(f.string(from: $0.1)), \(bc.string(fromByteCount: Int64($0.2))))" }.joined(separator: "\n"))
        })
}
