import EventKit
import Foundation

/// "remind me to call HR at 4", "note: …", "add standup tomorrow 10am" —
/// straight into Reminders / Notes / Calendar, no model round-trip.
///
/// Deliberately narrow (like the music fast path): only whole utterances that
/// start with a capture phrase. "add tests for the parser" or "note how the
/// router works" must still reach Ledge.
enum QuickIntent: Equatable {
    case reminder(title: String, due: Date?, timed: Bool)
    case note(String)
    case event(title: String, start: Date, end: Date)
}

enum QuickCapture {
    static func parse(_ raw: String, now: Date = Date()) -> QuickIntent? {
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let name = NSRegularExpression.escapedPattern(for: UserDefaults.standard.string(forKey: "assistantName") ?? "Ledge")
        text = text.replacingOccurrences(of: "^(?i)(?:hey |ok |okay )?\(name)[,:]?\\s+", with: "",
                                         options: .regularExpression)
        text = text.replacingOccurrences(of: #"^(?i)please\s+"#, with: "", options: .regularExpression)
        guard !text.isEmpty, text.split(separator: " ").count <= 30, !text.contains("\n") else { return nil }
        let lower = text.lowercased()

        // Notes: "note: …", "note that …", "jot down …", "take a note …"
        for p in [#"^note\s*[:\-–]\s*(.+)$"#, #"^note that\s+(.+)$"#, #"^jot(?: this)? down[:\s]+(.+)$"#,
                  #"^take a note[:,\s]+(?:that\s+)?(.+)$"#, #"^add (?:a )?note[:\s]+(.+)$"#] {
            if let body = capture(p, in: text) { return .note(body) }
        }

        // Reminders: "remind me (to) …", "todo: …", "add … to my todo/reminders"
        if let body = capture(#"^remind me(?: to)?\s+(.+)$"#, in: text)
            ?? capture(#"^(?:add (?:a )?)?(?:todo|to-do|task)\s*[:\-–]\s*(.+)$"#, in: text)
            ?? capture(#"^add (.+?) to my (?:todo|to-do|task|reminders?)(?: list)?$"#, in: text) {
            // "remind me what we discussed?" is a question for Ledge, not a task.
            if body.hasSuffix("?") || body.range(of: #"^(?i)(what|when|where|who|why|how|which|whether|if|about)\b"#,
                                                   options: .regularExpression) != nil { return nil }
            let (title, due, _) = extractDateRange(from: body, now: now)
            guard !title.isEmpty else { return nil }
            if let due, due < now.addingTimeInterval(-60) { return nil }        // in the past: not a reminder
            return .reminder(title: title, due: due, timed: due.map { _ in hasTime(body) } ?? false)
        }

        // Events: need an explicit calendar word AND a time, or "… to my calendar".
        // Keep "call"/"lunch" in the title; only drop the generic nouns.
        let eventLead = #"^(?:add|schedule|create|book|put|set up)\s+(?:an?\s+)?(?:(?:event|appointment)\s*[:\-–]?\s*|meeting\s*[:\-–]\s*)?(.+)$"#
        let mentionsCalendar = lower.contains("calendar")
        let calendarWord = lower.range(of: #"\b(event|meeting|call|appointment|standup|stand-up|sync|interview|lunch|dinner)\b"#,
                                       options: .regularExpression) != nil
        if (mentionsCalendar || calendarWord), let body = capture(eventLead, in: text) {
            let cleaned = body.replacingOccurrences(of: #"(?i)\s*\b(?:to|on|in|into) my calendar\b"#, with: "",
                                                    options: .regularExpression)
            let (title, start, duration) = extractDateRange(from: cleaned, now: now)
            if let start, hasTime(cleaned), !title.isEmpty, start > now.addingTimeInterval(-3600) {
                return .event(title: title, start: start, end: start.addingTimeInterval(duration ?? 30 * 60))
            }
        }
        return nil
    }

    private static func capture(_ pattern: String, in text: String) -> String? {
        guard let rx = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]),
              let m = rx.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              m.numberOfRanges > 1, let r = Range(m.range(at: 1), in: text) else { return nil }
        let s = String(text[r]).trimmingCharacters(in: .whitespacesAndNewlines)
        return s.isEmpty ? nil : s
    }

    /// Finds a date phrase, removes it (and a dangling "at/on/by/in"), returns both.
    static func extractDateRange(from body: String, now: Date) -> (String, Date?, TimeInterval?) {
        let cal = Calendar.current
        let ns = body as NSString

        // 1. "in 20 minutes" / "in 2 hours" / "in half an hour" — the detector misses these.
        if let rx = try? NSRegularExpression(pattern: #"(?i)\bin (\d+|an?|one|two|three|half an?) (minutes?|mins?|hours?|hrs?)\b"#),
           let m = rx.firstMatch(in: body, range: NSRange(location: 0, length: ns.length)) {
            let n = ns.substring(with: m.range(at: 1)).lowercased()
            let unit = ns.substring(with: m.range(at: 2)).lowercased()
            let value: Double = ["a": 1, "an": 1, "one": 1, "two": 2, "three": 3, "half a": 0.5, "half an": 0.5][n] ?? Double(n) ?? 1
            let secs = value * (unit.hasPrefix("h") ? 3600 : 60)
            return (tidy(ns.replacingCharacters(in: m.range, with: "")), now.addingTimeInterval(secs), nil)
        }

        var date: Date?
        var duration: TimeInterval?
        var title = body
        if let det = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.date.rawValue),
           let m = det.matches(in: body, range: NSRange(location: 0, length: ns.length)).last, var d = m.date {
            // The detector resolves "tomorrow" / "next Monday" against the real
            // clock; re-anchor relative phrases on `now` (absolute dates stay put).
            let phrase = ns.substring(with: m.range).lowercased()
            let shift = cal.dateComponents([.day], from: cal.startOfDay(for: Date()), to: cal.startOfDay(for: now)).day ?? 0
            if shift != 0 {
                if phrase.range(of: #"\b(monday|tuesday|wednesday|thursday|friday|saturday|sunday)\b"#, options: .regularExpression) != nil {
                    // "Friday" / "next Monday" = the coming one: first such weekday after `now`'s day.
                    let want = cal.component(.weekday, from: d)
                    let time = cal.dateComponents([.hour, .minute], from: d)
                    for k in 1...7 {
                        if let day = cal.date(byAdding: .day, value: k, to: cal.startOfDay(for: now)),
                           cal.component(.weekday, from: day) == want {
                            d = cal.date(bySettingHour: time.hour ?? 0, minute: time.minute ?? 0, second: 0, of: day) ?? d
                            break
                        }
                    }
                } else if phrase.range(of: #"\b(today|tonight|tomorrow|yesterday|in \d+ (day|week)s?)\b"#, options: .regularExpression) != nil {
                    d = cal.date(byAdding: .day, value: shift, to: d) ?? d
                }
            }
            date = d
            duration = m.duration > 0 ? m.duration : nil
            title = ns.replacingCharacters(in: m.range, with: "")
        }

        // 2. Bare "at 4" / "at 4:30" (no am/pm) — the detector often misses it or reads 4am.
        let bare = try? NSRegularExpression(pattern: #"(?i)\bat (\d{1,2})(?::(\d{2}))?\b(?!\s*(?:am|pm|a\.m|p\.m))"#)
        let tns = title as NSString
        if let rx = bare, let m = rx.firstMatch(in: title, range: NSRange(location: 0, length: tns.length)) {
            var hour = Int(tns.substring(with: m.range(at: 1))) ?? 0
            let minute = m.range(at: 2).location != NSNotFound ? Int(tns.substring(with: m.range(at: 2))) ?? 0 : 0
            if (1...7).contains(hour) { hour += 12 }                 // "at 4" in a workday means 4pm
            let day = date ?? now
            if var d = cal.date(bySettingHour: hour % 24, minute: minute, second: 0, of: day) {
                if date == nil && d < now { d = cal.date(byAdding: .day, value: 1, to: d) ?? d }
                date = d
                title = tns.replacingCharacters(in: m.range, with: "")
            }
        } else if let d = date {
            // Detector read "4" as 4am: people mean the afternoon.
            let hour = cal.component(.hour, from: d)
            let said = body.lowercased()
            if (1...7).contains(hour) && !said.contains("am") && !said.contains("a.m") && hasTime(body) {
                date = d.addingTimeInterval(12 * 3600)
            }
        }
        return (tidy(title), date, duration)
    }

    /// Did the user actually say a time (not just a day)?
    static func hasTime(_ text: String) -> Bool {
        text.range(of: #"(?i)\b\d{1,2}(:\d{2})?\s*(am|pm|a\.m\.|p\.m\.)|\b\d{1,2}:\d{2}\b|\bat \d{1,2}\b|\bnoon\b|\bmidnight\b|\bin (\d+|an?|half an?) (min|hour|hr)"#,
                   options: .regularExpression) != nil
    }

    private static func tidy(_ s: String) -> String {
        var t = s.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespaces)
        t = t.replacingOccurrences(of: #"(?i)\s+(?:at|on|by|in|for|from|this|next)\s*$"#, with: "", options: .regularExpression)
        t = t.replacingOccurrences(of: #"(?i)^(?:to|that)\s+"#, with: "", options: .regularExpression)
        t = t.trimmingCharacters(in: CharacterSet(charactersIn: " ,.;:-–"))
        return t.prefix(1).uppercased() + t.dropFirst()
    }

    // MARK: human wording

    static func describe(_ intent: QuickIntent) -> String {
        switch intent {
        case let .reminder(title, due, timed):
            guard let due else { return "Added to Reminders: “\(title)”." }
            return "Reminder set: “\(title)” — \(timed ? friendly(due) : dayOnly(due))."
        case .note:
            return "Saved to your notes."
        case let .event(title, start, end):
            return "Added to your calendar: “\(title)”, \(friendly(start)) – \(timeOnly(end))."
        }
    }

    static func friendly(_ d: Date) -> String {
        let cal = Calendar.current
        let t = timeOnly(d)
        if cal.isDateInToday(d) { return "today at \(t)" }
        if cal.isDateInTomorrow(d) { return "tomorrow at \(t)" }
        let f = DateFormatter(); f.dateFormat = "EEEE d MMM"
        return "\(f.string(from: d)) at \(t)"
    }

    static func dayOnly(_ d: Date) -> String {
        let cal = Calendar.current
        if cal.isDateInToday(d) { return "today" }
        if cal.isDateInTomorrow(d) { return "tomorrow" }
        let f = DateFormatter(); f.dateFormat = "EEEE d MMM"
        return f.string(from: d)
    }

    static func timeOnly(_ d: Date) -> String {
        let f = DateFormatter(); f.timeStyle = .short; f.dateStyle = .none
        return f.string(from: d)
    }
}

/// Performs a quick-capture intent against EventKit / notes, with undo.
@MainActor
final class QuickCaptureRunner {
    private let calendar: CalendarStore
    private let notes: NotesStore
    private var lastUndo: (() -> Void)?

    init(calendar: CalendarStore, notes: NotesStore) {
        self.calendar = calendar
        self.notes = notes
    }

    /// Returns the confirmation text, or an error message.
    func run(_ intent: QuickIntent) -> (ok: Bool, message: String) {
        switch intent {
        case let .note(body):
            let stamp = QuickCapture.friendly(Date())
            let line = "- \(body)  _(\(stamp))_"
            let before = notes.text
            notes.text = before.isEmpty ? line : before.trimmingCharacters(in: .newlines) + "\n" + line
            lastUndo = { [weak notes] in notes?.text = before }
            return (true, QuickCapture.describe(intent))
        case let .reminder(title, due, timed):
            guard calendar.remindersOK else { return (false, "needs-reminders") }
            guard let id = calendar.addReminder(title, due: due, timed: timed) else { return (false, "Couldn't save the reminder.") }
            lastUndo = { [weak calendar] in calendar?.deleteItem(id) }
            return (true, QuickCapture.describe(intent))
        case let .event(title, start, end):
            guard calendar.eventsOK else { return (false, "needs-calendar") }
            guard let id = calendar.addEvent(title, start: start, end: end) else { return (false, "Couldn't save the event.") }
            lastUndo = { [weak calendar] in calendar?.deleteItem(id) }
            return (true, QuickCapture.describe(intent))
        }
    }

    func undo() -> Bool {
        guard let u = lastUndo else { return false }
        u()
        lastUndo = nil
        return true
    }
}
