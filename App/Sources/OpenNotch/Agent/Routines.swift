import AppKit
import Foundation

// Routines: named, saved instructions ("start work" → open Linear and Slack, set Focus, brief me on my day).
// Say the name (or "run start work") and the assistant does the steps with its usual tools and approvals.
// A routine can be exported as a real Apple Shortcut: one step that opens
// opennotch://routine/<id>?key=<secret>, so Siri, the Shortcuts app, the menu bar and keyboard shortcuts can start it.
// The secret is per routine — a web page can't trigger a routine through the link.

struct Routine: Codable, Equatable, Sendable, Identifiable {
    var id: String
    var name: String
    var steps: String
    var key: String
    var created: Date
    var lastRun: Date?
}

/// Pure rules (checked): names, the typed-name fast path, what the model is told, the URL, the Shortcut file.
enum RoutineLogic {
    /// A usable routine name: 1–40 characters, needs a letter, trimmed and single-spaced.
    static func cleanName(_ raw: String) -> String? {
        let n = raw.trimmingCharacters(in: .whitespacesAndNewlines.union(CharacterSet(charactersIn: "\"“”'‘’.")))
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
        guard (1...40).contains(n.count), n.rangeOfCharacter(from: .letters) != nil else { return nil }
        return n
    }

    private static func norm(_ s: String) -> String {
        s.lowercased().replacingOccurrences(of: #"[^\p{L}\p{N} ]"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression).trimmingCharacters(in: .whitespaces)
    }

    /// The routine a message asks for: exactly its name, or "run|start|do (my) (routine) <name>", optionally
    /// with "please"/"now". Anything longer is a normal message (rule 9: narrow fast path).
    static func match(_ message: String, in routines: [Routine]) -> Routine? {
        var m = norm(message)
        guard !m.isEmpty, m.count <= 60 else { return nil }
        for suffix in [" please", " now"] where m.hasSuffix(suffix) { m = String(m.dropLast(suffix.count)) }
        for prefix in ["please "] where m.hasPrefix(prefix) { m = String(m.dropFirst(prefix.count)) }
        if let r = routines.first(where: { norm($0.name) == m }) { return r }
        for verb in ["run ", "start ", "do "] where m.hasPrefix(verb) {
            var rest = String(m.dropFirst(verb.count))
            for filler in ["my ", "the "] where rest.hasPrefix(filler) { rest = String(rest.dropFirst(filler.count)) }
            if rest.hasPrefix("routine ") { rest = String(rest.dropFirst(8)) }
            if rest.hasSuffix(" routine") { rest = String(rest.dropLast(8)) }
            if let r = routines.first(where: { norm($0.name) == rest }) { return r }
        }
        return nil
    }

    /// What the model receives when a routine runs.
    static func expansion(_ r: Routine) -> String {
        "Run my routine “\(r.name)” now. Its steps:\n\(r.steps)\n\nDo every step with your tools (ask for approval where needed), "
            + "then tell me briefly what you did and anything that didn't work."
    }

    static func newKey() -> String {
        var bytes = [UInt8](repeating: 0, count: 18)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        return Data(bytes).base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    static func url(for r: Routine) -> URL? { URL(string: "opennotch://routine/\(r.id)?key=\(r.key)") }

    /// opennotch://routine/<id>?key=… → (id, key), or nil.
    static func parse(_ url: URL) -> (id: String, key: String)? {
        guard url.scheme?.lowercased() == "opennotch", url.host?.lowercased() == "routine" else { return nil }
        let id = url.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let key = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "key" }?.value ?? ""
        guard !id.isEmpty, !id.contains("/"), !key.isEmpty else { return nil }
        return (id, key)
    }

    /// Only the routine's own secret opens it (constant-time compare).
    static func keyMatches(_ given: String, _ stored: String) -> Bool {
        let a = Array(given.utf8), b = Array(stored.utf8)
        guard a.count == b.count, !b.isEmpty else { return false }
        return zip(a, b).reduce(0) { $0 | ($1.0 ^ $1.1) } == 0
    }

    /// A shortcut file (WFWorkflow plist): a URL step, then Open URLs — runs the routine in OpenNotch.
    static func shortcutPlist(url: URL) -> [String: Any] {
        [
            "WFWorkflowActions": [
                ["WFWorkflowActionIdentifier": "is.workflow.actions.url",
                 "WFWorkflowActionParameters": ["WFURLActionURL": url.absoluteString]],
                ["WFWorkflowActionIdentifier": "is.workflow.actions.openurl",
                 "WFWorkflowActionParameters": [String: Any]()],
            ],
            "WFWorkflowClientVersion": "2302.0.4",
            "WFWorkflowMinimumClientVersion": 900,
            "WFWorkflowMinimumClientVersionString": "900",
            "WFWorkflowIcon": ["WFWorkflowIconStartColor": 4_282_601_983, "WFWorkflowIconGlyphNumber": 59_446],
            "WFWorkflowImportQuestions": [Any](),
            "WFWorkflowTypes": [Any](),
            "WFWorkflowInputContentItemClasses": [Any](),
            "WFWorkflowHasShortcutInputVariables": false,
        ]
    }

    /// A safe file name for the exported shortcut (it becomes the shortcut's name).
    static func fileName(_ name: String) -> String {
        let s = name.replacingOccurrences(of: #"[/:\\\x00-\x1F]"#, with: "-", options: .regularExpression).trimmingCharacters(in: .whitespaces)
        return (s.isEmpty ? "Routine" : String(s.prefix(60))) + ".shortcut"
    }
}

final class RoutineStore: @unchecked Sendable {
    static let shared = RoutineStore()
    private let lock = NSLock()
    private let path: String
    private var items: [Routine] = []

    init(path: String = opennotchDir("") + "/routines.json") {
        self.path = path
        if let d = FileManager.default.contents(atPath: path), let r = try? JSONDecoder().decode([Routine].self, from: d) { items = r }
    }

    func all() -> [Routine] { lock.lock(); defer { lock.unlock() }; return items }

    func find(_ nameOrID: String) -> Routine? {
        let n = nameOrID.trimmingCharacters(in: .whitespaces).lowercased()
        return all().first { $0.id == nameOrID || $0.name.lowercased() == n }
    }

    /// Adds or replaces (same name) a routine; keeps its id and key when replacing.
    @discardableResult
    func save(name: String, steps: String) -> Routine {
        lock.lock(); defer { lock.unlock() }
        if let i = items.firstIndex(where: { $0.name.lowercased() == name.lowercased() }) {
            items[i].name = name
            items[i].steps = steps
            persist()
            return items[i]
        }
        let r = Routine(id: String(UUID().uuidString.prefix(8)).lowercased(), name: name, steps: steps,
                        key: RoutineLogic.newKey(), created: Date())
        items.append(r)
        persist()
        return r
    }

    @discardableResult
    func delete(_ id: String) -> Bool {
        lock.lock(); defer { lock.unlock() }
        let before = items.count
        items.removeAll { $0.id == id }
        persist()
        return items.count < before
    }

    func markRun(_ id: String) {
        lock.lock(); defer { lock.unlock() }
        if let i = items.firstIndex(where: { $0.id == id }) { items[i].lastRun = Date(); persist() }
    }

    private func persist() {
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let d = try? enc.encode(items) { try? d.write(to: URL(fileURLWithPath: path), options: .atomic) }
    }
}

// MARK: - Exporting to Apple Shortcuts

enum ShortcutExport {
    /// Writes and signs the shortcut file, then opens it — the Shortcuts app shows "Add Shortcut".
    static func export(_ r: Routine) async -> ToolOutcome {
        guard let url = RoutineLogic.url(for: r) else { return .fail("Couldn't build the routine's link.") }
        let dir = opennotchDir("shortcuts")
        let raw = dir + "/unsigned-" + r.id + ".shortcut"
        let signed = dir + "/" + RoutineLogic.fileName(r.name)
        guard let data = try? PropertyListSerialization.data(fromPropertyList: RoutineLogic.shortcutPlist(url: url), format: .binary, options: 0),
              (try? data.write(to: URL(fileURLWithPath: raw))) != nil else { return .fail("Couldn't write the shortcut file.") }
        defer { try? FileManager.default.removeItem(atPath: raw) }
        try? FileManager.default.removeItem(atPath: signed)
        var r1 = Proc.run("/usr/bin/shortcuts", ["sign", "--mode", "anyone", "--input", raw, "--output", signed], timeout: 60)
        if r1.status != 0 {
            r1 = Proc.run("/usr/bin/shortcuts", ["sign", "--mode", "people-who-know-me", "--input", raw, "--output", signed], timeout: 60)
        }
        guard r1.status == 0, FileManager.default.fileExists(atPath: signed) else {
            let why = r1.err.trimmingCharacters(in: .whitespacesAndNewlines)
            return .fail("macOS couldn't sign the shortcut" + (why.isEmpty ? "" : ": " + String(why.prefix(300)))
                         + ". Signing needs you to be signed in to iCloud.")
        }
        let opened = await MainActor.run { NSWorkspace.shared.open(URL(fileURLWithPath: signed)) }
        return opened ? ToolOutcome(ok: true, text: "The Shortcuts app is asking to add “\(r.name)” — click Add Shortcut. "
                                    + "Then Siri (\"Hey Siri, \(r.name)\"), the Shortcuts menu or a keyboard shortcut can run it.")
            : .fail("Saved the shortcut to \(signed), but couldn't open it — double-click it to add it.")
    }
}

// MARK: - Tools

enum RoutineTools {
    static func all() -> [AgentTool] { [save, list, run, delete, export] }

    static let save = AgentTool(
        name: "routine_save",
        description: "Save a routine: a name the user will say (e.g. \"start work\") and the steps to do, in plain language, "
            + "one per line, naming the apps, sites, shortcuts and checks involved. Saving the same name replaces it. "
            + "Saying the name later runs it.",
        schema: Schema.object(["name": Schema.string("Short name the user will say"),
                               "steps": Schema.string("What to do, one step per line")], required: ["name", "steps"]),
        risk: .confirm, verb: "Saving a routine", detail: { $0.str("name") ?? "" },
        preview: { a in "Save routine “\(a.str("name") ?? "")”:\n" + String((a.str("steps") ?? "").prefix(900)) },
        run: { a in
            guard let name = a.str("name").flatMap(RoutineLogic.cleanName) else { return .fail("Give the routine a short name (1–40 characters).") }
            guard let steps = a.str("steps")?.trimmingCharacters(in: .whitespacesAndNewlines), !steps.isEmpty else { return .fail("steps are required") }
            let r = RoutineStore.shared.save(name: name, steps: String(steps.prefix(4000)))
            return ToolOutcome(ok: true, text: "Saved routine “\(r.name)”. Say “\(r.name)” to run it. It can also be added to Apple "
                               + "Shortcuts (routine_export_shortcut) or put on a schedule (schedule_task with “run my routine \(r.name)”).")
        })

    static let list = AgentTool(
        name: "routine_list",
        description: "List the user's saved routines with their steps.",
        schema: Schema.object([:]),
        risk: .read, verb: "Checking your routines", detail: { _ in "" }, preview: { _ in "" },
        run: { _ in
            let all = RoutineStore.shared.all()
            if all.isEmpty { return ToolOutcome(ok: true, text: "No routines yet.") }
            return ToolOutcome(ok: true, text: all.map { "• \($0.name)\n  " + $0.steps.replacingOccurrences(of: "\n", with: "\n  ") }
                .joined(separator: "\n"))
        })

    static let run = AgentTool(
        name: "routine_run",
        description: "Get a saved routine's steps so you can do them now (for schedules and \"run my … routine\").",
        schema: Schema.object(["name": Schema.string("The routine's name")], required: ["name"]),
        risk: .read, verb: "Running a routine", detail: { $0.str("name") ?? "" }, preview: { _ in "" },
        run: { a in
            guard let r = a.str("name").flatMap(RoutineStore.shared.find) else {
                let names = RoutineStore.shared.all().map(\.name)
                return .fail("No routine called “\(a.str("name") ?? "")”." + (names.isEmpty ? "" : " Routines: " + names.joined(separator: ", ")))
            }
            RoutineStore.shared.markRun(r.id)
            return ToolOutcome(ok: true, text: RoutineLogic.expansion(r))
        })

    static let delete = AgentTool(
        name: "routine_delete",
        description: "Delete a saved routine (its exported Shortcut, if any, stops working).",
        schema: Schema.object(["name": Schema.string("The routine's name")], required: ["name"]),
        risk: .confirm, verb: "Deleting a routine", detail: { $0.str("name") ?? "" },
        preview: { a in "Delete routine “\(a.str("name") ?? "")”" },
        run: { a in
            guard let r = a.str("name").flatMap(RoutineStore.shared.find) else { return .fail("No routine called “\(a.str("name") ?? "")”.") }
            RoutineStore.shared.delete(r.id)
            return ToolOutcome(ok: true, text: "Deleted “\(r.name)”.")
        })

    static let export = AgentTool(
        name: "routine_export_shortcut",
        description: "Add a saved routine to Apple Shortcuts as a one-step shortcut that runs it in OpenNotch — then Siri, the "
            + "Shortcuts menu or a keyboard shortcut can start it. The Shortcuts app asks the user to confirm.",
        schema: Schema.object(["name": Schema.string("The routine's name")], required: ["name"]),
        risk: .confirm, verb: "Making a Shortcut", detail: { $0.str("name") ?? "" },
        preview: { a in "Add “\(a.str("name") ?? "")” to Apple Shortcuts" },
        run: { a in
            if ToolKit.background { return .fail("Exporting opens the Shortcuts app — ask the user in the chat.") }
            guard let r = a.str("name").flatMap(RoutineStore.shared.find) else { return .fail("No routine called “\(a.str("name") ?? "")”.") }
            return await ShortcutExport.export(r)
        })
}
