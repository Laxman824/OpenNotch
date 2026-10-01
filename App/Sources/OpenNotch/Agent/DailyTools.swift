import AppKit
import Contacts
import EventKit
import Foundation

// Everyday tools that work with the apps people already use — no accounts or
// keys: the browser tab you're reading, Mail.app, Apple Notes, Contacts,
// Reminders, the weather (Open-Meteo, free) and scheduled prompts.
// Anything that creates something (mail draft, note) asks first; nothing sends.

enum DailyTools {
    static func all() -> [AgentTool] { browser + mail + notes + people + weather + schedule }

    // MARK: Helpers

    /// AppleScript string literal contents.
    static func esc(_ s: String) -> String {
        s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
    }

    /// Make sure macOS lets us script `appName`; asks once, with the notch out of the way.
    static func ensureAutomation(_ bundleID: String, _ appName: String) async -> String? {
        let st = ContextGrabber.automationStatus(bundleID)
        if st == noErr || st == -600 { return nil }               // allowed, or not running (osascript asks)
        if st == -1743 {
            return "OpenNotch isn't allowed to control \(appName). Turn it on in System Settings › Privacy & Security › Automation › OpenNotch."
        }
        await MainActor.run { ToolHost.notch?.yieldForSystemPrompt("control of \(appName)") }
        let r = ContextGrabber.automationStatus(bundleID, ask: true)
        return r == noErr ? nil : "Permission to control \(appName) was declined."
    }

    static func script(_ src: String, timeout: TimeInterval = 25) -> (ok: Bool, out: String) {
        let r = Proc.run("/usr/bin/osascript", ["-e", src], timeout: timeout)
        return (r.status == 0 && !r.timedOut, r.status == 0 ? r.out : (r.timedOut ? "timed out" : r.err))
    }

    // MARK: Browser tab

    static let browsers: [(name: String, bundle: String, safari: Bool)] = [
        ("Safari", "com.apple.Safari", true), ("Google Chrome", "com.google.Chrome", false),
        ("Arc", "company.thebrowser.Browser", false), ("Brave Browser", "com.brave.Browser", false),
        ("Microsoft Edge", "com.microsoft.edgemac", false),
    ]

    static let browser: [AgentTool] = [
        AgentTool(
            name: "active_tab",
            description: "The web page the user is looking at right now (frontmost browser tab): its title and URL. Then use fetch_url to read it.",
            schema: Schema.object([:]),
            risk: .read, verb: "Checking your browser", detail: { _ in "" }, preview: { _ in "" },
            run: { _ in
                let front = await MainActor.run { NSWorkspace.shared.frontmostApplication?.bundleIdentifier }
                let running = Set(NSWorkspace.shared.runningApplications.compactMap(\.bundleIdentifier))
                let order = browsers.filter { $0.bundle == front } + browsers.filter { $0.bundle != front && running.contains($0.bundle) }
                guard let b = order.first else { return .fail("No supported browser is open (Safari, Chrome, Arc, Brave, Edge).") }
                if let problem = await ensureAutomation(b.bundle, b.name) { return .fail(problem) }
                let src = b.safari
                    ? "tell application \"Safari\" to return (URL of front document) & linefeed & (name of front document)"
                    : "tell application \"\(b.name)\" to return (URL of active tab of front window) & linefeed & (title of active tab of front window)"
                let r = script(src, timeout: 8)
                guard r.ok, !r.out.isEmpty else { return .fail("Couldn't read the tab from \(b.name): \(r.out)") }
                let parts = r.out.components(separatedBy: "\n")
                return ToolOutcome(ok: true, text: "\(b.name) tab: \(parts.dropFirst().joined(separator: " "))\n\(parts.first ?? "")")
            }),
    ]

    // MARK: Mail.app

    static let mail: [AgentTool] = [
        AgentTool(
            name: "mail_recent",
            description: "Recent emails in Mail.app's inbox (sender, subject, date, id), newest first. Works with any account set up in Mail.",
            schema: Schema.object(["days": Schema.integer("How many days back (default 2, max 14)"),
                                   "unread_only": Schema.boolean("Only unread messages")]),
            risk: .read, verb: "Checking your email", detail: { $0.bool("unread_only") ? "unread" : "recent" }, preview: { _ in "" },
            run: { a in
                if let p = await ensureAutomation("com.apple.mail", "Mail") { return .fail(p) }
                let days = min(14, max(1, a.int("days") ?? 2))
                let unread = a.bool("unread_only")
                let src = """
                tell application "Mail"
                  set out to ""
                  set theMsgs to (messages of inbox whose date received > ((current date) - \(days) * days))
                  repeat with m in theMsgs
                    if (\(unread ? "read status of m is false" : "true")) then
                      set out to out & (id of m) & tab & (sender of m) & tab & (subject of m) & tab & ((date received of m) as «class isot» as string) & tab & (read status of m) & linefeed
                    end if
                  end repeat
                  return out
                end tell
                """
                let r = script(src, timeout: 40)
                guard r.ok else { return .fail("Mail didn't answer: \(r.out). Is Mail.app set up with your account?") }
                let rows = r.out.split(separator: "\n").map { $0.components(separatedBy: "\t") }.filter { $0.count >= 5 }
                if rows.isEmpty { return ToolOutcome(ok: true, text: unread ? "No unread email in the last \(days) days." : "No email in the last \(days) days.") }
                let sorted = rows.sorted { $0[3] > $1[3] }.prefix(40)
                return ToolOutcome(ok: true, text: sorted.map { r in
                    "- [id \(r[0])] \(r[4] == "false" ? "● " : "")\(r[1]) — \(r[2]) (\(r[3].replacingOccurrences(of: "T", with: " ").prefix(16)))"
                }.joined(separator: "\n"))
            }),
        AgentTool(
            name: "mail_read",
            description: "Read one email from Mail.app by its id (from mail_recent).",
            schema: Schema.object(["id": Schema.integer("Message id")], required: ["id"]),
            risk: .read, verb: "Reading an email", detail: { "#\($0.int("id") ?? 0)" }, preview: { _ in "" },
            run: { a in
                guard let id = a.int("id") else { return .fail("id is required") }
                if let p = await ensureAutomation("com.apple.mail", "Mail") { return .fail(p) }
                let r = script("""
                tell application "Mail"
                  set m to first message of inbox whose id is \(id)
                  return "From: " & (sender of m) & linefeed & "Subject: " & (subject of m) & linefeed & "Date: " & ((date received of m) as string) & linefeed & linefeed & (content of m)
                end tell
                """, timeout: 30)
                return r.ok ? ToolOutcome(ok: true, text: String(r.out.prefix(12_000))) : .fail("Couldn't open that email: \(r.out)")
            }),
        AgentTool(
            name: "mail_draft",
            description: "Open a new email draft in Mail.app for the user to review and send themselves. Never sends.",
            schema: Schema.object(["to": Schema.string("Recipient email address(es), comma-separated"),
                                   "subject": Schema.string("Subject"), "body": Schema.string("Plain-text body")],
                                  required: ["to", "subject", "body"]),
            risk: .confirm, verb: "Drafting an email", detail: { $0.str("to") ?? "" },
            preview: { a in "To: \(a.str("to") ?? "")\nSubject: \(a.str("subject") ?? "")\n\n" + String((a.str("body") ?? "").prefix(500)) },
            run: { a in
                guard let to = a.str("to"), let subject = a.str("subject") else { return .fail("to and subject are required") }
                if let p = await ensureAutomation("com.apple.mail", "Mail") { return .fail(p) }
                let recipients = to.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
                let adds = recipients.map { "make new to recipient at end of to recipients with properties {address:\"\(esc($0))\"}" }
                    .joined(separator: "\n    ")
                let r = script("""
                tell application "Mail"
                  set msg to make new outgoing message with properties {subject:"\(esc(subject))", content:"\(esc(a.str("body") ?? ""))", visible:true}
                  tell msg
                    \(adds)
                  end tell
                  activate
                end tell
                """)
                return r.ok ? ToolOutcome(ok: true, text: "Draft opened in Mail for you to review and send (not sent).")
                    : .fail("Couldn't create the draft: \(r.out)")
            }),
    ]

    // MARK: Apple Notes

    static let notes: [AgentTool] = [
        AgentTool(
            name: "notes_search",
            description: "Search Apple Notes by title or text. Returns note names and ids.",
            schema: Schema.object(["query": Schema.string("Words to look for")], required: ["query"]),
            risk: .read, verb: "Searching Notes", detail: { $0.str("query") ?? "" }, preview: { _ in "" },
            run: { a in
                guard let q = a.str("query") else { return .fail("query is required") }
                if let p = await ensureAutomation("com.apple.Notes", "Notes") { return .fail(p) }
                let r = script("""
                tell application "Notes"
                  set out to ""
                  set hits to (notes whose name contains "\(esc(q))" or plaintext contains "\(esc(q))")
                  set n to 0
                  repeat with x in hits
                    set n to n + 1
                    if n > 20 then exit repeat
                    set out to out & (id of x) & tab & (name of x) & tab & ((modification date of x) as string) & linefeed
                  end repeat
                  return out
                end tell
                """, timeout: 40)
                guard r.ok else { return .fail("Notes didn't answer: \(r.out)") }
                let rows = r.out.split(separator: "\n").map { $0.components(separatedBy: "\t") }.filter { $0.count >= 2 }
                return ToolOutcome(ok: true, text: rows.isEmpty ? "No notes match “\(q)”."
                                   : rows.map { "- \($0[1]) (id \($0[0]))" }.joined(separator: "\n"))
            }),
        AgentTool(
            name: "notes_read",
            description: "Read an Apple Note by id (from notes_search).",
            schema: Schema.object(["id": Schema.string("Note id")], required: ["id"]),
            risk: .read, verb: "Reading a note", detail: { _ in "" }, preview: { _ in "" },
            run: { a in
                guard let id = a.str("id") else { return .fail("id is required") }
                if let p = await ensureAutomation("com.apple.Notes", "Notes") { return .fail(p) }
                let r = script("tell application \"Notes\" to return (name of note id \"\(esc(id))\") & linefeed & (plaintext of note id \"\(esc(id))\")")
                return r.ok ? ToolOutcome(ok: true, text: String(r.out.prefix(15_000))) : .fail("Couldn't open that note: \(r.out)")
            }),
        AgentTool(
            name: "notes_create",
            description: "Create a new note in Apple Notes.",
            schema: Schema.object(["title": Schema.string("Title"), "body": Schema.string("Text")], required: ["title", "body"]),
            risk: .confirm, verb: "Creating a note", detail: { $0.str("title") ?? "" },
            preview: { "“\($0.str("title") ?? "")”\n\n" + String(($0.str("body") ?? "").prefix(400)) },
            run: { a in
                guard let t = a.str("title") else { return .fail("title is required") }
                if let p = await ensureAutomation("com.apple.Notes", "Notes") { return .fail(p) }
                let body = (a.str("body") ?? "").components(separatedBy: "\n").map { "<div>\(esc(htmlEscape($0)))</div>" }.joined()
                let r = script("tell application \"Notes\" to make new note with properties {name:\"\(esc(t))\", body:\"<h1>\(esc(htmlEscape(t)))</h1>\(body)\"}")
                return r.ok ? ToolOutcome(ok: true, text: "Note “\(t)” created in Apple Notes.") : .fail("Couldn't create the note: \(r.out)")
            }),
    ]

    static func htmlEscape(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;").replacingOccurrences(of: ">", with: "&gt;")
    }

    // MARK: Contacts & reminders

    static let people: [AgentTool] = [
        AgentTool(
            name: "contacts_find",
            description: "Look up a person in Contacts: emails, phone numbers, company, birthday.",
            schema: Schema.object(["name": Schema.string("Name or part of it")], required: ["name"]),
            risk: .read, verb: "Looking up a contact", detail: { $0.str("name") ?? "" }, preview: { _ in "" },
            run: { a in
                guard let name = a.str("name") else { return .fail("name is required") }
                let store = CNContactStore()
                switch CNContactStore.authorizationStatus(for: .contacts) {
                case .authorized: break
                case .notDetermined:
                    await MainActor.run { ToolHost.notch?.yieldForSystemPrompt("Contacts") }
                    let ok = (try? await store.requestAccess(for: .contacts)) ?? false
                    if !ok { return .fail("Contacts access was declined.") }
                default:
                    return .fail("Contacts access isn't allowed — turn it on in Settings › Permissions.")
                }
                let keys: [CNKeyDescriptor] = [CNContactGivenNameKey, CNContactFamilyNameKey, CNContactEmailAddressesKey,
                                               CNContactPhoneNumbersKey, CNContactOrganizationNameKey, CNContactBirthdayKey] as [CNKeyDescriptor]
                guard let found = try? store.unifiedContacts(matching: CNContact.predicateForContacts(matchingName: name), keysToFetch: keys),
                      !found.isEmpty else { return ToolOutcome(ok: true, text: "No contact named “\(name)”.") }
                return ToolOutcome(ok: true, text: found.prefix(8).map { c in
                    var parts = ["\(c.givenName) \(c.familyName)".trimmingCharacters(in: .whitespaces)]
                    if !c.organizationName.isEmpty { parts.append(c.organizationName) }
                    parts += c.emailAddresses.map { "email: \($0.value)" }
                    parts += c.phoneNumbers.map { "phone: \($0.value.stringValue)" }
                    if let b = c.birthday, let m = b.month, let d = b.day { parts.append("birthday: \(d)/\(m)") }
                    return "- " + parts.joined(separator: " · ")
                }.joined(separator: "\n"))
            }),
        AgentTool(
            name: "reminders_list",
            description: "The user's open (not completed) reminders, with due dates.",
            schema: Schema.object([:]),
            risk: .read, verb: "Checking reminders", detail: { _ in "" }, preview: { _ in "" },
            run: { _ in
                guard EKEventStore.authorizationStatus(for: .reminder) == .fullAccess else {
                    return .fail("Reminders access isn't allowed — turn it on in Settings › Permissions.")
                }
                let store = ToolKit.eventStore
                let pred = store.predicateForIncompleteReminders(withDueDateStarting: nil, ending: nil, calendars: nil)
                let rows: [String] = await withCheckedContinuation { c in
                    store.fetchReminders(matching: pred) { rs in
                        let f = DateFormatter(); f.dateFormat = "EEE d MMM HH:mm"
                        let list = (rs ?? []).sorted {
                            ($0.dueDateComponents?.date ?? .distantFuture) < ($1.dueDateComponents?.date ?? .distantFuture)
                        }.prefix(50).map { r -> String in
                            "- \(r.title ?? "(untitled)")" + (r.dueDateComponents?.date.map { " — due \(f.string(from: $0))" } ?? "")
                        }
                        c.resume(returning: Array(list))
                    }
                }
                return ToolOutcome(ok: true, text: rows.isEmpty ? "No open reminders." : rows.joined(separator: "\n"))
            }),
    ]

    // MARK: Weather (Open-Meteo, no key)

    static let weather: [AgentTool] = [
        AgentTool(
            name: "weather",
            description: "Current weather and a 3-day forecast for a place. Pass a city; if you don't know where the user is, use a remembered home city or ask.",
            schema: Schema.object(["place": Schema.string("City, e.g. Hyderabad or Paris")], required: ["place"]),
            risk: .read, verb: "Checking the weather", detail: { $0.str("place") ?? "" }, preview: { _ in "" },
            run: { a in
                guard let place = a.str("place") else { return .fail("place is required") }
                var g = URLComponents(string: "https://geocoding-api.open-meteo.com/v1/search")!
                g.queryItems = [.init(name: "name", value: place), .init(name: "count", value: "1")]
                guard let (gd, _) = try? await HTTP.session.data(from: g.url!),
                      let hit = ((HTTP.parse(String(decoding: gd, as: UTF8.self)))?["results"] as? [[String: Any]])?.first,
                      let lat = hit["latitude"] as? Double, let lon = hit["longitude"] as? Double else {
                    return .fail("Couldn't find “\(place)”.")
                }
                var f = URLComponents(string: "https://api.open-meteo.com/v1/forecast")!
                f.queryItems = [.init(name: "latitude", value: "\(lat)"), .init(name: "longitude", value: "\(lon)"),
                                .init(name: "current", value: "temperature_2m,apparent_temperature,weather_code,wind_speed_10m,relative_humidity_2m"),
                                .init(name: "daily", value: "weather_code,temperature_2m_max,temperature_2m_min,precipitation_probability_max"),
                                .init(name: "timezone", value: "auto"), .init(name: "forecast_days", value: "3")]
                guard let (fd, _) = try? await HTTP.session.data(from: f.url!), let w = HTTP.parse(String(decoding: fd, as: UTF8.self)),
                      let cur = w["current"] as? [String: Any], let daily = w["daily"] as? [String: Any] else {
                    return .fail("The weather service didn't answer.")
                }
                let name = [hit["name"] as? String, hit["country"] as? String].compactMap { $0 }.joined(separator: ", ")
                var lines = ["\(name) now: \(num(cur["temperature_2m"]))°C (feels \(num(cur["apparent_temperature"]))°C), \(describe(cur["weather_code"])), wind \(num(cur["wind_speed_10m"])) km/h, humidity \(num(cur["relative_humidity_2m"]))%"]
                let days = daily["time"] as? [String] ?? []
                for (i, d) in days.enumerated() {
                    let hi = (daily["temperature_2m_max"] as? [Any])?[i], lo = (daily["temperature_2m_min"] as? [Any])?[i]
                    let rain = (daily["precipitation_probability_max"] as? [Any])?[i], code = (daily["weather_code"] as? [Any])?[i]
                    lines.append("\(i == 0 ? "Today" : i == 1 ? "Tomorrow" : d): \(describe(code)), \(num(lo))–\(num(hi))°C, rain chance \(num(rain))%")
                }
                return ToolOutcome(ok: true, text: lines.joined(separator: "\n"))
            }),
    ]

    static func num(_ v: Any?) -> String {
        guard let d = (v as? NSNumber)?.doubleValue else { return "?" }
        return d.rounded() == d ? "\(Int(d))" : String(format: "%.0f", d)
    }

    /// WMO weather codes → words.
    static func describe(_ v: Any?) -> String {
        switch (v as? NSNumber)?.intValue ?? -1 {
        case 0: return "clear"
        case 1, 2: return "partly cloudy"
        case 3: return "overcast"
        case 45, 48: return "fog"
        case 51, 53, 55, 56, 57: return "drizzle"
        case 61, 63, 65, 66, 67: return "rain"
        case 71, 73, 75, 77: return "snow"
        case 80, 81, 82: return "rain showers"
        case 85, 86: return "snow showers"
        case 95, 96, 99: return "thunderstorms"
        default: return "unknown"
        }
    }

    // MARK: Scheduled prompts

    static let schedule: [AgentTool] = [
        AgentTool(
            name: "schedule_task",
            description: "Run a prompt automatically at a time — once, every day, or on weekdays (e.g. a morning brief at 09:00). The answer appears in the notch.",
            schema: Schema.object(["prompt": Schema.string("What to do, written as a request to you"),
                                   "time": Schema.string("24-hour local time, HH:mm"),
                                   "repeat": Schema.enumeration("How often", ["once", "daily", "weekdays"]),
                                   "date": Schema.string("For once: yyyy-MM-dd (default: the next time it's that time)")],
                                  required: ["prompt", "time", "repeat"]),
            risk: .confirm, verb: "Scheduling", detail: { "\($0.str("repeat") ?? "") at \($0.str("time") ?? "")" },
            preview: { "\($0.str("repeat") ?? "once") at \($0.str("time") ?? "?")\n“\($0.str("prompt") ?? "")”" },
            run: { a in
                guard let prompt = a.str("prompt"), let time = a.str("time"),
                      let r = ScheduleStore.Repeat(rawValue: a.str("repeat") ?? "once") else { return .fail("prompt, time and repeat are required") }
                let hm = time.split(separator: ":").compactMap { Int($0) }
                guard hm.count == 2, (0..<24).contains(hm[0]), (0..<60).contains(hm[1]) else { return .fail("time must be HH:mm (24-hour)") }
                let t = ScheduleStore.shared.add(prompt: prompt, hour: hm[0], minute: hm[1], repeat: r, date: a.str("date"))
                return ToolOutcome(ok: true, text: "Scheduled (id \(t.id)): next run \(ScheduleStore.describe(t)).")
            }),
        AgentTool(
            name: "list_scheduled",
            description: "List scheduled prompts.",
            schema: Schema.object([:]),
            risk: .read, verb: "Listing schedules", detail: { _ in "" }, preview: { _ in "" },
            run: { _ in
                let all = ScheduleStore.shared.all()
                return ToolOutcome(ok: true, text: all.isEmpty ? "Nothing is scheduled."
                                   : all.map { "- [\($0.id)] \($0.repeat.rawValue) at \(String(format: "%02d:%02d", $0.hour, $0.minute)): \($0.prompt)" }
                                    .joined(separator: "\n"))
            }),
        AgentTool(
            name: "cancel_scheduled",
            description: "Cancel a scheduled prompt by id.",
            schema: Schema.object(["id": Schema.string("Schedule id")], required: ["id"]),
            risk: .read, verb: "Cancelling a schedule", detail: { $0.str("id") ?? "" }, preview: { _ in "" },
            run: { a in
                ScheduleStore.shared.remove(a.str("id") ?? "") ? ToolOutcome(ok: true, text: "Cancelled.") : .fail("No schedule with that id.")
            }),
    ]
}

/// Scheduled prompts, saved in Application Support/OpenNotch/schedule.json.
final class ScheduleStore: @unchecked Sendable {
    static let shared = ScheduleStore()
    enum Repeat: String, Codable, Sendable { case once, daily, weekdays }

    struct Task: Codable, Equatable, Sendable {
        var id: String
        var prompt: String
        var hour: Int
        var minute: Int
        var `repeat`: Repeat
        var date: String?              // once: yyyy-MM-dd
        var lastRun: Date?
    }

    private let lock = NSLock()
    private let path: String
    private var tasks: [Task] = []

    init(path: String = opennotchDir("") + "/schedule.json") {
        self.path = path
        if let d = FileManager.default.contents(atPath: path), let t = try? JSONDecoder().decode([Task].self, from: d) { tasks = t }
    }

    func all() -> [Task] { lock.lock(); defer { lock.unlock() }; return tasks }

    @discardableResult
    func add(prompt: String, hour: Int, minute: Int, repeat r: Repeat, date: String?) -> Task {
        lock.lock(); defer { lock.unlock() }
        var day = date
        if r == .once && day == nil {
            // No date: the next time the clock reads hour:minute.
            let cal = Calendar.current
            let now = Date()
            var next = cal.date(bySettingHour: hour, minute: minute, second: 0, of: now) ?? now
            if next <= now { next = cal.date(byAdding: .day, value: 1, to: next) ?? next }
            let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX"); f.dateFormat = "yyyy-MM-dd"
            day = f.string(from: next)
        }
        // lastRun = now: only future slots fire (not one that passed minutes ago).
        let t = Task(id: String(UUID().uuidString.prefix(6)).lowercased(), prompt: prompt, hour: hour, minute: minute,
                     repeat: r, date: day, lastRun: Date())
        tasks.append(t)
        save()
        return t
    }

    func remove(_ id: String) -> Bool {
        lock.lock(); defer { lock.unlock() }
        let before = tasks.count
        tasks.removeAll { $0.id == id }
        save()
        return tasks.count < before
    }

    /// Tasks due at `now` (and not yet run for this slot); marks them run. Once-tasks are removed.
    func takeDue(_ now: Date = Date()) -> [Task] {
        lock.lock(); defer { lock.unlock() }
        var due: [Task] = []
        for i in tasks.indices {
            guard let slot = Self.lastSlot(tasks[i], before: now), now.timeIntervalSince(slot) < 30 * 60,
                  tasks[i].lastRun.map({ $0 < slot }) ?? true else { continue }
            tasks[i].lastRun = now
            due.append(tasks[i])
        }
        tasks.removeAll { t in t.repeat == .once && due.contains { $0.id == t.id } }
        if !due.isEmpty { save() }
        return due
    }

    /// The most recent scheduled moment at or before `now`.
    static func lastSlot(_ t: Task, before now: Date) -> Date? {
        let cal = Calendar.current
        if t.repeat == .once, let ds = t.date {
            let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX"); f.dateFormat = "yyyy-MM-dd HH:mm"
            guard let d = f.date(from: "\(ds) \(String(format: "%02d:%02d", t.hour, t.minute))"), d <= now else { return nil }
            return d
        }
        for back in 0..<8 {
            guard let day = cal.date(byAdding: .day, value: -back, to: now),
                  let slot = cal.date(bySettingHour: t.hour, minute: t.minute, second: 0, of: day), slot <= now else { continue }
            let wd = cal.component(.weekday, from: slot)
            if t.repeat == .weekdays && (wd == 1 || wd == 7) { continue }
            return slot
        }
        return nil
    }

    static func describe(_ t: Task) -> String {
        let hm = String(format: "%02d:%02d", t.hour, t.minute)
        switch t.repeat {
        case .once: return t.date.map { "\($0) at \(hm)" } ?? "today/tomorrow at \(hm)"
        case .daily: return "every day at \(hm)"
        case .weekdays: return "weekdays at \(hm)"
        }
    }

    private func save() {
        if let d = try? JSONEncoder().encode(tasks) { try? d.write(to: URL(fileURLWithPath: path), options: .atomic) }
    }
}
