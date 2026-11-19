import AppKit
import EventKit
import Foundation

// Every calendar account the Mac knows (iCloud, Google — several accounts — Exchange, …) through EventKit,
// plus real invitations. EventKit can't add invitees (attendees are read-only), so `invite_event` opens the
// account's own "new event" page prefilled — Google Calendar (guests, the right Google account, one-click Meet)
// or Outlook — and the user clicks Save there; that's when the invites go out. No keys, no OAuth.
// Google accounts reach EventKit when added in System Settings › Internet Accounts.

/// Pure rules (checked in AgentChecks).
enum CalendarLogic {
    struct Cal: Equatable {
        let title: String
        let account: String        // EKSource title: an email for Google/Exchange, "iCloud", "On My Mac"…
        let writable: Bool
        var isGoogle = false
    }

    /// The calendar a request means: exact title, then "title (account)", then the account (its first writable
    /// calendar, preferring one named like the account), then a unique partial title. Nil = ambiguous or none.
    static func pick(_ cals: [Cal], query: String?) -> Cal? {
        let w = cals.filter(\.writable)
        guard let q = query?.trimmingCharacters(in: .whitespaces).lowercased(), !q.isEmpty else { return nil }
        if let c = w.first(where: { "\($0.title) (\($0.account))".lowercased() == q }) { return c }
        let exact = w.filter { $0.title.lowercased() == q }
        if exact.count == 1 { return exact[0] }
        let byAccount = w.filter { $0.account.lowercased() == q }
        if !byAccount.isEmpty { return byAccount.first { $0.title.lowercased() == q } ?? byAccount[0] }
        let partial = w.filter { $0.title.lowercased().contains(q) || $0.account.lowercased().contains(q) }
        return partial.count == 1 ? partial[0] : nil
    }

    /// A video-call link in an event's URL, location or notes.
    static func joinLink(_ texts: [String?]) -> String? {
        let pattern = #"https?://(meet\.google\.com/[a-z0-9-]+|([a-z0-9-]+\.)?zoom\.us/(j|my)/[^\s<>"]+|teams\.microsoft\.com/l/meetup-join/[^\s<>"]+|teams\.live\.com/meet/[^\s<>"]+|[a-z0-9-]+\.webex\.com/[^\s<>"]+|facetime\.apple\.com/join[^\s<>"]*)"#
        for t in texts.compactMap({ $0 }) {
            if let r = t.range(of: pattern, options: [.regularExpression, .caseInsensitive]) { return String(t[r]) }
        }
        return nil
    }

    /// The accounts, each with its calendars — what `calendars_list` returns.
    static func listing(_ cals: [Cal]) -> String {
        guard !cals.isEmpty else {
            return "No calendars. To add Google (any number of accounts), Exchange or Outlook: System Settings › Internet Accounts "
                + "(the open tool can open x-apple.systempreferences:com.apple.Internet-Accounts-Settings.extension)."
        }
        var order: [String] = []
        var by: [String: [Cal]] = [:]
        for c in cals { if by[c.account] == nil { order.append(c.account) }; by[c.account, default: []].append(c) }
        var lines = order.map { acct -> String in
            let cs = by[acct] ?? []
            let tag = cs.contains(where: \.isGoogle) ? " [Google]" : ""
            return "\(acct)\(tag): " + cs.map { $0.title + ($0.writable ? "" : " (read-only)") }.joined(separator: ", ")
        }
        if !cals.contains(where: \.isGoogle) {
            lines.append("(No Google account yet — add one in System Settings › Internet Accounts to see and use Google Calendar.)")
        }
        return lines.joined(separator: "\n")
    }

    static func isEmail(_ s: String) -> Bool {
        s.range(of: #"^[^@\s,;<>]+@[^@\s,;<>]+\.[a-z]{2,}$"#, options: [.regularExpression, .caseInsensitive]) != nil
    }

    static func guests(_ s: String?) -> (ok: [String], bad: [String]) {
        let parts = (s ?? "").split(whereSeparator: { ",; \n".contains($0) }).map(String.init).filter { !$0.isEmpty }
        var seen = Set<String>(), ok: [String] = [], bad: [String] = []
        for p in parts {
            if isEmail(p) { if seen.insert(p.lowercased()).inserted { ok.append(p) } } else { bad.append(p) }
        }
        return (ok, bad)
    }

    /// Google Calendar's prefilled "new event" page. `authuser` picks the Google account (multi-account browsers).
    static func googleURL(title: String, start: Date, end: Date, details: String?, location: String?,
                          guests: [String], account: String?, zone: TimeZone = .current) -> URL? {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = "yyyyMMdd'T'HHmmss'Z'"
        var c = URLComponents(string: "https://calendar.google.com/calendar/render")
        var q = [URLQueryItem(name: "action", value: "TEMPLATE"), URLQueryItem(name: "text", value: title),
                 URLQueryItem(name: "dates", value: f.string(from: start) + "/" + f.string(from: end)),
                 URLQueryItem(name: "ctz", value: zone.identifier)]
        if let details, !details.isEmpty { q.append(URLQueryItem(name: "details", value: details)) }
        if let location, !location.isEmpty { q.append(URLQueryItem(name: "location", value: location)) }
        if !guests.isEmpty { q.append(URLQueryItem(name: "add", value: guests.joined(separator: ","))) }
        if let account, isEmail(account) { q.append(URLQueryItem(name: "authuser", value: account)) }
        c?.queryItems = q
        return c?.url
    }

    /// Outlook on the web (work or personal) compose page.
    static func outlookURL(title: String, start: Date, end: Date, details: String?, location: String?,
                           guests: [String], personal: Bool) -> URL? {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        var c = URLComponents(string: personal ? "https://outlook.live.com/calendar/0/deeplink/compose"
                                                : "https://outlook.office.com/calendar/0/deeplink/compose")
        var q = [URLQueryItem(name: "subject", value: title), URLQueryItem(name: "startdt", value: f.string(from: start)),
                 URLQueryItem(name: "enddt", value: f.string(from: end)), URLQueryItem(name: "path", value: "/calendar/action/compose")]
        if let details, !details.isEmpty { q.append(URLQueryItem(name: "body", value: details)) }
        if let location, !location.isEmpty { q.append(URLQueryItem(name: "location", value: location)) }
        if !guests.isEmpty { q.append(URLQueryItem(name: "to", value: guests.joined(separator: ","))) }
        c?.queryItems = q
        return c?.url
    }

    /// Which service an invite goes through: asked for, else the account's kind, else Google.
    static func service(asked: String?, account: String?) -> String {
        if let a = asked?.lowercased(), ["google", "outlook", "outlook_personal"].contains(a) { return a }
        let acct = account?.lowercased() ?? ""
        if acct.hasSuffix("@outlook.com") || acct.hasSuffix("@hotmail.com") || acct.hasSuffix("@live.com") { return "outlook_personal" }
        return "google"
    }
}

enum CalendarTools {
    static func all() -> [AgentTool] { [calendarsList, invite] }

    static let calendarsList = AgentTool(
        name: "calendars_list",
        description: "Every calendar account on this Mac (iCloud, each Google account, Exchange…) with its calendars. "
            + "Use it to pick a calendar for create_event or the Google account for invite_event.",
        schema: Schema.object([:]),
        risk: .read, verb: "Checking calendars", detail: { _ in "" }, preview: { _ in "" },
        run: { _ in
            if let no = await ToolKit.ensureAccess(.event) { return .fail(no) }
            return ToolOutcome(ok: true, text: CalendarLogic.listing(cals()))
        })

    static let invite = AgentTool(
        name: "invite_event",
        description: "Invite people to a meeting. Opens the calendar's own new-event page (Google Calendar by default, or Outlook) "
            + "prefilled with title, time, guests, notes and the chosen account; the user adds Google Meet there and clicks Save, "
            + "which sends the invitations. Nothing is sent before that — say so. Use create_event for events without guests.",
        schema: Schema.object(["title": Schema.string("Title"), "start": Schema.string("Start (ISO 8601 local time)"),
                               "end": Schema.string("End (optional, default 30 minutes later)"),
                               "guests": Schema.string("Guest email addresses, comma-separated"),
                               "details": Schema.string("Agenda/notes (optional)"),
                               "location": Schema.string("Place or link (optional)"),
                               "account": Schema.string("Google account email to send from (optional; see calendars_list)"),
                               "service": Schema.enumeration("Where to create it (default: from the account, else google)",
                                                             ["google", "outlook", "outlook_personal"])],
                              required: ["title", "start", "guests"]),
        risk: .read, verb: "Preparing an invite", detail: { $0.str("title") ?? "" },
        preview: { "“\($0.str("title") ?? "")” with \($0.str("guests") ?? "")" },
        run: { a in
            guard let title = a.str("title"), let start = ToolKit.parseDate(a.str("start")) else {
                return .fail("title and a valid start time are required.")
            }
            let end = ToolKit.parseDate(a.str("end")) ?? start.addingTimeInterval(30 * 60)
            guard end > start else { return .fail("end must be after start.") }
            let g = CalendarLogic.guests(a.str("guests"))
            guard g.bad.isEmpty else { return .fail("These aren't email addresses: \(g.bad.joined(separator: ", ")) — use contacts_find first.") }
            guard !g.ok.isEmpty else { return .fail("Add at least one guest email (or use create_event for an event without guests).") }
            let service = CalendarLogic.service(asked: a.str("service"), account: a.str("account"))
            let url = service == "google"
                ? CalendarLogic.googleURL(title: title, start: start, end: end, details: a.str("details"), location: a.str("location"),
                                          guests: g.ok, account: a.str("account"))
                : CalendarLogic.outlookURL(title: title, start: start, end: end, details: a.str("details"), location: a.str("location"),
                                           guests: g.ok, personal: service == "outlook_personal")
            guard let url else { return .fail("Couldn't build the invite page.") }
            let opened = await MainActor.run { NSWorkspace.shared.open(url) }
            guard opened else { return .fail("Couldn't open the browser.") }
            let place = service == "google" ? "Google Calendar" + (a.str("account").map { " (\($0))" } ?? "") : "Outlook"
            return ToolOutcome(ok: true, text: "Opened \(place) with “\(title)” on "
                + DateFormatter.localizedString(from: start, dateStyle: .medium, timeStyle: .short)
                + " and \(g.ok.count) guest\(g.ok.count == 1 ? "" : "s"). NOT sent yet: the user clicks Save there"
                + (service == "google" ? " (and \"Add Google Meet video conferencing\" for a call link)" : "")
                + " — that sends the invitations.")
        })

    /// Calendars as plain values (EventKit stays here).
    static func cals() -> [CalendarLogic.Cal] {
        ToolKit.eventStore.calendars(for: .event).map(cal)
            .sorted { ($0.account, $0.title) < ($1.account, $1.title) }
    }

    static func cal(_ c: EKCalendar) -> CalendarLogic.Cal {
        let src = c.source
        let account = src?.title ?? "Other"
        let google = account.lowercased().hasSuffix("@gmail.com") || account.lowercased().hasSuffix("@googlemail.com")
            || (src?.sourceType == .calDAV && (c.calendarIdentifier.contains("google") || account.lowercased().contains("google")))
        return CalendarLogic.Cal(title: c.title, account: account, writable: c.allowsContentModifications, isGoogle: google)
    }

    static func ekCalendar(for pick: CalendarLogic.Cal) -> EKCalendar? {
        ToolKit.eventStore.calendars(for: .event).first { $0.title == pick.title && ($0.source?.title ?? "Other") == pick.account }
    }
}
